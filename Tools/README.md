[CmdletBinding()]
param([switch]$InstallJdk)
$ErrorActionPreference = "Stop"
$toolsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $toolsDir

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows is required: https://git-scm.com/download/win"
}
Write-Host "Initializing NSTool, Ghidra source, and nested submodules..."
Push-Location $repoRoot
try {
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Git submodule initialization failed." }
}
finally { Pop-Location }

$javaMajor = 0
if (Get-Command java -ErrorAction SilentlyContinue) {
    $versionText = (& java -version 2>&1 | Out-String)
    if ($versionText -match 'version "(\d+)') { $javaMajor = [int]$Matches[1] }
}
if ($javaMajor -lt 25) {
    if (-not $InstallJdk) {
        throw "Ghidra 12.2 requires a 64-bit JDK 25+. Install Eclipse Temurin 25 from https://adoptium.net/temurin/releases/ or rerun with -InstallJdk."
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget is unavailable. Install JDK 25 manually from https://adoptium.net/temurin/releases/." }
    & winget install --id EclipseAdoptium.Temurin.25.JDK --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "JDK installation failed." }
    Write-Warning "Open a new PowerShell window, then rerun this script."
    exit 0
}

$ghidraDir = Join-Path $toolsDir "Ghidra-Distribution"
$launcher = Get-ChildItem -Path $ghidraDir -Filter "ghidraRun.bat" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $launcher) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/tags/Ghidra_12.2_build" -Headers @{ "User-Agent" = "nxnative-tools-setup" }
    $asset = $release.assets | Where-Object { $_.name -match '^ghidra_.*\.zip$' -and $_.name -notmatch 'source' } | Select-Object -First 1
    if (-not $asset) { throw "Official Ghidra distribution ZIP was not found in the Ghidra_12.2_build release." }
    $cacheDir = Join-Path $toolsDir ".cache"
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $zipPath = Join-Path $cacheDir $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    if (Test-Path $ghidraDir) { Remove-Item -Recurse -Force $ghidraDir }
    New-Item -ItemType Directory -Force -Path $ghidraDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $ghidraDir -Force
    $launcher = Get-ChildItem -Path $ghidraDir -Filter "ghidraRun.bat" -File -Recurse | Select-Object -First 1
}
if (-not $launcher) { throw "Ghidra extracted, but ghidraRun.bat was not found." }
Write-Host "Setup complete."
Write-Host ("NSTool source and dependencies: " + (Join-Path $toolsDir "NSTool"))
Write-Host ("Ghidra launcher: " + $launcher.FullName)
Write-Host "To build NSTool, install Visual Studio 2019/2022 or Build Tools with C++ workload, MSVC, and Windows SDK; then run Tools/build-nstool-windows.ps1."
