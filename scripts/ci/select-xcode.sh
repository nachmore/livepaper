#!/bin/bash
# Selects an Xcode for the rest of a CI job and checks its Swift (docs/RELEASING.md).
#
#   scripts/ci/select-xcode.sh <Xcode.app> [minimum Swift, default 6.2]
#
# Fails, listing the Xcodes that are installed, when the app is missing or its Swift is too old.
# Exports DEVELOPER_DIR through $GITHUB_ENV (no sudo xcode-select); outside GitHub Actions it prints
# the export line instead. Runs only xcrun / swift --version; nothing GUI.
set -euo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
XCODE="${1%/}"
MIN="${2:-6.2}"
fail() {
  echo "✗ $*" >&2
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=Xcode::$*"
  local x found=""
  for x in /Applications/Xcode*.app; do [ -d "$x" ] && found="$found $x"; done
  echo "  installed:${found:- none}" >&2
  exit 1
}

[ -d "$XCODE/Contents/Developer" ] || fail "$XCODE is not installed on this runner (update XCODE_APP in .github/workflows/ci.yml)"
DEV="$XCODE/Contents/Developer"
SWIFT_LINE="$(DEVELOPER_DIR="$DEV" xcrun swift --version 2>&1 | grep -m1 'Swift version')" \
  || fail "$XCODE has no working swift (licence not accepted?)"
# "Apple Swift version 6.3.3 (swiftlang-…)" → 6.3.3
SWIFT="$(printf '%s\n' "$SWIFT_LINE" | sed -E 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/')"

# True when dotted version $1 ≥ $2 (numeric, component by component; bash 3.2 — no sort -V).
version_ge() {
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"; read -r -a b <<< "$2"
  for i in 0 1 2; do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}
[[ "$SWIFT" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "couldn't read the Swift version of $XCODE ('$SWIFT_LINE')"
version_ge "$SWIFT" "$MIN" || fail "$XCODE has Swift $SWIFT; LivePaper needs Swift $MIN or later"

XCODE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XCODE/Contents/Info.plist" 2>/dev/null || echo '?')"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$DEV" >> "$GITHUB_ENV"
else
  echo "export DEVELOPER_DIR='$DEV'"
fi
echo "✓ Xcode $XCODE_VERSION ($XCODE), Swift $SWIFT, $(DEVELOPER_DIR="$DEV" xcrun --show-sdk-version 2>/dev/null | sed 's/^/macOS SDK /')" >&2
