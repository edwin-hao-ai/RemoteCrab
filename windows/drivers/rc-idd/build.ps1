<#
.SYNOPSIS
    Build the RemoteCrab indirect display driver (rc-idd).

.DESCRIPTION
    The one build in this repo that is not `cargo`. It needs the Windows Driver
    Kit (WDK) and the MSVC toolset, installed on the machine doing the build —
    see README.md for the exact prerequisites.

    This script only *builds*. Signing the .cat (required to load on a normal
    machine) and installing the device are separate, documented steps.

.EXAMPLE
    pwsh -File build.ps1                 # Release, x64
    pwsh -File build.ps1 -Configuration Debug
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('x64')]
    [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $here 'rc-idd.vcxproj'

if (-not (Test-Path $project)) {
    throw "rc-idd.vcxproj not found next to this script ($here)"
}

# Find MSBuild. Prefer vswhere (ships with every VS 2017+); fall back to the
# Build Tools path so a machine without the full IDE still works.
function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $path = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
            -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($path) { return $path }
    }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw 'MSBuild not found. Install Visual Studio 2022 (or Build Tools) with the C++ workload.'
}

# The WDK registers its toolset under the VS root; make sure it is present so
# the error is "install the WDK", not a wall of "platform toolset not found".
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
if (-not (Test-Path (Join-Path $kitsRoot 'Include'))) {
    throw "Windows SDK not found under $kitsRoot. Install the Windows SDK, then the WDK."
}
$iddcx = Get-ChildItem -Path (Join-Path $kitsRoot 'Include') -Recurse -Filter 'IddCx.h' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $iddcx) {
    throw "IddCx.h not found under $kitsRoot\Include — the WDK is not installed. " +
          "Install 'Windows Driver Kit' matching the Windows SDK version (winget: Microsoft.WindowsWDK.10.0.26100)."
}

$msbuild = Find-MSBuild
Write-Host "MSBuild:  $msbuild"
Write-Host "WDK:      $($iddcx.FullName)"
Write-Host "Building: $Configuration|$Platform"

& $msbuild $project /m /p:Configuration=$Configuration /p:Platform=$Platform `
    /p:DriverTargetPlatform=Universal

if ($LASTEXITCODE -ne 0) {
    throw "msbuild failed ($LASTEXITCODE)"
}

$out = Join-Path $here "$Platform\$Configuration\rc-idd"
Write-Host ""
Write-Host "Built. Package files are under:"
Write-Host "  $out"
Get-ChildItem -Path $out -ErrorAction SilentlyContinue |
    Select-Object Name, Length | Format-Table | Out-String | Write-Host
Write-Host "Next: sign rc-idd.cat, then install (see README.md)."
