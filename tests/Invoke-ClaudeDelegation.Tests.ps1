$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TaskExample = Join-Path $RepoRoot 'delegating-to-claude-code/references/task-packet.example.json'
$ResultSchema = Join-Path $RepoRoot 'delegating-to-claude-code/references/result-schema.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-TestGit([string]$Path, [string[]]$Arguments) {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Path @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Test Git command failed: git -C $Path $($Arguments -join ' '): $($output -join [Environment]::NewLine)"
    }
    return $output
}

Assert-True (Test-Path -LiteralPath $TaskExample) 'task example must exist'
Assert-True (Test-Path -LiteralPath $ResultSchema) 'result schema must exist'

$task = Get-Content -Raw -LiteralPath $TaskExample | ConvertFrom-Json
$schema = Get-Content -Raw -LiteralPath $ResultSchema | ConvertFrom-Json
$requiredTaskFields = @(
    'id', 'goal', 'mode', 'allowedPaths', 'forbiddenPaths',
    'forbiddenActions', 'context', 'acceptanceCriteria',
    'requiredVerification', 'limits'
)
foreach ($field in $requiredTaskFields) {
    Assert-True ($null -ne $task.$field) "task example missing $field"
}
Assert-True (@('direct', 'subagents', 'agent-team') -contains $task.mode) 'invalid mode'
foreach ($field in @('taskId', 'status', 'summary', 'changedFiles', 'tests', 'unresolvedIssues', 'deviations')) {
    Assert-True ($schema.required -contains $field) "result schema missing $field"
}

$Runner = Join-Path $RepoRoot 'delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1'
. $Runner -LibraryMode

$parsedExample = Read-TaskPacket -Path $TaskExample
Assert-True ($parsedExample.id -eq 'task-001') 'task packet reader did not return the parsed packet'

$missingContextPacket = $task | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$missingContextPacket.PSObject.Properties.Remove('context')
$missingContextPath = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-delegation-missing-context-" + [guid]::NewGuid() + '.json')
try {
    $missingContextPacket | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $missingContextPath -Encoding UTF8
    $missingContextRejected = $false
    try { Read-TaskPacket -Path $missingContextPath | Out-Null } catch { $missingContextRejected = $true }
    Assert-True $missingContextRejected 'task packet reader must require context'
} finally {
    if (Test-Path -LiteralPath $missingContextPath) { Remove-Item -LiteralPath $missingContextPath -Force }
}

$direct = [pscustomobject]@{
    id='task-direct'; goal='Fix one parser'; mode='direct'
    allowedPaths=@('src/parser.ps1'); forbiddenPaths=@('.git/**')
    forbiddenActions=@('git commit'); context=@()
    acceptanceCriteria=@('Focused tests pass'); requiredVerification=@('Run parser tests')
    limits=[pscustomobject]@{ maxTurns=20; timeoutSeconds=900; maxBudgetUsd=3.0 }
}
$directInvocation = New-ClaudeInvocation -Task $direct -SessionId 'session-123' -SupportsForwarding $true
Assert-True ($directInvocation.arguments -contains '--resume') 'direct mode must resume primary session'
Assert-True (-not $directInvocation.environment.ContainsKey('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')) 'direct mode enabled teams'
$expectedGitDenyPatterns = @(
    'Bash(git *)', 'Bash(git.exe *)',
    'Bash(* git *)', 'Bash(* git.exe *)',
    'Bash(*\git *)', 'Bash(*\git.exe *)',
    'Bash(*/git *)', 'Bash(*/git.exe *)'
)
foreach ($denyPattern in $expectedGitDenyPatterns) {
    Assert-True ($directInvocation.arguments -contains $denyPattern) "git wrapper deny rule missing: $denyPattern"
}
Assert-True ($directInvocation.arguments -contains '--output-format') 'output-format flag missing'
Assert-True ($directInvocation.arguments[[Array]::IndexOf([object[]]$directInvocation.arguments, '--output-format') + 1] -eq 'json') 'direct mode output must remain JSON'

$zeroBudget = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$zeroBudget.limits.maxBudgetUsd = 0
$zeroBudgetInvocation = New-ClaudeInvocation -Task $zeroBudget -SessionId 'session-123' -SupportsForwarding $true
$zeroBudgetIndex = [Array]::IndexOf([object[]]$zeroBudgetInvocation.arguments, '--max-budget-usd')
Assert-True ($zeroBudgetIndex -ge 0) 'explicit zero budget must not be omitted'
Assert-True ($zeroBudgetInvocation.arguments[$zeroBudgetIndex + 1] -eq '0') 'explicit zero budget was not preserved'

foreach ($invalidLimit in @(
    [pscustomobject]@{ property = 'maxTurns'; value = 0; message = 'zero maxTurns must be rejected' },
    [pscustomobject]@{ property = 'maxTurns'; value = 1.5; message = 'fractional maxTurns must be rejected' },
    [pscustomobject]@{ property = 'timeoutSeconds'; value = 0; message = 'zero timeoutSeconds must be rejected' },
    [pscustomobject]@{ property = 'maxBudgetUsd'; value = -0.01; message = 'negative maxBudgetUsd must be rejected' }
)) {
    $invalidTask = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidTask.limits.($invalidLimit.property) = $invalidLimit.value
    $invalidRejected = $false
    try { Assert-DelegationPolicy -Task $invalidTask } catch { $invalidRejected = $true }
    Assert-True $invalidRejected $invalidLimit.message
}
$missingTurns = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$missingTurns.limits.PSObject.Properties.Remove('maxTurns')
$missingTurnsRejected = $false
try { Assert-DelegationPolicy -Task $missingTurns } catch { $missingTurnsRejected = $true }
Assert-True $missingTurnsRejected 'missing maxTurns must be rejected'

$subagents = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$subagents.mode = 'subagents'
$subagentInvocation = New-ClaudeInvocation -Task $subagents -SessionId 'session-123' -SupportsForwarding $true
Assert-True (-not $subagentInvocation.freshSession) 'subagents mode must reuse the primary session'
Assert-True ($subagentInvocation.arguments -contains '--resume') 'subagents mode must resume primary session'
Assert-True ($subagentInvocation.arguments -contains '--forward-subagent-text') 'subagents forwarding missing'
Assert-True ($subagentInvocation.arguments[[Array]::IndexOf([object[]]$subagentInvocation.arguments, '--output-format') + 1] -eq 'stream-json') 'subagents mode must use stream JSON when forwarding'
$subagentWithoutForwarding = New-ClaudeInvocation -Task $subagents -SessionId 'session-123' -SupportsForwarding $false
Assert-True (-not ($subagentWithoutForwarding.arguments -contains '--forward-subagent-text')) 'unsupported versions must not receive forwarding'
Assert-True ($subagentWithoutForwarding.arguments[[Array]::IndexOf([object[]]$subagentWithoutForwarding.arguments, '--output-format') + 1] -eq 'json') 'unsupported versions must retain JSON output'

$team = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$team.mode = 'agent-team'
$team | Add-Member -NotePropertyName parallelWorkstreams -NotePropertyValue @(
    [pscustomobject]@{ name='api'; ownedPaths=@('src/api/**') },
    [pscustomobject]@{ name='ui'; ownedPaths=@('src/ui/**') }
)
$teamInvocation = New-ClaudeInvocation -Task $team -SessionId 'session-123' -SupportsForwarding $true
Assert-True ($teamInvocation.freshSession) 'team mode must use a fresh session'
Assert-True ($teamInvocation.environment['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] -eq '1') 'team env missing'
Assert-True ($teamInvocation.arguments -contains '--forward-subagent-text') 'stream forwarding missing'
Assert-True (-not ($teamInvocation.arguments -contains '--resume')) 'team mode must not resume a prior session'
Assert-True (Test-ForwardSubagentSupport -VersionText '2.1.211 (Claude Code)') 'supported forwarding version rejected'
Assert-True (-not (Test-ForwardSubagentSupport -VersionText '2.1.210 (Claude Code)')) 'unsupported forwarding version accepted'
Assert-True (-not (Test-ForwardSubagentSupport -VersionText 'invalid')) 'invalid forwarding version accepted'
Assert-True (-not (Test-ForwardSubagentSupport -VersionText 'Claude Code 2.1.211')) 'embedded forwarding version accepted'

$overlap = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$overlap.parallelWorkstreams = @(
    [pscustomobject]@{ name='one'; ownedPaths=@('src/**') },
    [pscustomobject]@{ name='two'; ownedPaths=@('src/api/**') }
)
$rejected = $false
try { Assert-DelegationPolicy -Task $overlap } catch { $rejected = $true }
Assert-True $rejected 'overlapping team ownership must be rejected'

$mixedSeparatorOverlap = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$mixedSeparatorOverlap.parallelWorkstreams = @(
    [pscustomobject]@{ name='one'; ownedPaths=@('src\api\**') },
    [pscustomobject]@{ name='two'; ownedPaths=@('src/api/**') }
)
$rejected = $false
try { Assert-DelegationPolicy -Task $mixedSeparatorOverlap } catch { $rejected = $true }
Assert-True $rejected 'mixed path separators must still overlap'

$boundaryDistinct = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$boundaryDistinct.parallelWorkstreams = @(
    [pscustomobject]@{ name='api'; ownedPaths=@('src/api/**') },
    [pscustomobject]@{ name='api-client'; ownedPaths=@('src/api-client/**') }
)
Assert-DelegationPolicy -Task $boundaryDistinct

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-delegation-" + [guid]::NewGuid())
$mainRepo = Join-Path $fixtureRoot 'main'
$linked = Join-Path $fixtureRoot 'feature'
$fixtureFailure = $null
$fixtureCleaned = $false
try {
    New-Item -ItemType Directory -Force -Path $mainRepo | Out-Null
    Invoke-TestGit $mainRepo @('init') | Out-Null
    Invoke-TestGit $mainRepo @('config', 'user.email', 'tests@example.invalid') | Out-Null
    Invoke-TestGit $mainRepo @('config', 'user.name', 'Delegation Tests') | Out-Null
    $invalidGitRejected = $false
    try { Invoke-TestGit $mainRepo @('show', '--format=%H', 'not-a-real-revision') | Out-Null } catch { $invalidGitRejected = $true }
    Assert-True $invalidGitRejected 'test Git helper must reject nonzero exit codes'
    Set-Content -LiteralPath (Join-Path $mainRepo 'seed.txt') -Value 'seed'
    Invoke-TestGit $mainRepo @('add', 'seed.txt') | Out-Null
    Invoke-TestGit $mainRepo @('commit', '-m', 'seed') | Out-Null
    Invoke-TestGit $mainRepo @('worktree', 'add', '-b', 'feature/test', $linked) | Out-Null
    Set-Content -LiteralPath (Join-Path $linked '.gitignore') -Value 'existing-rule'

    $mainContext = Get-WorktreeContext -WorktreePath $mainRepo
    $linkedContext = Get-WorktreeContext -WorktreePath $linked
    Assert-True ($mainContext.gitDir -eq $mainContext.commonDir) 'main checkout detection failed'
    Assert-True ($linkedContext.gitDir -ne $linkedContext.commonDir) 'linked worktree detection failed'

    $rejected = $false
    try { Assert-LinkedWorktree -Context $mainContext } catch { $rejected = $true }
    Assert-True $rejected 'main checkout must be rejected'
    Assert-LinkedWorktree -Context $linkedContext

    $state = Initialize-HandoffState -Context $linkedContext
    Assert-True (Test-Path -LiteralPath $state.ledgerPath) 'ledger was not created'
    $ignoreLines = Get-Content -LiteralPath (Join-Path $linked '.gitignore')
    Assert-True ($ignoreLines -contains 'existing-rule') 'gitignore did not preserve existing content'
    Assert-True ($ignoreLines -contains '.codex/claude-handoff/') 'gitignore missing handoff rule'

    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    Assert-True ($ledger.version -eq 1) 'ledger version must be 1'
    foreach ($field in @('repositoryId', 'worktreePath', 'branch', 'primarySessionId', 'tasks')) {
        Assert-True ($ledger.PSObject.Properties.Name -contains $field) "ledger missing $field"
    }
    Assert-True ($ledger.repositoryId -eq $linkedContext.repositoryId) 'ledger repository ID mismatch'
    Assert-True ($ledger.worktreePath -eq $linkedContext.worktreePath) 'ledger worktree path mismatch'
    Assert-True ($ledger.branch -eq $linkedContext.branch) 'ledger branch mismatch'
    Assert-True (@($ledger.tasks).Count -eq 0) 'new ledger tasks must be empty'

    $fakeClaude = Join-Path $fixtureRoot 'fake-claude.cmd'
    @'
@echo off
if not "%1"=="auth" goto version
if not "%2"=="status" goto version
echo {"loggedIn":true}
exit /b 0
:version
if not "%1"=="--version" goto modes
echo 2.1.211 ^(Claude Code^)
exit /b 0
:modes
if "%CLAUDE_FAKE_MODE%"=="malformed" (
  echo not-json
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="timeout" (
  ping 127.0.0.1 -n 6 >nul
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="allowed-edit" (
  echo delegated-change>>"%CD%\src\parser.ps1"
)
if "%CLAUDE_FAKE_MODE%"=="forbidden-edit" (
  if not exist "%CD%\.github\workflows" mkdir "%CD%\.github\workflows"
  echo forbidden>"%CD%\.github\workflows\ci.yml"
)
if "%CLAUDE_FAKE_MODE%"=="remote-change" (
  git -C "%CD%" remote add delegation-evil https://example.invalid/evil.git
)
if not "%CLAUDE_FAKE_MODE%"=="missing-session" goto output
if exist "%CD%\.codex\claude-handoff\missing-session-attempted" goto output
echo attempted>"%CD%\.codex\claude-handoff\missing-session-attempted"
echo session not found 1>&2
exit /b 1
:output
set TASK_ID=%CLAUDE_FAKE_TASK%
if "%TASK_ID%"=="" set TASK_ID=task-direct
set SESSION_ID=%CLAUDE_FAKE_SESSION%
if "%SESSION_ID%"=="" set SESSION_ID=fake-session
echo {"type":"result","session_id":"%SESSION_ID%","result":{"taskId":"%TASK_ID%","status":"completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
exit /b 0
'@ | Set-Content -LiteralPath $fakeClaude -Encoding ASCII

    Assert-True (Test-ClaudeAvailable $fakeClaude) 'fake Claude command was not detected'
    Assert-True (Test-ClaudeAuthenticated $fakeClaude) 'fake Claude authentication was not detected'
    Assert-True (-not (Test-ClaudeAuthenticated (Join-Path $fixtureRoot 'missing-claude.cmd'))) 'missing Claude command was treated as authenticated'

    $capturedStartProcess = $null
    function Start-Process {
        param(
            [string]$FilePath,
            [object[]]$ArgumentList,
            [string]$WorkingDirectory
        )
        $script:capturedStartProcess = [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            WorkingDirectory = $WorkingDirectory
        }
    }
    try {
        Show-OwnerSetup -Worktree $linked -Installed $true
        $setupArguments = @($capturedStartProcess.ArgumentList) -join ' '
        Assert-True ($setupArguments -match 'claude auth login') 'owner setup did not offer authentication'
        Assert-True ($setupArguments -notmatch 'dangerously-skip-permissions') 'owner setup received bypass permissions'
        Assert-True ($capturedStartProcess.WorkingDirectory -eq $linked) 'owner setup used the wrong working directory'
    } finally {
        Remove-Item -Path Function:\Start-Process -Force
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $linked 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $linked 'src/parser.ps1') -Value 'dirty-before-delegation'
    $executionTask = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $executionTask.forbiddenPaths = @('.git/**', '.github/**')
    $taskPath = Join-Path $state.stateDir 'task-direct.json'
    $executionTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $taskPath -Encoding UTF8

    $successJson = (& $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-String).Trim()
    $successResult = $successJson | ConvertFrom-Json
    Assert-True ($successResult.taskId -eq 'task-direct') 'runner did not return normalized task JSON'
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $successRecord = @($ledger.tasks)[-1]
    $successRawOutput = Get-Content -Raw -LiteralPath $successRecord.rawOutputPath
    $successRawError = Get-Content -Raw -LiteralPath $successRecord.rawErrorPath
    Assert-True ($ledger.primarySessionId -eq 'fake-session') "session ID was not persisted; exit: $($successRecord.exitCode); raw output: $successRawOutput; raw error: $successRawError"
    Assert-True ($successRecord.status -eq 'needs-review') 'Claude completion must require Codex review'
    Assert-True (Test-Path -LiteralPath $successRecord.rawOutputPath) 'raw output was not captured'
    Assert-True (Test-Path -LiteralPath $successRecord.rawErrorPath) 'raw error was not captured'
    Assert-True (Test-Path -LiteralPath $successRecord.resultPath) 'normalized result was not captured'
    Assert-True (@($successRecord.attempts).Count -eq 1) 'successful execution must record one attempt'

    $lockPath = $state.lockPath
    Set-Content -LiteralPath $lockPath -Value 'busy'
    $locked = $false
    try { & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null } catch { $locked = $true }
    Assert-True $locked 'concurrent task lock was not enforced'
    Assert-True (Test-Path -LiteralPath $lockPath) 'runner removed a lock it did not own'
    Remove-Item -LiteralPath $lockPath -Force

    $env:CLAUDE_FAKE_MODE = 'malformed'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $malformedRecord = @($ledger.tasks)[-1]
    Assert-True ($malformedRecord.status -eq 'needs-review') 'malformed output must require review'
    Assert-True ((Get-Content -Raw -LiteralPath $malformedRecord.rawOutputPath).Trim() -eq 'not-json') 'malformed raw output was not retained'

    $timeoutTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $timeoutTask.id = 'task-timeout'
    $timeoutTask.limits.timeoutSeconds = 1
    $timeoutPath = Join-Path $state.stateDir 'task-timeout.json'
    $timeoutTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $timeoutPath -Encoding UTF8
    $env:CLAUDE_FAKE_MODE = 'timeout'
    $env:CLAUDE_FAKE_TASK = 'task-timeout'
    $timeoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $timeoutPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        $timeoutStopwatch.Stop()
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $timeoutRecord = @($ledger.tasks)[-1]
    Assert-True ($timeoutRecord.status -eq 'needs-review') 'timeout must require review'
    Assert-True ([bool]$timeoutRecord.attempts[0].timedOut) 'timeout attempt was not identified'
    Assert-True ($timeoutStopwatch.Elapsed.TotalSeconds -lt 4) 'timeout waited for a descendant that inherited the output pipe'

    $beforeFingerprint = Get-WorktreeFingerprint -Worktree $linked
    Add-Content -LiteralPath (Join-Path $linked 'src/parser.ps1') -Value 'second-change'
    $afterFingerprint = Get-WorktreeFingerprint -Worktree $linked
    $fingerprintChanges = Compare-WorktreeFingerprint -Before $beforeFingerprint -After $afterFingerprint
    Assert-True ($fingerprintChanges -contains 'src/parser.ps1') 'hash fingerprint missed a second change to an already dirty file'

    $env:CLAUDE_FAKE_MODE = 'allowed-edit'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $allowedRecord = @($ledger.tasks)[-1]
    Assert-True ($allowedRecord.changedDuringTask -contains 'src/parser.ps1') 'runner missed a change to an already dirty allowed file'
    Assert-True (@($allowedRecord.scopeViolations).Count -eq 0) 'allowed path was rejected'

    $scopeViolations = Get-ScopeViolations -ChangedPaths @('.github/workflows/ci.yml', 'src/parser.ps1') -Task $executionTask
    Assert-True ($scopeViolations -contains '.github/workflows/ci.yml') 'forbidden path was not detected'
    Assert-True (-not ($scopeViolations -contains 'src/parser.ps1')) 'allowed path was rejected by the scope helper'

    $env:CLAUDE_FAKE_MODE = 'forbidden-edit'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $forbiddenRecord = @($ledger.tasks)[-1]
    Assert-True ($forbiddenRecord.status -eq 'rejected') 'scope violation was not rejected'
    Assert-True ($forbiddenRecord.scopeViolations -contains '.github/workflows/ci.yml') 'scope violation was not recorded'
    Assert-True (Test-Path -LiteralPath (Join-Path $linked '.github/workflows/ci.yml')) 'runner automatically reverted a rejected change'

    $env:CLAUDE_FAKE_MODE = 'remote-change'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $repositoryRecord = @($ledger.tasks)[-1]
    Assert-True ($repositoryRecord.status -eq 'rejected') 'remote mutation was not rejected'
    Assert-True ($repositoryRecord.repositoryViolations -contains 'remotes-changed') 'remote mutation was not recorded'
    $fixtureRemotes = Invoke-TestGit $linked @('remote')
    Assert-True ($fixtureRemotes -contains 'delegation-evil') 'runner automatically reverted a remote mutation'

    $env:CLAUDE_FAKE_MODE = 'missing-session'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $retryRecord = @($ledger.tasks)[-1]
    Assert-True (@($retryRecord.attempts).Count -eq 2) 'missing session was not retried exactly once'
    Assert-True ($retryRecord.attempts[0].exitCode -ne 0) 'missing-session attempt did not retain its failure'
    Assert-True ($retryRecord.attempts[1].exitCode -eq 0) 'fresh retry did not succeed'
    Assert-True ($ledger.primarySessionId -eq 'fake-session') 'fresh retry session was not persisted'

    $teamExecutionTask = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $teamExecutionTask.id = 'task-team'
    $teamTaskPath = Join-Path $state.stateDir 'task-team.json'
    $teamExecutionTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $teamTaskPath -Encoding UTF8
    $env:CLAUDE_FAKE_TASK = 'task-team'
    $env:CLAUDE_FAKE_SESSION = 'team-session'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $teamTaskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_SESSION -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $teamRecord = @($ledger.tasks)[-1]
    Assert-True ($teamRecord.sessionId -eq 'team-session') 'team session was not recorded on its task'
    Assert-True ($ledger.primarySessionId -eq 'fake-session') 'team session replaced the primary session'

    Invoke-TestGit $linked @('checkout', '--detach') | Out-Null
    $detachedContext = Get-WorktreeContext -WorktreePath $linked
    $detachedRejected = $false
    try { Assert-LinkedWorktree -Context $detachedContext } catch { $detachedRejected = $true }
    Assert-True $detachedRejected 'detached HEAD must be rejected'
} catch {
    $fixtureFailure = $_
} finally {
    try {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
        }
        $fixtureCleaned = -not (Test-Path -LiteralPath $fixtureRoot)
    } catch {
        if ($null -eq $fixtureFailure) { throw }
    }
}
if ($null -ne $fixtureFailure) { throw $fixtureFailure }
Assert-True $fixtureCleaned 'temporary Git fixture was not removed'
