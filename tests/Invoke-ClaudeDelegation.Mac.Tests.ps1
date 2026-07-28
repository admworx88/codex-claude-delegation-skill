$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7 -or
    -not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX
    )) {
    throw 'Invoke-ClaudeDelegation.Mac.Tests.ps1 supports only macOS with PowerShell 7 (pwsh).'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-TestGit([string]$Path, [string[]]$Arguments) {
    $output = & git -C $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Test Git command failed: git -C $Path $($Arguments -join ' '): $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-NativeCapture(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory
) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True ($process.Start()) "failed to start native process: $FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Write-PosixExecutable([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText(
        $Path,
        $Content.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    $absolutePath = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    & chmod 700 $absolutePath
    if ($LASTEXITCODE -ne 0) { throw "Failed to secure test executable: $Path" }
}

function Read-NulArgumentCapture([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "argument capture was not written: $Path"
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
    $fields = [string[]]$text.Split(
        [char[]]@([char]0),
        [System.StringSplitOptions]::None
    )
    Assert-True (
        $fields.Count -ge 1 -and $fields[-1] -ceq ''
    ) 'argument capture must end with exactly one protocol delimiter'
    if ($fields.Count -eq 1) { return [string[]]@() }
    return [string[]]$fields[0..($fields.Count - 2)]
}

function Assert-VerifiedFixtureRoot([string]$Path) {
    $temporaryDirectory = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar
    )
    $leaf = Split-Path -Leaf $fullPath
    $parent = Split-Path -Parent $fullPath
    Assert-True ($parent -ceq $temporaryDirectory) 'fixture cleanup path escaped the temporary directory'
    Assert-True (
        $leaf -cmatch '^claude-delegation-macos-e2e-[0-9a-f]{32}$'
    ) 'fixture cleanup path did not match the test-owned name'
    return $fullPath
}

function Assert-StringArrayShape([object]$Value, [string]$Name) {
    Assert-True ($Value -is [System.Array]) "$Name must remain an array"
    foreach ($item in @($Value)) {
        Assert-True ($item -is [string]) "$Name must contain only strings"
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repositoryRoot 'delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1'
$pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$pwsh = [string]$pwshCommand.Path
Assert-True (Test-Path -LiteralPath $runner -PathType Leaf) 'delegation runner must exist'
Assert-True (
    -not [string]::IsNullOrWhiteSpace($pwsh) -and
    [System.IO.Path]::IsPathRooted($pwsh) -and
    (Test-Path -LiteralPath $pwsh -PathType Leaf)
) 'macOS test must select one absolute pwsh executable path'

. $runner -LibraryMode

$fixtureRoot = Join-Path (
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
) ("claude-delegation-macos-e2e-" + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Assert-VerifiedFixtureRoot $fixtureRoot
$mainRepository = Join-Path $fixtureRoot 'main repository'
$linkedWorktree = Join-Path $fixtureRoot "linked worktree's feature"
$binDirectory = Join-Path $fixtureRoot 'bin'
$savedPath = $env:PATH
$savedClaudeArgvCapture = $env:CLAUDE_FAKE_ARGV_CAPTURE
$savedClaudeStdinCapture = $env:CLAUDE_FAKE_STDIN_CAPTURE
$savedOpenCapture = $env:DELEGATION_OPEN_CAPTURE

try {
    New-Item -ItemType Directory -Path $mainRepository -Force | Out-Null
    New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null

    Invoke-TestGit $mainRepository @('init', '-b', 'sentinel-base-branch-mac-e2e') | Out-Null
    Invoke-TestGit $mainRepository @('config', 'user.email', 'mac-tests@example.invalid') | Out-Null
    Invoke-TestGit $mainRepository @('config', 'user.name', 'macOS Delegation Tests') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mainRepository 'src') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $mainRepository 'src/parser.ps1'),
        "original-content`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $mainRepository 'sibling-marker.txt'),
        "sibling-unchanged`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Invoke-TestGit $mainRepository @('add', '--all') | Out-Null
    Invoke-TestGit $mainRepository @('commit', '-m', 'seed') | Out-Null
    Invoke-TestGit $mainRepository @(
        'worktree', 'add', '-b', 'sentinel-feature-branch-mac-e2e', $linkedWorktree
    ) | Out-Null

    $stateDirectory = Join-Path $linkedWorktree '.codex/claude-handoff'
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $taskPacketPath = Join-Path $stateDirectory 'task-mac-e2e.json'
    $taskPacket = [pscustomobject][ordered]@{
        id = 'SENTINEL_TASK_ID_MAC_E2E'
        goal = 'SENTINEL_GOAL_MAC_E2E'
        mode = 'direct'
        baseBranch = 'sentinel-base-branch-mac-e2e'
        featureBranch = 'sentinel-feature-branch-mac-e2e'
        allowedPaths = @('src/**', 'sentinel-allowed-path-mac-e2e/**')
        forbiddenPaths = @(
            '.git/**',
            '.github/**',
            '.env*',
            'secrets/**',
            'credentials/**',
            'sentinel-forbidden-path-mac-e2e/**'
        )
        forbiddenActions = @(
            'git commit',
            'git push',
            'git pull',
            'git fetch',
            'git merge',
            'git rebase',
            'git reset',
            'git checkout',
            'git switch',
            'git stash',
            'git tag',
            'git remote',
            'git worktree',
            'read or expose secrets',
            'read or expose credentials',
            'prohibit SENTINEL_FORBIDDEN_ACTION_MAC_E2E while protecting secrets and credentials'
        )
        context = @('SENTINEL_CONTEXT_MAC_E2E')
        acceptanceCriteria = @('SENTINEL_ACCEPTANCE_CRITERION_MAC_E2E')
        requiredVerification = @('SENTINEL_REQUIRED_VERIFICATION_MAC_E2E')
        limits = [pscustomobject][ordered]@{
            maxTurns = 2
            timeoutSeconds = 37
            maxBudgetUsd = 1
        }
    }
    $stdinOnlySentinels = [ordered]@{
        taskId = 'SENTINEL_TASK_ID_MAC_E2E'
        goal = 'SENTINEL_GOAL_MAC_E2E'
        context = 'SENTINEL_CONTEXT_MAC_E2E'
        acceptanceCriteria = 'SENTINEL_ACCEPTANCE_CRITERION_MAC_E2E'
        requiredVerification = 'SENTINEL_REQUIRED_VERIFICATION_MAC_E2E'
        allowedPaths = 'sentinel-allowed-path-mac-e2e/**'
        forbiddenPaths = 'sentinel-forbidden-path-mac-e2e/**'
        forbiddenActions = 'SENTINEL_FORBIDDEN_ACTION_MAC_E2E'
        baseBranch = 'sentinel-base-branch-mac-e2e'
        featureBranch = 'sentinel-feature-branch-mac-e2e'
        modeField = '"mode": "direct"'
        timeoutField = '"timeoutSeconds": 37'
        promptLabel = 'Execute the bounded task packet below.'
        modeDirective = 'Work directly. Do not spawn subagents or teammates.'
        safetyDirective = 'Do not commit, push, switch branches, modify remotes, or expand scope.'
    }
    [System.IO.File]::WriteAllText(
        $taskPacketPath,
        ($taskPacket | ConvertTo-Json -Depth 12),
        [System.Text.UTF8Encoding]::new($false)
    )

    $validatedTask = Read-TaskPacket -Path $taskPacketPath
    Assert-DelegationPolicy -Task $validatedTask

    $fakeClaude = Join-Path $binDirectory 'claude'
    Write-PosixExecutable -Path $fakeClaude -Content @'
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  printf '%s\n' '{"loggedIn":true}'
  exit 0
fi
if [ "$1" = "--version" ]; then
  printf '%s\n' '2.1.211 (Claude Code)'
  exit 0
fi
: > "$CLAUDE_FAKE_ARGV_CAPTURE"
for argument do
  printf '%s\000' "$argument" >> "$CLAUDE_FAKE_ARGV_CAPTURE"
done
cat > "$CLAUDE_FAKE_STDIN_CAPTURE"
printf '\ndelegated-change\n' >> './src/parser.ps1'
printf '%s\n' '{"type":"result","session_id":"mac-fake-session","result":{"taskId":"SENTINEL_TASK_ID_MAC_E2E","status":"completed","summary":"one allowed edit","changedFiles":["src/parser.ps1"],"tests":[{"command":"fixture verification","outcome":"passed"}],"unresolvedIssues":[],"deviations":[]}}'
'@

    $fakeOpen = Join-Path $binDirectory 'open'
    Write-PosixExecutable -Path $fakeOpen -Content @'
#!/bin/sh
: > "$DELEGATION_OPEN_CAPTURE"
for argument do
  printf '%s\000' "$argument" >> "$DELEGATION_OPEN_CAPTURE"
done
'@

    $env:PATH = "$binDirectory$([System.IO.Path]::PathSeparator)$savedPath"
    $env:CLAUDE_FAKE_ARGV_CAPTURE = Join-Path $stateDirectory 'claude-argv.bin'
    $env:CLAUDE_FAKE_STDIN_CAPTURE = Join-Path $stateDirectory 'claude-stdin.txt'
    $env:DELEGATION_OPEN_CAPTURE = Join-Path $stateDirectory 'open-argv.bin'

    $nestedDirectory = Join-Path $linkedWorktree 'nested'
    New-Item -ItemType Directory -Path $nestedDirectory -Force | Out-Null
    $nestedRun = Invoke-NativeCapture -FilePath $pwsh -WorkingDirectory $repositoryRoot -Arguments @(
        '-NoProfile',
        '-File', $runner,
        '-WorktreePath', $nestedDirectory,
        '-TaskPacketPath', $taskPacketPath,
        '-ClaudeCommand', $fakeClaude
    )
    Assert-True ($nestedRun.ExitCode -ne 0) 'nested linked-worktree path was accepted'
    Assert-True (
        $nestedRun.StandardError -match 'WorktreePath must be the linked worktree root'
    ) 'nested path rejection did not identify the required linked-worktree root'

    $dryRun = Invoke-NativeCapture -FilePath $pwsh -WorkingDirectory $repositoryRoot -Arguments @(
        '-NoProfile',
        '-File', $runner,
        '-WorktreePath', $linkedWorktree,
        '-TaskPacketPath', $taskPacketPath,
        '-ClaudeCommand', $fakeClaude,
        '-DryRun'
    )
    Assert-True (
        $dryRun.ExitCode -eq 0
    ) "macOS dry-run failed: $($dryRun.StandardError)"
    $dryInvocation = $dryRun.StandardOutput | ConvertFrom-Json
    Assert-True (
        @($dryInvocation.arguments | Where-Object {
            $_ -ceq '--dangerously-skip-permissions'
        }).Count -eq 1
    ) 'validated Claude invocation must contain exactly one permission-bypass argument'
    $dryArguments = [string[]]@(
        $dryInvocation.arguments | ForEach-Object { [string]$_ }
    )
    foreach ($sentinel in $stdinOnlySentinels.GetEnumerator()) {
        Assert-True (
            ([string]$dryInvocation.standardInput).Contains([string]$sentinel.Value)
        ) "stdin-only $($sentinel.Key) sentinel was missing from the validated prompt"
        Assert-True (
            @($dryArguments | Where-Object {
                $_.Contains([string]$sentinel.Value)
            }).Count -eq 0
        ) "stdin-only $($sentinel.Key) sentinel leaked onto validated dry-run argv"
    }

    $ownerSpec = New-OwnerSetupLaunchSpec -Worktree $linkedWorktree `
        -StateDirectory $stateDirectory -Installed $true -Platform 'MacOS'
    Assert-True (
        $ownerSpec.ScriptPath.Contains(' ') -and $ownerSpec.ScriptPath.Contains("'")
    ) 'owner setup fixture path must exercise spaces and apostrophes'
    Assert-True (
        (@($ownerSpec.ArgumentList) -join "`n") -notmatch 'dangerously-skip-permissions'
    ) 'owner setup argv received permission bypass'
    Assert-True (
        $ownerSpec.ScriptContent -notmatch 'dangerously-skip-permissions'
    ) 'owner setup content received permission bypass'

    $capturingOpenSpec = [pscustomobject]@{
        FilePath = $fakeOpen
        ArgumentList = [object[]]$ownerSpec.ArgumentList
        WorkingDirectory = $ownerSpec.WorkingDirectory
        ScriptPath = $ownerSpec.ScriptPath
        ScriptContent = $ownerSpec.ScriptContent
    }
    $openProcess = Invoke-OwnerSetupLaunchSpec -LaunchSpec $capturingOpenSpec -Platform 'MacOS'
    try {
        Assert-True ($openProcess.WaitForExit(30000)) 'fake open process did not exit'
        Assert-True ($openProcess.ExitCode -eq 0) 'fake open process failed'
    } finally {
        $openProcess.Dispose()
    }
    $openArguments = Read-NulArgumentCapture $env:DELEGATION_OPEN_CAPTURE
    Assert-True ($openArguments.Count -eq 3) 'macOS open launch changed the native argument count'
    Assert-True ($openArguments[0] -ceq '-a') 'macOS open launch changed the application selector'
    Assert-True ($openArguments[1] -ceq 'Terminal') 'macOS open launch changed the Terminal application name'
    Assert-True (
        $openArguments[2] -ceq $ownerSpec.ScriptPath
    ) 'macOS open launch split or changed the complete .command path'
    Remove-Item -LiteralPath $env:DELEGATION_OPEN_CAPTURE -Force

    $context = Get-WorktreeContext -WorktreePath $linkedWorktree
    Assert-LinkedWorktree -Context $context
    $beforeMetadata = Get-GitMetadataSnapshot -Context $context
    $beforeSiblings = Get-SiblingWorktreeFingerprint -Context $context
    $siblingMarkerBefore = Get-Content -Raw -LiteralPath (
        Join-Path $mainRepository 'sibling-marker.txt'
    )

    $run = Invoke-NativeCapture -FilePath $pwsh -WorkingDirectory $repositoryRoot -Arguments @(
        '-NoProfile',
        '-File', $runner,
        '-WorktreePath', $linkedWorktree,
        '-TaskPacketPath', $taskPacketPath,
        '-ClaudeCommand', $fakeClaude
    )
    Assert-True ($run.ExitCode -eq 0) "native delegation failed: $($run.StandardError)"
    $result = $run.StandardOutput | ConvertFrom-Json
    Assert-True (
        (Test-ClaudeResultContract -Result $result -Task $validatedTask)
    ) 'runner output did not satisfy the result contract'
    Assert-True (
        $result.taskId -ceq 'SENTINEL_TASK_ID_MAC_E2E'
    ) 'runner returned the wrong task result'

    $ledgerPath = Join-Path $stateDirectory 'ledger.json'
    $ledger = Read-AndAssertHandoffLedger -LedgerPath $ledgerPath `
        -Context $context -Task $validatedTask
    Assert-True ($ledger.primarySessionId -ceq 'mac-fake-session') 'session id was not persisted'
    $record = @($ledger.tasks)[-1]
    Assert-True ($record.status -ceq 'needs-review') 'allowed edit did not produce needs-review'
    Assert-True ($record.changedDuringTask -ccontains 'src/parser.ps1') 'allowed edit was not recorded'
    Assert-True (@($record.scopeViolations).Count -eq 0) 'allowed edit caused a scope violation'
    Assert-True (@($record.repositoryViolations).Count -eq 0) 'allowed edit caused a repository violation'
    Assert-True (@($record.attempts).Count -eq 1) 'successful native execution recorded the wrong attempt count'
    Assert-True (Test-Path -LiteralPath $record.rawOutputPath) 'raw output contract path is missing'
    Assert-True (Test-Path -LiteralPath $record.rawErrorPath) 'raw error contract path is missing'
    Assert-True (Test-Path -LiteralPath $record.resultPath) 'normalized result contract path is missing'
    $storedResult = Get-Content -Raw -LiteralPath $record.resultPath | ConvertFrom-Json
    Assert-True (
        (Test-ClaudeResultContract -Result $storedResult -Task $validatedTask)
    ) 'stored result did not satisfy the result contract'
    Assert-StringArrayShape -Value $record.changedDuringTask -Name 'changedDuringTask'
    Assert-StringArrayShape -Value $record.scopeViolations -Name 'scopeViolations'
    Assert-StringArrayShape -Value $record.repositoryViolations -Name 'repositoryViolations'

    $afterMetadata = Get-GitMetadataSnapshot -Context $context
    $afterSiblings = Get-SiblingWorktreeFingerprint -Context $context
    foreach ($property in @(
        'Head',
        'Branch',
        'Remotes',
        'Index',
        'IndexFile',
        'Refs',
        'RepositoryConfig',
        'WorktreeConfig'
    )) {
        Assert-True (
            $beforeMetadata.$property -ceq $afterMetadata.$property
        ) "delegation changed protected Git state: $property"
    }
    Assert-True (
        @(Compare-SiblingWorktreeFingerprint -Before $beforeSiblings -After $afterSiblings).Count -eq 0
    ) 'delegation changed a sibling worktree'
    Assert-True (
        (Get-Content -Raw -LiteralPath (Join-Path $mainRepository 'sibling-marker.txt')) -ceq
        $siblingMarkerBefore
    ) 'delegation changed the sibling checkout marker'
    Assert-True (
        (Get-Content -Raw -LiteralPath (Join-Path $linkedWorktree 'src/parser.ps1')) -match
        '(?m)^delegated-change$'
    ) 'runner automatically reverted or missed the allowed edit'

    $capturedPrompt = Get-Content -Raw -LiteralPath $env:CLAUDE_FAKE_STDIN_CAPTURE
    Assert-True (
        $capturedPrompt -ceq [string]$dryInvocation.standardInput
    ) 'captured standard input differed from the complete validated task prompt'
    $claudeArguments = Read-NulArgumentCapture $env:CLAUDE_FAKE_ARGV_CAPTURE
    $expectedClaudeArguments = [string[]]@(
        $dryInvocation.arguments | ForEach-Object { [string]$_ }
    )
    Assert-True (
        $claudeArguments.Count -eq $expectedClaudeArguments.Count
    ) "Claude argv count differed from the validated invocation: expected $($expectedClaudeArguments.Count), got $($claudeArguments.Count)"
    for ($argumentIndex = 0; $argumentIndex -lt $expectedClaudeArguments.Count; $argumentIndex++) {
        Assert-True (
            $claudeArguments[$argumentIndex] -ceq $expectedClaudeArguments[$argumentIndex]
        ) "Claude argv[$argumentIndex] differed from the validated invocation"
    }
    foreach ($sentinel in $stdinOnlySentinels.GetEnumerator()) {
        Assert-True (
            @($claudeArguments | Where-Object {
                $_.Contains([string]$sentinel.Value)
            }).Count -eq 0
        ) "stdin-only $($sentinel.Key) sentinel leaked onto captured native argv"
    }
    Assert-True (
        @($claudeArguments | Where-Object {
            $_ -ceq '--dangerously-skip-permissions'
        }).Count -eq 1
    ) 'validated Claude execution did not receive exactly one permission-bypass argument'
    Assert-True (
        -not (Test-Path -LiteralPath $env:DELEGATION_OPEN_CAPTURE)
    ) 'authenticated delegation opened the owner setup Terminal'

    Write-Output 'macOS delegation end-to-end tests passed.'
} finally {
    $env:PATH = $savedPath
    if ($null -eq $savedClaudeArgvCapture) {
        Remove-Item Env:\CLAUDE_FAKE_ARGV_CAPTURE -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_FAKE_ARGV_CAPTURE = $savedClaudeArgvCapture
    }
    if ($null -eq $savedClaudeStdinCapture) {
        Remove-Item Env:\CLAUDE_FAKE_STDIN_CAPTURE -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_FAKE_STDIN_CAPTURE = $savedClaudeStdinCapture
    }
    if ($null -eq $savedOpenCapture) {
        Remove-Item Env:\DELEGATION_OPEN_CAPTURE -ErrorAction SilentlyContinue
    } else {
        $env:DELEGATION_OPEN_CAPTURE = $savedOpenCapture
    }
    $fixtureRoot = Assert-VerifiedFixtureRoot $fixtureRoot
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
