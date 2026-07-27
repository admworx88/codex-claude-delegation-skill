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
