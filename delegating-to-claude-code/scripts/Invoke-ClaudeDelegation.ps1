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
