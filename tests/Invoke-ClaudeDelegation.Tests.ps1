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
    'id', 'goal', 'mode', 'baseBranch', 'featureBranch', 'allowedPaths', 'forbiddenPaths',
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

Assert-True ((Get-PathStringComparison -Platform 'Windows') -eq [System.StringComparison]::OrdinalIgnoreCase) 'Windows paths must use ordinal case-insensitive comparison'
Assert-True ((Get-PathStringComparison -Platform 'MacOS') -eq [System.StringComparison]::Ordinal) 'macOS paths must use ordinal case-sensitive comparison'
Assert-True (Test-CanonicalPathEqual -Left 'C:\Delegation\Task.json' -Right 'c:\delegation\task.json' -Platform 'Windows') 'Windows canonical paths must compare case-insensitively'
Assert-True (-not (Test-CanonicalPathEqual -Left '/Users/delegation/Task.json' -Right '/Users/delegation/task.json' -Platform 'MacOS')) 'macOS canonical paths must compare case-sensitively'

$canonicalPathFixture = Join-Path ([System.IO.Path]::GetTempPath()) (
    'claude-delegation-canonical-path-' + [guid]::NewGuid().ToString('N')
)
$canonicalPathTarget = Join-Path $canonicalPathFixture 'physical-target'
$canonicalPathAlias = Join-Path $canonicalPathFixture 'directory-alias'
try {
    New-Item -ItemType Directory -Path $canonicalPathTarget -Force | Out-Null
    $canonicalPathFile = Join-Path $canonicalPathTarget 'task.json'
    Set-Content -LiteralPath $canonicalPathFile -Value '{}' -Encoding UTF8
    New-Item -ItemType Junction -Path $canonicalPathAlias -Target $canonicalPathTarget | Out-Null

    $resolvedPhysicalFile = Resolve-AbsolutePath $canonicalPathFile
    $resolvedAliasFile = Resolve-AbsolutePath (Join-Path $canonicalPathAlias 'task.json')
    Assert-True (
        $resolvedAliasFile -eq $resolvedPhysicalFile
    ) 'existing absolute paths must resolve parent link aliases to one filesystem identity'

    $canonicalExpectedState = Join-Path $canonicalPathFixture 'expected-state'
    New-Item -ItemType Directory -Path $canonicalExpectedState -Force | Out-Null
    $escapedDirectoryAlias = Join-Path $canonicalExpectedState 'escaped-directory'
    New-Item -ItemType Junction -Path $escapedDirectoryAlias -Target $canonicalPathTarget | Out-Null
    $escapedTaskAlias = Join-Path $escapedDirectoryAlias 'task.json'
    Assert-True (
        (Resolve-AbsolutePath $escapedTaskAlias) -eq $resolvedPhysicalFile
    ) 'a task packet under a linked parent must resolve outside the state directory so containment checks reject escapes'
} finally {
    $canonicalPathFixtureFull = [System.IO.Path]::GetFullPath($canonicalPathFixture)
    $temporaryRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd('\', '/')
    Assert-True (
        (Split-Path -Parent $canonicalPathFixtureFull).TrimEnd('\', '/') -eq $temporaryRoot -and
        (Split-Path -Leaf $canonicalPathFixtureFull) -match '^claude-delegation-canonical-path-[0-9a-f]{32}$'
    ) 'canonical-path fixture cleanup escaped its test-owned temporary path'
    if (Test-Path -LiteralPath $canonicalPathFixtureFull) {
        Remove-Item -LiteralPath $canonicalPathFixtureFull -Recurse -Force
    }
}

$macAliasOriginalResolveAbsolutePath = ${function:Resolve-AbsolutePath}
$macAliasOriginalInvokeGit = ${function:Invoke-Git}
$macAliasOriginalGetDelegationPlatform = ${function:Get-DelegationPlatform}
try {
    function Resolve-AbsolutePath([string]$Path) { return $Path.TrimEnd('/', '\') }
    function Get-DelegationPlatform { return 'MacOS' }
    function Invoke-Git([string]$Path, [string[]]$Arguments) {
        $operation = $Arguments -join ' '
        switch ($operation) {
            'rev-parse --show-prefix' {
                if ($Path -ceq '/var/folders/delegation/linked/nested') { return 'nested/' }
                return ''
            }
            'rev-parse --show-toplevel' { return '/private/var/folders/delegation/linked' }
            'rev-parse --absolute-git-dir' { return '/private/var/folders/delegation/main/.git/worktrees/linked' }
            'rev-parse --git-common-dir' { return '/private/var/folders/delegation/main/.git' }
            'branch --show-current' { return 'feature/mac-alias' }
            default { throw "Unexpected alias-regression Git operation: $operation" }
        }
    }

    $macAliasContext = Get-WorktreeContext -WorktreePath '/var/folders/delegation/linked'
    Assert-True ($macAliasContext.worktreePath -ceq '/private/var/folders/delegation/linked') 'Git top level must be authoritative across the macOS /var alias'
    Assert-True ($macAliasContext.branch -ceq 'feature/mac-alias') 'macOS alias context lost the linked branch'

    $macAliasNestedRejected = $false
    try {
        Get-WorktreeContext -WorktreePath '/var/folders/delegation/linked/nested' | Out-Null
    } catch {
        $macAliasNestedRejected = $true
    }
    Assert-True $macAliasNestedRejected 'non-empty Git prefix must reject a nested macOS worktree path'
} finally {
    Set-Item Function:\Resolve-AbsolutePath -Value $macAliasOriginalResolveAbsolutePath
    Set-Item Function:\Invoke-Git -Value $macAliasOriginalInvokeGit
    Set-Item Function:\Get-DelegationPlatform -Value $macAliasOriginalGetDelegationPlatform
}

$ownerSetupWindowsWorktree = 'C:\Delegation Worktree'
$ownerSetupWindowsState = Join-Path $ownerSetupWindowsWorktree '.codex/claude-handoff'
foreach ($installed in @($false, $true)) {
    $windowsOwnerSetup = New-OwnerSetupLaunchSpec -Worktree $ownerSetupWindowsWorktree `
        -StateDirectory $ownerSetupWindowsState -Installed $installed -Platform 'Windows'
    Assert-True ($windowsOwnerSetup.FilePath -eq 'powershell') 'Windows owner setup must launch Windows PowerShell'
    Assert-True ($windowsOwnerSetup.ArgumentList -contains '-NoExit') 'Windows owner setup must remain visible and interactive'
    Assert-True ($windowsOwnerSetup.WorkingDirectory -eq $ownerSetupWindowsWorktree) 'Windows owner setup must use the worktree as its working directory'
    Assert-True ((@($windowsOwnerSetup.ArgumentList) -join ' ') -notmatch 'dangerously-skip-permissions') 'Windows owner setup must not receive bypass permissions'
}

$ownerSetupMacWorktree = "/Users/Owner's Worktrees/Delegation Task"
$ownerSetupMacState = Join-Path $ownerSetupMacWorktree '.codex/claude-handoff'
$expectedQuotedMacWorktree = "'/Users/Owner'`"`"'`"`"'s Worktrees/Delegation Task'"
Assert-True ((ConvertTo-PosixSingleQuotedString $ownerSetupMacWorktree) -ceq $expectedQuotedMacWorktree) 'macOS owner setup must safely POSIX-quote spaces and apostrophes'

$missingMacOwnerSetup = New-OwnerSetupLaunchSpec -Worktree $ownerSetupMacWorktree `
    -StateDirectory $ownerSetupMacState -Installed $false -Platform 'MacOS'
$installedMacOwnerSetup = New-OwnerSetupLaunchSpec -Worktree $ownerSetupMacWorktree `
    -StateDirectory $ownerSetupMacState -Installed $true -Platform 'MacOS'
foreach ($macOwnerSetup in @($missingMacOwnerSetup, $installedMacOwnerSetup)) {
    Assert-True ($macOwnerSetup.FilePath -eq 'open') 'macOS owner setup must use open'
    Assert-True ($macOwnerSetup.ArgumentList.Count -eq 3) 'macOS owner setup must pass only the Terminal application and setup script'
    Assert-True ($macOwnerSetup.ArgumentList[0] -eq '-a') 'macOS owner setup must select an application'
    Assert-True ($macOwnerSetup.ArgumentList[1] -eq 'Terminal') 'macOS owner setup must launch Terminal'
    Assert-True ($macOwnerSetup.ArgumentList[2] -eq $macOwnerSetup.ScriptPath) 'macOS Terminal must receive the generated setup script path'
    Assert-True ([System.IO.Path]::GetExtension($macOwnerSetup.ScriptPath) -eq '.command') 'macOS owner setup script must use the .command extension'
    Assert-True ((Split-Path -Parent $macOwnerSetup.ScriptPath) -eq $ownerSetupMacState) 'macOS owner setup script must stay under the handoff state directory'
    Assert-True ($macOwnerSetup.ScriptContent -match [regex]::Escape("cd -- $expectedQuotedMacWorktree")) 'macOS owner setup script must safely change to the requested worktree'
    Assert-True ($macOwnerSetup.ScriptContent -notmatch 'dangerously-skip-permissions') 'macOS owner setup script must not contain bypass permissions'
}
Assert-True ($missingMacOwnerSetup.ScriptContent -match 'Claude Code CLI is not installed') 'missing-Claude macOS setup must explain the install requirement'
Assert-True ($missingMacOwnerSetup.ScriptContent -notmatch '(?m)^\s*claude(?:\s|$)') 'missing-Claude macOS setup must not invoke an unavailable Claude CLI'
Assert-True ($missingMacOwnerSetup.ScriptContent -match '(?m)^exec "\$\{SHELL:-/bin/zsh\}" -l\s*$') 'missing-Claude macOS setup must end in an interactive login shell'
Assert-True ($installedMacOwnerSetup.ScriptContent -match '(?m)^\s*claude\s*$') 'installed macOS setup must start Claude interactively'
Assert-True ($installedMacOwnerSetup.ScriptContent -match '/login') 'installed macOS setup must direct the owner to /login'
Assert-True ($installedMacOwnerSetup.ScriptContent -match '(?m)^exec "\$\{SHELL:-/bin/zsh\}" -l\s*$') 'installed macOS setup must leave an interactive login shell afterward'

$macOwnerSetupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-delegation-macos-owner-setup-' + [guid]::NewGuid())
$macOwnerSetupState = Join-Path $macOwnerSetupRoot '.codex/claude-handoff'
$macOwnerSetupBin = Join-Path $macOwnerSetupRoot 'bin'
$macChmodCapturePath = Join-Path $macOwnerSetupRoot 'chmod-arguments.txt'
$macOwnerSetupOriginalPlatform = ${function:Get-DelegationPlatform}
$macOwnerSetupOriginalLaunch = ${function:Invoke-OwnerSetupLaunchSpec}
$macOwnerSetupSavedPath = $env:PATH
$global:capturedMacOwnerSetup = [ordered]@{
    Launch = $null
    LaunchPlatform = $null
}
try {
    New-Item -ItemType Directory -Force -Path $macOwnerSetupState, $macOwnerSetupBin | Out-Null
    @'
@echo off
echo %~1>"%CLAUDE_CHMOD_CAPTURE%"
echo %~2>>"%CLAUDE_CHMOD_CAPTURE%"
if not "%~3"=="" echo %~3>>"%CLAUDE_CHMOD_CAPTURE%"
'@ | Set-Content -LiteralPath (Join-Path $macOwnerSetupBin 'chmod.cmd') -Encoding ASCII
    $env:CLAUDE_CHMOD_CAPTURE = $macChmodCapturePath
    $env:PATH = "$macOwnerSetupBin;$macOwnerSetupSavedPath"
    Set-Item Function:\Get-DelegationPlatform -Value { return 'MacOS' }
    function Invoke-OwnerSetupLaunchSpec {
        param($LaunchSpec, [string]$Platform)
        $global:capturedMacOwnerSetup.Launch = $LaunchSpec
        $global:capturedMacOwnerSetup.LaunchPlatform = $Platform
    }
    function Start-Process {
        throw 'macOS owner setup must not use Start-Process because it flattens native argument boundaries.'
    }

    Show-OwnerSetup -Worktree $macOwnerSetupRoot -StateDirectory $macOwnerSetupState -Installed $true

    $writtenMacSetupPath = Join-Path $macOwnerSetupState 'claude-owner-setup.command'
    Assert-True (Test-Path -LiteralPath $writtenMacSetupPath) 'macOS owner setup must write the generated command script before launch'
    $writtenMacSetupBytes = [System.IO.File]::ReadAllBytes($writtenMacSetupPath)
    $hasUtf8Bom = $writtenMacSetupBytes.Length -ge 3 -and $writtenMacSetupBytes[0] -eq 0xEF -and `
        $writtenMacSetupBytes[1] -eq 0xBB -and $writtenMacSetupBytes[2] -eq 0xBF
    Assert-True (-not $hasUtf8Bom) 'macOS owner setup script must be UTF-8 without BOM'
    Assert-True (Test-Path -LiteralPath $macChmodCapturePath) 'macOS owner setup must secure the script before launching Terminal'
    $capturedMacChmodArguments = @(Get-Content -LiteralPath $macChmodCapturePath)
    Assert-True ($capturedMacChmodArguments.Count -eq 2) "macOS owner setup chmod must receive mode and exact path only: $($capturedMacChmodArguments -join '|')"
    Assert-True ($capturedMacChmodArguments[0] -eq '700') 'macOS owner setup chmod must set mode 700'
    Assert-True ([System.IO.Path]::IsPathRooted($capturedMacChmodArguments[1])) 'macOS owner setup chmod must receive an absolute script path'
    Assert-True ($capturedMacChmodArguments[1] -ceq $writtenMacSetupPath) 'macOS owner setup chmod must receive the exact script path without shell interpolation'
    Assert-True ($global:capturedMacOwnerSetup.Launch.FilePath -eq 'open') 'macOS owner setup execution must launch the inspected open specification'
    Assert-True ($global:capturedMacOwnerSetup.LaunchPlatform -eq 'MacOS') 'macOS owner setup must use the argv-preserving macOS launch seam'
} finally {
    Set-Item Function:\Get-DelegationPlatform -Value $macOwnerSetupOriginalPlatform
    if ($null -ne $macOwnerSetupOriginalLaunch) {
        Set-Item Function:\Invoke-OwnerSetupLaunchSpec -Value $macOwnerSetupOriginalLaunch
    } else {
        Remove-Item -Path Function:\Invoke-OwnerSetupLaunchSpec -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path Function:\Start-Process -Force -ErrorAction SilentlyContinue
    $env:PATH = $macOwnerSetupSavedPath
    Remove-Item Env:\CLAUDE_CHMOD_CAPTURE -ErrorAction SilentlyContinue
    Remove-Variable -Name capturedMacOwnerSetup -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $macOwnerSetupRoot) {
        Remove-Item -LiteralPath $macOwnerSetupRoot -Recurse -Force
    }
}

$argumentListProperty = [System.Diagnostics.ProcessStartInfo].GetProperty('ArgumentList')
if ($null -eq $argumentListProperty) {
    $macLaunchRejectedOnLegacyPowerShell = $false
    try {
        Invoke-OwnerSetupLaunchSpec -LaunchSpec ([pscustomobject]@{
            FilePath = 'open'
            ArgumentList = [object[]]@('-a', 'Terminal', "/tmp/Owner's Delegation Task.command")
            WorkingDirectory = '/tmp'
        }) -Platform 'MacOS' | Out-Null
    } catch {
        $macLaunchRejectedOnLegacyPowerShell = $_.Exception.Message -match 'PowerShell 7|ArgumentList'
    }
    Assert-True $macLaunchRejectedOnLegacyPowerShell 'legacy PowerShell must reject macOS launch instead of flattening argument boundaries'
} else {
    $argvProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-delegation-argv-probe-' + [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Force -Path $argvProbeRoot | Out-Null
        $argvProbeScript = Join-Path $argvProbeRoot 'capture argv.ps1'
        $argvProbeOutput = Join-Path $argvProbeRoot 'captured argv.json'
        @'
param([string]$OutputPath)
[System.IO.File]::WriteAllText(
    $OutputPath,
    (@($args) | ConvertTo-Json -Compress),
    [System.Text.UTF8Encoding]::new($false)
)
'@ | Set-Content -LiteralPath $argvProbeScript -Encoding UTF8
        $expectedSpacedScriptPath = Join-Path $argvProbeRoot "Owner's Delegation Task.command"
        $argvProbeLaunch = [pscustomobject]@{
            FilePath = (Get-Process -Id $PID).Path
            ArgumentList = [object[]]@(
                '-NoProfile', '-File', $argvProbeScript, $argvProbeOutput,
                '-a', 'Terminal', $expectedSpacedScriptPath
            )
            WorkingDirectory = $argvProbeRoot
        }
        $argvProbeProcess = Invoke-OwnerSetupLaunchSpec -LaunchSpec $argvProbeLaunch -Platform 'MacOS'
        try {
            Assert-True ($argvProbeProcess.WaitForExit(30000)) 'argv probe process did not exit'
            Assert-True ($argvProbeProcess.ExitCode -eq 0) 'argv probe process failed'
        } finally {
            $argvProbeProcess.Dispose()
        }
        $capturedArgv = @(Get-Content -Raw -LiteralPath $argvProbeOutput | ConvertFrom-Json)
        Assert-True ($capturedArgv.Count -eq 3) 'macOS argv-preserving launch changed the native argument count'
        Assert-True ($capturedArgv[0] -eq '-a') 'macOS argv-preserving launch changed the application selector'
        Assert-True ($capturedArgv[1] -eq 'Terminal') 'macOS argv-preserving launch changed the Terminal application name'
        Assert-True ($capturedArgv[2] -ceq $expectedSpacedScriptPath) 'macOS argv-preserving launch split or changed the spaced/apostrophe script path'
    } finally {
        if (Test-Path -LiteralPath $argvProbeRoot) {
            Remove-Item -LiteralPath $argvProbeRoot -Recurse -Force
        }
    }
}

$macFingerprintRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-delegation-macos-fingerprint-' + [guid]::NewGuid())
$originalGetDelegationPlatform = ${function:Get-DelegationPlatform}
$originalInvokeGit = ${function:Invoke-Git}
$originalResolveAbsolutePath = ${function:Resolve-AbsolutePath}
$originalGetWorktreeFingerprint = ${function:Get-WorktreeFingerprint}
try {
    Set-Item Function:\Get-DelegationPlatform -Value { return 'MacOS' }
    New-Item -ItemType Directory -Path $macFingerprintRoot | Out-Null

    $macPrimaryFingerprint = Get-WorktreeFingerprint -Worktree $macFingerprintRoot
    $macPrimaryFingerprint['Foo.txt'] = 'upper'
    $macPrimaryFingerprint['foo.txt'] = 'lower'
    Assert-True ($macPrimaryFingerprint.Count -eq 2) 'macOS primary fingerprint collapsed paths that differ only by case'

    $emptyMacPrimaryFingerprint = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $macPrimaryChanges = Compare-WorktreeFingerprint -Before $emptyMacPrimaryFingerprint -After $macPrimaryFingerprint
    Assert-True (@($macPrimaryChanges).Count -eq 2) 'macOS primary fingerprint comparison collapsed case-distinct path keys'

    Set-Item Function:\Invoke-Git -Value {
        param([string]$Path, [string[]]$Arguments)
        return "worktree /repo/primary`nworktree /repo/Foo`nworktree /repo/foo"
    }
    Set-Item Function:\Resolve-AbsolutePath -Value {
        param([string]$Path)
        return $Path
    }
    Set-Item Function:\Get-WorktreeFingerprint -Value {
        param([string]$Worktree)
        return @{ marker = $Worktree }
    }
    $macSiblingContext = [pscustomobject]@{ worktreePath = '/repo/primary' }
    $macSiblingFingerprint = Get-SiblingWorktreeFingerprint -Context $macSiblingContext
    Assert-True ($macSiblingFingerprint.Count -eq 2) 'macOS sibling fingerprint collapsed worktree paths that differ only by case'

    $emptyMacSiblingFingerprint = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $macSiblingChanges = Compare-SiblingWorktreeFingerprint -Before $emptyMacSiblingFingerprint -After $macSiblingFingerprint
    Assert-True (@($macSiblingChanges).Count -eq 2) 'macOS sibling fingerprint comparison collapsed case-distinct path keys'
} finally {
    Set-Item Function:\Get-DelegationPlatform -Value $originalGetDelegationPlatform
    Set-Item Function:\Invoke-Git -Value $originalInvokeGit
    Set-Item Function:\Resolve-AbsolutePath -Value $originalResolveAbsolutePath
    Set-Item Function:\Get-WorktreeFingerprint -Value $originalGetWorktreeFingerprint
    if (Test-Path -LiteralPath $macFingerprintRoot) {
        Remove-Item -LiteralPath $macFingerprintRoot -Recurse -Force
    }
}

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
    baseBranch='main'; featureBranch='feature/test'
    allowedPaths=@('src/parser.ps1'); forbiddenPaths=@('.git/**', '.env*', 'secrets/**', 'credentials/**')
    forbiddenActions=@(
        'git commit', 'git push', 'git pull', 'git fetch', 'git merge',
        'git rebase', 'git reset', 'git checkout', 'git switch', 'git stash',
        'git tag', 'git remote', 'git worktree',
        'read or expose secrets', 'read or expose credentials'
    ); context=@()
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
foreach ($denyPattern in ($expectedGitDenyPatterns | ForEach-Object { $_ -replace '^Bash', 'PowerShell' })) {
    Assert-True ($directInvocation.arguments -contains $denyPattern) "native PowerShell git wrapper deny rule missing: $denyPattern"
}
Assert-True ($directInvocation.arguments -contains '--output-format') 'output-format flag missing'
Assert-True ($directInvocation.arguments[[Array]::IndexOf([object[]]$directInvocation.arguments, '--output-format') + 1] -eq 'json') 'direct mode output must remain JSON'

foreach ($invalidLimit in @(
    [pscustomobject]@{ property = 'maxTurns'; value = 0; message = 'zero maxTurns must be rejected' },
    [pscustomobject]@{ property = 'maxTurns'; value = 1.5; message = 'fractional maxTurns must be rejected' },
    [pscustomobject]@{ property = 'timeoutSeconds'; value = 0; message = 'zero timeoutSeconds must be rejected' },
    [pscustomobject]@{ property = 'maxBudgetUsd'; value = 0; message = 'zero maxBudgetUsd must be rejected' },
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

foreach ($invalidPath in @('C:/outside/**', '../outside/**', './src/**', 'src\**', '**', 'src*', 'src//api/**')) {
    $invalidPathTask = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidPathTask.allowedPaths = @($invalidPath)
    $invalidPathRejected = $false
    try { Assert-DelegationPolicy -Task $invalidPathTask } catch { $invalidPathRejected = $true }
    Assert-True $invalidPathRejected "unsafe or non-normalized allowed path was accepted: $invalidPath"
}
$missingSensitiveProhibitions = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$missingSensitiveProhibitions.forbiddenPaths = @('.git/**')
$missingSensitiveRejected = $false
try { Assert-DelegationPolicy -Task $missingSensitiveProhibitions } catch { $missingSensitiveRejected = $true }
Assert-True $missingSensitiveRejected 'task without sensitive or credential path prohibitions was accepted'

$missingGitActions = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$missingGitActions.forbiddenActions = @('git commit', 'read or expose secrets', 'read or expose credentials')
$missingGitActionsRejected = $false
try { Assert-DelegationPolicy -Task $missingGitActions } catch { $missingGitActionsRejected = $true }
Assert-True $missingGitActionsRejected 'task without the complete Git prohibition set was accepted'

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
$team.allowedPaths = @('src/api/**', 'src/ui/**')
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
$boundaryDistinct.allowedPaths = @('src/api/**', 'src/api-client/**')
Assert-DelegationPolicy -Task $boundaryDistinct

$oversizedTeam = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$oversizedTeam.parallelWorkstreams = @(
    [pscustomobject]@{ name='one'; ownedPaths=@('src/one/**') },
    [pscustomobject]@{ name='two'; ownedPaths=@('src/two/**') },
    [pscustomobject]@{ name='three'; ownedPaths=@('src/three/**') },
    [pscustomobject]@{ name='four'; ownedPaths=@('src/four/**') }
)
$oversizedTeam.allowedPaths = @('src/one/**', 'src/two/**', 'src/three/**', 'src/four/**')
$oversizedRejected = $false
try { Assert-DelegationPolicy -Task $oversizedTeam } catch { $oversizedRejected = $true }
Assert-True $oversizedRejected 'agent team with more than three workstreams and no justification was accepted'
$oversizedTeam | Add-Member -NotePropertyName parallelismJustification -NotePropertyValue 'Four disjoint platform adapters must be completed within the bounded task limits.'
Assert-DelegationPolicy -Task $oversizedTeam

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-delegation-" + [guid]::NewGuid())
$mainRepo = Join-Path $fixtureRoot 'main'
$linked = Join-Path $fixtureRoot 'feature'
$fixtureFailure = $null
$fixtureCleaned = $false
try {
    New-Item -ItemType Directory -Force -Path $mainRepo | Out-Null
    Invoke-TestGit $mainRepo @('init', '-b', 'main') | Out-Null
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

    $nestedPathRejected = $false
    New-Item -ItemType Directory -Force -Path (Join-Path $linked 'nested') | Out-Null
    try { Get-WorktreeContext -WorktreePath (Join-Path $linked 'nested') | Out-Null } catch { $nestedPathRejected = $true }
    Assert-True $nestedPathRejected 'a nested directory was accepted as the linked worktree root'

    $state = Initialize-HandoffState -Context $linkedContext -Task $direct
    Assert-True (Test-Path -LiteralPath $state.ledgerPath) 'ledger was not created'
    $ignoreLines = Get-Content -LiteralPath (Join-Path $linked '.gitignore')
    Assert-True ($ignoreLines -contains 'existing-rule') 'gitignore did not preserve existing content'
    Assert-True ($ignoreLines -contains '.codex/claude-handoff/') 'gitignore missing handoff rule'

    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    Assert-True ($ledger.version -eq 1) 'ledger version must be 1'
    foreach ($field in @('repositoryId', 'worktreePath', 'baseBranch', 'featureBranch', 'primarySessionId', 'tasks')) {
        Assert-True ($ledger.PSObject.Properties.Name -contains $field) "ledger missing $field"
    }
    Assert-True ($ledger.repositoryId -eq $linkedContext.repositoryId) 'ledger repository ID mismatch'
    Assert-True ($ledger.worktreePath -eq $linkedContext.worktreePath) 'ledger worktree path mismatch'
    Assert-True ($ledger.baseBranch -eq 'main') 'ledger base branch mismatch'
    Assert-True ($ledger.featureBranch -eq $linkedContext.branch) 'ledger feature branch mismatch'
    Assert-True (@($ledger.tasks).Count -eq 0) 'new ledger tasks must be empty'

    $validLedgerJson = Get-Content -Raw -LiteralPath $state.ledgerPath
    $mainRepositoryAlias = Join-Path $fixtureRoot 'main-alias'
    $linkedWorktreeAlias = Join-Path $fixtureRoot 'feature-alias'
    New-Item -ItemType Junction -Path $mainRepositoryAlias -Target $mainRepo | Out-Null
    New-Item -ItemType Junction -Path $linkedWorktreeAlias -Target $linked | Out-Null
    $aliasLedger = $validLedgerJson | ConvertFrom-Json
    $aliasLedger.repositoryId = Join-Path $mainRepositoryAlias '.git'
    $aliasLedger.worktreePath = $linkedWorktreeAlias
    $aliasLedger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $state.ledgerPath -Encoding UTF8
    Read-AndAssertHandoffLedger -LedgerPath $state.ledgerPath -Context $linkedContext -Task $direct | Out-Null
    Set-Content -LiteralPath $state.ledgerPath -Value $validLedgerJson -Encoding UTF8

    foreach ($mutation in @(
        [pscustomobject]@{ name='version'; apply={ param($x) $x.version = 2 } },
        [pscustomobject]@{ name='repository'; apply={ param($x) $x.repositoryId = 'wrong' } },
        [pscustomobject]@{ name='worktree'; apply={ param($x) $x.worktreePath = $mainRepo } },
        [pscustomobject]@{ name='feature branch'; apply={ param($x) $x.featureBranch = 'feature/wrong' } }
    )) {
        $mutatedLedger = $validLedgerJson | ConvertFrom-Json
        & $mutation.apply $mutatedLedger
        $mutatedLedger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $state.ledgerPath -Encoding UTF8
        $ledgerRejected = $false
        try { Read-AndAssertHandoffLedger -LedgerPath $state.ledgerPath -Context $linkedContext -Task $direct | Out-Null } catch { $ledgerRejected = $true }
        Assert-True $ledgerRejected "ledger $($mutation.name) mismatch was accepted"
    }
    Set-Content -LiteralPath $state.ledgerPath -Value $validLedgerJson -Encoding UTF8
    Read-AndAssertHandoffLedger -LedgerPath $state.ledgerPath -Context $linkedContext -Task $direct | Out-Null

    $fakeClaude = Join-Path $fixtureRoot 'fake-claude.cmd'
    @'
@echo off
if not "%1"=="auth" goto version
if not "%2"=="status" goto version
if "%CLAUDE_FAKE_AUTH%"=="false" (
  echo {"loggedIn":false}
  exit /b 0
)
echo {"loggedIn":true}
exit /b 0
:version
if not "%1"=="--version" goto modes
echo 2.1.211 ^(Claude Code^)
exit /b 0
:modes
if "%CLAUDE_FAKE_MODE%"=="timeout" (
  ping 127.0.0.1 -n 6 >nul
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="no-stdin" (
  ping 127.0.0.1 -n 8 >nul
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="capture-stdin" (
  chcp 65001 >nul
  powershell -NoProfile -Command "$utf8 = [System.Text.UTF8Encoding]::new($false); $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8); $text = $reader.ReadToEnd(); $path = Join-Path (Get-Location) '.codex\claude-handoff\captured-stdin.txt'; [System.IO.File]::WriteAllText($path, $text, $utf8)"
) else (
  more >nul
)
if "%CLAUDE_FAKE_MODE%"=="malformed" (
  echo not-json
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="allowed-edit" (
  echo delegated-change>>"%CD%\src\parser.ps1"
)
if "%CLAUDE_FAKE_MODE%"=="ignored-edit" (
  echo delegated-secret>>"%CD%\.env"
)
if "%CLAUDE_FAKE_MODE%"=="forbidden-edit" (
  if not exist "%CD%\.github\workflows" mkdir "%CD%\.github\workflows"
  echo forbidden>"%CD%\.github\workflows\ci.yml"
)
if "%CLAUDE_FAKE_MODE%"=="remote-change" (
  git -C "%CD%" remote add delegation-evil https://example.invalid/evil.git
)
if "%CLAUDE_FAKE_MODE%"=="staged-change" (
  git -C "%CD%" add src\parser.ps1
)
if "%CLAUDE_FAKE_MODE%"=="skip-worktree-change" (
  git -C "%CD%" update-index --skip-worktree src\parser.ps1
)
if "%CLAUDE_FAKE_MODE%"=="assume-unchanged-change" (
  git -C "%CD%" update-index --assume-unchanged src\parser.ps1
)
if "%CLAUDE_FAKE_MODE%"=="ref-change" (
  git -C "%CD%" branch delegated-ref
  git -C "%CD%" tag delegated-tag
)
if "%CLAUDE_FAKE_MODE%"=="config-change" (
  git -C "%CD%" config --local delegation.fake true
)
if "%CLAUDE_FAKE_MODE%"=="sibling-edit" (
  echo delegated-sibling-change>>"%CD%\..\main\seed.txt"
)
if "%CLAUDE_FAKE_MODE%"=="head-change" (
  git -C "%CD%" commit --allow-empty -m delegated-head-change >nul
)
if "%CLAUDE_FAKE_MODE%"=="branch-change" (
  git -C "%CD%" checkout -b delegated-branch >nul
)
if "%CLAUDE_FAKE_MODE%"=="replace-lock" (
  echo replacement-lock>"%CD%\.codex\claude-handoff\running.lock"
)
if "%CLAUDE_FAKE_MODE%"=="capture-environment" (
  if defined CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (echo %CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS%) else (echo ^<unset^>) >"%CD%\.codex\claude-handoff\child-team-env.txt"
)
if "%CLAUDE_FAKE_MODE%"=="large" (
  for /L %%A in (1,1,700) do <nul set /p "=0123456789"
  echo.
)
if "%CLAUDE_FAKE_MODE%"=="slow-eof" (
  start "" /b powershell -NoProfile -Command "Start-Sleep -Seconds 3; Write-Output delayed-eof-marker"
)
if "%CLAUDE_FAKE_MODE%"=="mismatched-id" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"wrong-task","status":"completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="wrong-types" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"completed","summary":"done","changedFiles":"not-an-array","tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="bad-status" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"rejected","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="extra-field" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[],"extra":"no"}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="invalid-test" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"completed","summary":"done","changedFiles":[],"tests":[{"command":"test","outcome":"unknown","extra":"no"}],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="wrong-case-property" (
  echo {"type":"result","session_id":"invalid-session","result":{"TaskId":"task-direct","status":"completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="wrong-case-status" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"Completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="wrong-case-outcome" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"task-direct","status":"completed","summary":"done","changedFiles":[],"tests":[{"command":"test","outcome":"Passed"}],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="wrong-case-task-id" (
  echo {"type":"result","session_id":"invalid-session","result":{"taskId":"TASK-DIRECT","status":"completed","summary":"done","changedFiles":[],"tests":[],"unresolvedIssues":[],"deviations":[]}}
  exit /b 0
)
if "%CLAUDE_FAKE_MODE%"=="nonzero" (
  echo ordinary failure 1>&2
  exit /b 7
)
if "%CLAUDE_FAKE_MODE%"=="git-corrupt" (
  echo entered>"%CD%\.codex\claude-handoff\corrupt-entered.txt"
  powershell -NoProfile -Command "$p = Join-Path (Get-Location) '.git'; [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::Normal); [System.IO.File]::WriteAllText($p, 'gitdir: Z:\missing-delegation-gitdir')" 2>"%CD%\.codex\claude-handoff\corrupt-error.txt"
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
        Show-OwnerSetup -Worktree $linked -StateDirectory $state.stateDir -Installed $true
        $installedSetup = $capturedStartProcess
        $installedSetupArguments = @($installedSetup.ArgumentList) -join ' '
        Assert-True ($installedSetup.FilePath -eq 'powershell') 'owner setup must launch Windows PowerShell'
        Assert-True ($installedSetup.ArgumentList -contains '-NoExit') 'owner setup window must remain open for manual work'
        Assert-True ($installedSetupArguments -match 'if \(Get-Command claude') 'installed setup must verify Claude before login'
        Assert-True ($installedSetupArguments -match 'claude auth login') 'installed setup did not offer authentication'
        Assert-True ($installedSetupArguments -notmatch 'dangerously-skip-permissions') 'owner setup received bypass permissions'
        Assert-True ($capturedStartProcess.WorkingDirectory -eq $linked) 'owner setup used the wrong working directory'

        Show-OwnerSetup -Worktree $linked -StateDirectory $state.stateDir -Installed $false
        $missingSetup = $capturedStartProcess
        $missingSetupArguments = @($missingSetup.ArgumentList) -join ' '
        Assert-True ($missingSetup.FilePath -eq 'powershell') 'missing setup must launch Windows PowerShell'
        Assert-True ($missingSetup.ArgumentList -contains '-NoExit') 'missing setup window must remain open for installation'
        Assert-True ($missingSetupArguments -match 'Press Enter to reach the interactive PowerShell prompt') 'missing setup must explain how to reach the interactive prompt'
        Assert-True ($missingSetupArguments -match "install Claude Code, then run ''claude auth login'' here") 'missing setup must direct install and authentication in the same window'
        Assert-True ($missingSetupArguments -notmatch 'if \(Get-Command claude') 'missing setup must not try authentication before manual installation'
        Assert-True ($missingSetupArguments -notmatch 'dangerously-skip-permissions') 'missing owner setup received bypass permissions'
        Assert-True ($missingSetup.WorkingDirectory -eq $linked) 'missing owner setup used the wrong working directory'
    } finally {
        Remove-Item -Path Function:\Start-Process -Force
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $linked 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $linked 'src/parser.ps1') -Value 'dirty-before-delegation'
    $executionTask = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $executionTask.forbiddenPaths = @('.git/**', '.github/**', '.env*', 'secrets/**', 'credentials/**')
    $taskPath = Join-Path $state.stateDir 'task-direct.json'
    $executionTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $taskPath -Encoding UTF8

    $preflightLedger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $preflightLedger.featureBranch = 'feature/tampered'
    $preflightLedger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $state.ledgerPath -Encoding UTF8
    $dryRunRejectedTamperedLedger = $false
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -DryRun | Out-Null
    } catch {
        $dryRunRejectedTamperedLedger = $true
    }
    Assert-True $dryRunRejectedTamperedLedger 'dry-run proceeded with a mismatched ledger'
    Set-Content -LiteralPath $state.ledgerPath -Value $validLedgerJson -Encoding UTF8

    $global:capturedRunnerStartProcess = $null
    function Start-Process {
        param(
            [string]$FilePath,
            [object[]]$ArgumentList,
            [string]$WorkingDirectory
        )
        $ledgerAtLaunch = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
        $global:capturedRunnerStartProcess = [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            WorkingDirectory = $WorkingDirectory
            LedgerStatusAtLaunch = @($ledgerAtLaunch.tasks)[-1].status
        }
    }
    try {
        $missingSetupRejected = $false
        $missingSetupError = $null
        try {
            & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand (Join-Path $fixtureRoot 'absent-claude.cmd') | Out-Null
        } catch {
            $missingSetupRejected = $true
            $missingSetupError = $_
        }
        Assert-True $missingSetupRejected 'missing Claude CLI did not require owner setup'
        $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
        $missingWait = @($ledger.tasks)[-1]
        Assert-True ($missingWait.status -eq 'waiting-for-owner') 'missing CLI did not append owner wait state'
        Assert-True ($missingWait.reason -eq 'claude-cli-missing') 'missing CLI wait reason was incorrect'
        Assert-True ($null -ne $global:capturedRunnerStartProcess) "missing CLI did not open owner setup: $missingSetupError"
        Assert-True ($global:capturedRunnerStartProcess.LedgerStatusAtLaunch -eq 'waiting-for-owner') 'missing CLI opened owner setup before recording owner wait state'
        Assert-True ((@($global:capturedRunnerStartProcess.ArgumentList) -join ' ') -notmatch 'dangerously-skip-permissions') 'missing CLI setup received bypass permissions'

        $global:capturedRunnerStartProcess = $null
        $env:CLAUDE_FAKE_AUTH = 'false'
        $unauthenticatedRejected = $false
        try {
            & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
        } catch {
            $unauthenticatedRejected = $true
        } finally {
            Remove-Item Env:\CLAUDE_FAKE_AUTH -ErrorAction SilentlyContinue
        }
        Assert-True $unauthenticatedRejected 'unauthenticated Claude CLI did not require owner setup'
        $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
        $authenticationWait = @($ledger.tasks)[-1]
        Assert-True ($authenticationWait.status -eq 'waiting-for-owner') 'unauthenticated CLI did not append owner wait state'
        Assert-True ($authenticationWait.reason -eq 'claude-authentication-required') 'authentication wait reason was incorrect'
        Assert-True ($null -ne $global:capturedRunnerStartProcess) 'unauthenticated Claude did not open owner setup'
        Assert-True ($global:capturedRunnerStartProcess.LedgerStatusAtLaunch -eq 'waiting-for-owner') 'unauthenticated Claude opened owner setup before recording owner wait state'
        Assert-True ((@($global:capturedRunnerStartProcess.ArgumentList) -join ' ') -notmatch 'dangerously-skip-permissions') 'authentication setup received bypass permissions'
    } finally {
        Remove-Item -Path Function:\Start-Process -Force
        Remove-Variable -Name capturedRunnerStartProcess -Scope Global -ErrorAction SilentlyContinue
    }

    $namedFakeClaude = Join-Path $fixtureRoot 'fake-claude-name.cmd'
    Copy-Item -LiteralPath $fakeClaude -Destination $namedFakeClaude
    $savedPath = $env:PATH
    $env:PATH = "$fixtureRoot;$savedPath"
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand 'fake-claude-name' | Out-Null
    } finally {
        $env:PATH = $savedPath
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $namedRecord = @($ledger.tasks)[-1]
    Assert-True ($ledger.primarySessionId -eq 'fake-session') "PATH-resolved Claude batch shim did not execute; inputError=$($namedRecord.attempts[0].inputError) stdout=$(Get-Content -Raw -LiteralPath $namedRecord.rawOutputPath) stderr=$(Get-Content -Raw -LiteralPath $namedRecord.rawErrorPath)"

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

    $ownedLockHandle = Enter-TaskLock -LockPath $lockPath -TaskId 'owned-lock'
    $replacementBlocked = $false
    try {
        Set-Content -LiteralPath $lockPath -Value 'replacement-lock'
    } catch {
        $replacementBlocked = $true
    }
    Assert-True $replacementBlocked 'exclusive lifetime lock allowed another owner to replace it'
    Exit-TaskLock -LockHandle $ownedLockHandle
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'disposing the owned lifetime lock did not delete it'

    $env:CLAUDE_FAKE_MODE = 'replace-lock'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'runner lifetime lock was not deleted on cleanup'

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

    foreach ($invalidResultMode in @(
        'mismatched-id', 'wrong-types', 'bad-status', 'extra-field', 'invalid-test',
        'wrong-case-property', 'wrong-case-status', 'wrong-case-outcome', 'wrong-case-task-id'
    )) {
        $primaryBeforeInvalidResult = $ledger.primarySessionId
        $env:CLAUDE_FAKE_MODE = $invalidResultMode
        try {
            & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
        } finally {
            Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        }
        $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
        $invalidResultRecord = @($ledger.tasks)[-1]
        $invalidNormalized = Get-Content -Raw -LiteralPath $invalidResultRecord.resultPath | ConvertFrom-Json
        Assert-True ($invalidNormalized.status -eq 'failed') "invalid result contract was accepted: $invalidResultMode"
        Assert-True ($ledger.primarySessionId -eq $primaryBeforeInvalidResult) "invalid result session was persisted: $invalidResultMode"
    }

    $env:CLAUDE_FAKE_MODE = 'nonzero'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $nonzeroRecord = @($ledger.tasks)[-1]
    $nonzeroResult = Get-Content -Raw -LiteralPath $nonzeroRecord.resultPath | ConvertFrom-Json
    Assert-True (@($nonzeroRecord.attempts).Count -eq 1) 'ordinary nonzero failure was retried'
    Assert-True ($nonzeroRecord.exitCode -eq 7) 'ordinary nonzero exit code was not retained'
    Assert-True ($nonzeroResult.status -eq 'failed') 'ordinary nonzero exit was not normalized as failure'

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
    Assert-True ([bool]$timeoutRecord.attempts[0].timedOut) "timeout attempt was not identified; elapsed=$($timeoutStopwatch.Elapsed.TotalSeconds) exit=$($timeoutRecord.exitCode) stderr=$(Get-Content -Raw -LiteralPath $timeoutRecord.rawErrorPath)"
    Assert-True ($timeoutStopwatch.Elapsed.TotalSeconds -lt 4) 'timeout waited for a descendant that inherited the output pipe'

    $largeInputTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $largeInputTask.id = 'task-large-input'
    $largeInputTask.goal = 'x' * 2097152
    $largeInputTask.limits.timeoutSeconds = 1
    $largeInputPath = Join-Path $state.stateDir 'task-large-input.json'
    $largeInputTask | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $largeInputPath -Encoding UTF8
    $env:CLAUDE_FAKE_MODE = 'no-stdin'
    $env:CLAUDE_FAKE_TASK = 'task-large-input'
    $largeInputStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $largeInputPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        $largeInputStopwatch.Stop()
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $largeInputRecord = @($ledger.tasks)[-1]
    $largeInputResult = Get-Content -Raw -LiteralPath $largeInputRecord.resultPath | ConvertFrom-Json
    Assert-True ($largeInputStopwatch.Elapsed.TotalSeconds -lt 6) "large stdin blocked before the invocation deadline could terminate the child; elapsed=$($largeInputStopwatch.Elapsed.TotalSeconds)"
    Assert-True ([bool]$largeInputRecord.timedOut) 'non-reading child did not record a timeout'
    Assert-True ($largeInputResult.status -eq 'failed') 'non-reading child did not reach normalized result finalization'

    $metacharTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $metacharTask.id = 'task-metachar'
    $unicodeGoal = '%ROUNDTRIP% & "quoted" (paren) ^ caret - caf' + [char]0x00E9 + ' ' +
        [char]0x65E5 + [char]0x672C + [char]0x8A9E + ' ' + [char]::ConvertFromUtf32(0x1F680)
    $metacharTask.goal = $unicodeGoal
    $metacharPath = Join-Path $state.stateDir 'task-metachar.json'
    $metacharTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metacharPath -Encoding UTF8
    $env:CLAUDE_FAKE_MODE = 'capture-stdin'
    $env:CLAUDE_FAKE_TASK = 'task-metachar'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $metacharPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
    }
    $capturedPrompt = Get-Content -Raw -LiteralPath (Join-Path $state.stateDir 'captured-stdin.txt')
    $capturedTask = $capturedPrompt.Substring($capturedPrompt.IndexOf('{')) | ConvertFrom-Json
    $expectedGoalCodes = ([char[]]$unicodeGoal | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ','
    $actualGoalCodes = ([char[]][string]$capturedTask.goal | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ','
    Assert-True ($capturedTask.goal -ceq $unicodeGoal) "Unicode task goal did not round-trip through UTF-8 standard input; expected=$expectedGoalCodes actual=$actualGoalCodes"

    $savedTeamEnvironment = $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
    $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = 'inherited'
    $env:CLAUDE_FAKE_MODE = 'capture-environment'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        if ($null -eq $savedTeamEnvironment) {
            Remove-Item Env:\CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = $savedTeamEnvironment
        }
    }
    $childTeamEnvironment = (Get-Content -Raw -LiteralPath (Join-Path $state.stateDir 'child-team-env.txt')).Trim()
    Assert-True ($childTeamEnvironment -eq '<unset>') 'non-team child inherited the experimental agent-team environment'

    $env:CLAUDE_FAKE_MODE = 'large'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $largeRecord = @($ledger.tasks)[-1]
    Assert-True ((Get-Content -Raw -LiteralPath $largeRecord.rawOutputPath).Length -gt 7000) 'large successful output was truncated'

    $slowEofTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $slowEofTask.id = 'task-slow-eof'
    $slowEofTask.limits.timeoutSeconds = 8
    $slowEofPath = Join-Path $state.stateDir 'task-slow-eof.json'
    $slowEofTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $slowEofPath -Encoding UTF8
    $env:CLAUDE_FAKE_MODE = 'slow-eof'
    $env:CLAUDE_FAKE_TASK = 'task-slow-eof'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $slowEofPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $slowEofRecord = @($ledger.tasks)[-1]
    $slowEofOutput = Get-Content -Raw -LiteralPath $slowEofRecord.rawOutputPath
    Assert-True (-not [bool]$slowEofRecord.timedOut) 'slow successful EOF was incorrectly timed out'
    Assert-True ($slowEofOutput.Contains('delayed-eof-marker')) 'successful execution did not drain delayed output to EOF'

    $unsafeIdTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $unsafeIdTask.id = '../escape:star'
    $unsafeIdPath = Join-Path $state.stateDir 'task-unsafe-id.json'
    $unsafeIdTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $unsafeIdPath -Encoding UTF8
    $env:CLAUDE_FAKE_TASK = '../escape:star'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $unsafeIdPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_TASK -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $unsafeIdRecord = @($ledger.tasks)[-1]
    $statePrefixForArtifacts = $state.stateDir.TrimEnd('\') + '\'
    foreach ($artifactPath in @($unsafeIdRecord.rawOutputPath, $unsafeIdRecord.rawErrorPath, $unsafeIdRecord.resultPath)) {
        Assert-True ($artifactPath.StartsWith($statePrefixForArtifacts, [System.StringComparison]::OrdinalIgnoreCase)) 'unsafe task ID escaped the state directory'
    }

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
    Assert-True ($allowedRecord.status -eq 'needs-review') 'an allowed unstaged edit was falsely classified as a repository mutation'

    Add-Content -LiteralPath (Join-Path $linked '.gitignore') -Value '.env'
    Set-Content -LiteralPath (Join-Path $linked '.env') -Value 'ignored-before'
    $env:CLAUDE_FAKE_MODE = 'ignored-edit'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $ignoredRecord = @($ledger.tasks)[-1]
    Assert-True ($ignoredRecord.changedDuringTask -contains '.env') 'ignored file change bypassed fingerprinting'
    Assert-True ($ignoredRecord.status -eq 'rejected') 'ignored forbidden file change was not rejected'

    $scopeViolations = Get-ScopeViolations -ChangedPaths @('.github/workflows/ci.yml', 'src/parser.ps1') -Task $executionTask
    Assert-True ($scopeViolations -contains '.github/workflows/ci.yml') 'forbidden path was not detected'
    Assert-True (-not ($scopeViolations -contains 'src/parser.ps1')) 'allowed path was rejected by the scope helper'
    $windowsPatternTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $windowsPatternTask.allowedPaths = @('src\**')
    $windowsPatternTask.forbiddenPaths = @('.github\**')
    $windowsPatternViolations = Get-ScopeViolations -ChangedPaths @('.github/workflows/ci.yml', 'src/parser.ps1') -Task $windowsPatternTask
    Assert-True ($windowsPatternViolations -contains '.github/workflows/ci.yml') 'Windows forbidden pattern was not normalized'
    Assert-True (-not ($windowsPatternViolations -contains 'src/parser.ps1')) 'Windows allowed pattern was not normalized'

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

    foreach ($gitMutation in @(
        [pscustomobject]@{ mode='staged-change'; violation='index-changed'; message='staged-only index mutation' },
        [pscustomobject]@{ mode='skip-worktree-change'; violation='index-changed'; message='skip-worktree index flag mutation' },
        [pscustomobject]@{ mode='assume-unchanged-change'; violation='index-changed'; message='assume-unchanged index flag mutation' },
        [pscustomobject]@{ mode='ref-change'; violation='refs-changed'; message='new branch and tag mutation' },
        [pscustomobject]@{ mode='config-change'; violation='config-changed'; message='local repository configuration mutation' },
        [pscustomobject]@{ mode='sibling-edit'; violation='sibling-worktree-changed'; message='sibling checkout file mutation' }
    )) {
        $env:CLAUDE_FAKE_MODE = $gitMutation.mode
        try {
            & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
        } finally {
            Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        }
        $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
        $mutationRecord = @($ledger.tasks)[-1]
        Assert-True ($mutationRecord.status -eq 'rejected') "$($gitMutation.message) was not rejected"
        Assert-True ($mutationRecord.repositoryViolations -contains $gitMutation.violation) "$($gitMutation.message) was not recorded"
        if ($gitMutation.mode -eq 'skip-worktree-change') {
            $indexFlag = Invoke-TestGit $linked @('ls-files', '-v', '--', 'src/parser.ps1')
            Assert-True ($indexFlag -cmatch '^S ') 'runner automatically reverted the skip-worktree index flag'
        }
        if ($gitMutation.mode -eq 'assume-unchanged-change') {
            $indexFlag = Invoke-TestGit $linked @('ls-files', '-v', '--', 'src/parser.ps1')
            Assert-True ($indexFlag -cmatch '^s ') 'runner automatically reverted the assume-unchanged index flag'
        }
    }

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

    $env:CLAUDE_FAKE_MODE = 'head-change'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $headRecord = @($ledger.tasks)[-1]
    Assert-True ($headRecord.status -eq 'rejected') 'HEAD mutation was not rejected'
    Assert-True ($headRecord.repositoryViolations -contains 'head-changed') 'HEAD mutation was not recorded'

    $env:CLAUDE_FAKE_MODE = 'branch-change'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $branchRecord = @($ledger.tasks)[-1]
    Assert-True ($branchRecord.status -eq 'rejected') 'branch mutation was not rejected'
    Assert-True ($branchRecord.repositoryViolations -contains 'branch-changed') 'branch mutation was not recorded'
    Assert-True ((Invoke-TestGit $linked @('branch', '--show-current')) -contains 'delegated-branch') 'runner automatically reverted a branch mutation'

    $corruptMain = Join-Path $fixtureRoot 'corrupt-main'
    $corruptLinked = Join-Path $fixtureRoot 'corrupt-feature'
    New-Item -ItemType Directory -Force -Path $corruptMain | Out-Null
    Invoke-TestGit $corruptMain @('init', '-b', 'main') | Out-Null
    Invoke-TestGit $corruptMain @('config', 'user.email', 'tests@example.invalid') | Out-Null
    Invoke-TestGit $corruptMain @('config', 'user.name', 'Delegation Tests') | Out-Null
    Set-Content -LiteralPath (Join-Path $corruptMain 'seed.txt') -Value 'seed'
    Invoke-TestGit $corruptMain @('add', 'seed.txt') | Out-Null
    Invoke-TestGit $corruptMain @('commit', '-m', 'seed') | Out-Null
    Invoke-TestGit $corruptMain @('worktree', 'add', '-b', 'feature/corrupt', $corruptLinked) | Out-Null
    $corruptContext = Get-WorktreeContext -WorktreePath $corruptLinked
    $corruptTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $corruptTask.featureBranch = 'feature/corrupt'
    $corruptState = Initialize-HandoffState -Context $corruptContext -Task $corruptTask
    $corruptTaskPath = Join-Path $corruptState.stateDir 'task-corrupt.json'
    $corruptTask | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $corruptTaskPath -Encoding UTF8
    $env:CLAUDE_FAKE_MODE = 'git-corrupt'
    $corruptionThrew = $false
    try {
        & $Runner -WorktreePath $corruptLinked -TaskPacketPath $corruptTaskPath -ClaudeCommand $fakeClaude | Out-Null
    } catch {
        $corruptionThrew = $true
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $corruptEntered = Test-Path -LiteralPath (Join-Path $corruptState.stateDir 'corrupt-entered.txt')
    $corruptError = if (Test-Path -LiteralPath (Join-Path $corruptState.stateDir 'corrupt-error.txt')) { Get-Content -Raw -LiteralPath (Join-Path $corruptState.stateDir 'corrupt-error.txt') } else { '<none>' }
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $corruptLinked '.git')) -match 'missing-delegation-gitdir') "fake corruption did not alter the disposable fixture; entered=$corruptEntered error=$corruptError"
    Assert-True (-not $corruptionThrew) 'post-run Git corruption escaped ledger finalization'
    $corruptLedger = Get-Content -Raw -LiteralPath $corruptState.ledgerPath | ConvertFrom-Json
    $corruptRecord = @($corruptLedger.tasks)[-1]
    Assert-True ($corruptRecord.status -eq 'rejected') 'post-run Git probe failure was not rejected'
    Assert-True (@($corruptRecord.repositoryViolations | Where-Object { $_ -like '*probe-failed' }).Count -gt 0) 'post-run Git probe failure was not recorded'

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
