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
    return (Get-Item -LiteralPath (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
}

function Get-DelegationPlatform() {
    if ($env:OS -eq 'Windows_NT' -or [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return 'Windows'
    }
    if ($PSVersionTable.PSVersion.Major -ge 7 -and
        [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return 'MacOS'
    }
    throw 'Claude delegation supports only Windows and macOS hosts.'
}

function Get-PathStringComparison([string]$Platform) {
    switch ($Platform) {
        'Windows' { return [System.StringComparison]::OrdinalIgnoreCase }
        'MacOS' { return [System.StringComparison]::Ordinal }
        default { throw "Unsupported delegation platform: $Platform" }
    }
}

function Test-CanonicalPathEqual([string]$Left, [string]$Right, [string]$Platform) {
    return [string]::Equals($Left, $Right, (Get-PathStringComparison -Platform $Platform))
}

function Get-WorktreeContext([string]$WorktreePath) {
    $resolved = Resolve-AbsolutePath $WorktreePath
    $topLevel = Resolve-AbsolutePath (Invoke-Git $resolved @('rev-parse', '--show-toplevel'))
    if (-not (Test-CanonicalPathEqual -Left $resolved -Right $topLevel -Platform (Get-DelegationPlatform))) {
        throw "WorktreePath must be the linked worktree root: $topLevel"
    }
    $gitDir = Resolve-AbsolutePath (Invoke-Git $topLevel @('rev-parse', '--absolute-git-dir'))
    $commonDirRaw = Invoke-Git $resolved @('rev-parse', '--git-common-dir')
    $commonDirCandidate = if ([System.IO.Path]::IsPathRooted($commonDirRaw)) {
        [System.IO.Path]::GetFullPath($commonDirRaw)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $topLevel $commonDirRaw))
    }
    $commonDir = Resolve-AbsolutePath $commonDirCandidate
    [pscustomobject]@{
        worktreePath = $topLevel
        gitDir = $gitDir
        commonDir = $commonDir
        branch = Invoke-Git $topLevel @('branch', '--show-current')
        repositoryId = $commonDir
    }
}

function Assert-LinkedWorktree($Context) {
    if (Test-CanonicalPathEqual -Left $Context.gitDir -Right $Context.commonDir -Platform (Get-DelegationPlatform)) {
        throw 'Delegation requires a linked Git worktree.'
    }
    if ([string]::IsNullOrWhiteSpace($Context.branch)) { throw 'Detached HEAD is not allowed.' }
}

function Initialize-HandoffState($Context, $Task) {
    if ($null -eq $Task) { throw 'A validated task packet is required to initialize handoff state.' }
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
            baseBranch = $Task.baseBranch
            featureBranch = $Task.featureBranch
            primarySessionId = $null
            tasks = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ledgerPath -Encoding UTF8
    }
    Read-AndAssertHandoffLedger -LedgerPath $ledgerPath -Context $Context -Task $Task | Out-Null
    [pscustomobject]@{
        stateDir = $stateDir
        ledgerPath = $ledgerPath
        lockPath = Join-Path $stateDir 'running.lock'
    }
}

function Read-TaskPacket([string]$Path) {
    $resolved = Resolve-AbsolutePath $Path
    $task = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    foreach ($name in @('id', 'goal', 'mode', 'baseBranch', 'featureBranch', 'allowedPaths', 'forbiddenPaths', 'forbiddenActions', 'context', 'acceptanceCriteria', 'requiredVerification', 'limits')) {
        if ($null -eq $task.$name) { throw "Task packet missing required field: $name" }
    }
    Assert-DelegationPolicy -Task $task
    return $task
}

function Read-AndAssertHandoffLedger([string]$LedgerPath, $Context, $Task) {
    try {
        $ledger = Get-Content -Raw -LiteralPath $LedgerPath -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Handoff ledger is not valid JSON: $LedgerPath"
    }
    $required = @('version', 'repositoryId', 'worktreePath', 'baseBranch', 'featureBranch', 'primarySessionId', 'tasks')
    $names = @($ledger.PSObject.Properties.Name)
    if (@($required | Where-Object { $names -notcontains $_ }).Count -gt 0 -or
        @($names | Where-Object { $required -notcontains $_ }).Count -gt 0) {
        throw 'Handoff ledger has an invalid shape.'
    }
    if ($ledger.version -isnot [int] -or $ledger.version -ne 1) { throw 'Unsupported handoff ledger version.' }
    if (-not (Test-NonEmptyString $ledger.repositoryId) -or
        -not (Test-CanonicalPathEqual -Left ([string]$ledger.repositoryId) -Right $Context.repositoryId -Platform (Get-DelegationPlatform))) {
        throw 'Handoff ledger repository identity does not match the linked worktree.'
    }
    if (-not (Test-NonEmptyString $ledger.worktreePath)) { throw 'Handoff ledger worktreePath is invalid.' }
    $ledgerWorktree = Resolve-AbsolutePath ([string]$ledger.worktreePath)
    if (-not (Test-CanonicalPathEqual -Left $ledgerWorktree -Right $Context.worktreePath -Platform (Get-DelegationPlatform))) {
        throw 'Handoff ledger worktree identity does not match the linked worktree.'
    }
    if (-not (Test-NonEmptyString $ledger.baseBranch) -or [string]$ledger.baseBranch -cne [string]$Task.baseBranch) {
        throw 'Handoff ledger baseBranch does not match the task packet.'
    }
    if (-not (Test-NonEmptyString $ledger.featureBranch) -or
        [string]$ledger.featureBranch -cne [string]$Task.featureBranch -or
        [string]$ledger.featureBranch -cne [string]$Context.branch) {
        throw 'Handoff ledger featureBranch does not match the task packet and current branch.'
    }
    if ($null -ne $ledger.primarySessionId -and -not (Test-NonEmptyString $ledger.primarySessionId)) {
        throw 'Handoff ledger primarySessionId must be null or a non-empty string.'
    }
    if (-not ($ledger.tasks -is [System.Array])) { throw 'Handoff ledger tasks must be an array.' }
    Invoke-Git $Context.worktreePath @('show-ref', '--verify', '--quiet', "refs/heads/$($ledger.baseBranch)") | Out-Null
    return $ledger
}

function Test-NonEmptyString([object]$Value) {
    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Assert-StringArray($Value, [string]$Name, [bool]$AllowEmpty = $false) {
    if (-not ($Value -is [System.Array])) { throw "$Name must be an array." }
    if (-not $AllowEmpty -and @($Value).Count -eq 0) { throw "$Name must not be empty." }
    foreach ($item in @($Value)) {
        if (-not (Test-NonEmptyString $item)) { throw "$Name must contain only non-empty strings." }
    }
}

function Assert-NormalizedRelativePattern([string]$Pattern, [string]$Name) {
    if (-not (Test-NonEmptyString $Pattern)) { throw "$Name contains an empty path." }
    if ([System.IO.Path]::IsPathRooted($Pattern) -or $Pattern -match '^[A-Za-z]:' -or $Pattern.StartsWith('/') -or $Pattern.StartsWith('\')) {
        throw "$Name paths must be relative."
    }
    if ($Pattern -match '\\|//|(^|/)\.\.?($|/)' -or $Pattern.EndsWith('/') -or $Pattern -match '[:<>"|?\[\]]') {
        throw "$Name contains a non-normalized path: $Pattern"
    }
    if ($Pattern -in @('*', '**') -or $Pattern -match '\*\*/.+' -or $Pattern -match '\*.+/') {
        throw "$Name contains an unsafe or malformed wildcard: $Pattern"
    }
    if ($Pattern -match '\*' -and $Pattern -notmatch '(^|/)[^/]*\*$' -and $Pattern -notmatch '/\*\*$') {
        throw "$Name contains an unsupported wildcard: $Pattern"
    }
    if ($Name -like 'allowedPaths*' -or $Name -like 'parallelWorkstreams*') {
        if ($Pattern -match '\*' -and $Pattern -notmatch '/\*\*$') {
            throw "$Name may use wildcards only as a final /** suffix."
        }
    }
}

function Test-PatternContainsPath([string]$Container, [string]$Candidate) {
    $containerRoot = $Container.TrimEnd([char[]]@('*', '/'))
    $candidateRoot = $Candidate.TrimEnd([char[]]@('*', '/'))
    return $candidateRoot.Equals($containerRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
           $candidateRoot.StartsWith($containerRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
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
    if (@($limitNames | Where-Object { $_ -notin @('maxTurns', 'timeoutSeconds', 'maxBudgetUsd') }).Count -gt 0) {
        throw 'Task packet limits contain unsupported fields.'
    }
    if ($limitNames -notcontains 'maxTurns' -or -not (Test-PositiveInteger $Limits.maxTurns)) {
        throw 'limits.maxTurns must be a positive integer.'
    }
    if ($limitNames -notcontains 'timeoutSeconds' -or -not (Test-PositiveNumber $Limits.timeoutSeconds)) {
        throw 'limits.timeoutSeconds must be positive.'
    }
    if ($limitNames -notcontains 'maxBudgetUsd' -or -not (Test-PositiveNumber $Limits.maxBudgetUsd)) {
        throw 'limits.maxBudgetUsd must be positive.'
    }
}

function Assert-DelegationPolicy($Task) {
    $commonProperties = @(
        'id', 'goal', 'mode', 'baseBranch', 'featureBranch', 'allowedPaths',
        'forbiddenPaths', 'forbiddenActions', 'context', 'acceptanceCriteria',
        'requiredVerification', 'limits'
    )
    $allowedProperties = $commonProperties + @('parallelWorkstreams', 'parallelismJustification')
    foreach ($property in $Task.PSObject.Properties.Name) {
        if ($allowedProperties -notcontains $property) { throw "Unsupported task packet field: $property" }
    }
    foreach ($name in @('id', 'goal', 'baseBranch', 'featureBranch')) {
        if (-not (Test-NonEmptyString $Task.$name)) { throw "$name must be a non-empty string." }
    }
    if ([string]$Task.baseBranch -eq [string]$Task.featureBranch) {
        throw 'baseBranch and featureBranch must be different.'
    }
    if (@('direct', 'subagents', 'agent-team') -notcontains $Task.mode) { throw "Unsupported mode: $($Task.mode)" }
    Assert-StringArray -Value $Task.allowedPaths -Name 'allowedPaths'
    Assert-StringArray -Value $Task.forbiddenPaths -Name 'forbiddenPaths'
    Assert-StringArray -Value $Task.forbiddenActions -Name 'forbiddenActions'
    Assert-StringArray -Value $Task.context -Name 'context' -AllowEmpty $true
    Assert-StringArray -Value $Task.acceptanceCriteria -Name 'acceptanceCriteria'
    Assert-StringArray -Value $Task.requiredVerification -Name 'requiredVerification'
    foreach ($path in @($Task.allowedPaths)) { Assert-NormalizedRelativePattern -Pattern $path -Name 'allowedPaths' }
    foreach ($path in @($Task.forbiddenPaths)) { Assert-NormalizedRelativePattern -Pattern $path -Name 'forbiddenPaths' }
    if (@($Task.allowedPaths | Where-Object { $_ -in @('.git', '.git/**') }).Count -gt 0) {
        throw 'allowedPaths must not authorize Git metadata.'
    }
    if (-not (@($Task.forbiddenPaths) -contains '.git/**')) {
        throw 'forbiddenPaths must include .git/**.'
    }
    if (@($Task.forbiddenPaths | Where-Object { $_ -match '(?i)(^|/)(\.env|[^/]*(secret|credential))' }).Count -eq 0) {
        throw 'forbiddenPaths must prohibit sensitive or credential files.'
    }
    $normalizedActions = @($Task.forbiddenActions | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    foreach ($operation in @('commit', 'push', 'pull', 'fetch', 'merge', 'rebase', 'reset', 'checkout', 'switch', 'stash', 'tag', 'remote', 'worktree')) {
        if (@($normalizedActions | Where-Object { $_ -match "(^|\s)git(?:\.exe)?\s+.*\b$operation\b" }).Count -eq 0) {
            throw "forbiddenActions must prohibit git $operation."
        }
    }
    foreach ($sensitiveTerm in @('secret', 'credential')) {
        if (@($normalizedActions | Where-Object { $_ -match $sensitiveTerm }).Count -eq 0) {
            throw "forbiddenActions must prohibit access to $sensitiveTerm data."
        }
    }
    Assert-TaskLimits $Task.limits
    if ($Task.mode -ne 'agent-team') {
        if ($Task.PSObject.Properties.Name -contains 'parallelWorkstreams') {
            throw 'parallelWorkstreams is allowed only for agent-team mode.'
        }
        if ($Task.PSObject.Properties.Name -contains 'parallelismJustification') {
            throw 'parallelismJustification is allowed only for agent-team mode.'
        }
        return
    }

    $workstreams = @($Task.parallelWorkstreams)
    if ($workstreams.Count -lt 2) { throw 'Agent-team mode requires at least two workstreams.' }
    if ($workstreams.Count -gt 3 -and (
        $Task.PSObject.Properties.Name -notcontains 'parallelismJustification' -or
        -not (Test-NonEmptyString $Task.parallelismJustification)
    )) {
        throw 'Agent-team mode with more than three workstreams requires parallelismJustification.'
    }
    $names = @()
    for ($i = 0; $i -lt $workstreams.Count; $i++) {
        $stream = $workstreams[$i]
        if ($null -eq $stream -or @($stream.PSObject.Properties.Name | Where-Object { $_ -notin @('name', 'ownedPaths') }).Count -gt 0) {
            throw "Agent-team workstream $i has an invalid shape."
        }
        if (-not (Test-NonEmptyString $stream.name)) { throw "Agent-team workstream $i must have a non-empty name." }
        if ($names -contains ([string]$stream.name).ToLowerInvariant()) { throw "Duplicate workstream name: $($stream.name)" }
        $names += ([string]$stream.name).ToLowerInvariant()
        Assert-StringArray -Value $stream.ownedPaths -Name "parallelWorkstreams[$i].ownedPaths"
        foreach ($ownedPath in @($stream.ownedPaths)) {
            Assert-NormalizedRelativePattern -Pattern $ownedPath -Name "parallelWorkstreams[$i].ownedPaths"
            if (@($Task.allowedPaths | Where-Object { Test-PatternContainsPath -Container $_ -Candidate $ownedPath }).Count -eq 0) {
                throw "Workstream-owned path is outside allowedPaths: $ownedPath"
            }
            if (@($Task.forbiddenPaths | Where-Object { Test-PathPatternOverlap $_ $ownedPath }).Count -gt 0) {
                throw "Workstream-owned path overlaps forbiddenPaths: $ownedPath"
            }
        }
        for ($j = $i + 1; $j -lt $workstreams.Count; $j++) {
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

function ConvertTo-AsciiJson([string]$Json) {
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Json.ToCharArray()) {
        if ([int]$character -gt 127) {
            [void]$builder.AppendFormat('\u{0:X4}', [int]$character)
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
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
    $taskJson = ConvertTo-AsciiJson -Json ($Task | ConvertTo-Json -Depth 12)
    $prompt = "Execute the bounded task packet below. $modeDirective Do not commit, push, switch branches, modify remotes, or expand scope.`n`n" +
              $taskJson
    $args = @('-p', '--dangerously-skip-permissions', '--output-format', 'json',
              '--json-schema', $schema, '--max-turns', [string]$Task.limits.maxTurns)
    $args += '--disallowedTools'
    $bashGitDenials = @(
        'Bash(git *)', 'Bash(git.exe *)',
        'Bash(* git *)', 'Bash(* git.exe *)',
        'Bash(*\git *)', 'Bash(*\git.exe *)',
        'Bash(*/git *)', 'Bash(*/git.exe *)'
    )
    $args += $bashGitDenials
    $args += @($bashGitDenials | ForEach-Object { $_ -replace '^Bash', 'PowerShell' })

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
    [pscustomobject]@{
        arguments = [object[]]$args
        environment = $environment
        freshSession = $fresh
        standardInput = $prompt
    }
}

function Test-ClaudeAvailable([string]$Command) {
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Resolve-ClaudeCommandPath([string]$Command) {
    $resolved = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $resolved) { throw "Claude command was not found: $Command" }
    $path = if ($resolved.Path) { $resolved.Path } elseif ($resolved.Source) { $resolved.Source } else { $resolved.Definition }
    if ([string]::IsNullOrWhiteSpace($path)) { throw "Claude command could not be resolved: $Command" }
    return [System.IO.Path]::GetFullPath($path)
}

function Test-ClaudeAuthenticated([string]$Command) {
    try {
        $output = & $Command auth status 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $status = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        if ($null -ne $status.loggedIn) { return [bool]$status.loggedIn }
        if ($null -ne $status.authenticated) { return [bool]$status.authenticated }
        return $true
    } catch {
        return $false
    }
}

function Show-OwnerSetup([string]$Worktree, [bool]$Installed) {
    $message = if ($Installed) {
        "Claude Code needs owner authentication. Complete the login here; this window stays open at an interactive PowerShell prompt afterward. Close it when finished."
    } else {
        "Claude Code CLI is not installed. Press Enter to reach the interactive PowerShell prompt; install Claude Code, then run 'claude auth login' here. Close this window when finished. Installation help: https://code.claude.com/docs/en/setup"
    }
    $escaped = $message.Replace("'", "''")
    $escapedWorktree = $Worktree.Replace("'", "''")
    $command = if ($Installed) {
        "Set-Location -LiteralPath '$escapedWorktree'; Write-Host '$escaped' -ForegroundColor Yellow; if (Get-Command claude -ErrorAction SilentlyContinue) { claude auth login } else { Write-Warning 'Claude Code CLI is no longer available. Install it in this window, then run claude auth login.' }; Write-Host 'Interactive PowerShell prompt ready. Close this window when finished.' -ForegroundColor Yellow"
    } else {
        "Set-Location -LiteralPath '$escapedWorktree'; Write-Host '$escaped' -ForegroundColor Yellow; Read-Host 'Press Enter to reach the interactive PowerShell prompt' | Out-Null; Write-Host 'Interactive PowerShell prompt ready. Install Claude Code and authenticate here, then close this window.' -ForegroundColor Yellow"
    }
    Start-Process powershell -ArgumentList @('-NoExit', '-NoProfile', '-Command', $command) -WorkingDirectory $Worktree | Out-Null
}

function Set-OwnerWaitState([string]$LedgerPath, $Task, [string]$Reason) {
    $ledger = Get-Content -Raw -LiteralPath $LedgerPath | ConvertFrom-Json
    $ledger.tasks += [pscustomobject]@{
        id = $Task.id
        mode = $Task.mode
        status = 'waiting-for-owner'
        reason = $Reason
        recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $LedgerPath -Encoding UTF8
}

function Enter-TaskLock([string]$LockPath, [string]$TaskId) {
    $ownershipToken = [guid]::NewGuid().ToString('N')
    try {
        $stream = New-Object System.IO.FileStream(
            $LockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::DeleteOnClose
        )
        $content = "$ownershipToken`n$TaskId`n$PID`n$([DateTimeOffset]::UtcNow.ToString('o'))`n"
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $stream
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "Another Claude task is already running: $LockPath"
    }
}

function Exit-TaskLock($LockHandle) {
    if ($null -ne $LockHandle) { $LockHandle.Dispose() }
}

function Get-WorktreeFingerprint([string]$Worktree) {
    $map = @{}
    $root = Get-Item -LiteralPath $Worktree -ErrorAction Stop
    $rootPrefixLength = $root.FullName.TrimEnd('\', '/').Length + 1
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($file in $directory.GetFiles()) {
            $relative = $file.FullName.Substring($rootPrefixLength).Replace('\', '/')
            if ((Test-CanonicalPathEqual -Left $relative -Right '.git' -Platform (Get-DelegationPlatform)) -or
                $relative.StartsWith('.codex/claude-handoff/', (Get-PathStringComparison (Get-DelegationPlatform)))) {
                continue
            }
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $map[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
        }
        foreach ($child in $directory.GetDirectories()) {
            $relative = $child.FullName.Substring($rootPrefixLength).Replace('\', '/')
            if ((Test-CanonicalPathEqual -Left $relative -Right '.git' -Platform (Get-DelegationPlatform)) -or
                (Test-CanonicalPathEqual -Left $relative -Right '.codex/claude-handoff' -Platform (Get-DelegationPlatform))) {
                continue
            }
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $pending.Push($child)
        }
    }
    return $map
}

function Compare-WorktreeFingerprint([hashtable]$Before, [hashtable]$After) {
    $all = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    return @($all | Where-Object { $Before[$_] -ne $After[$_] })
}

function Get-FileIdentity([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function ConvertTo-StableFingerprint([hashtable]$Fingerprint) {
    return (($Fingerprint.Keys | Sort-Object | ForEach-Object { "$_=$($Fingerprint[$_])" }) -join "`n")
}

function Get-SiblingWorktreeFingerprint($Context) {
    $comparison = Get-PathStringComparison -Platform (Get-DelegationPlatform)
    $comparer = if ($comparison -eq [System.StringComparison]::OrdinalIgnoreCase) {
        [System.StringComparer]::OrdinalIgnoreCase
    } else {
        [System.StringComparer]::Ordinal
    }
    $siblings = [System.Collections.Hashtable]::new($comparer)
    $worktreeList = Invoke-Git $Context.worktreePath @('worktree', 'list', '--porcelain')
    foreach ($line in @($worktreeList -split "`r?`n")) {
        if (-not $line.StartsWith('worktree ')) { continue }
        $path = Resolve-AbsolutePath $line.Substring(9)
        if (Test-CanonicalPathEqual -Left $path -Right $Context.worktreePath -Platform (Get-DelegationPlatform)) { continue }
        $siblings[$path] = ConvertTo-StableFingerprint (Get-WorktreeFingerprint -Worktree $path)
    }
    return $siblings
}

function Compare-SiblingWorktreeFingerprint([hashtable]$Before, [hashtable]$After) {
    $all = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    return @($all | Where-Object { $Before[$_] -cne $After[$_] })
}

function Get-GitMetadataSnapshot($Context) {
    $refs = @(Invoke-Git $Context.worktreePath @('for-each-ref', '--format=%(refname)%09%(objectname)%09%(symref)') -split "`r?`n" |
        Where-Object { $_ -ne '' } | Sort-Object) -join "`n"
    $remotes = @(Invoke-Git $Context.worktreePath @('remote', '-v') -split "`r?`n" |
        Where-Object { $_ -ne '' } | Sort-Object) -join "`n"
    $indexPath = Resolve-AbsolutePath (Invoke-Git $Context.worktreePath @('rev-parse', '--git-path', 'index'))
    [pscustomobject]@{
        Head = Invoke-Git $Context.worktreePath @('rev-parse', 'HEAD')
        Branch = Invoke-Git $Context.worktreePath @('branch', '--show-current')
        Remotes = $remotes
        Index = @(Invoke-Git $Context.worktreePath @('ls-files', '--stage') -split "`r?`n" |
            Where-Object { $_ -ne '' } | Sort-Object) -join "`n"
        IndexFile = Get-FileIdentity $indexPath
        Refs = $refs
        RepositoryConfig = Get-FileIdentity (Join-Path $Context.commonDir 'config')
        WorktreeConfig = Get-FileIdentity (Join-Path $Context.gitDir 'config.worktree')
    }
}

function Get-GitMetadataProbe($Context) {
    try {
        return [pscustomobject]@{ Success = $true; Value = Get-GitMetadataSnapshot -Context $Context; Violation = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Value = $null; Violation = 'git-metadata-probe-failed' }
    }
}

function Get-SiblingFingerprintProbe($Context) {
    try {
        return [pscustomobject]@{ Success = $true; Value = Get-SiblingWorktreeFingerprint -Context $Context; Violation = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Value = $null; Violation = 'sibling-worktree-probe-failed' }
    }
}

function Get-ScopeViolations([string[]]$ChangedPaths, $Task) {
    $violations = @()
    foreach ($path in $ChangedPaths) {
        $normalized = $path.Replace('\', '/')
        $forbidden = @($Task.forbiddenPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Where-Object { $normalized -like $_ }).Count -gt 0
        $allowed = @($Task.allowedPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Where-Object { $normalized -like $_ }).Count -gt 0
        if ($forbidden -or -not $allowed) { $violations += $normalized }
    }
    return @($violations | Sort-Object -Unique)
}

function Get-GitProbe([string]$Worktree, [string[]]$Arguments, [string]$Name) {
    try {
        return [pscustomobject]@{
            Success = $true
            Value = Invoke-Git $Worktree $Arguments
            Violation = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Value = $null
            Violation = "$Name-probe-failed"
        }
    }
}

function Get-FingerprintProbe([string]$Worktree) {
    try {
        return [pscustomobject]@{
            Success = $true
            Value = Get-WorktreeFingerprint -Worktree $Worktree
            Violation = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Value = $null
            Violation = 'fingerprint-probe-failed'
        }
    }
}

function ConvertTo-ProcessArgument([string]$Value) {
    $Value = $Value -replace "`r?`n", ' '
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function ConvertTo-BatchProcessArgument([string]$Value) {
    $Value = $Value -replace "`r?`n", ' '
    if ($Value -notmatch '[\s"&|<>()^]') { return $Value }
    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-ClaudeProcess(
    $Context,
    $Invocation,
    [string]$ClaudeCommand,
    [decimal]$TimeoutSeconds,
    [string]$RawOutputPath,
    [string]$RawErrorPath
) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ClaudeCommand
    $startInfo.WorkingDirectory = $Context.worktreePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
        $startInfo.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    $startInfo.CreateNoWindow = $true
    foreach ($entry in $Invocation.environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }
    if (-not $Invocation.environment.ContainsKey('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')) {
        [void]$startInfo.EnvironmentVariables.Remove('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')
    }
    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Invocation.arguments) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $isBatchCommand = @('.cmd', '.bat') -contains [System.IO.Path]::GetExtension($ClaudeCommand).ToLowerInvariant()
        $startInfo.Arguments = (($Invocation.arguments | ForEach-Object {
            if ($isBatchCommand) {
                ConvertTo-BatchProcessArgument ([string]$_)
            } else {
                ConvertTo-ProcessArgument ([string]$_)
            }
        }) -join ' ')
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    $timedOut = $false
    $stdout = ''
    $stderr = ''
    $exitCode = $null
    $inputError = $null
    try {
        $started = $process.Start()
        $timeoutMilliseconds = [int][math]::Min([decimal][int]::MaxValue, $TimeoutSeconds * 1000)
        $executionWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $readers = @(
            [pscustomobject]@{
                Reader = $process.StandardOutput
                Buffer = New-Object char[] 4096
                Builder = New-Object System.Text.StringBuilder
                Task = $null
                Complete = $false
            },
            [pscustomobject]@{
                Reader = $process.StandardError
                Buffer = New-Object char[] 4096
                Builder = New-Object System.Text.StringBuilder
                Task = $null
                Complete = $false
            }
        )
        foreach ($readerState in $readers) {
            $readerState.Task = $readerState.Reader.ReadAsync($readerState.Buffer, 0, $readerState.Buffer.Length)
        }
        $inputClosed = $false
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $inputWriteTask = if ($null -ne $Invocation.standardInput) {
            $inputBytes = $utf8.GetBytes([string]$Invocation.standardInput)
            $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
        } else {
            $null
        }
        if ($null -eq $inputWriteTask) {
            try { $process.StandardInput.BaseStream.Close() } catch { $inputError = $_.Exception.Message }
            $inputClosed = $true
        }

        while ($executionWatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
            foreach ($readerState in $readers | Where-Object { -not $_.Complete -and $_.Task.IsCompleted }) {
                try {
                    $count = $readerState.Task.GetAwaiter().GetResult()
                    if ($count -eq 0) {
                        $readerState.Complete = $true
                    } else {
                        [void]$readerState.Builder.Append($readerState.Buffer, 0, $count)
                        $readerState.Task = $readerState.Reader.ReadAsync($readerState.Buffer, 0, $readerState.Buffer.Length)
                    }
                } catch {
                    $readerState.Complete = $true
                }
            }
            if (-not $inputClosed -and $inputWriteTask.IsCompleted) {
                $inputWriteSucceeded = $false
                try {
                    $inputWriteTask.GetAwaiter().GetResult()
                    $inputWriteSucceeded = $true
                } catch {
                    $inputError = $_.Exception.Message
                }
                try {
                    $process.StandardInput.BaseStream.Close()
                } catch {
                    if (-not $inputWriteSucceeded -and -not $inputError) { $inputError = $_.Exception.Message }
                }
                $inputClosed = $true
            }
            if ($process.HasExited -and @($readers | Where-Object { -not $_.Complete }).Count -eq 0 -and $inputClosed) {
                break
            }
            [System.Threading.Thread]::Sleep(10)
        }
        $executionWatch.Stop()
        $deadlineReached = -not ($process.HasExited -and @($readers | Where-Object { -not $_.Complete }).Count -eq 0 -and $inputClosed)
        if ($deadlineReached) {
            $timedOut = $true
            if (-not $process.HasExited) {
                try {
                    $process.Kill()
                } catch {
                    if (-not $process.HasExited) { throw }
                }
            }
        }
        if (-not $process.WaitForExit(2000)) {
            throw 'Claude process did not exit after termination.'
        }
        if ($timedOut) {
            if (-not $inputClosed) {
                try { $process.StandardInput.BaseStream.Close() } catch {
                    if (-not $inputError) { $inputError = $_.Exception.Message }
                }
                if ($inputWriteTask.IsCompleted) {
                    try { $inputWriteTask.GetAwaiter().GetResult() } catch {
                        if (-not $inputError) { $inputError = $_.Exception.Message }
                    }
                } elseif (-not $inputError) {
                    $inputError = 'Standard input did not complete before the invocation deadline.'
                }
                $inputClosed = $true
            }
            $drainWatch = [System.Diagnostics.Stopwatch]::StartNew()
            while (@($readers | Where-Object { -not $_.Complete }).Count -gt 0 -and $drainWatch.ElapsedMilliseconds -lt 250) {
                foreach ($readerState in $readers | Where-Object { -not $_.Complete -and $_.Task.IsCompleted }) {
                    try {
                        $count = $readerState.Task.GetAwaiter().GetResult()
                        if ($count -eq 0) {
                            $readerState.Complete = $true
                        } else {
                            [void]$readerState.Builder.Append($readerState.Buffer, 0, $count)
                            $readerState.Task = $readerState.Reader.ReadAsync($readerState.Buffer, 0, $readerState.Buffer.Length)
                        }
                    } catch {
                        $readerState.Complete = $true
                    }
                }
                [System.Threading.Thread]::Sleep(10)
            }
            $drainWatch.Stop()
        }
        $stdout = $readers[0].Builder.ToString()
        $stderr = $readers[1].Builder.ToString()
        if ($inputError) {
            if ($stderr.Length -gt 0) { $stderr += [Environment]::NewLine }
            $stderr += "[standard-input] $inputError"
        }
        $exitCode = $process.ExitCode
    } finally {
        if ($started -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
                if (-not $process.HasExited) { throw }
            }
            [void]$process.WaitForExit(2000)
        }
        $process.Dispose()
        $stdout | Set-Content -LiteralPath $RawOutputPath -Encoding UTF8
        $stderr | Set-Content -LiteralPath $RawErrorPath -Encoding UTF8
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        StandardOutput = $stdout
        StandardError = $stderr
        InputError = $inputError
        RawOutputPath = $RawOutputPath
        RawErrorPath = $RawErrorPath
    }
}

function Test-ClaudeResultContract($Result, $Task) {
    if ($null -eq $Result -or $Result -isnot [pscustomobject]) { return $false }
    $required = @('taskId', 'status', 'summary', 'changedFiles', 'tests', 'unresolvedIssues', 'deviations')
    $names = @($Result.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count -or @($required | Where-Object { $names -cnotcontains $_ }).Count -gt 0) { return $false }
    if ($Result.taskId -isnot [string] -or -not [string]::Equals($Result.taskId, [string]$Task.id, [System.StringComparison]::Ordinal)) { return $false }
    if ($Result.status -isnot [string] -or @('completed', 'blocked', 'failed') -cnotcontains $Result.status) { return $false }
    if ($Result.summary -isnot [string]) { return $false }
    foreach ($arrayName in @('changedFiles', 'tests', 'unresolvedIssues', 'deviations')) {
        if ($Result.$arrayName -isnot [System.Array]) { return $false }
    }
    foreach ($value in @($Result.changedFiles) + @($Result.unresolvedIssues) + @($Result.deviations)) {
        if ($value -isnot [string]) { return $false }
    }
    foreach ($testResult in @($Result.tests)) {
        if ($testResult -isnot [pscustomobject]) { return $false }
        $testNames = @($testResult.PSObject.Properties.Name)
        $allowedTestNames = @('command', 'outcome', 'details')
        if ($testNames -cnotcontains 'command' -or $testNames -cnotcontains 'outcome' -or
            @($testNames | Where-Object { $allowedTestNames -cnotcontains $_ }).Count -gt 0) {
            return $false
        }
        if ($testResult.command -isnot [string] -or @('passed', 'failed', 'not-run') -cnotcontains $testResult.outcome) { return $false }
        if ($testNames -ccontains 'details' -and $testResult.details -isnot [string]) { return $false }
    }
    return $true
}

function ConvertFrom-ClaudeOutput([string]$Output, $Task, [bool]$TimedOut, [int]$ExitCode, [string]$InputError) {
    $envelope = $null
    if (-not $TimedOut) {
        foreach ($line in @($Output -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $candidate = $line | ConvertFrom-Json
                if ($candidate.type -eq 'result' -or $null -ne $candidate.result) {
                    $envelope = $candidate
                }
            } catch {
                # Preserve malformed output in the raw log and synthesize a reviewable result.
            }
        }
        if ($null -eq $envelope) {
            try { $envelope = $Output | ConvertFrom-Json } catch { $envelope = $null }
        }
    }

    $result = if ($null -ne $envelope) { $envelope.result } else { $null }
    if ($result -is [string]) {
        try { $result = $result | ConvertFrom-Json } catch { $result = $null }
    }
    $valid = -not $TimedOut -and $ExitCode -eq 0 -and -not $InputError -and
        (Test-ClaudeResultContract -Result $result -Task $Task)
    if (-not $valid) {
        $reason = if ($TimedOut) {
            'Claude execution timed out.'
        } elseif ($ExitCode -ne 0) {
            "Claude exited with code $ExitCode."
        } elseif ($InputError) {
            "Claude standard input failed: $InputError"
        } else {
            'Claude returned malformed or incomplete JSON.'
        }
        $result = [pscustomobject][ordered]@{
            taskId = [string]$Task.id
            status = 'failed'
            summary = $reason
            changedFiles = @()
            tests = @()
            unresolvedIssues = @($reason)
            deviations = @()
        }
    }
    $sessionId = if ($valid -and $null -ne $envelope.session_id) {
        [string]$envelope.session_id
    } elseif ($valid -and $null -ne $envelope.sessionId) {
        [string]$envelope.sessionId
    } else {
        $null
    }
    return [pscustomobject]@{
        Result = $result
        SessionId = $sessionId
        Valid = $valid
    }
}

function Get-ClaudeVersionSupport([string]$ClaudeCommand) {
    try {
        $versionOutput = & $ClaudeCommand --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        return Test-ForwardSubagentSupport -VersionText ($versionOutput -join [Environment]::NewLine)
    } catch {
        return $false
    }
}

function Invoke-Delegation($Context, $State, $Task, [string]$ClaudeCommand) {
    $lockAcquired = $false
    $lockHandle = $null
    try {
        $lockHandle = Enter-TaskLock -LockPath $State.lockPath -TaskId $Task.id
        $lockAcquired = $true

        $startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $startingStatus = Invoke-Git $Context.worktreePath @('status', '--porcelain=v1')
        $startingMetadata = Get-GitMetadataSnapshot -Context $Context
        $startingHead = $startingMetadata.Head
        $startingBranch = $startingMetadata.Branch
        $startingRemotes = Invoke-Git $Context.worktreePath @('remote', '-v')
        $startingSiblings = Get-SiblingWorktreeFingerprint -Context $Context
        $beforeFingerprint = Get-WorktreeFingerprint -Worktree $Context.worktreePath
        $ledger = Read-AndAssertHandoffLedger -LedgerPath $State.ledgerPath -Context $Context -Task $Task
        $sessionId = if ($Task.mode -eq 'agent-team') { $null } else { [string]$ledger.primarySessionId }
        $resolvedClaudeCommand = Resolve-ClaudeCommandPath -Command $ClaudeCommand
        $supportsForwarding = Get-ClaudeVersionSupport -ClaudeCommand $resolvedClaudeCommand
        $invocation = New-ClaudeInvocation -Task $Task -SessionId $sessionId -SupportsForwarding $supportsForwarding
        $attempts = @()
        $runToken = [guid]::NewGuid().ToString('N')
        $attemptNumber = 1
        $retryWithoutSession = $false

        do {
            $rawOutputPath = Join-Path $State.stateDir "$runToken-attempt-$attemptNumber.stdout.log"
            $rawErrorPath = Join-Path $State.stateDir "$runToken-attempt-$attemptNumber.stderr.log"
            $process = Invoke-ClaudeProcess -Context $Context -Invocation $invocation -ClaudeCommand $resolvedClaudeCommand `
                -TimeoutSeconds $Task.limits.timeoutSeconds -RawOutputPath $rawOutputPath -RawErrorPath $rawErrorPath
            $wasResumed = $invocation.arguments -contains '--resume'
            $attempts += [pscustomobject][ordered]@{
                number = $attemptNumber
                resumed = $wasResumed
                exitCode = $process.ExitCode
                timedOut = $process.TimedOut
                inputError = $process.InputError
                rawOutputPath = $process.RawOutputPath
                rawErrorPath = $process.RawErrorPath
            }
            $combinedOutput = "$($process.StandardOutput)`n$($process.StandardError)"
            $retryWithoutSession = $attemptNumber -eq 1 -and $wasResumed -and
                -not $process.TimedOut -and $process.ExitCode -ne 0 -and
                $combinedOutput -match '(?i)(session|conversation).*(not found|does not exist|invalid|cannot resume)'
            if ($retryWithoutSession) {
                $ledger.primarySessionId = $null
                $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $State.ledgerPath -Encoding UTF8
                $invocation = New-ClaudeInvocation -Task $Task -SessionId $null -SupportsForwarding $supportsForwarding
                $attemptNumber++
            }
        } while ($retryWithoutSession)

        $parsed = ConvertFrom-ClaudeOutput -Output $process.StandardOutput -Task $Task -TimedOut $process.TimedOut `
            -ExitCode $process.ExitCode -InputError $process.InputError
        $normalizedResultPath = Join-Path $State.stateDir "$runToken-result.json"
        $parsed.Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $normalizedResultPath -Encoding UTF8

        $endingHeadProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('rev-parse', 'HEAD') -Name 'head'
        $endingBranchProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('branch', '--show-current') -Name 'branch'
        $endingRemotesProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('remote', '-v') -Name 'remotes'
        $endingStatusProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('status', '--porcelain=v1') -Name 'status'
        $endingMetadataProbe = Get-GitMetadataProbe -Context $Context
        $endingSiblingsProbe = Get-SiblingFingerprintProbe -Context $Context
        $afterFingerprintProbe = Get-FingerprintProbe -Worktree $Context.worktreePath
        $changedDuringTask = if ($afterFingerprintProbe.Success) {
            Compare-WorktreeFingerprint -Before $beforeFingerprint -After $afterFingerprintProbe.Value
        } else {
            @()
        }
        $scopeViolations = Get-ScopeViolations -ChangedPaths $changedDuringTask -Task $Task
        $repositoryViolations = @()
        foreach ($probe in @($endingHeadProbe, $endingBranchProbe, $endingRemotesProbe, $endingStatusProbe, $endingMetadataProbe, $endingSiblingsProbe, $afterFingerprintProbe)) {
            if (-not $probe.Success) { $repositoryViolations += $probe.Violation }
        }
        if ($endingHeadProbe.Success -and $startingHead -ne $endingHeadProbe.Value) { $repositoryViolations += 'head-changed' }
        if ($endingBranchProbe.Success -and $startingBranch -ne $endingBranchProbe.Value) { $repositoryViolations += 'branch-changed' }
        if ($endingRemotesProbe.Success -and $startingRemotes -ne $endingRemotesProbe.Value) { $repositoryViolations += 'remotes-changed' }
        if ($endingMetadataProbe.Success) {
            if ($startingMetadata.Index -cne $endingMetadataProbe.Value.Index -or
                $startingMetadata.IndexFile -cne $endingMetadataProbe.Value.IndexFile) {
                $repositoryViolations += 'index-changed'
            }
            if ($startingMetadata.Refs -cne $endingMetadataProbe.Value.Refs) { $repositoryViolations += 'refs-changed' }
            if ($startingMetadata.RepositoryConfig -cne $endingMetadataProbe.Value.RepositoryConfig -or
                $startingMetadata.WorktreeConfig -cne $endingMetadataProbe.Value.WorktreeConfig) {
                $repositoryViolations += 'config-changed'
            }
        }
        if ($endingSiblingsProbe.Success -and
            @(Compare-SiblingWorktreeFingerprint -Before $startingSiblings -After $endingSiblingsProbe.Value).Count -gt 0) {
            $repositoryViolations += 'sibling-worktree-changed'
        }
        $repositoryViolations = @($repositoryViolations | Sort-Object -Unique)
        $reviewStatus = if (@($scopeViolations).Count -gt 0 -or @($repositoryViolations).Count -gt 0) {
            'rejected'
        } else {
            'needs-review'
        }

        $taskRecord = [pscustomobject][ordered]@{
            id = $Task.id
            mode = $Task.mode
            status = $reviewStatus
            startedAt = $startedAt
            finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
            exitCode = $process.ExitCode
            timedOut = $process.TimedOut
            startingGitStatus = $startingStatus
            endingGitStatus = $endingStatusProbe.Value
            changedDuringTask = @($changedDuringTask)
            scopeViolations = @($scopeViolations)
            repositoryViolations = @($repositoryViolations)
            rawOutputPath = $process.RawOutputPath
            rawErrorPath = $process.RawErrorPath
            resultPath = $normalizedResultPath
            attempts = @($attempts)
        }
        if ($parsed.SessionId) {
            if ($Task.mode -eq 'agent-team') {
                $taskRecord | Add-Member -NotePropertyName sessionId -NotePropertyValue $parsed.SessionId
            } else {
                $ledger.primarySessionId = $parsed.SessionId
            }
        }
        $ledger.tasks += $taskRecord
        $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $State.ledgerPath -Encoding UTF8
        return $parsed.Result
    } finally {
        if ($lockAcquired) {
            Exit-TaskLock -LockHandle $lockHandle
        }
    }
}

if (-not $LibraryMode) {
    if (-not $WorktreePath -or -not $TaskPacketPath) {
        throw 'WorktreePath and TaskPacketPath are required.'
    }
    $context = Get-WorktreeContext -WorktreePath $WorktreePath
    Assert-LinkedWorktree -Context $context
    $resolvedTask = Resolve-AbsolutePath $TaskPacketPath
    $expectedStateDir = Join-Path $context.worktreePath '.codex/claude-handoff'
    $statePrefix = $expectedStateDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTask.StartsWith($statePrefix, (Get-PathStringComparison (Get-DelegationPlatform)))) {
        throw 'Task packet must be stored inside .codex/claude-handoff/.'
    }
    $task = Read-TaskPacket -Path $resolvedTask
    if ([string]$task.featureBranch -cne [string]$context.branch) {
        throw 'Task packet featureBranch must match the current linked-worktree branch.'
    }
    Invoke-Git $context.worktreePath @('show-ref', '--verify', '--quiet', "refs/heads/$($task.baseBranch)") | Out-Null
    $state = Initialize-HandoffState -Context $context -Task $task
    Read-AndAssertHandoffLedger -LedgerPath $state.ledgerPath -Context $context -Task $task | Out-Null
    if ($DryRun) {
        New-ClaudeInvocation -Task $task -SessionId $null -SupportsForwarding $true | ConvertTo-Json -Depth 8
        return
    }
    if (-not (Test-ClaudeAvailable $ClaudeCommand)) {
        Set-OwnerWaitState -LedgerPath $state.ledgerPath -Task $task -Reason 'claude-cli-missing'
        Show-OwnerSetup -Worktree $context.worktreePath -Installed $false
        throw 'Claude Code setup requires owner action.'
    }
    $resolvedClaudeCommand = Resolve-ClaudeCommandPath -Command $ClaudeCommand
    if (-not (Test-ClaudeAuthenticated $resolvedClaudeCommand)) {
        Set-OwnerWaitState -LedgerPath $state.ledgerPath -Task $task -Reason 'claude-authentication-required'
        Show-OwnerSetup -Worktree $context.worktreePath -Installed $true
        throw 'Claude Code authentication requires owner action.'
    }
    Invoke-Delegation -Context $context -State $state -Task $task -ClaudeCommand $resolvedClaudeCommand | ConvertTo-Json -Depth 12
}
