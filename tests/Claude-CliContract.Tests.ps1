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
# help output. Each probe runs with empty stdin so the CLI stops at argument
# parsing and never reaches an API call.
#
# Skips cleanly when Claude Code is not installed, so it is safe to run locally.

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    Write-Host "  ok  $Message"
}

function Invoke-ClaudeProbe([string]$ClaudePath, [string[]]$Arguments) {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $merged = @(& $ClaudePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($merged | ForEach-Object { [string]$_ }) -join "`n")
    }
}

$claude = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $claude) {
    Write-Output 'Claude Code CLI is not installed; skipping the CLI contract tests.'
    exit 0
}
$claudePath = $claude.Path
Write-Host "Checking the CLI contract against: $claudePath"

$version = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments @('--version')
Assert-True ($version.ExitCode -eq 0) 'claude --version exits successfully'
Write-Host "  Reported version: $($version.Output.Trim())"

# Confirm the probe can actually tell a real flag from a fake one before
# trusting any of its verdicts.
$controlProbe = Invoke-ClaudeProbe -ClaudePath $claudePath -Arguments @(
    '--print', '--delegation-contract-control-flag'
)
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
} else {
    Write-Host '  skip  claude auth status returned nonzero (unauthenticated runner); JSON shape not checked'
}

Write-Output 'Claude CLI contract tests passed.'
