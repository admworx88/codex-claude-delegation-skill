$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TaskExample = Join-Path $RepoRoot 'delegating-to-claude-code/references/task-packet.example.json'
$ResultSchema = Join-Path $RepoRoot 'delegating-to-claude-code/references/result-schema.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
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
New-Item -ItemType Directory -Force -Path $mainRepo | Out-Null
git -C $mainRepo init | Out-Null
git -C $mainRepo config user.email 'tests@example.invalid'
git -C $mainRepo config user.name 'Delegation Tests'
Set-Content -LiteralPath (Join-Path $mainRepo 'seed.txt') -Value 'seed'
git -C $mainRepo add seed.txt
git -C $mainRepo commit -m seed | Out-Null
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
git -C $mainRepo worktree add -b feature/test $linked 2>&1 | Out-Null
$ErrorActionPreference = $savedErrorActionPreference

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
Assert-True ((Get-Content -Raw (Join-Path $linked '.gitignore')) -match '\.codex/claude-handoff/') 'gitignore missing handoff rule'
