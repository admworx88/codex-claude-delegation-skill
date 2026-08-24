# Contract check against the real Claude Code CLI.
#
# Both delegation suites run against a fake `claude` shim authored in this
# repository, so they verify the runner's assumptions rather than the CLI's
# actual interface. If upstream renames or drops a flag the runner depends on,
# those suites still pass and the failure only appears during a live
# delegation. This file asserts the interface itself.
#
# Flags are probed by invoking the CLI, not by grepping --help: several flags
# the runner depends on, including --max-turns, work but are not listed in the
# help output. Each probe redirects stdin and closes it, so the CLI stops at
# argument parsing and never reaches an API call, and each probe is bounded by a
# timeout so an interface change can never hang the suite instead of failing it.
#
# Skips cleanly when Claude Code is not installed unless -RequireLiveEnforcement
# is set, so ordinary local checks remain useful while release gates can fail
# closed when the authenticated probes do not run.

param(
    [switch]$RequireLiveEnforcement
)

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    Write-Host "  ok  $Message"
}

function Test-ExplicitAuthenticationStatus($Status) {
    if ($null -eq $Status -or $Status -isnot [pscustomobject]) { return $false }
    $propertyNames = @($Status.PSObject.Properties.Name)
    foreach ($name in @('loggedIn', 'authenticated')) {
        if ($propertyNames -ccontains $name) {
            $value = $Status.$name
            return $value -is [bool] -and [bool]$value
        }
    }
    return $false
}

$ProbeTimeoutSeconds = 60
# A live probe runs a real session rather than stopping at argument parsing.
$LiveProbeTimeoutSeconds = 180

function ConvertTo-ProbeRulePath([string]$Path) {
    # Same normalization the runner uses: Claude Code wants POSIX form with a
    # leading // for filesystem-absolute rule paths, and C:\x becomes //c/x.
    $normalized = ([string]$Path).Replace('\', '/').TrimEnd('/')
    if ($normalized -match '^([A-Za-z]):(/.*)?$') {
        return '//' + $Matches[1].ToLowerInvariant() + $Matches[2]
    }
    if ($normalized.StartsWith('/')) { return '/' + $normalized }
    throw "Probe rule path must be absolute: $Path"
}

function Invoke-ClaudeProbe([string]$ClaudePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0) {
    # Empty stdin is what keeps a probe at argument parsing. Calling the CLI
    # directly inherits the parent's stdin instead, so `claude --print` blocks on
    # a terminal and this suite hangs when run locally as the README instructs.
    # Worse, if stdin ever carries content the probes stop being argument checks
    # and become real sessions run with --dangerously-skip-permissions. Redirect
    # stdin and close it so the guarantee in the header is enforced by the code.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ClaudePath
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    $effectiveTimeout = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { $ProbeTimeoutSeconds }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    # Read both streams before waiting; a full pipe buffer would otherwise
    # deadlock a process that never exits on its own.
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($effectiveTimeout * 1000)) {
        try { $process.Kill($true) } catch { }
        return [pscustomobject]@{
            ExitCode = -1
            Output = "the probe did not exit within $effectiveTimeout seconds"
            TimedOut = $true
        }
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (@(
            $standardOutput.GetAwaiter().GetResult()
            $standardError.GetAwaiter().GetResult()
        ) -join "`n")
        TimedOut = $false
    }
}

$claude = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $claude) {
    if ($RequireLiveEnforcement) {
        throw 'Claude Code CLI is required for live enforcement probes.'
    }
    Write-Output 'Claude Code CLI is not installed; skipping the CLI contract tests.'
    exit 0
}
$claudePath = $claude.Path
Write-Host "Checking the CLI contract against: $claudePath"

$version = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments @('--version')
Assert-True (-not $version.TimedOut) 'claude --version returns without blocking on stdin'
Assert-True ($version.ExitCode -eq 0) 'claude --version exits successfully'
Write-Host "  Reported version: $($version.Output.Trim())"

# Confirm the probe can actually tell a real flag from a fake one before
# trusting any of its verdicts.
$controlProbe = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments @(
    '--print', '--delegation-contract-control-flag'
)
Assert-True (-not $controlProbe.TimedOut) 'the control probe returns without blocking on stdin'
Assert-True (
    $controlProbe.Output -match "unknown option"
) "the probe distinguishes a fake flag from a real one (control): $($controlProbe.Output)"

# Every flag the runner puts on the command line, with a representative value.
$requiredFlags = [ordered]@{
    '--print'                        = @('--print')
    '--dangerously-skip-permissions' = @('--print', '--dangerously-skip-permissions')
    '--output-format json'           = @('--print', '--output-format', 'json')
    '--output-format stream-json'    = @('--print', '--output-format', 'stream-json', '--verbose')
    '--json-schema'                  = @('--print', '--json-schema', '{"type":"object"}')
    '--max-turns'                    = @('--print', '--max-turns', '1')
    '--disallowedTools'              = @('--print', '--disallowedTools', 'Bash(git *)', 'Agent', 'Read(.env*)', 'Edit(//tmp/x/**)')
    '--max-budget-usd'               = @('--print', '--max-budget-usd', '1')
    '--resume'                       = @('--print', '--resume', '00000000-0000-4000-8000-000000000000')
    '--verbose'                      = @('--print', '--verbose')
    '--forward-subagent-text'        = @('--print', '--forward-subagent-text')
    '--strict-mcp-config'            = @('--print', '--strict-mcp-config')
    '--setting-sources'              = @('--print', '--setting-sources', 'user')
}
foreach ($entry in $requiredFlags.GetEnumerator()) {
    $probe = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments $entry.Value
    # A probe that reached an API call rather than stopping at argument parsing
    # would surface here as a timeout, not as a silent pass.
    Assert-True (-not $probe.TimedOut) "probing $($entry.Key) stops at argument parsing"
    Assert-True (
        $probe.Output -notmatch "unknown option"
    ) "the CLI still accepts $($entry.Key): $($probe.Output)"
}

# Test-ClaudeAuthenticated parses `claude auth status` as JSON and reads
# loggedIn or authenticated from it.
$auth = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments @('auth', 'status')
if ($auth.ExitCode -eq 0) {
    $authStatus = $null
    try { $authStatus = $auth.Output | ConvertFrom-Json } catch { $authStatus = $null }
    Assert-True ($null -ne $authStatus) "claude auth status still emits JSON: $($auth.Output)"
    $authFields = @($authStatus.PSObject.Properties.Name)
    Assert-True (
        $authFields -contains 'loggedIn' -or $authFields -contains 'authenticated'
    ) "claude auth status still reports loggedIn or authenticated: $($authFields -join ',')"
    $authField = if ($authFields -contains 'loggedIn') { 'loggedIn' } else { 'authenticated' }
    Assert-True ($authStatus.$authField -is [bool]) "claude auth status reports a Boolean $authField field"
} else {
    Write-Host '  skip  claude auth status returned nonzero (unauthenticated runner); JSON shape not checked'
}

# Every other check here, and every assertion in both delegation suites, proves
# only that the right string reached argv. The runner's central claim is that a
# deny rule is *honoured* under --dangerously-skip-permissions. An unknown value
# passed to --disallowedTools is not an error, so nothing above would catch the
# rule silently ceasing to mean anything. This probe runs a real session, so it
# is gated on authentication like the check above.
$authenticated = $false
if ($auth.ExitCode -eq 0) {
    try {
        $parsedAuth = $auth.Output | ConvertFrom-Json
        $authenticated = Test-ExplicitAuthenticationStatus $parsedAuth
    } catch { $authenticated = $false }
}

if (-not $authenticated) {
    if ($RequireLiveEnforcement) {
        throw 'Authenticated Claude Code is required for live enforcement probes.'
    }
    Write-Host '  skip  unauthenticated runner; deny-rule enforcement not probed live'
} else {
    $liveRoot = Join-Path ([System.IO.Path]::GetFullPath((Get-Location).Path)) (
        ".claude-cli-contract-$([guid]::NewGuid().ToString('N'))"
    )
    New-Item -ItemType Directory -Force -Path $liveRoot | Out-Null
    try {
        $sentinel = "DENY-PROBE-$([guid]::NewGuid().ToString('N').ToUpperInvariant())"
        $fixtureFile = Join-Path $liveRoot 'fixture.txt'
        Set-Content -LiteralPath $fixtureFile -Value $sentinel -Encoding UTF8
        $rulePath = ConvertTo-ProbeRulePath $liveRoot
        $readPrompt = "This repository test created $fixtureFile as a harmless permission fixture. Read it and reply with its exact contents and nothing else."

        # Control first: if an allowed read does not surface the sentinel, the
        # probe cannot tell enforcement from an unrelated refusal, and a pass on
        # the denied run below would be worthless.
        $allowedRead = Invoke-ClaudeProbe -ClaudePath $claudePath -TimeoutSeconds $LiveProbeTimeoutSeconds -Arguments @(
            '--print', $readPrompt,
            '--dangerously-skip-permissions',
            '--max-turns', '4',
            '--strict-mcp-config', '--setting-sources', 'user'
        )
        if ($allowedRead.TimedOut -or ($allowedRead.Output -notmatch [regex]::Escape($sentinel))) {
            if ($RequireLiveEnforcement) {
                throw "The live control read did not surface its sentinel: $($allowedRead.Output)"
            }
            Write-Host '  skip  the control read did not surface the sentinel; deny enforcement is not distinguishable here'
            Write-Host "        control output: $($allowedRead.Output)"
        } else {
            Write-Host '  ok  the control read surfaces the sentinel, so a denied read is distinguishable'
            $deniedRead = Invoke-ClaudeProbe -ClaudePath $claudePath -TimeoutSeconds $LiveProbeTimeoutSeconds -Arguments @(
                '--print', $readPrompt,
                '--dangerously-skip-permissions',
                '--max-turns', '4',
                '--strict-mcp-config', '--setting-sources', 'user',
                '--disallowedTools', "Read($rulePath/**)", "Edit($rulePath/**)"
            )
            Assert-True (-not $deniedRead.TimedOut) 'the denied read probe returned within the timeout'
            Assert-True (
                $deniedRead.Output -notmatch [regex]::Escape($sentinel)
            ) "a Read deny rule is still enforced under --dangerously-skip-permissions: $($deniedRead.Output)"

            $agentToolPattern = '"name"\s*:\s*"Agent"'
            $agentPrompt = "This repository test created $fixtureFile as a harmless permission fixture. Use the Agent tool exactly once. Ask that subagent to read the fixture with the Read tool and return only its exact contents. Return the subagent result unchanged."
            $agentBaseArguments = @(
                '--print', $agentPrompt,
                '--dangerously-skip-permissions',
                '--max-turns', '8',
                '--output-format', 'stream-json', '--verbose', '--forward-subagent-text',
                '--strict-mcp-config', '--setting-sources', 'user'
            )

            $allowedAgent = Invoke-ClaudeProbe -ClaudePath $claudePath `
                -TimeoutSeconds $LiveProbeTimeoutSeconds -Arguments $agentBaseArguments
            Assert-True (-not $allowedAgent.TimedOut) 'the allowed Agent control returned within the timeout'
            Assert-True ($allowedAgent.Output -match $agentToolPattern) 'the allowed control invoked the Agent tool'
            Assert-True (
                $allowedAgent.Output -match [regex]::Escape($sentinel)
            ) 'the allowed subagent control surfaced the sentinel'

            $inheritedDenyAgent = Invoke-ClaudeProbe -ClaudePath $claudePath `
                -TimeoutSeconds $LiveProbeTimeoutSeconds -Arguments (
                    $agentBaseArguments + @('--disallowedTools', "Read($rulePath/**)", "Edit($rulePath/**)")
                )
            Assert-True (-not $inheritedDenyAgent.TimedOut) 'the inherited-deny Agent probe returned within the timeout'
            Assert-True ($inheritedDenyAgent.Output -match $agentToolPattern) 'the inherited-deny probe invoked the Agent tool'
            Assert-True (
                $inheritedDenyAgent.Output -notmatch [regex]::Escape($sentinel)
            ) 'a parent Read deny rule remains enforced inside a subagent'

            $deniedAgent = Invoke-ClaudeProbe -ClaudePath $claudePath `
                -TimeoutSeconds $LiveProbeTimeoutSeconds -Arguments (
                    $agentBaseArguments + @('--disallowedTools', 'Agent')
                )
            Assert-True (-not $deniedAgent.TimedOut) 'the denied Agent probe returned within the timeout'
            Assert-True (
                $deniedAgent.Output -notmatch $agentToolPattern
            ) 'a bare Agent deny removes the subagent tool in direct mode'
        }
    } finally {
        Remove-Item -LiteralPath $liveRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Claude CLI contract tests passed.'
