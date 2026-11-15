#!/bin/bash
# Removes LivePaper: everything `livepaper uninstall` undoes (helper, screen saver, lock-keys setting
# and other changed preferences, LivePaper's data), then the app itself. Your scene library and
# preferences are KEPT unless you pass --delete-scenes.
#
#   scripts/uninstall-dev.sh [--delete-scenes] [--yes] [--dry-run] [--app PATH]
#
#   --delete-scenes  also delete the scene library (every scene you or an AI made) and preferences in
#                    ~/Library/Application Support/LivePaper — permanently, not to the Trash. Asks
#                    first, after showing what uninstall would do, unless --yes is given
#   --yes            don't ask (only matters with --delete-scenes)
#   --dry-run        show what would happen; change nothing
#   --app PATH       the installed bundle (default: /Applications/LivePaper.app or
#                    ~/Applications/LivePaper.app, whichever exists)
#   --keep-scenes    accepted for compatibility; keeping the scenes is the default
#
# The bundled CLI does the uninstall, so it always matches the installed version. If no installed
# app is found, the CLI from build/LivePaper.app is used to clean up what is left.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
KEEP=1
YES=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-scenes) KEEP=1; shift ;;
    --delete-scenes) KEEP=0; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --app) APP="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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

CLI_ARGS=()
if [ "$KEEP" = 1 ]; then CLI_ARGS+=(--keep-scenes); fi
if [ "$DRY" = 1 ]; then
  CLI_ARGS+=(--dry-run)
else
  # Deleting the scenes can't be undone: show the plan and ask before changing anything (including
  # quitting the app). EOF or anything but y/yes is a no.
  if [ "$KEEP" = 0 ] && [ "$YES" = 0 ]; then
    "$CLI" uninstall --dry-run
    echo
    echo "This also deletes your scene library ($HOME/Library/Application Support/LivePaper/Library) permanently."
    answer=""
    read -r -p "Delete LivePaper and all your scenes? [y/N] " answer || true
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) echo "Nothing was changed. (Without --delete-scenes your scenes are kept.)"; exit 1 ;;
    esac
  fi
  CLI_ARGS+=(--yes)
fi

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
