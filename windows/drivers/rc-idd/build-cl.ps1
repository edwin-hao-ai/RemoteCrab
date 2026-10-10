# Build rc-idd without MSBuild.
#
# The standalone WDK (winget) does not register its `WindowsUserModeDriver10.0`
# VS platform toolset, so `build.ps1` (msbuild) cannot resolve the toolset on a
# machine that only has the WDK + Build Tools. This script does exactly what
# that toolset would: it locates cl/link via vcvars64, points at the WDK's
# IddCx + UMDF headers/libs, and compiles the UMDF driver directly.
#
# It only *builds*. Signing the .cat and installing the device are separate
# steps — see README.md.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-cl.ps1            # Release
#   powershell -ExecutionPolicy Bypass -File build-cl.ps1 -Config Debug
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Release',
    [string]$DriverVer = '1.0.0.0'
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

# IddCx is version-folderised; pick the newest <= the version we compile against.
$iddcxRoot = "$kits\Include\$sdk\um\iddcx"
$iddcxVer = Get-ChildItem $iddcxRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $iddcxVer) { throw "IddCx.h not found under $iddcxRoot — the WDK is not installed" }

# UMDF headers are version-folderised too; 2.25 matches the .vcxproj.
$wdfVer = '2.25'
if (-not (Test-Path -LiteralPath "$kits\Include\wdf\umdf\$wdfVer")) {
    $wdfVer = (Get-ChildItem "$kits\Include\wdf\umdf" -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
}

$incDirs = @(
    "$iddcxRoot\$($iddcxVer.Name)"
    "$kits\Include\wdf\umdf\$wdfVer"
    "$kits\Include\$sdk\um"
    "$kits\Include\$sdk\shared"
    "$kits\Include\$sdk\ucrt"
    "$kits\Include\$sdk\winrt"
    "$kits\Include\$sdk\cppwinrt"
)
$libDirs = @(
    "$kits\Lib\$sdk\um\x64"
    "$kits\Lib\$sdk\um\x64\iddcx\$($iddcxVer.Name)"
    "$kits\Lib\$sdk\ucrt\x64"
    "$kits\Lib\wdf\umdf\x64\$wdfVer"
)

$out = Join-Path $here "x64\$Config"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$defs = '/D_WIN64 /D_AMD64_ /DAMD64 /DUMDF_DRIVER /DIDDCX_VERSION_MAJOR=1 ' +
        "/DIDDCX_VERSION_MINOR=$($iddcxVer.Name -replace '^1\.','') " +
        '/DIDDCX_MINIMUM_VERSION_REQUIRED=4 /D_ATL_NO_WIN_SUPPORT /DUNICODE /D_UNICODE'
$inc = ($incDirs | ForEach-Object { "/I`"$_`"" }) -join ' '
$libp = ($libDirs | ForEach-Object { "/LIBPATH:`"$_`"" }) -join ' '

$optFlags = if ($Config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }

$bat = @"
@echo off
call "$vcvars" >nul || exit /b 2
echo === compile ===
cl /nologo /c /EHsc /std:c++17 /W3 /utf-8 /wd4005 $optFlags $defs $inc /Fo:"$out\rc-idd.obj" "$here\rc-idd.cpp"
if errorlevel 1 exit /b 1
echo === link ===
link /nologo /DLL /SUBSYSTEM:WINDOWS $libp /OUT:"$out\rc-idd.dll" "$out\rc-idd.obj" ^
    iddcxstub.lib WdfDriverStubUm.lib ntdll.lib mincore.lib OneCoreUAP.lib avrt.lib ^
    uuid.lib ole32.lib dxgi.lib d3d11.lib
exit /b %errorlevel%
"@

$batPath = Join-Path $out 'build.bat'
Set-Content -LiteralPath $batPath -Value $bat -Encoding ASCII

Write-Host "SDK      $sdk"
Write-Host "IddCx    $($iddcxVer.Name)"
Write-Host "UMDF     $wdfVer"
Write-Host "Output   $out"
Write-Host ""

& cmd.exe /c $batPath
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

# Package: stage the INF, let stampinf fill DriverVer + $ARCH$/$UMDFVERSION$,
# then let Inf2Cat produce the catalog the driver would be signed against. This
# is exactly what the MSBuild driver toolset's StampInf + Inf2Cat targets do.
function Find-KitTool([string]$name) {
    $t = Get-ChildItem "$kits\bin" -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x86\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $t) { throw "$name not found under $kits\bin (is the WDK installed?)" }
    return $t.FullName
}

Copy-Item (Join-Path $here 'rc-idd.inf') (Join-Path $out 'rc-idd.inf') -Force
$stampinf = Find-KitTool 'stampinf.exe'
Write-Host "=== stampinf ==="
& $stampinf -f "$out\rc-idd.inf" -d '*' -v $DriverVer -a amd64 -u "$wdfVer.0"
if ($LASTEXITCODE -ne 0) { throw "stampinf failed ($LASTEXITCODE)" }

$inf2cat = Find-KitTool 'Inf2Cat.exe'
Write-Host "=== inf2cat ==="
& $inf2cat /driver:$out /os:10_X64
if ($LASTEXITCODE -ne 0) { throw "inf2cat failed ($LASTEXITCODE)" }

Write-Host ""
Write-Host "Built:"
Get-ChildItem $out -Filter 'rc-idd.*' |
    Select-Object Name, Length | Format-Table | Out-String | Write-Host
Write-Host "Next: sign rc-idd.cat, then install (see README.md)."
