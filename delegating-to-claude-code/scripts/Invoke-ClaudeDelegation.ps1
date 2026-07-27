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
    $args = @('-p', '--dangerously-skip-permissions', '--output-format', 'json',
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
        "Claude Code needs owner authentication. Run 'claude auth login' here, complete login, then close this window."
    } else {
        "Claude Code CLI is not installed. Follow the official instructions at https://code.claude.com/docs/en/setup, then run 'claude' and authenticate."
    }
    $escaped = $message.Replace("'", "''")
    $escapedWorktree = $Worktree.Replace("'", "''")
    $command = "Set-Location -LiteralPath '$escapedWorktree'; Write-Host '$escaped' -ForegroundColor Yellow; if (Get-Command claude -ErrorAction SilentlyContinue) { claude auth login }; Read-Host 'Press Enter to close'"
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
        $stream = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.WriteLine("$ownershipToken`n$TaskId`n$PID`n$([DateTimeOffset]::UtcNow.ToString('o'))")
        $writer.Dispose()
        return $ownershipToken
    } catch {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        throw "Another Claude task is already running: $LockPath"
    }
}

function Exit-TaskLock([string]$LockPath, [string]$OwnershipToken) {
    if (-not $OwnershipToken -or -not (Test-Path -LiteralPath $LockPath)) { return }
    $recordedToken = Get-Content -LiteralPath $LockPath -TotalCount 1 -ErrorAction SilentlyContinue
    if ($recordedToken -eq $OwnershipToken) {
        Remove-Item -LiteralPath $LockPath -Force
    }
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
            if ($relative -eq '.git' -or $relative.StartsWith('.codex/claude-handoff/', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $map[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
        }
        foreach ($child in $directory.GetDirectories()) {
            $relative = $child.FullName.Substring($rootPrefixLength).Replace('\', '/')
            if ($relative -eq '.git' -or $relative -eq '.codex/claude-handoff') { continue }
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
    try {
        $started = $process.Start()
        if ($null -ne $Invocation.standardInput) {
            $process.StandardInput.Write([string]$Invocation.standardInput)
        }
        $process.StandardInput.Close()
        $timeoutMilliseconds = [int][math]::Min([decimal][int]::MaxValue, $TimeoutSeconds * 1000)
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
        $executionWatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -and $executionWatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
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
        $executionWatch.Stop()
        if (-not $process.HasExited) {
            $timedOut = $true
            try {
                $process.Kill()
            } catch {
                if (-not $process.HasExited) { throw }
            }
        }
        if (-not $process.WaitForExit(2000)) {
            throw 'Claude process did not exit after termination.'
        }
        $drainLimitMilliseconds = if ($timedOut) { 250 } else { 2000 }
        $drainWatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (@($readers | Where-Object { -not $_.Complete }).Count -gt 0 -and $drainWatch.ElapsedMilliseconds -lt $drainLimitMilliseconds) {
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
        $stdout = $readers[0].Builder.ToString()
        $stderr = $readers[1].Builder.ToString()
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
        RawOutputPath = $RawOutputPath
        RawErrorPath = $RawErrorPath
    }
}

function Test-ClaudeResultContract($Result, $Task) {
    if ($null -eq $Result -or $Result -isnot [pscustomobject]) { return $false }
    $required = @('taskId', 'status', 'summary', 'changedFiles', 'tests', 'unresolvedIssues', 'deviations')
    $names = @($Result.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count -or @($required | Where-Object { $names -notcontains $_ }).Count -gt 0) { return $false }
    if ($Result.taskId -isnot [string] -or $Result.taskId -ne [string]$Task.id) { return $false }
    if ($Result.status -isnot [string] -or @('completed', 'blocked', 'failed') -notcontains $Result.status) { return $false }
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
        if ($testNames -notcontains 'command' -or $testNames -notcontains 'outcome' -or
            @($testNames | Where-Object { $allowedTestNames -notcontains $_ }).Count -gt 0) {
            return $false
        }
        if ($testResult.command -isnot [string] -or @('passed', 'failed', 'not-run') -notcontains $testResult.outcome) { return $false }
        if ($testNames -contains 'details' -and $testResult.details -isnot [string]) { return $false }
    }
    return $true
}

function ConvertFrom-ClaudeOutput([string]$Output, $Task, [bool]$TimedOut, [int]$ExitCode) {
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
    $valid = -not $TimedOut -and $ExitCode -eq 0 -and (Test-ClaudeResultContract -Result $result -Task $Task)
    if (-not $valid) {
        $reason = if ($TimedOut) {
            'Claude execution timed out.'
        } elseif ($ExitCode -ne 0) {
            "Claude exited with code $ExitCode."
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
    $lockOwnershipToken = $null
    try {
        $lockOwnershipToken = Enter-TaskLock -LockPath $State.lockPath -TaskId $Task.id
        $lockAcquired = $true

        $startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $startingStatus = Invoke-Git $Context.worktreePath @('status', '--porcelain=v1')
        $startingHead = Invoke-Git $Context.worktreePath @('rev-parse', 'HEAD')
        $startingBranch = Invoke-Git $Context.worktreePath @('branch', '--show-current')
        $startingRemotes = Invoke-Git $Context.worktreePath @('remote', '-v')
        $beforeFingerprint = Get-WorktreeFingerprint -Worktree $Context.worktreePath
        $ledger = Get-Content -Raw -LiteralPath $State.ledgerPath | ConvertFrom-Json
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

        $parsed = ConvertFrom-ClaudeOutput -Output $process.StandardOutput -Task $Task -TimedOut $process.TimedOut -ExitCode $process.ExitCode
        $normalizedResultPath = Join-Path $State.stateDir "$runToken-result.json"
        $parsed.Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $normalizedResultPath -Encoding UTF8

        $endingHeadProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('rev-parse', 'HEAD') -Name 'head'
        $endingBranchProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('branch', '--show-current') -Name 'branch'
        $endingRemotesProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('remote', '-v') -Name 'remotes'
        $endingStatusProbe = Get-GitProbe -Worktree $Context.worktreePath -Arguments @('status', '--porcelain=v1') -Name 'status'
        $afterFingerprintProbe = Get-FingerprintProbe -Worktree $Context.worktreePath
        $changedDuringTask = if ($afterFingerprintProbe.Success) {
            Compare-WorktreeFingerprint -Before $beforeFingerprint -After $afterFingerprintProbe.Value
        } else {
            @()
        }
        $scopeViolations = Get-ScopeViolations -ChangedPaths $changedDuringTask -Task $Task
        $repositoryViolations = @()
        foreach ($probe in @($endingHeadProbe, $endingBranchProbe, $endingRemotesProbe, $endingStatusProbe, $afterFingerprintProbe)) {
            if (-not $probe.Success) { $repositoryViolations += $probe.Violation }
        }
        if ($endingHeadProbe.Success -and $startingHead -ne $endingHeadProbe.Value) { $repositoryViolations += 'head-changed' }
        if ($endingBranchProbe.Success -and $startingBranch -ne $endingBranchProbe.Value) { $repositoryViolations += 'branch-changed' }
        if ($endingRemotesProbe.Success -and $startingRemotes -ne $endingRemotesProbe.Value) { $repositoryViolations += 'remotes-changed' }
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
            Exit-TaskLock -LockPath $State.lockPath -OwnershipToken $lockOwnershipToken
        }
    }
}

if (-not $LibraryMode) {
    if (-not $WorktreePath -or -not $TaskPacketPath) {
        throw 'WorktreePath and TaskPacketPath are required.'
    }
    $context = Get-WorktreeContext -WorktreePath $WorktreePath
    Assert-LinkedWorktree -Context $context
    $state = Initialize-HandoffState -Context $context
    $resolvedTask = Resolve-AbsolutePath $TaskPacketPath
    $statePrefix = $state.stateDir.TrimEnd('\') + '\'
    if (-not $resolvedTask.StartsWith($statePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Task packet must be stored inside .codex/claude-handoff/.'
    }
    $task = Read-TaskPacket -Path $resolvedTask
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
