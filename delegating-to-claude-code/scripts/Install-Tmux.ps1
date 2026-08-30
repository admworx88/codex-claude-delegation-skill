[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX)) {
    throw 'Install-Tmux.ps1 supports only macOS.'
}

if ($null -ne (Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host 'tmux is already installed.'
    & tmux -V
    exit 0
}

if ($null -eq (Get-Command brew -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Homebrew is required. Install Homebrew from https://brew.sh/ and rerun Install-Tmux.ps1.'
}

Write-Host 'Installing tmux with Homebrew...'
& brew install tmux
if ($LASTEXITCODE -ne 0) {
    throw 'Homebrew could not install tmux.'
}

if ($null -eq (Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'tmux installation completed but tmux is not available on PATH. Open a new Terminal and rerun the check.'
}

Write-Host 'tmux installation completed.'
& tmux -V
