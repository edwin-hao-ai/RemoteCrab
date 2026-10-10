# Compile rc-vmic (kernel PortCls driver) without MSBuild.
#
# The standalone WDK does not register its MSBuild driver toolsets, so this
# mirrors what `WindowsKernelModeDriver10.0` would do: locate cl via vcvars64,
# point at the WDK's km headers, and compile.
#
# NOTE: this compiles the *source*. A linkable `.sys` needs the PortCls
# descriptors + `DriverEntry` that `rc-vmic.cpp` deliberately leaves as TODOs —
# see README.md. So this script produces the `.obj` and reports whether the code
# is at least type-correct against the WDK interfaces.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-cl.ps1
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Release'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "vcvars64.bat not found: $vcvars (install VS 2022 Build Tools with the C++ workload)"
}

$kits = 'C:\Program Files (x86)\Windows Kits\10'
$sdk = '10.0.26100.0'
if (-not (Test-Path -LiteralPath "$kits\Include\$sdk")) {
    $newest = Get-ChildItem "$kits\Include" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^10\.' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw "no Windows SDK under $kits\Include" }
    $sdk = $newest.Name
}
if (-not (Test-Path -LiteralPath "$kits\Include\$sdk\km\portcls.h")) {
    throw "portcls.h not found under $kits\Include\$sdk\km — the WDK is not installed"
}

$incDirs = @(
    "$kits\Include\$sdk\km"
    "$kits\Include\$sdk\shared"
    "$kits\Include\$sdk\ucrt"
)
$inc = ($incDirs | ForEach-Object { "/I`"$_`"" }) -join ' '

$defs = '/D_WIN64 /D_AMD64_ /DAMD64 /D_KERNEL_MODE /DPOOL_NX_OPTIN=1 ' +
        '/DNTDDI_VERSION=0x0A000010 /D_WIN32_WINNT=0x0A00 /DWIN32_LEAN_AND_MEAN'
$optFlags = if ($Config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }

$out = Join-Path $here "x64\$Config"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$bat = @"
@echo off
call "$vcvars" >nul || exit /b 2
cl /nologo /c /kernel /EHsc /std:c++17 /W3 /utf-8 /wd4005 $optFlags $defs $inc /Fo:"$out\rc-vmic.obj" "$here\rc-vmic.cpp"
exit /b %errorlevel%
"@

$batPath = Join-Path $out 'build.bat'
Set-Content -LiteralPath $batPath -Value $bat -Encoding ASCII

Write-Host "SDK     $sdk"
Write-Host "Output  $out"
Write-Host ""
& cmd.exe /c $batPath
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }

Write-Host ""
Write-Host "Compiled:"
Get-ChildItem $out -Filter 'rc-vmic.obj' | Select-Object Name, Length | Format-Table | Out-String | Write-Host
Write-Host "A linkable .sys needs the PortCls descriptors + DriverEntry (see README.md)."
