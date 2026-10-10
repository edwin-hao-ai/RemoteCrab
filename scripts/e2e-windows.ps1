#Requires -Version 5.1
<#
.SYNOPSIS
  End-to-end test of the shipped Windows receiver against the fake iPhone.

.DESCRIPTION
  No iPhone, no Mac. `rc-phone-sim` speaks the exact receiver-role protocol the
  real iOS app does, so this drives the *real* `remotecrab.exe` over a real TCP
  socket and asserts what the receiver logs: the dial, the handshake reply, the
  stream metadata, and (with --video) real H.264 NALs actually decoding.

  This is the Windows counterpart of the Mac-side `scripts/e2e-parity.sh
  --input fake`. It does NOT prove camera/mic/WiFi/real-encoder behaviour --
  only a device does -- but it exercises every code path that needs frames
  flowing, which is most of the binary.

  The run is hermetic: APPDATA and LOCALAPPDATA are pointed at a temp dir for
  the child, so it cannot read or pollute the user's pairing tokens, prefs or log.

.EXAMPLE
  ./scripts/e2e-windows.ps1
  ./scripts/e2e-windows.ps1 -VideoFrames 0 -NoBuild   # handshake only
#>
param(
    [int]$Port = 8765,
    [int]$VideoFrames = 200,
    [string]$Scenario = 'normal',
    [switch]$NoBuild,
    [int]$TimeoutSeconds = 25
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'windows'
$profile = 'debug'
$exeDir = Join-Path $win "target\x86_64-pc-windows-msvc\debug"
$sim = Join-Path $exeDir 'rc-phone-sim.exe'
$receiver = Join-Path $exeDir 'remotecrab.exe'

function Say($msg) { Write-Host "==> $msg" }

# --- build (debug is enough; this is about behaviour, not optimisation) -----
if (-not $NoBuild) {
    Say "building rc-phone-sim + rc-app (debug, MSVC)"
    Push-Location $win
    try {
        $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
        # cargo writes progress to stderr, which with ErrorActionPreference=Stop
        # becomes a terminating error. Watch the exit code instead.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & cargo build -p rc-phone-sim -p rc-app --target x86_64-pc-windows-msvc
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { throw "cargo build failed ($code)" }
    } finally { Pop-Location }
}

$sim = Join-Path $win 'target\x86_64-pc-windows-msvc\debug\rc-phone-sim.exe'
$receiver = Join-Path $win 'target\x86_64-pc-windows-msvc\debug\remotecrab.exe'
$sim = Join-Path $win 'target\x86_64-pc-windows-msvc\debug\rc-phone-sim.exe'
$receiver = Join-Path $win 'target\x86_64-pc-windows-msvc\debug\remotecrab.exe'
if (-not (Test-Path $sim)) { throw "missing $sim (run without -NoBuild)" }

# --- hermetic state dir -----------------------------------------------------
$state = Join-Path $env:TEMP "rc-e2e-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $state | Out-Null
$out = Join-Path $state 'receiver.out'
$err = Join-Path $state 'receiver.err'
$simOut = Join-Path $state 'sim.out'
$simErr = Join-Path $state 'sim.err'

# Stop any receiver already running so the port/single-instance are free.
Get-Process -Name remotecrab -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$fail = 0
$simProc = $null
$recvProc = $null
try {
    Say "starting fake iPhone: rc-phone-sim --port $Port --scenario $Scenario --video $VideoFrames"
    $simArgs = @('--port', "$Port", '--scenario', "$Scenario", '--video', "$VideoFrames", '--seconds', '60')
    $simProc = Start-Process -FilePath $sim -ArgumentList $simArgs `
        -RedirectStandardOutput $simOut -RedirectStandardError $simErr -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800

    Say "starting receiver: remotecrab --connect 127.0.0.1:$Port --no-tray --no-preview --decode-only"
    # Hermetic: the child's APPDATA/LOCALAPPDATA point at the temp dir, so the
    # token store, prefs and log are the test's, not the user's.
    $savedAppData = $env:APPDATA
    $savedLocalAppData = $env:LOCALAPPDATA
    $env:APPDATA = $state
    $env:LOCALAPPDATA = $state
    try {
        $recvProc = Start-Process -FilePath $receiver `
            -ArgumentList @('--connect', "127.0.0.1:$Port", '--no-tray', '--no-preview', '--decode-only') `
            -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    } finally {
        $env:APPDATA = $savedAppData
        $env:LOCALAPPDATA = $savedLocalAppData
    }

    # --- wait for the markers ------------------------------------------------
    function Log() {
        $text = ''
        if (Test-Path $out) { $text += (Get-Content $out -Raw) }
        if (Test-Path $err) { $text += (Get-Content $err -Raw) }
        return $text
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawStream = $false
    $sawDecode = $false
    while ((Get-Date) -lt $deadline) {
        $t = Log
        if ($t -match 'streaming:') { $sawStream = $true }
        if ($t -match 'decoded / \d+ received') { $sawDecode = $true }
        if ($sawStream -and ($VideoFrames -le 0 -or $sawDecode)) { break }
        Start-Sleep -Milliseconds 250
    }

    $log = Log
    Say "checking the receiver log"

    function Check($name, $pattern) {
        if ($log -match $pattern) {
            Write-Host ("  PASS  {0}" -f $name)
        } else {
            Write-Host ("  FAIL  {0}  (no match for /{1}/)" -f $name, $pattern) -ForegroundColor Red
            $script:fail++
        }
    }

    Check 'dial reached the fake phone'  'TCP connected to 127\.0\.0\.1'
    Check 'handshake answered'           'sessionReply:\s*(Accepted|Pending)'
    Check 'stream metadata arrived'      'streaming:'
    if ($VideoFrames -gt 0) {
        Check 'H.264 decoded (frames > 0)' 'decoded / \d+ received'
    }

    Write-Host ''
    Write-Host '--- receiver log (stderr tail) ---'
    if (Test-Path $err) { Get-Content $err | Select-Object -Last 12 }
} finally {
    foreach ($p in @($recvProc, $simProc)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Get-Process -Name remotecrab -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'RESULT: PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: FAIL ($fail)" -ForegroundColor Red
    Write-Host "logs kept in $state"
    exit 1
}
