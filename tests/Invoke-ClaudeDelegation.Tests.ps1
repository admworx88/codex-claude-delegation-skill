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
