#!/bin/bash
# Installs a locally built LivePaper.app (scripts/build.sh) for the current user.
#
#   scripts/dev-install.sh [--app PATH] [--dest DIR] [--launch] [--link-cli [DIR]]
#
#   --app PATH       the bundle to install (default: build/LivePaper.app)
#   --dest DIR       install into DIR (default: where LivePaper is already installed, else
#                    /Applications when it is writable, else ~/Applications)
#   --launch         open LivePaper afterwards (first launch runs the guided setup)
#   --link-cli [DIR] symlink the bundled `livepaper` CLI into DIR (default ~/.local/bin)
#
# It quits a running LivePaper first (the helper and render daemon are restarted by launchd / on
# demand), replaces the bundle in one move, clears the quarantine flag and verifies the signature.
# Nothing is launched unless --launch is given. Undo with scripts/uninstall-dev.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/LivePaper.app"
DEST_DIR=""
LAUNCH=0
LINK_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) SRC="$2"; shift 2 ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    --launch) LAUNCH=1; shift ;;
    --link-cli)
      if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then LINK_DIR="$2"; shift 2; else LINK_DIR="$HOME/.local/bin"; shift; fi ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[ -d "$SRC/Contents" ] || { echo "✗ $SRC not found — run scripts/build.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$SRC" || { echo "✗ $SRC has an invalid signature — rebuild it" >&2; exit 1; }

# Keep a single copy: two LivePaper.apps confuse Launch Services and the login item.
if [ -z "$DEST_DIR" ]; then
  for d in /Applications "$HOME/Applications"; do
    if [ -d "$d/LivePaper.app" ]; then DEST_DIR="$d"; break; fi
  done
fi
if [ -z "$DEST_DIR" ]; then
  if [ -w /Applications ]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; fi
fi
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/LivePaper.app"
for d in /Applications "$HOME/Applications"; do
  if [ "$d/LivePaper.app" != "$DEST" ] && [ -d "$d/LivePaper.app" ]; then
    echo "! another copy exists at $d/LivePaper.app — remove it (scripts/uninstall-dev.sh --app $d/LivePaper.app removes everything)" >&2
  fi
done

# Quit the running app (SIGTERM lets it shut its embedded render server down cleanly).
if pgrep -x LivePaper >/dev/null 2>&1; then
  echo "▸ quitting the running LivePaper"
  pkill -TERM -x LivePaper || true
  for _ in $(seq 1 50); do pgrep -x LivePaper >/dev/null 2>&1 || break; sleep 0.1; done
  if pgrep -x LivePaper >/dev/null 2>&1; then echo "✗ LivePaper is still running; quit it and try again" >&2; exit 1; fi
fi

echo "▸ installing $DEST"
# Copy next to the destination, then swap: a running helper keeps its (old) executable file, and a
# failed copy never leaves a half-installed app.
TMP="$DEST_DIR/.LivePaper.app.installing"
rm -rf "$TMP"
ditto "$SRC" "$TMP"
xattr -dr com.apple.quarantine "$TMP" 2>/dev/null || true
rm -rf "$DEST"
mv "$TMP" "$DEST"
codesign --verify --deep --strict "$DEST"
# Register the bundle so Finder knows .lpscene packages (does not launch anything).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# A registered helper keeps running the old binary until it restarts.
HELPER="gui/$(id -u)/com.nachmore.livepaper.helper"
if launchctl print "$HELPER" >/dev/null 2>&1; then
  echo "▸ restarting the helper"
  launchctl kickstart -k "$HELPER" >/dev/null 2>&1 || true
fi
# A render daemon started from the old bundle hands over to the next one on demand.
CLI="$DEST/Contents/Helpers/livepaper"
"$CLI" server stop >/dev/null 2>&1 || true

if [ -n "$LINK_DIR" ]; then
  mkdir -p "$LINK_DIR"
  ln -sfn "$CLI" "$LINK_DIR/livepaper"
  echo "▸ linked $LINK_DIR/livepaper → $CLI"
  case ":$PATH:" in *":$LINK_DIR:"*) ;; *) echo "  (add $LINK_DIR to your PATH to run \`livepaper\` directly)" ;; esac
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
echo "✓ LivePaper $VERSION (build $BUILD) installed in $DEST"
if [ "$LAUNCH" = 1 ]; then
  open "$DEST"
else
  echo "  open it with: open \"$DEST\"   (first launch walks you through setup)"
  echo "  check it with: \"$CLI\" doctor"
fi
