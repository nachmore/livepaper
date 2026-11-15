#!/bin/bash
# Removes LivePaper completely: everything `livepaper uninstall` undoes (helper, screen saver,
# lock-keys setting and other changed preferences, LivePaper's data), then the app itself.
#
#   scripts/uninstall-dev.sh [--keep-scenes] [--dry-run] [--app PATH]
#
#   --keep-scenes  keep the scene library and preferences in ~/Library/Application Support/LivePaper
#   --dry-run      show what would happen; change nothing
#   --app PATH     the installed bundle (default: /Applications/LivePaper.app or
#                  ~/Applications/LivePaper.app, whichever exists)
#
# The bundled CLI does the uninstall, so it always matches the installed version. If no installed
# app is found, the CLI from build/LivePaper.app is used to clean up what is left.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
CLI_ARGS=(--yes)
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-scenes) CLI_ARGS+=(--keep-scenes); shift ;;
    --dry-run) CLI_ARGS+=(--dry-run); DRY=1; shift ;;
    --app) APP="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

APPS=()
if [ -n "$APP" ]; then
  [ -d "$APP/Contents" ] || { echo "✗ $APP is not an app bundle" >&2; exit 1; }
  APPS=("$APP")
else
  for d in /Applications "$HOME/Applications"; do [ -d "$d/LivePaper.app" ] && APPS+=("$d/LivePaper.app"); done
fi

CLI=""
for a in ${APPS[@]+"${APPS[@]}"} "$ROOT/build/LivePaper.app"; do
  if [ -x "$a/Contents/Helpers/livepaper" ]; then CLI="$a/Contents/Helpers/livepaper"; break; fi
done
[ -n "$CLI" ] || { echo "✗ no LivePaper.app found (looked in /Applications, ~/Applications and build/)" >&2; exit 1; }

# The app must not run while its files and settings are removed (it would recreate some).
if [ "$DRY" = 0 ] && pgrep -x LivePaper >/dev/null 2>&1; then
  echo "▸ quitting LivePaper"
  pkill -TERM -x LivePaper || true
  for _ in $(seq 1 50); do pgrep -x LivePaper >/dev/null 2>&1 || break; sleep 0.1; done
  if pgrep -x LivePaper >/dev/null 2>&1; then echo "✗ LivePaper is still running; quit it and try again" >&2; exit 1; fi
fi

echo "▸ $CLI uninstall ${CLI_ARGS[*]}"
"$CLI" uninstall "${CLI_ARGS[@]}"

remove_link() {   # a `livepaper` symlink made by dev-install.sh --link-cli
  local link="$1" app="$2"
  if [ -L "$link" ] && [[ "$(readlink "$link")" == "$app/"* ]]; then
    if [ "$DRY" = 1 ]; then echo "  • remove $link"; else rm -f "$link"; echo "  ✓ removed $link"; fi
  fi
}

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for a in ${APPS[@]+"${APPS[@]}"}; do
  for link in "$HOME/.local/bin/livepaper" /usr/local/bin/livepaper /opt/homebrew/bin/livepaper; do remove_link "$link" "$a"; done
  if [ "$DRY" = 1 ]; then
    echo "  • delete $a"
  else
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$a" >/dev/null 2>&1 || true
    rm -rf "$a"
    echo "  ✓ deleted $a"
  fi
done
if [ "$DRY" = 1 ]; then echo "Dry run — nothing was changed."; else echo "✓ LivePaper is uninstalled."; fi
