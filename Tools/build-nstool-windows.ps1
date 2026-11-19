[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("Win32", "x64")]
    [string]$Platform = "x64"
)
$ErrorActionPreference = "Stop"
$nstoolDir = Join-Path $PSScriptRoot "NSTool"
$solution = Join-Path $nstoolDir "build\visualstudio\nstool.sln"
if (-not (Test-Path $solution)) { throw "NSTool solution missing. Run Tools/setup-windows.ps1 first." }

$programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "Install Visual Studio 2019/2022 or Build Tools with Desktop development with C++ and a Windows SDK." }
$installPath = & $vswhere -latest -products "*" -requires Microsoft.Component.MSBuild -property installationPath
if (-not $installPath) { throw "MSBuild component not found in Visual Studio." }
$msbuild = Join-Path $installPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msbuild)) { throw "MSBuild executable not found." }

Write-Host "Building NSTool ($Configuration | $Platform)..."
& $msbuild $solution /m "/p:Configuration=$Configuration" "/p:Platform=$Platform" /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw "NSTool build failed with exit code $LASTEXITCODE." }
Write-Host "Build completed. NSTool executables:"
Get-ChildItem -Path $nstoolDir -Filter "nstool.exe" -File -Recurse | ForEach-Object { Write-Host $_.FullName }
