# install.ps1 - one-shot installer for ps1-toolkit
# Usage: irm https://raw.githubusercontent.com/sosramalex/ps1-toolkit/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$RepoOwner = 'sosramalex'
$RepoName  = 'ps1-toolkit'
$Branch    = 'main'

if (-not $env:LOCALAPPDATA) {
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
}
$InstallDir = Join-Path $env:LOCALAPPDATA 'ps1-toolkit'

$files = @(
    'ps1-toolkit.ps1',
    'ps1-toolkit.cmd',
    'ps1-toolkit-admin.cmd',
    'README.md'
)

function Try-Download($url, $out) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 30
        return $true
    } catch {
        return $false
    }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

foreach ($f in $files) {
    $dest = Join-Path $InstallDir $f
    $url  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/$f"
    $ok   = Try-Download $url $dest
    if (-not $ok -and $Branch -eq 'main') {
        $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/master/$f"
        $ok  = Try-Download $url $dest
    }
    if (-not $ok) {
        throw "Failed to download $f from $url"
    }
}

Write-Host ""
Write-Host "ps1-toolkit installed to: $InstallDir" -ForegroundColor Green
Write-Host "Launching interactive menu (Administrator required)..." -ForegroundColor Cyan
Write-Host ""

# Start-Process with -Verb RunAs triggers UAC; the .cmd then handles -Elevate.
Start-Process -FilePath (Join-Path $InstallDir 'ps1-toolkit-admin.cmd') -Verb RunAs