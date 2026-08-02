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

function Remove-TestFixtureTree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    $reparsePoints = New-Object 'System.Collections.Generic.List[object]'
    $directories.Push($Path)

    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparsePoint) {
                $reparsePoints.Add([pscustomobject]@{
                    Path = $item.FullName
                    IsDirectory = [bool]$item.PSIsContainer
                })
            } elseif ($item.PSIsContainer -and $item.Name -ne '.git') {
                $directories.Push($item.FullName)
            }
        }
    }

    foreach ($reparsePoint in $reparsePoints) {
        if ($reparsePoint.IsDirectory) {
            [System.IO.Directory]::Delete($reparsePoint.Path, $false)
        } else {
            [System.IO.File]::Delete($reparsePoint.Path)
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
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

# Every shipped skill file must appear in the README's install-verification and
# update integrity lists, or an install that loses it still reports success.
$SkillRoot = Join-Path $RepoRoot 'delegating-to-claude-code'
$ReadmeText = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'README.md')
$shippedSkillFiles = @(
    Get-ChildItem -LiteralPath $SkillRoot -Recurse -File -Force |
        Where-Object { $_.Name -ne '.gitkeep' } |
        ForEach-Object {
            $_.FullName.Substring($SkillRoot.Length).TrimStart('\', '/').Replace('\', '/')
        }
)
Assert-True ($shippedSkillFiles.Count -ge 4) "skill directory enumeration found too few files: $($shippedSkillFiles -join '|')"
foreach ($shipped in $shippedSkillFiles) {
    $posixReference = $shipped
    $windowsReference = $shipped.Replace('/', '\')
    Assert-True (
        $ReadmeText.Contains($posixReference) -or $ReadmeText.Contains($windowsReference)
    ) "shipped skill file is missing from the README verification and update lists: $shipped"
}

$Runner = Join-Path $RepoRoot 'delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1'
. $Runner -LibraryMode

Assert-True (Test-SupportedLedgerVersion ([int]1)) 'Int32 ledger version 1 must be accepted'
Assert-True (Test-SupportedLedgerVersion ([long]1)) 'Int64 ledger version 1 must be accepted'
Assert-True (-not (Test-SupportedLedgerVersion '1')) 'string ledger version 1 must be rejected'
Assert-True (-not (Test-SupportedLedgerVersion $true)) 'boolean ledger version true must be rejected'
Assert-True (-not (Test-SupportedLedgerVersion ([double]1.0))) 'fraction-capable ledger version 1.0 must be rejected'
Assert-True (-not (Test-SupportedLedgerVersion ([long]2))) 'unknown integral ledger versions must be rejected'
Assert-True (
    (Remove-TrailingPathSeparatorsExceptRoot 'D:\') -ceq 'D:\'
) 'drive roots must preserve their trailing root separator'
Assert-True (
    (Remove-TrailingPathSeparatorsExceptRoot '\\server\share\') -ceq '\\server\share\'
) 'UNC roots must preserve their trailing root separator'

$nativeCaptureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'claude-delegation-native-capture-' + [guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $nativeCaptureRoot -Force | Out-Null
    $noisyCommand = Join-Path $nativeCaptureRoot 'noisy.cmd'
    @'
@echo off
echo advisory text 1>&2
echo standard output
exit /b 0
'@ | Set-Content -LiteralPath $noisyCommand -Encoding ASCII

    # $ErrorActionPreference is 'Stop' for this whole suite, which is exactly the
    # condition under which Windows PowerShell 5.1 turns native stderr into a
    # terminating error. Git emits advisory stderr on successful commands.
    $noisyResult = Invoke-DelegationNativeCommand -Command $noisyCommand -Arguments @()
    Assert-True ($noisyResult.ExitCode -eq 0) 'stderr on a successful native command changed its reported exit code'
    Assert-True ($noisyResult.StandardOutput.Trim() -ceq 'standard output') "native stdout was contaminated by stderr: $($noisyResult.StandardOutput)"
    Assert-True ($noisyResult.StandardError -match 'advisory text') 'native stderr was not captured for diagnostics'
    Assert-True ($noisyResult.Combined -match 'advisory text') 'combined native output dropped stderr'

    $failingCommand = Join-Path $nativeCaptureRoot 'failing.cmd'
    @'
@echo off
echo fatal detail 1>&2
exit /b 3
'@ | Set-Content -LiteralPath $failingCommand -Encoding ASCII
    $failingResult = Invoke-DelegationNativeCommand -Command $failingCommand -Arguments @()
    Assert-True ($failingResult.ExitCode -eq 3) 'a failing native command did not report its exit code'
    Assert-True ($failingResult.Combined -match 'fatal detail') 'a failing native command lost its stderr detail'
} finally {
    if (Test-Path -LiteralPath $nativeCaptureRoot) {
        Remove-Item -LiteralPath $nativeCaptureRoot -Recurse -Force
    }
}

$ignoreRuleRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'claude-delegation-ignore-rule-' + [guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $ignoreRuleRoot -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $unterminatedPath = Join-Path $ignoreRuleRoot 'unterminated.gitignore'
    [System.IO.File]::WriteAllText($unterminatedPath, "node_modules`nbuild/output", $utf8NoBom)
    Add-HandoffIgnoreRule -IgnorePath $unterminatedPath
    $unterminatedRules = @([System.IO.File]::ReadAllText($unterminatedPath) -split "`r?`n" |
        Where-Object { $_ -ne '' })
    Assert-True ($unterminatedRules -ccontains 'build/output') "appending the handoff rule rewrote the final existing entry: $($unterminatedRules -join '|')"
    Assert-True ($unterminatedRules -ccontains '.codex/claude-handoff/') 'the handoff ignore rule was not appended'
    Assert-True ($unterminatedRules.Count -eq 3) "unexpected .gitignore contents: $($unterminatedRules -join '|')"

    Add-HandoffIgnoreRule -IgnorePath $unterminatedPath
    $repeatedRules = @([System.IO.File]::ReadAllText($unterminatedPath) -split "`r?`n" |
        Where-Object { $_ -ne '' })
    Assert-True ($repeatedRules.Count -eq 3) 'the handoff ignore rule was appended twice'

    $rootedPath = Join-Path $ignoreRuleRoot 'rooted.gitignore'
    [System.IO.File]::WriteAllText($rootedPath, "/.codex/claude-handoff/`n", $utf8NoBom)
    Add-HandoffIgnoreRule -IgnorePath $rootedPath
    $rootedRules = @([System.IO.File]::ReadAllText($rootedPath) -split "`r?`n" |
        Where-Object { $_ -ne '' })
    Assert-True ($rootedRules.Count -eq 1) "an equivalent rooted handoff rule was duplicated: $($rootedRules -join '|')"

    $unslashedPath = Join-Path $ignoreRuleRoot 'unslashed.gitignore'
    [System.IO.File]::WriteAllText($unslashedPath, ".codex/claude-handoff`n", $utf8NoBom)
    Add-HandoffIgnoreRule -IgnorePath $unslashedPath
    $unslashedRules = @([System.IO.File]::ReadAllText($unslashedPath) -split "`r?`n" |
        Where-Object { $_ -ne '' })
    Assert-True ($unslashedRules.Count -eq 1) "an equivalent unslashed handoff rule was duplicated: $($unslashedRules -join '|')"

    $createdPath = Join-Path $ignoreRuleRoot 'created.gitignore'
    Add-HandoffIgnoreRule -IgnorePath $createdPath
    $createdRules = @([System.IO.File]::ReadAllText($createdPath) -split "`r?`n" |
        Where-Object { $_ -ne '' })
    Assert-True ($createdRules -ccontains '.codex/claude-handoff/') 'a missing .gitignore was not created with the handoff rule'
} finally {
    if (Test-Path -LiteralPath $ignoreRuleRoot) {
        Remove-Item -LiteralPath $ignoreRuleRoot -Recurse -Force
    }
}

Assert-True (@(Get-IgnoreRuleChanges -ChangedPaths @('src/app.ts')).Count -eq 0) 'an ordinary change was reported as an ignore-rule change'
Assert-True (@(Get-IgnoreRuleChanges -ChangedPaths @('.gitignore')).Count -eq 1) 'a root .gitignore change was not detected'
Assert-True (@(Get-IgnoreRuleChanges -ChangedPaths @('packages/api/.gitignore')).Count -eq 1) 'a nested .gitignore change was not detected'
Assert-True (@(Get-IgnoreRuleChanges -ChangedPaths @('src\nested\.gitignore')).Count -eq 1) 'a Windows-separated .gitignore change was not detected'

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

    $writtenMacSetupPath = [string]$global:capturedMacOwnerSetup.Launch.ScriptPath
    Assert-True (
        (Split-Path -Leaf $writtenMacSetupPath) -match
        '^claude-owner-setup-[0-9a-f]{32}\.command$'
    ) 'macOS owner setup must use an unpredictable generated script leaf'
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

Assert-True ((ConvertTo-PermissionRuleAbsolutePath 'C:\Repos\main\.git') -ceq '//c/Repos/main/.git') 'Windows drive paths must normalize to POSIX permission-rule form'
Assert-True ((ConvertTo-PermissionRuleAbsolutePath '/Users/owner/repo/.git') -ceq '//Users/owner/repo/.git') 'POSIX paths must gain the absolute permission-rule prefix'
Assert-True ((ConvertTo-PermissionRuleAbsolutePath 'D:/a/b/') -ceq '//d/a/b') 'permission-rule paths must trim separators and lowercase the drive'
$relativeRuleRejected = $false
try { ConvertTo-PermissionRuleAbsolutePath 'relative/path' | Out-Null } catch { $relativeRuleRejected = $true }
Assert-True $relativeRuleRejected 'a relative permission-rule path must be rejected'

# forbiddenPaths is otherwise only prose in the prompt, and a read leaves no
# trace in any snapshot, so it has to become an enforced deny rule.
$denyRuleContext = [pscustomobject]@{
    worktreePath = '/repo/feature'
    gitDir = '/repo/main/.git/worktrees/feature'
    commonDir = '/repo/main/.git'
    branch = 'feature/test'
    repositoryId = '/repo/main/.git'
}
$derivedDenyRules = Get-DelegationDenyRules -Task $direct -Context $denyRuleContext
foreach ($forbiddenPattern in @($direct.forbiddenPaths)) {
    Assert-True ($derivedDenyRules -ccontains "Read($forbiddenPattern)") "forbiddenPaths did not produce a Read deny rule: $forbiddenPattern"
    Assert-True ($derivedDenyRules -ccontains "Edit($forbiddenPattern)") "forbiddenPaths did not produce an Edit deny rule: $forbiddenPattern"
}
# The bare relative form carries the intended gitignore depth semantics, but the
# CLI documents anchoring only for the rooted form, so the worktree-absolute
# forms must be emitted too rather than relying on an undocumented reading.
foreach ($forbiddenPattern in @($direct.forbiddenPaths)) {
    foreach ($tool in @('Read', 'Edit')) {
        Assert-True (
            $derivedDenyRules -ccontains "$tool(//repo/feature/$forbiddenPattern)"
        ) "forbiddenPaths did not produce a worktree-absolute $tool deny rule: $forbiddenPattern"
        Assert-True (
            $derivedDenyRules -ccontains "$tool(//repo/feature/**/$forbiddenPattern)"
        ) "forbiddenPaths did not produce a depth-matched absolute $tool deny rule: $forbiddenPattern"
    }
}
foreach ($credentialRule in @(
    'Read(~/.ssh/**)', 'Read(~/.aws/**)', 'Read(~/.claude/.credentials.json)',
    'Read(//**/.env)', 'Read(//**/id_rsa)',
    # A Git credential store, in a skill built around Git; the gh token beside
    # the gcloud one; and transcripts of the owner's unrelated projects.
    'Read(~/.git-credentials)', 'Read(~/.config/gh/hosts.yml)',
    'Read(~/.claude.json)', 'Read(~/.claude/projects/**)'
)) {
    Assert-True ($derivedDenyRules -ccontains $credentialRule) "credential deny rule missing: $credentialRule"
}
# Git honours ~/.config/git/ignore with core.excludesFile unset, so a write here
# widens the worktree's ignore set from outside every worktree-relative rule.
$userExcludesRulePath = ConvertTo-PermissionRuleAbsolutePath (Split-Path -Parent (Get-DefaultUserExcludesPath))
Assert-True (
    $derivedDenyRules -ccontains "Edit($userExcludesRulePath/**)"
) "the default user Git config directory must be edit-denied: $userExcludesRulePath"

# Test-ClaudeAvailable gates the dry run, and Resolve-ClaudeCommandPath runs
# straight after it, so a command the first accepts and the second rejects turns
# a dry run into a throw. A shell function is exactly that case.
function claude-availability-probe { 'not an application' }
Assert-True (
    -not (Test-ClaudeAvailable 'claude-availability-probe')
) 'a shell function must not be reported as an available Claude command'
$availabilityResolveThrew = $false
try { Resolve-ClaudeCommandPath -Command 'claude-availability-probe' | Out-Null } catch { $availabilityResolveThrew = $true }
Assert-True $availabilityResolveThrew 'a shell function must still fail to resolve to an executable path'
Remove-Item -Path Function:\claude-availability-probe -Force

# ... and because `git config --get core.excludesFile` exits 1 whether or not
# that file exists, only fingerprinting it directly can detect the change.
$savedXdgConfigHome = $env:XDG_CONFIG_HOME
$excludesProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "delegation-xdg-$([guid]::NewGuid().ToString('N'))"
try {
    $env:XDG_CONFIG_HOME = $excludesProbeRoot
    Assert-True (
        (Get-DefaultUserExcludesPath) -eq (Join-Path (Join-Path $excludesProbeRoot 'git') 'ignore')
    ) 'XDG_CONFIG_HOME must redirect the default user excludes path'
    $beforeExcludes = Get-ExcludeFileFingerprint -Context $denyRuleContext
    New-Item -ItemType Directory -Force -Path (Join-Path $excludesProbeRoot 'git') | Out-Null
    Set-Content -LiteralPath (Join-Path $excludesProbeRoot 'git/ignore') -Value 'nested/'
    $afterExcludes = Get-ExcludeFileFingerprint -Context $denyRuleContext
    Assert-True (
        $beforeExcludes -cne $afterExcludes
    ) 'creating the default user excludes file must change the exclude fingerprint'
} finally {
    if ($null -eq $savedXdgConfigHome) {
        Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue
    } else {
        $env:XDG_CONFIG_HOME = $savedXdgConfigHome
    }
    Remove-Item -LiteralPath $excludesProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ($derivedDenyRules -ccontains 'Edit(//repo/main/.git/**)') 'the shared common directory must be edit-denied so hooks cannot be planted'
Assert-True ($derivedDenyRules -ccontains 'Edit(//repo/main/.git/worktrees/feature/**)') 'the linked worktree Git directory must be edit-denied'
# Write(path) and Glob(path) rules are accepted but never matched by Claude
# Code's file permission checks, so they would be silently useless.
Assert-True (@($derivedDenyRules | Where-Object { $_ -like 'Write(*' -or $_ -like 'Glob(*' }).Count -eq 0) 'deny rules must not use forms that file permission checks never match'
Assert-True (@($derivedDenyRules | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'deny rules must not contain duplicates'

$contextualInvocation = New-ClaudeInvocation -Task $direct -SessionId $null -SupportsForwarding $false -Context $denyRuleContext
$contextualArguments = [string[]]$contextualInvocation.arguments
Assert-True ($contextualArguments -ccontains '--strict-mcp-config') 'the delegated session must not load ambient MCP servers'
$settingSourcesIndex = [Array]::IndexOf($contextualArguments, '--setting-sources')
Assert-True ($settingSourcesIndex -ge 0) 'the delegated session must scope its setting sources'
Assert-True ($contextualArguments[$settingSourcesIndex + 1] -ceq 'user') 'the worktree must not contribute settings, which can register hooks'
# Commander stops collecting a variadic option at the next flag, so every deny
# rule must sit in one uninterrupted run after --disallowedTools.
$denyFlagIndex = [Array]::IndexOf($contextualArguments, '--disallowedTools')
Assert-True ($denyFlagIndex -ge 0) '--disallowedTools missing from the contextual invocation'
$collectedDenyRules = @()
for ($denyOffset = $denyFlagIndex + 1; $denyOffset -lt $contextualArguments.Count; $denyOffset++) {
    if ($contextualArguments[$denyOffset].StartsWith('--')) { break }
    $collectedDenyRules += $contextualArguments[$denyOffset]
}
Assert-True (
    $collectedDenyRules.Count -eq $derivedDenyRules.Count
) "deny rules were split by an intervening flag: expected $($derivedDenyRules.Count), collected $($collectedDenyRules.Count)"

# direct mode promises no subagents. The subagent tool is named Agent; a rule
# naming a tool that does not exist would silently enforce nothing.
Assert-True ($derivedDenyRules -ccontains 'Agent') 'direct mode did not deny the subagent tool'
$subagentModeTask = $direct | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$subagentModeTask.mode = 'subagents'
$subagentDenyRules = Get-DelegationDenyRules -Task $subagentModeTask -Context $denyRuleContext
Assert-True (-not ($subagentDenyRules -ccontains 'Agent')) 'subagents mode must keep the subagent tool available'
Assert-True (@($subagentDenyRules | Where-Object { $_ -like 'Read(*' }).Count -gt 0) 'subagents mode lost its path deny rules'

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
Assert-True (-not ((Get-DelegationDenyRules -Task $team -Context $null) -ccontains 'Agent')) 'agent-team mode must keep the subagent tool available'

# A filesystem snapshot cannot attribute a write to one teammate, so declared
# ownership is unverifiable per teammate. What is checkable is that every
# in-scope change landed in exactly one declared ownedPaths set.
Assert-True (
    @(Get-UnownedWorkstreamPaths -ChangedPaths @('src/api/routes.ts', 'src/ui/app.tsx') -Task $team).Count -eq 0
) 'changes inside a single declared owner were reported as unowned'
$teamUnowned = Get-UnownedWorkstreamPaths -Task $team -ChangedPaths @(
    'src/api/routes.ts', 'src/shared/config.ts', 'docs/readme.md'
)
Assert-True (-not ($teamUnowned -contains 'src/api/routes.ts')) 'an owned path was reported as unowned'
Assert-True (-not ($teamUnowned -contains 'docs/readme.md')) 'an out-of-scope path belongs to the scope check, not the ownership check'
$teamWideAllow = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$teamWideAllow.allowedPaths = @('src/**')
Assert-True (
    (Get-UnownedWorkstreamPaths -Task $teamWideAllow -ChangedPaths @('src/shared/config.ts')) -contains 'src/shared/config.ts'
) 'an in-scope change owned by no workstream was not reported'
$teamDoubleOwned = $team | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$teamDoubleOwned.parallelWorkstreams = @(
    [pscustomobject]@{ name='api'; ownedPaths=@('src/api/**') },
    [pscustomobject]@{ name='ui'; ownedPaths=@('src/api/**') }
)
Assert-True (
    (Get-UnownedWorkstreamPaths -Task $teamDoubleOwned -ChangedPaths @('src/api/routes.ts')) -contains 'src/api/routes.ts'
) 'a change claimed by two workstreams was not reported'
Assert-True (
    @(Get-UnownedWorkstreamPaths -ChangedPaths @('src/parser.ps1') -Task $direct).Count -eq 0
) 'the ownership check must not apply outside agent-team mode'
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

$cleanupProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-delegation-cleanup-probe-" + [guid]::NewGuid())
$cleanupProbeExternal = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-delegation-cleanup-external-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $cleanupProbeRoot 'nested') -Force | Out-Null
    New-Item -ItemType Directory -Path $cleanupProbeExternal -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanupProbeExternal 'must-survive.txt') -Value 'external'
    New-Item -ItemType Junction -Path (Join-Path $cleanupProbeRoot 'nested/external-alias') -Target $cleanupProbeExternal | Out-Null

    Remove-TestFixtureTree -Path $cleanupProbeRoot

    Assert-True (-not (Test-Path -LiteralPath $cleanupProbeRoot)) 'fixture cleanup left a tree containing a directory junction'
    Assert-True (Test-Path -LiteralPath (Join-Path $cleanupProbeExternal 'must-survive.txt')) 'fixture cleanup traversed a directory junction'
} finally {
    if (Test-Path -LiteralPath $cleanupProbeExternal) {
        Remove-Item -LiteralPath $cleanupProbeExternal -Recurse -Force
    }
}

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
  ping 127.0.0.1 -n 10 >nul
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
if "%CLAUDE_FAKE_MODE%"=="artifact-edit" (
  echo delegated-change>>"%CD%\src\parser.ps1"
  if not exist "%CD%\build" mkdir "%CD%\build"
  echo build-output>"%CD%\build\output.txt"
)
if "%CLAUDE_FAKE_MODE%"=="ignore-widen" (
  echo delegated-artifact>>"%CD%\.gitignore"
  echo widened>"%CD%\delegated-artifact"
)
if "%CLAUDE_FAKE_MODE%"=="forbidden-edit" (
  if not exist "%CD%\.github\workflows" mkdir "%CD%\.github\workflows"
  echo forbidden>"%CD%\.github\workflows\ci.yml"
)
if "%CLAUDE_FAKE_MODE%"=="forbidden-link-create" (
  if not exist "%CD%\.github" mkdir "%CD%\.github"
  powershell -NoProfile -Command "New-Item -ItemType Junction -Path (Join-Path (Get-Location) '.github\delegated-link') -Target $env:CLAUDE_FAKE_LINK_TARGET | Out-Null"
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
if "%CLAUDE_FAKE_MODE%"=="hook-plant" (
  if not exist "%CD%\..\main\.git\hooks" mkdir "%CD%\..\main\.git\hooks"
  echo exfiltrate>"%CD%\..\main\.git\hooks\pre-commit"
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

    # A dry run that reports a different invocation than the one that executes is
    # worse than no dry run: the ledger now holds a session id the real run
    # resumes, so the inspected argv has to show it.
    $parityDryRunJson = (& $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude -DryRun | Out-String).Trim()
    $parityDryRun = $parityDryRunJson | ConvertFrom-Json
    $parityArguments = [string[]]@($parityDryRun.arguments | ForEach-Object { [string]$_ })
    Assert-True ($parityArguments -ccontains '--resume') 'dry run omitted the resume the real invocation would perform'
    $parityResumeIndex = [Array]::IndexOf($parityArguments, '--resume')
    Assert-True ($parityArguments[$parityResumeIndex + 1] -ceq 'fake-session') 'dry run resumed a different session than the ledger records'
    Assert-True ($parityDryRun.supportsForwardingSource -ceq 'detected') 'dry run did not probe the real CLI for forwarding support'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$parityDryRun.resolvedClaudeCommand)) 'dry run did not report the resolved Claude command'
    $parityMissingDryRun = (& $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand (Join-Path $fixtureRoot 'absent-claude.cmd') -DryRun | Out-String).Trim() | ConvertFrom-Json
    Assert-True (
        $parityMissingDryRun.supportsForwardingSource -ceq 'claude-cli-unavailable'
    ) 'dry run assumed forwarding support when the CLI is unavailable'
    Assert-True (-not $parityMissingDryRun.supportsForwarding) 'dry run claimed forwarding support without a CLI to probe'

    # A hook planted in the shared common directory runs under the owner account
    # the next time Codex commits, after acceptance.
    $env:CLAUDE_FAKE_MODE = 'hook-plant'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $hookRecord = @($ledger.tasks)[-1]
    Assert-True ($hookRecord.repositoryViolations -contains 'hooks-changed') 'a planted Git hook was not recorded'
    Assert-True ($hookRecord.status -eq 'rejected') 'a planted Git hook was not rejected'
    Remove-Item -LiteralPath (Join-Path $mainRepo '.git/hooks/pre-commit') -Force -ErrorAction SilentlyContinue
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
    Assert-True (
        $timeoutStopwatch.Elapsed.TotalSeconds -lt 6
    ) "timeout waited for a descendant that inherited the output pipe; elapsed=$($timeoutStopwatch.Elapsed.TotalSeconds)"

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
    $caseOnlyFingerprintChanges = Compare-WorktreeFingerprint `
        -Before @{ 'src/link' = '{"targets":["CaseTarget"]}' } `
        -After @{ 'src/link' = '{"targets":["casetarget"]}' }
    Assert-True ($caseOnlyFingerprintChanges -contains 'src/link') 'fingerprint comparison ignored a case-only link target change'

    $externalLinkTargetOne = Join-Path $fixtureRoot 'external-link-target-one'
    $externalLinkTargetTwo = Join-Path $fixtureRoot 'external-link-target-two'
    New-Item -ItemType Directory -Force -Path $externalLinkTargetOne, $externalLinkTargetTwo | Out-Null
    Set-Content -LiteralPath (Join-Path $externalLinkTargetOne 'outside-one.txt') -Value 'outside-one'
    Set-Content -LiteralPath (Join-Path $externalLinkTargetTwo 'outside-two.txt') -Value 'outside-two'
    $allowedLinkPath = Join-Path $linked 'src/delegated-link'
    $linkBeforeCreate = Get-WorktreeFingerprint -Worktree $linked
    New-Item -ItemType Junction -Path $allowedLinkPath -Target $externalLinkTargetOne | Out-Null
    $linkAfterCreate = Get-WorktreeFingerprint -Worktree $linked
    $linkCreateChanges = Compare-WorktreeFingerprint -Before $linkBeforeCreate -After $linkAfterCreate
    Assert-True ($linkCreateChanges -contains 'src/delegated-link') 'fingerprint missed a created junction entry'
    Assert-True ($linkAfterCreate.ContainsKey('src/delegated-link')) 'fingerprint omitted a junction entry'
    Assert-True ($linkAfterCreate['src/delegated-link'] -match '"entryKind":"directory"') 'junction fingerprint omitted its entry kind'
    Assert-True ($linkAfterCreate['src/delegated-link'] -match '"linkType":"Junction"') 'junction fingerprint omitted its link type'
    Assert-True ($linkAfterCreate['src/delegated-link'] -match [regex]::Escape($externalLinkTargetOne.Replace('\', '\\'))) 'junction fingerprint omitted its target'
    Assert-True (-not $linkAfterCreate.ContainsKey('src/delegated-link/outside-one.txt')) 'fingerprint traversed an external junction target'
    Set-Content -LiteralPath (Join-Path $externalLinkTargetOne 'outside-one.txt') -Value 'outside-one-mutated'
    $linkAfterExternalContentChange = Get-WorktreeFingerprint -Worktree $linked
    $externalContentChanges = Compare-WorktreeFingerprint -Before $linkAfterCreate -After $linkAfterExternalContentChange
    Assert-True (-not ($externalContentChanges -contains 'src/delegated-link')) 'external junction target contents affected the link fingerprint'
    $allowedLinkTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $allowedLinkTask.allowedPaths = @('src/**')
    $allowedLinkViolations = Get-ScopeViolations -ChangedPaths $linkCreateChanges -Task $allowedLinkTask
    Assert-True (@($allowedLinkViolations).Count -eq 0) 'allowed junction path was classified as a scope violation'

    [System.IO.Directory]::Delete($allowedLinkPath)
    New-Item -ItemType Junction -Path $allowedLinkPath -Target $externalLinkTargetTwo | Out-Null
    $linkAfterRepoint = Get-WorktreeFingerprint -Worktree $linked
    $linkRepointChanges = Compare-WorktreeFingerprint -Before $linkAfterCreate -After $linkAfterRepoint
    Assert-True ($linkRepointChanges -contains 'src/delegated-link') 'fingerprint missed a repointed junction entry'
    Assert-True ($linkAfterRepoint['src/delegated-link'] -match [regex]::Escape($externalLinkTargetTwo.Replace('\', '\\'))) 'repointed junction fingerprint omitted its new target'
    Assert-True (-not $linkAfterRepoint.ContainsKey('src/delegated-link/outside-two.txt')) 'fingerprint traversed a repointed external junction target'
    $forbiddenLinkViolations = Get-ScopeViolations -ChangedPaths $linkRepointChanges -Task $executionTask
    Assert-True ($forbiddenLinkViolations -contains 'src/delegated-link') 'out-of-scope junction repoint was not classified as a scope violation'

    [System.IO.Directory]::Delete($allowedLinkPath)
    $linkAfterRemoval = Get-WorktreeFingerprint -Worktree $linked
    $linkRemovalChanges = Compare-WorktreeFingerprint -Before $linkAfterRepoint -After $linkAfterRemoval
    Assert-True ($linkRemovalChanges -contains 'src/delegated-link') 'fingerprint missed a removed junction entry'

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

    # A required verification command legitimately drops build and cache output
    # outside allowedPaths. Ignored byproducts must be reported, never rejected.
    Add-Content -LiteralPath (Join-Path $linked '.gitignore') -Value 'build/'
    $env:CLAUDE_FAKE_MODE = 'artifact-edit'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $artifactRecord = @($ledger.tasks)[-1]
    Assert-True ($artifactRecord.changedDuringTask -contains 'build/output.txt') 'ignored build output bypassed fingerprinting'
    Assert-True ($artifactRecord.ignoredArtifacts -contains 'build/output.txt') 'ignored build output was not recorded as an artifact'
    Assert-True (-not ($artifactRecord.scopeViolations -contains 'build/output.txt')) 'a git-ignored build artifact was treated as a scope violation'
    Assert-True (@($artifactRecord.scopeViolations).Count -eq 0) "verification artifacts rejected a compliant delegation: $(@($artifactRecord.scopeViolations) -join '|')"
    Assert-True ($artifactRecord.status -eq 'needs-review') 'a delegation was rejected for output its own verification command created'

    # Widening the ignore set is how a delegation would launder an out-of-scope
    # write into the artifact bucket, so it must reject on its own.
    $env:CLAUDE_FAKE_MODE = 'ignore-widen'
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $ignoreWidenRecord = @($ledger.tasks)[-1]
    Assert-True ($ignoreWidenRecord.repositoryViolations -contains 'ignore-rules-changed') 'a delegated .gitignore edit was not recorded'
    Assert-True ($ignoreWidenRecord.status -eq 'rejected') 'a delegation that widened the ignore set was not rejected'

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

    # By now the fixture .gitignore covers build/, delegated-artifact and .env.
    $classification = Get-ScopeClassification -Worktree $linked -Task $executionTask -ChangedPaths @(
        'src/parser.ps1', 'build/output.txt', 'not-ignored.txt', '.github/workflows/ci.yml', '.env'
    )
    Assert-True (-not ($classification.Violations -contains 'src/parser.ps1')) 'an allowed path was classified as a violation'
    Assert-True (-not ($classification.IgnoredArtifacts -contains 'src/parser.ps1')) 'an allowed path was classified as an artifact'
    Assert-True ($classification.IgnoredArtifacts -contains 'build/output.txt') 'a git-ignored byproduct was not classified as an artifact'
    Assert-True (-not ($classification.Violations -contains 'build/output.txt')) 'a git-ignored byproduct was still counted as a violation'
    Assert-True ($classification.Violations -contains 'not-ignored.txt') 'an untracked out-of-scope file escaped the scope check'
    Assert-True ($classification.Violations -contains '.github/workflows/ci.yml') 'a forbidden path escaped the scope check'
    Assert-True ($classification.Violations -contains '.env') 'a forbidden path was laundered into an artifact by .gitignore'
    Assert-True (-not ($classification.IgnoredArtifacts -contains '.env')) 'a forbidden path was classified as an artifact'
    Assert-True (-not $classification.ProbeFailed) 'the ignore probe failed on a healthy worktree'

    # Deny rules read forbiddenPaths with gitignore depth semantics, so detection
    # has to as well. A root-anchored match let config/.env and app/secrets/key
    # fall past the forbidden check into the ignore probe, where the .gitignore
    # entries that every real repository carries for these names filed them as
    # ordinary build artifacts and downgraded a rejection to needs-review.
    Add-Content -LiteralPath (Join-Path $linked '.gitignore') -Value '.env'
    Add-Content -LiteralPath (Join-Path $linked '.gitignore') -Value 'secrets/'
    $nestedForbidden = @('config/.env', 'app/secrets/key', 'deep/nested/.env.local')
    $nestedClassification = Get-ScopeClassification -Worktree $linked -Task $executionTask `
        -ChangedPaths $nestedForbidden
    foreach ($nestedPath in $nestedForbidden) {
        Assert-True (
            $nestedClassification.Violations -contains $nestedPath
        ) "a nested forbidden path was not treated as a violation: $nestedPath"
        Assert-True (
            -not ($nestedClassification.IgnoredArtifacts -contains $nestedPath)
        ) "a nested forbidden path was laundered into an artifact: $nestedPath"
        Assert-True (
            (Get-ScopeViolations -ChangedPaths @($nestedPath) -Task $executionTask) -contains $nestedPath
        ) "a nested forbidden path escaped Get-ScopeViolations: $nestedPath"
    }

    # The depth forms must keep the segment boundary: src/mysecrets is not
    # covered by secrets/**, and widening forbiddenPaths must never widen
    # allowedPaths, which stays root-anchored.
    Assert-True (
        -not (Test-ForbiddenPathMatch -Path 'src/mysecrets/key' -ForbiddenPatterns @('secrets/**'))
    ) 'a depth-matched pattern matched across a segment boundary'
    Assert-True (
        Test-ForbiddenPathMatch -Path 'src/secrets/key' -ForbiddenPatterns @('secrets/**')
    ) 'a nested directory pattern was not depth-matched'
    Assert-True (
        Test-ForbiddenPathMatch -Path 'sub/.git/config' -ForbiddenPatterns @('.git/**')
    ) 'a nested Git directory was not depth-matched'
    Assert-True (
        Test-ForbiddenPathMatch -Path 'secrets/key' -ForbiddenPatterns @('secrets')
    ) 'a bare directory pattern did not forbid the paths beneath it'
    Assert-True (
        (Get-ScopeViolations -ChangedPaths @('src/parser.ps1') -Task $executionTask).Count -eq 0
    ) 'an allowed path became a violation after forbidden matching was widened'

    # Git never reports a tracked file as ignored, so an out-of-scope edit to a
    # tracked file stays a violation even when an ignore rule matches its name.
    # seed.txt is committed in the fixture repository.
    Add-Content -LiteralPath (Join-Path $linked '.gitignore') -Value 'seed.txt'
    $trackedIgnoreTask = $executionTask | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $trackedIgnoreTask.allowedPaths = @('src/**')
    $trackedClassification = Get-ScopeClassification -Worktree $linked -Task $trackedIgnoreTask `
        -ChangedPaths @('seed.txt')
    Assert-True ($trackedClassification.Violations -contains 'seed.txt') 'a tracked out-of-scope file was reclassified as an artifact'
    Assert-True (@($trackedClassification.IgnoredArtifacts).Count -eq 0) 'a tracked file was classified as an ignored artifact'

    $probeFailure = Get-ScopeClassification -Worktree (Join-Path $fixtureRoot 'no-such-worktree') `
        -Task $executionTask -ChangedPaths @('build/output.txt')
    Assert-True $probeFailure.ProbeFailed 'a broken ignore probe was not reported'
    Assert-True ($probeFailure.Violations -contains 'build/output.txt') 'a broken ignore probe failed open instead of closed'
    Assert-True (@($probeFailure.IgnoredArtifacts).Count -eq 0) 'a broken ignore probe still produced artifacts'

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

    $env:CLAUDE_FAKE_MODE = 'forbidden-link-create'
    $env:CLAUDE_FAKE_LINK_TARGET = $externalLinkTargetOne
    try {
        & $Runner -WorktreePath $linked -TaskPacketPath $taskPath -ClaudeCommand $fakeClaude | Out-Null
    } finally {
        Remove-Item Env:\CLAUDE_FAKE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FAKE_LINK_TARGET -ErrorAction SilentlyContinue
    }
    $ledger = Get-Content -Raw -LiteralPath $state.ledgerPath | ConvertFrom-Json
    $forbiddenLinkRecord = @($ledger.tasks)[-1]
    Assert-True ($forbiddenLinkRecord.changedDuringTask -contains '.github/delegated-link') 'runner missed an out-of-scope junction creation'
    Assert-True ($forbiddenLinkRecord.scopeViolations -contains '.github/delegated-link') 'out-of-scope junction creation was not recorded as a scope violation'
    Assert-True ($forbiddenLinkRecord.status -eq 'rejected') 'out-of-scope junction creation was not rejected'
    Assert-True (Test-Path -LiteralPath (Join-Path $linked '.github/delegated-link')) 'runner automatically removed a rejected junction'

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
            Remove-TestFixtureTree -Path $fixtureRoot
        }
        $fixtureCleaned = -not (Test-Path -LiteralPath $fixtureRoot)
    } catch {
        if ($null -eq $fixtureFailure) { throw }
    }
}
if ($null -ne $fixtureFailure) { throw $fixtureFailure }
Assert-True $fixtureCleaned 'temporary Git fixture was not removed'
