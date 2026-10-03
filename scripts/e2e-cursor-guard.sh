#!/usr/bin/env bash
#
# Did a mirror scroll steal the cursor?
#
# Usage: e2e-cursor-guard.sh <logfile>   → exit 0 = invariant held, 1 = stolen
#
# Lives in its own file so it can be run against a KNOWN log in both
# directions. An assertion only a live 30-second race can exercise is one
# nobody can prove still catches the regression (AGENTS lesson 111: an
# assertion that can pass vacuously is worse than none).
#
# The subtlety this exists to get right:
#
#   CGEventInjector places the cursor when
#     !hasPlacedCursor || !lastCursorInside(current target)
#
# so a re-place after the mirror switches window — or flips to the
# extended virtual display, which the e2e triggers on a timer — is
# CORRECT. An earlier version of this assertion counted placements
# globally and therefore failed a correct run: the "跨目标切换计数，凭空造出
# 一个『回归』" note in AGENTS.md is exactly that false verdict.
#
# Two earlier attempts to infer the reason from the `origin`/`size`
# geometry in the log were both wrong (BSD sed has no `\?`, and "same
# target as the click" is not the same as "cursor was already inside the
# target" — a prior scroll can leave the cursor on another display). So
# the injector states the reason in its own marker line and this reads
# that. The injector is the only thing that knows.
set -uo pipefail

LOG="${1:?usage: e2e-cursor-guard.sh <logfile>}"

CLICK_SEEN=0
SCROLLS_SEEN=0
LEFT_ALONE=0
PLACED_FIRST=0
PLACED_TARGET_CHANGED=0
PLACED_STOLEN=0

while IFS= read -r line; do
  case "$line" in
    *"screen input click"*) CLICK_SEEN=1 ;;
    *"screen input scroll"*)
      if [ "$CLICK_SEEN" -eq 1 ]; then SCROLLS_SEEN=$((SCROLLS_SEEN+1)); fi
      ;;
    *"mirror scroll: cursor left where the user put it"*)
      LEFT_ALONE=$((LEFT_ALONE+1))
      ;;
    *"mirror scroll: cursor placed at window center (first scroll of session)"*)
      PLACED_FIRST=$((PLACED_FIRST+1))
      ;;
    *"mirror scroll: cursor placed at window center (target changed)"*)
      PLACED_TARGET_CHANGED=$((PLACED_TARGET_CHANGED+1))
      ;;
    *"mirror scroll: cursor placed at window center (STOLE"*)
      PLACED_STOLEN=$((PLACED_STOLEN+1))
      ;;
  esac
done < <(grep -a "com.remotecrab:injector" "$LOG" 2>/dev/null || true)

echo "click_seen=$CLICK_SEEN post_click_scrolls=$SCROLLS_SEEN" \
     "left_alone=$LEFT_ALONE placed_first=$PLACED_FIRST" \
     "placed_target_changed=$PLACED_TARGET_CHANGED" \
     "STOLEN=$PLACED_STOLEN" >&2

# The invariant: no scroll moved a cursor that was already inside the
# target it was scrolling.
#
# Requiring a click AND at least one post-click scroll keeps this from
# passing vacuously — "nothing happened" must never read as "passed". Note
# what is deliberately NOT required: that some scroll was observed being
# left alone. The scroll script and the target-switching script race on
# one timeline, so a post-click scroll may never land on an unchanged
# target, and demanding one failed a correct run.
[ "$CLICK_SEEN" -eq 1 ] && [ "$SCROLLS_SEEN" -ge 1 ] && [ "$PLACED_STOLEN" -eq 0 ]