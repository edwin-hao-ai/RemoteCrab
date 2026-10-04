#!/usr/bin/env bash
#
# Mac ↔ Windows receiver parity: the same phone, two receivers, one table.
#
# ## Why this exists
#
# There are two implementations of the same wire protocol — a Swift one that
# ships on macOS and a Rust one that ships on Windows — and nothing in the
# repository compared them. `e2e-simulator.sh` proved the Mac half against the
# iOS simulator; the Windows half could only be proved on a Windows machine, so
# "are the two aligned?" was answered by a person remembering. That is the
# question this script turns into a command.
#
# It runs the **same** iOS app against each receiver in turn and prints one row
# per capability. The phone allows exactly one owner, so the runs are
# **sequential** — a second concurrent receiver is answered `busy`, which is
# correct behaviour and would look like a failure.
#
# ## The rule this script is built around
#
# A cell is only red when the run *should* have produced its marker. Most of the
# ways a harness like this produces a wrong verdict come from reporting a
# failure for something the run never exercised — so every capability declares
# the input that makes it checkable, and a cell whose precondition is absent is
# reported as "not exercised" (neutral), never as a failure.
#
# The corollary is the guard below: a run that produced **zero** markers is a
# failed run, not a pass. A matrix of green ticks from a receiver that never
# connected is worse than no matrix.
#
# ## What this cannot verify, and why
#
# * **Input injection** (window drag, text select, real clicks). Needs
#   `SendInput`; the Windows receiver running on macOS receives the frames but
#   cannot inject them. Cells marked `inject`.
# * **Picture quality.** The simulator has no camera, so no run here has an
#   image to judge. That is `renderer_fidelity`'s job (no phone, runs on macOS)
#   plus a real phone.
# * **Virtual camera / microphone, tray, window enumeration.** Windows-only, and
#   they stay in `docs/WINDOWS-GAPS-2026-10-03.md` §5.6 for a real machine.
# * **Speaker capture (WASAPI loopback).** Windows-only by construction. The
#   *wire* half (kind 0x24) is wire-level and is checked by the protocol tests.
#
# ## Verification status — read this before trusting a green table
#
# * `--input fake` is **verified on this machine**: it drives the shipping
#   Windows binary (built for macOS, `--decode-only`) against `rc-phone-sim`
#   and proves the handshake and the H.264 decode path with real numbers.
# * `--input simulator` is **wired but not yet green here.** The same tier is
#   how `e2e-simulator.sh` works, and that script also fails on this machine,
#   so the blocker is environmental rather than something this script
#   introduced — but until it passes, treat the simulator tier as unproven
#   rather than as a parity result.
#
# A tier that cannot run says so and exits non-zero. It does not print a table.
#
# Usage:
#   ./scripts/e2e-parity.sh                     # iOS simulator app, both sides
#   ./scripts/e2e-parity.sh --side windows      # only the Windows receiver
#   ./scripts/e2e-parity.sh --input fake        # rc-phone-sim, fast, narrow
#   ./scripts/e2e-parity.sh --input fake --keep # leave the transcripts behind
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
PORT=8765
RECEIVER_DOMAIN="com.remotecrab.RemoteCrabReceiver"
OUT="$ROOT/.build/parity"
DD_SIM="$ROOT/.build/parity-sim-derived"
STAMP=$(date +%H%M%S)

SIDE="both"; INPUT="simulator"; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --side) SIDE="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --keep) KEEP=1; shift;;
    -h|--help) sed -n '2,45p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

mkdir -p "$OUT"

# Ask cargo where its output actually is, rather than assuming
# `windows/target/`. `~/.cargo/config.toml` on this machine redirects every
# project to one shared `target-dir`, so the hardcoded path does not exist and
# the failure looks like "the binary was never built" when it was.
CARGO_TARGET_DIR_EFFECTIVE=$(cd "$ROOT/windows" && cargo metadata --format-version 1 --no-deps 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || echo "")
[[ -n "$CARGO_TARGET_DIR_EFFECTIVE" ]] || CARGO_TARGET_DIR_EFFECTIVE="$ROOT/windows/target"
WIN_BIN="$CARGO_TARGET_DIR_EFFECTIVE/debug/remotecrab"
SIM_BIN="$CARGO_TARGET_DIR_EFFECTIVE/debug/rc-phone-sim"

# ─────────────────────────────────────────────────────────────────────────────
# The capability table.
#
#   name        what the user would call it
#   mac         marker substring the Mac receiver prints   (os_log subsystem
#               com.remotecrab; captured with `log stream`)
#   win         marker substring the Windows receiver prints (stderr)
#   input       the E2E env flag / scenario that makes this cell CHECKABLE.
#               A cell whose input did not run is neutral, not red.
#   need        extra requirement the host platform cannot meet (`inject`)
#
# The `mac`/`win` strings are checked against the receiver SOURCES in
# preflight. That is crude and it is the point: a marker that was renamed or
# deleted would otherwise make this script report a permanent false red, which
# is how a checklist rots into something nobody reads.
# ─────────────────────────────────────────────────────────────────────────────
CAPS=(
  "handshake|sessionReply: |sessionReply: accepted|[net] sessionReply:|sessionReply: Accepted|AUTOPAIR|"
  "audio|audio packets received:|audio packets received:|audio packets received:|audio packets received:|E2E_MIC|"
  "touch|touch events received:|touch events received:|touch events received:|touch events received:|E2E_INPUT|inject"
  "key|key events received:|key events received:|key events received:|key events received:|E2E_INPUT|inject"
  "file offer|receiving file|receiving file|file: receiving|file: receiving|E2E_SEND_FILE|"
  "file saved|file saved|file saved|file: saved|file: saved|E2E_SEND_FILE|"
  "clipboard|clipboard received from iPhone|clipboard received from iPhone|clipboard: received|clipboard: received|E2E_CLIPBOARD|"
  "app switch|activated app|activated app|app switch requested:|app switch requested:|E2E_SWITCH|inject"
  "video decode|(n/a)|(n/a)|decode: |decode: |--decode-only|"
)

# Seven fields per row:
#   name | mac LITERAL | mac MARKER | win LITERAL | win MARKER | input | need
#
# LITERAL and MARKER are separate because both receivers **format** part of the
# handshake outcome: the Mac logs `reply.result.rawValue` and the Rust receiver
# logs `{:?}` on the enum, so the word "accepted" appears in neither source
# file. A preflight that demanded the whole marker be a literal was therefore
# reporting a false alarm on a working marker — which is worse than no
# preflight, because it teaches you to ignore it.
#
# The LITERAL is the stable, greppable-in-source part and is what the rot check
# verifies. The MARKER is what the transcript is asserted against and may
# include the formatted outcome. `need=inject` cells can never pass on the
# macOS-hosted Windows receiver: it receives the frame and cannot act on it.
preflight() { # every declared literal must exist in its receiver's source
  local bad=0 name maclit macmark winlit winmark input need
  for row in "${CAPS[@]}"; do
    IFS='|' read -r name maclit macmark winlit winmark input need <<<"$row"
    if [[ "$maclit" != "(n/a)" ]] && ! rg -qF "$maclit" "$ROOT/RemoteCrabReceiver" 2>/dev/null; then
      printf '  \033[31m✗\033[0m %-12s Mac literal %q is not in RemoteCrabReceiver/\n' "$name" "$maclit"
      bad=1
    fi
    if [[ "$winlit" != "(n/a)" ]] && ! rg -qF "$winlit" --glob '!target' "$ROOT/windows/crates" 2>/dev/null; then
      printf '  \033[31m✗\033[0m %-12s Windows literal %q is not in windows/crates/\n' "$name" "$winlit"
      bad=1
    fi
  done
  [[ $bad -eq 0 ]] && printf '  \033[32m✓\033[0m every declared literal exists in both receivers\n'
  return $bad
}

# ─────────────────────────────────────────────────────────────────────────────
# Input sources
# ─────────────────────────────────────────────────────────────────────────────
launch_input() { # bring up whatever is acting as the iPhone
  if [[ "$INPUT" == "fake" ]]; then
    "$SIM_BIN" --port "$PORT" --video 400 --seconds 120 \
      >"$OUT/fakephone-$STAMP.log" 2>&1 &
    echo "$!" > "$OUT/fakephone.pid"
    echo "  rc-phone-sim --video 400 on 127.0.0.1:$PORT"
    return 0
  fi
  # Real iOS app in the simulator. Its Bonjour service is invisible to the host
  # (AGENTS.md lesson 11) but its TCP listener is reachable on the shared
  # network stack.
  SIM=$(xcrun simctl list devices booted 2>/dev/null | grep -E 'iPhone.*Booted' | head -1 \
        | grep -oE '[A-F0-9-]{36}' || true)
  if [[ -z "${SIM:-}" ]]; then
    SIM=$(xcrun simctl list devices available 2>/dev/null | grep -E 'iPhone' | head -1 \
          | grep -oE '[A-F0-9-]{36}' || true)
    xcrun simctl boot "$SIM" 2>/dev/null || true
  fi
  [[ -z "${SIM:-}" ]] && { echo "  no iPhone simulator available"; return 1; }
  xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1
  xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture \
    -configuration Debug -destination "id=$SIM" -derivedDataPath "$DD_SIM" \
    build CODE_SIGNING_ALLOWED=NO >"$OUT/iosbuild-$STAMP.log" 2>&1 \
    || { echo "  iOS build failed (see $OUT/iosbuild-$STAMP.log)"; return 1; }
  APP=$(find "$DD_SIM" -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" | head -1)
  [[ -z "$APP" ]] && { echo "  simulator .app not found"; return 1; }
  xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
  xcrun simctl uninstall "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
  xcrun simctl install "$SIM" "$APP" >/dev/null
  # BOTH camera and microphone. requestPermissions() awaits the camera prompt
  # before the listener starts, so an untapped prompt deadlocks the launch and
  # port 8765 never opens — which looks exactly like "Bonjour is broken".
  for p in camera microphone; do xcrun simctl privacy "$SIM" grant "$p" "$BUNDLE_IOS" 2>/dev/null || true; done
  # `simctl privacy` cannot grant kTCCServiceLocalNetwork at all — it errors.
  # Without it the very first frame is the system "find devices on your local
  # network?" alert, and an unanswered system alert is indistinguishable from
  # "the app never started": zero app logs, no listener, port 8765 closed.
  # Seeded straight into TCC.db, same as scripts/capture-feature-shots.sh.
  TCC_DB="$HOME/Library/Developer/CoreSimulator/Devices/$SIM/data/Library/TCC/TCC.db"
  if [[ -f "$TCC_DB" ]]; then
    xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
    for svc in kTCCServiceLocalNetwork kTCCServiceCamera kTCCServiceMicrophone; do
      sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access
        (service,client,client_type,auth_value,auth_reason,auth_version,policy_id,flags,last_modified)
        VALUES ('$svc','$BUNDLE_IOS',0,2,3,1,0,0,strftime('%s','now'));"
    done
    # The seed is INERT until tccd re-reads the file: tccd caches every decision
    # in memory and the simulator has no `killall` to bounce it. Only a boot
    # cycle reloads it. Booting AFTER the seed, not before.
    xcrun simctl shutdown "$SIM" 2>/dev/null || true
    sleep 4
    xcrun simctl boot "$SIM" 2>/dev/null || true
    for _ in $(seq 1 40); do
      xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 && break
      sleep 1
    done
    echo "  seeded TCC (local network, camera, mic) + boot-cycled so tccd reloads"
  fi
  # AUTOSTREAM is REQUIRED, not optional: ContentView.swift:361 is the only
  # path that calls `startStreaming()` without a user tap. AUTO_START alone only
  # bypasses onboarding and leaves the app on the home screen.
  xcrun simctl launch "$SIM" "$BUNDLE_IOS" \
    SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 \
    SIMCTL_CHILD_REMOTECRAB_AUTOSTREAM=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_AUTOPAIR=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_MIC=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_INPUT=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_CLIPBOARD=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_SEND_FILE=1 \
    SIMCTL_CHILD_REMOTECRAB_E2E_SWITCH=com.apple.TextEdit \
    >"$OUT/phone-$STAMP.log" 2>&1 &
  echo "$!" > "$OUT/phone.pid"
  echo "  iOS app in simulator $SIM (all E2E flags on)"
}

wait_for_port() {
  for _ in $(seq 1 60); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

stop_input() {
  [[ -f "$OUT/phone.pid" ]] && kill "$(cat "$OUT/phone.pid")" 2>/dev/null || true
  [[ -f "$OUT/fakephone.pid" ]] && kill "$(cat "$OUT/fakephone.pid")" 2>/dev/null || true
  rm -f "$OUT/phone.pid" "$OUT/fakephone.pid"
  pkill -f "rc-phone-sim --port $PORT" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# One receiver, one transcript.
# ─────────────────────────────────────────────────────────────────────────────
run_windows() { # the Windows receiver, hosted on this Mac
  local log="$OUT/windows-$STAMP.log"
  [[ -x "$WIN_BIN" ]] || { echo "  remotecrab not built — run: (cd windows && cargo build -p rc-app)"; return 1; }
  # --decode-only, never --preview: minifb cannot create a window on macOS and
  # takes the process down with "Rust cannot catch foreign exceptions".
  "$WIN_BIN" --no-tray --decode-only --connect "127.0.0.1:$PORT" >"$log" 2>&1 &
  echo $! > "$OUT/win.pid"
  sleep 45
  kill "$(cat "$OUT/win.pid")" 2>/dev/null || true
  rm -f "$OUT/win.pid"
  echo "$log"
}

run_mac() { # the shipping Mac receiver, via its log stream
  local log="$OUT/mac-$STAMP.log"
  xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$OUT/dd" \
    build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates >"$OUT/macbuild-$STAMP.log" 2>&1 \
    || { echo "  Mac build failed (see $OUT/macbuild-$STAMP.log)"; return 1; }
  # The simulator's listener is on the loopback stack; the Mac receiver's
  # direct-IP fallback is how it gets there. Restored at the end.
  echo "$(defaults read "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP 2>/dev/null || true)" > "$OUT/oldip"
  defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "127.0.0.1"
  pkill -f "log stream --predicate" 2>/dev/null
  nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact \
    >"$log" 2>&1 &
  disown 2>/dev/null || true
  "$OUT/dd/Build/Products/Debug/RemoteCrab.app/Contents/MacOS/RemoteCrab" >/dev/null 2>&1 &
  echo $! > "$OUT/mac.pid"
  sleep 45
  kill "$(cat "$OUT/mac.pid")" 2>/dev/null || true
  pkill -f "log stream --predicate" 2>/dev/null
  rm -f "$OUT/mac.pid"
  [[ -s "$OUT/oldip" ]] && defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "$(cat "$OUT/oldip")"
  echo "$log"
}

# ─────────────────────────────────────────────────────────────────────────────
# The table
# ─────────────────────────────────────────────────────────────────────────────
MARK="✔"; CROSS="✘"; DASH="–"
ROWS=""
add_row() { ROWS+="$1"$'\n'; }

cell() { # cell <log> <marker>
  [[ "$2" == "(n/a)" ]] && { echo "$DASH"; return; }
  [[ -n "${1:-}" && -f "$1" ]] && grep -aqF "$2" "$1" && { echo "$MARK"; return; }
  echo "$CROSS"
}

marker_count() { # how many distinct markers this transcript contains at all
  local log="$1" n=0 name mac win input need
  [[ -n "$log" && -f "$log" ]] || { echo 0; return; }
  for row in "${CAPS[@]}"; do
    IFS='|' read -r name mac win input need <<<"$row"
    for m in "$mac" "$win"; do
      [[ "$m" == "(n/a)" || "$m" == "" ]] && continue
      grep -aqF "$m" "$log" && { n=$((n+1)); break; }
    done
  done
  echo "$n"
}

# Inputs a run actually enabled, so `report` can tell "not proved" (a real
# failure) from "not exercised" (this run never sent the thing).
ENABLED=""
enable() { ENABLED+="$1 "; }
ROW_FAIL=0

report() { # report <label> <log>
  local label="$1" log="$2"
  if [[ "$(marker_count "$log")" -eq 0 ]]; then
    printf '  \033[31m✗\033[0m %s produced NO markers at all — that is a failed run, not a pass\n' "$label"
    add_row "__FAILED__$label"
    return 1
  fi
  local name maclit macmark winlit winmark input need mc wc
  ROW_FAIL=0
  for row in "${CAPS[@]}"; do
    IFS='|' read -r name maclit macmark winlit winmark input need <<<"$row"
    mc=$(cell "$log" "$macmark"); wc=$(cell "$log" "$winmark")
    # Not exercised by this run: the input that would trigger this capability
    # was not enabled, so its marker is absent BY CONSTRUCTION. Reporting that
    # as a failure is how a harness invents bugs — and the fake phone sends no
    # touch, key, clipboard, file or activateApp at all.
    if [[ " $ENABLED " != *" $input "* ]]; then
      mc="$DASH"; wc="$DASH"; input="(not exercised)"
    fi
    # `inject` cells cannot pass on the macOS-hosted Windows receiver: it
    # receives the frame and cannot act on it. Reported, never counted red.
    [[ "$need" == "inject" ]] && [[ "$wc" == "$MARK" ]] && wc="$DASH"
    if [[ "$mc" == "$CROSS" || "$wc" == "$CROSS" ]]; then
      ROW_FAIL=$((ROW_FAIL+1))
    fi
    add_row "$name|$mc|$wc|$input|$need"
  done
  return 0
}

echo "== RemoteCrab receiver parity =="
echo "-- input: $INPUT    side: $SIDE"
echo ""
echo "[1/3] preflight"
if ! preflight; then
  echo ""
  echo "  A declared marker does not exist in the receiver source. Fix the marker or"
  echo "  the capability list — do NOT weaken the assertion, or this table rots."
  exit 1
fi

MACLOG=""; WINLOG=""; FAILED=0
if [[ "$INPUT" == "fake" ]]; then
  # rc-phone-sim sends sessionReply, metadata, featureState, pings, and H.264
  # when asked with --video. Nothing else.
  enable AUTOPAIR; enable "--decode-only"
else
  # Every REMOTECRAB_E2E_* flag is passed unconditionally below.
  enable AUTOPAIR; enable E2E_MIC; enable E2E_INPUT; enable E2E_SEND_FILE
  enable E2E_CLIPBOARD; enable E2E_SWITCH; enable "--decode-only"
fi
if [[ "$SIDE" == "mac" || "$SIDE" == "both" ]]; then
  echo ""
  echo "[2/3] Mac receiver"
  stop_input; launch_input || exit 1
  if ! wait_for_port; then
    echo ""
    echo "  The phone never opened port $PORT, so nothing was proved."
    echo ""
    echo "  This is NOT a parity result and the script refuses to print a table."
    echo "  An unanswered system permission alert and an app that never started"
    echo "  look identical from here: no app logs, no listener, port closed."
    echo "  Checklist, in the order that has actually bitten:"
    echo "    1. Local Network granted. simctl privacy CANNOT do it — it errors."
    echo "       It must be seeded into TCC.db and the device boot-cycled (done above)."
    echo "    2. REMOTECRAB_AUTOSTREAM=1 present. It is the ONLY path that calls"
    echo "       startStreaming() without a tap (ContentView.swift:361)."
    echo "    3. The app is the one that was just installed, and the simulator is"
    echo "       Booted. scripts/e2e-simulator.sh has its own preflight for this."
    echo "  App log: $OUT/phone-$STAMP.log"
    stop_input
    exit 1
  fi
  MACLOG=$(run_mac) || exit 1
  echo "  transcript: $MACLOG"
  report "Mac receiver" "$MACLOG" || FAILED=$((FAILED+1))
  stop_input
fi
if [[ "$SIDE" == "windows" || "$SIDE" == "both" ]]; then
  echo ""
  echo "[3/3] Windows receiver (hosted on this Mac)"
  [[ -z "$MACLOG" || "$SIDE" == "windows" ]] && { stop_input; launch_input || exit 1; }
  if ! wait_for_port; then
    echo ""
    echo "  The phone never opened port $PORT, so nothing was proved."
    echo "  See the checklist above; this tier needs the local-network grant and"
    echo "  REMOTECRAB_AUTOSTREAM=1. Refusing to print an unearned table."
    echo "  App log: $OUT/phone-$STAMP.log"
    stop_input
    exit 1
  fi
  WINLOG=$(run_windows) || exit 1
  echo "  transcript: $WINLOG"
  report "Windows receiver" "$WINLOG" || FAILED=$((FAILED+1))
  stop_input
fi

echo ""
echo "── capability matrix ─────────────────────────────────────────────"
printf '  %-12s %-6s %-8s %s\n' "capability" "Mac" "Windows" "needs"
# `while read` over a string rather than an array: macOS ships bash 3.2, where
# an empty array under `set -u` is an unbound-variable error, and an empty ROWS
# is the *normal* case for a single-side run.
while IFS= read -r r; do
  [[ -z "$r" ]] && continue
  if [[ "$r" == __FAILED__* ]]; then
    printf '  \033[31m!! %s transcript is empty\033[0m\n' "${r#__FAILED__}"
    continue
  fi
  IFS='|' read -r name mc wc input need <<<"$r"
  paint() { case "$1" in
    "$MARK") printf '\033[32m%s\033[0m' "$MARK";;
    "$CROSS") printf '\033[33m%s\033[0m' "$CROSS";;
    *) printf '%s' "$1";; esac; }
  note=""
  [[ "$need" == "inject" ]] && note=" (needs SendInput)"
  [[ "$input" == "--decode-only" ]] && note=" (simulator has no camera)"
  printf '  %-12s %s     %s     %s\n' "$name" "$(paint "$mc")" "$(paint "$wc")" "${input}${note}"
done <<< "$ROWS"
echo ""
echo "  $MARK proved   $CROSS not proved   $DASH not applicable on this host"
echo "  Transcripts: $OUT"

if [[ "$KEEP" -eq 0 ]]; then
  echo ""
  echo "  (--keep to retain them; they are the evidence and are not deleted)"
fi

# A table with no red cell is a pass. An EMPTY table is not — that is the run
# that produced nothing at all, which `report` already caught.
if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  echo "  \033[31mFAILED\033[0m: $FAILED transcript(s) produced no markers at all."
  exit 1
fi
echo ""
echo "  Green means: every capability whose input this run enabled was proved on"
echo "  the receiver(s) selected. It does NOT mean the two receivers agree — run"
echo "  both sides and read the columns side by side."
exit 0
