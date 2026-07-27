[CmdletBinding()]
param(
    [string]$WorktreePath,
    [string]$TaskPacketPath,
    [string]$ClaudeCommand = 'claude',
    [switch]$DryRun,
    [switch]$LibraryMode
)

$ErrorActionPreference = 'Stop'

function Invoke-Git([string]$Path, [string[]]$Arguments) {
    $output = & git -C $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine).Trim()
}

function Resolve-AbsolutePath([string]$Path) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "Path must be absolute: $Path" }
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Get-WorktreeContext([string]$WorktreePath) {
    $resolved = Resolve-AbsolutePath $WorktreePath
    $gitDir = Invoke-Git $resolved @('rev-parse', '--absolute-git-dir')
    $commonDirRaw = Invoke-Git $resolved @('rev-parse', '--git-common-dir')
    $commonDir = if ([System.IO.Path]::IsPathRooted($commonDirRaw)) {
        [System.IO.Path]::GetFullPath($commonDirRaw)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $resolved $commonDirRaw))
    }
    [pscustomobject]@{
        worktreePath = $resolved
        gitDir = [System.IO.Path]::GetFullPath($gitDir)
        commonDir = $commonDir
        branch = Invoke-Git $resolved @('branch', '--show-current')
        repositoryId = Invoke-Git $resolved @('rev-parse', '--show-toplevel')
    }
}

function Assert-LinkedWorktree($Context) {
    if ($Context.gitDir -eq $Context.commonDir) { throw 'Delegation requires a linked Git worktree.' }
    if ([string]::IsNullOrWhiteSpace($Context.branch)) { throw 'Detached HEAD is not allowed.' }
}

function Initialize-HandoffState($Context) {
    $stateDir = Join-Path $Context.worktreePath '.codex/claude-handoff'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $ignorePath = Join-Path $Context.worktreePath '.gitignore'
    $rule = '.codex/claude-handoff/'
    $existing = if (Test-Path -LiteralPath $ignorePath) { Get-Content -LiteralPath $ignorePath } else { @() }
    if ($existing -notcontains $rule) { Add-Content -LiteralPath $ignorePath -Value $rule }
    $ledgerPath = Join-Path $stateDir 'ledger.json'
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        [ordered]@{
            version = 1
            repositoryId = $Context.repositoryId
            worktreePath = $Context.worktreePath
            branch = $Context.branch
            primarySessionId = $null
            tasks = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ledgerPath -Encoding UTF8
    }
    [pscustomobject]@{
        stateDir = $stateDir
        ledgerPath = $ledgerPath
        lockPath = Join-Path $stateDir 'running.lock'
    }
}

function Read-TaskPacket([string]$Path) {
    $resolved = Resolve-AbsolutePath $Path
    $task = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    foreach ($name in @('id', 'goal', 'mode', 'allowedPaths', 'forbiddenPaths', 'forbiddenActions', 'context', 'acceptanceCriteria', 'requiredVerification', 'limits')) {
        if ($null -eq $task.$name) { throw "Task packet missing required field: $name" }
    }
    Assert-DelegationPolicy -Task $task
    return $task
}

function Test-PathPatternOverlap([string]$Left, [string]$Right) {
    $a = (($Left -replace '\\', '/') -replace '/+', '/').TrimEnd([char[]]@('*', '/'))
    $b = (($Right -replace '\\', '/') -replace '/+', '/').TrimEnd([char[]]@('*', '/'))
    if ($a.Length -eq 0 -or $b.Length -eq 0) { return $true }
    return $a.Equals($b, [System.StringComparison]::OrdinalIgnoreCase) -or
           $a.StartsWith($b + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
           $b.StartsWith($a + '/', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PositiveInteger($Value) {
    $isInteger = $Value -is [byte] -or $Value -is [sbyte] -or
                 $Value -is [int16] -or $Value -is [uint16] -or
                 $Value -is [int32] -or $Value -is [uint32] -or
                 $Value -is [int64] -or $Value -is [uint64]
    return $isInteger -and $Value -gt 0
}

function Test-NonNegativeNumber($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $false }
    try { return [decimal]$Value -ge 0 } catch { return $false }
}

function Test-PositiveNumber($Value) {
    if (-not (Test-NonNegativeNumber $Value)) { return $false }
    return [decimal]$Value -gt 0
}

function Assert-TaskLimits($Limits) {
    if ($null -eq $Limits) { throw 'Task packet limits are required.' }
    $limitNames = $Limits.PSObject.Properties.Name
    if ($limitNames -notcontains 'maxTurns' -or -not (Test-PositiveInteger $Limits.maxTurns)) {
        throw 'limits.maxTurns must be a positive integer.'
    }
    if ($limitNames -notcontains 'timeoutSeconds' -or -not (Test-PositiveNumber $Limits.timeoutSeconds)) {
        throw 'limits.timeoutSeconds must be positive.'
    }
    if ($limitNames -contains 'maxBudgetUsd' -and -not (Test-NonNegativeNumber $Limits.maxBudgetUsd)) {
        throw 'limits.maxBudgetUsd must be non-negative when provided.'
    }
}

function Assert-DelegationPolicy($Task) {
    if (@('direct', 'subagents', 'agent-team') -notcontains $Task.mode) { throw "Unsupported mode: $($Task.mode)" }
    Assert-TaskLimits $Task.limits
    if ($Task.mode -ne 'agent-team') { return }

    $workstreams = @($Task.parallelWorkstreams)
    if ($workstreams.Count -lt 2) { throw 'Agent-team mode requires at least two workstreams.' }
    for ($i = 0; $i -lt $workstreams.Count; $i++) {
        if ($null -eq $workstreams[$i].ownedPaths -or @($workstreams[$i].ownedPaths).Count -eq 0) {
            throw "Agent-team workstream $i must declare ownedPaths."
        }
        for ($j = $i + 1; $j -lt $workstreams.Count; $j++) {
            if ($null -eq $workstreams[$j].ownedPaths -or @($workstreams[$j].ownedPaths).Count -eq 0) {
                throw "Agent-team workstream $j must declare ownedPaths."
            }
            foreach ($left in $workstreams[$i].ownedPaths) {
                foreach ($right in $workstreams[$j].ownedPaths) {
                    if (Test-PathPatternOverlap $left $right) { throw "Overlapping ownership: $left and $right" }
                }
            }
        }
    }
}

function Test-ForwardSubagentSupport([string]$VersionText) {
    $match = [regex]::Match($VersionText, '^\s*(\d+)\.(\d+)\.(\d+)(?:\s|$)')
    if (-not $match.Success) { return $false }
    $version = New-Object System.Version -ArgumentList @(
        [int]$match.Groups[1].Value,
        [int]$match.Groups[2].Value,
        [int]$match.Groups[3].Value
    )
    return $version -ge [version]'2.1.211'
}

function New-ClaudeInvocation($Task, [string]$SessionId, [bool]$SupportsForwarding) {
    Assert-DelegationPolicy -Task $Task
    $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/result-schema.json'
    $schema = (Get-Content -Raw -LiteralPath $schemaPath).Trim()
    $modeDirective = switch ($Task.mode) {
        'direct' { 'Work directly. Do not spawn subagents or teammates.' }
        'subagents' { 'Use focused Claude subagents for independent subtasks, then synthesize one result.' }
        'agent-team' { 'Create a small agent team from parallelWorkstreams. Enforce exclusive ownedPaths and stop all teammates before returning.' }
    }
    $prompt = "Execute the bounded task packet below. $modeDirective Do not commit, push, switch branches, modify remotes, or expand scope.`n`n" +
              ($Task | ConvertTo-Json -Depth 12)
    $args = @('-p', $prompt, '--dangerously-skip-permissions', '--output-format', 'json',
              '--json-schema', $schema, '--max-turns', [string]$Task.limits.maxTurns)
    $args += '--disallowedTools'
    $args += @(
        'Bash(git *)', 'Bash(git.exe *)',
        'Bash(* git *)', 'Bash(* git.exe *)',
        'Bash(*\git *)', 'Bash(*\git.exe *)',
        'Bash(*/git *)', 'Bash(*/git.exe *)'
    )

    $environment = @{}
    $fresh = $Task.mode -eq 'agent-team'
    if (-not $fresh -and $SessionId) { $args += @('--resume', $SessionId) }
    if ($Task.limits.PSObject.Properties.Name -contains 'maxBudgetUsd') {
        $args += @('--max-budget-usd', [string]$Task.limits.maxBudgetUsd)
    }
    if ($Task.mode -ne 'direct' -and $SupportsForwarding) {
        $outputIndex = [Array]::IndexOf([object[]]$args, '--output-format')
        $args[$outputIndex + 1] = 'stream-json'
        $args += @('--verbose', '--forward-subagent-text')
    }
    if ($fresh) { $environment['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1' }
    [pscustomobject]@{ arguments = [object[]]$args; environment = $environment; freshSession = $fresh }
}
