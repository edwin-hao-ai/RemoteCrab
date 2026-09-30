#!/usr/bin/env bash
#
# Guard the `CFBundleVersion` numbers in project-mac.yml.
#
# Why this exists (2026-09-30): a release bump was applied with a blind
# search-and-replace on `CFBundleVersion: "8"` and it matched TWO entries —
# the app and the camera system extension. The count matched what was
# expected, which is exactly why nothing looked wrong. But per AGENTS.md
# lesson 5, replacing a system extension **resets the user's approval**, so
# the camera silently disappears and has to be re-approved in System Settings.
# The mic driver is in the same category.
#
# The rule, from lesson 74(e): the app's build number rises every release;
# the sysex and mic-driver numbers stay FROZEN, because a Sparkle update
# replaces the app bundle only.
#
# Usage:
#   ./scripts/check-bundle-versions.sh              # check against the
#                                                  # previous release's appcast
#   ./scripts/check-bundle-versions.sh 9            # assert the app is at 9
#
# Exit 0 = safe to release. Exit 1 = do not release; fix the yml first.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YML="$ROOT/project-mac.yml"
APPCAST="$ROOT/dist/appcast/appcast.xml"

[[ -f "$YML" ]] || { echo "❌ $YML not found" >&2; exit 1; }

# The sysex and HAL plug-in are identified by the bundle they build, not by
# position — a line number would rot the first time a target is inserted.
frozen_owners=( "RemoteCrab Camera" "RemoteCrab Microphone" )

# Baseline = the last committed yml. Comparing against it is what turns
# "print the frozen versions" into "notice that a frozen version moved",
# which is the entire point — a check that only reports cannot fail.
BASELINE="$(mktemp)"
trap 'rm -f "$BASELINE"' EXIT
if git -C "$ROOT" show HEAD:project-mac.yml > "$BASELINE" 2>/dev/null; then
    HAVE_BASELINE=1
else
    HAVE_BASELINE=0
    cp "$YML" "$BASELINE"
fi

read_version() {  # read_version <CFBundleDisplayName> [file]
    # NOT `$2`: "RemoteCrab Camera" has a space in it, so field splitting
    # would compare against "RemoteCrab" and silently match the wrong target.
    # A guard that reports a false "not found" is worse than no guard.
    awk -v owner="$1" '
        /^[[:space:]]*CFBundleDisplayName:/ {
            name = $0
            sub(/^[[:space:]]*CFBundleDisplayName:[[:space:]]*/, "", name)
        }
        /^[[:space:]]*CFBundleVersion:/ {
            if (name == owner) {
                v = $0
                sub(/^[[:space:]]*CFBundleVersion:[[:space:]]*/, "", v)
                gsub(/"/, "", v)
                print v
                exit
            }
        }
    ' "${2:-$YML}"
}

fail=0
echo "── RemoteCrab bundle versions ──────────────────────────"

# 1. The app must be the only thing that moved.
app_version="$(read_version 'RemoteCrab')"
[[ -n "$app_version" ]] || { echo "❌ could not read the app's CFBundleVersion" >&2; exit 1; }
echo "  app (RemoteCrab)          : $app_version"

if [[ $# -ge 1 ]]; then
    if [[ "$app_version" != "$1" ]]; then
        echo "❌ expected the app at $1, found $app_version" >&2
        fail=1
    fi
elif [[ -f "$APPCAST" ]]; then
    previous="$(grep -o 'sparkle:version>[0-9]*' "$APPCAST" | head -1 | tr -dc '0-9')"
    if [[ -n "$previous" && "$app_version" -le "$previous" ]]; then
        echo "❌ the appcast already advertises build $previous; Sparkle compares" \
             "these numbers, so $app_version would be an *older* build and users" \
             "would never be offered this release" >&2
        fail=1
    fi
fi

# 2. The system extension and the HAL plug-in must not move.
for owner in "${frozen_owners[@]}"; do
    version="$(read_version "$owner")"
    baseline="$(read_version "$owner" "$BASELINE")"
    echo "  frozen ($owner)  : ${version:-<not found>}"
    if [[ -z "$version" ]]; then
        echo "❌ no CFBundleVersion found for $owner — did the target change name?" >&2
        fail=1
    elif [[ $HAVE_BASELINE -eq 1 && -n "$baseline" && "$version" != "$baseline" ]]; then
        # This is the trap from 2026-09-30: a blanket search-and-replace on
        # the version string matched the app AND the camera extension, and the
        # count matched expectations so nothing looked wrong.
        echo "❌ $owner moved from $baseline to $version." >&2
        echo "   It is a system extension: replacing it RESETS the user's approval," >&2
        echo "   the camera vanishes from every app, and they must re-approve it in" >&2
        echo "   System Settings. Put it back to $baseline." >&2
        fail=1
    fi
done

# 3. State the consequence out loud, so nobody "fixes" it later by bumping.
cat <<'NOTE'

  Bumping the camera extension or the microphone driver replaces a system
  extension, which RESETS the user's approval for it: the camera silently
  disappears from every app and the microphone stops appearing as an input,
  and the user has to approve it again in System Settings. It is not a
  cosmetic version number. (AGENTS.md lesson 5, and lesson 74(e).)
NOTE

if [[ $fail -ne 0 ]]; then
    echo
    echo "❌ NOT safe to release — see above."
    exit 1
fi
echo "  ✅ safe to release"
