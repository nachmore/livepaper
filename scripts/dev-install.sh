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
#
# The helper's login item can't always be restarted from here: launchd only starts it with the code
# signature recorded when it was registered, and an ad-hoc-signed helper's signature changes with
# every build that changes it. Only LivePaper.app itself can register it again (SMAppService), which
# it does at launch; this script says when that is needed (docs/RESEARCH.md §6).
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
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

HELPER_REL="Contents/Helpers/LivePaperHelper"
LOGIN_JOB="gui/$(id -u)/com.nachmore.livepaper.helper"
FALLBACK_JOB="gui/$(id -u)/com.nachmore.livepaper.helper.fallback"
TAB="$(printf '\t')"

# A top-level field of `launchctl print` output ($1), e.g. job_field "$out" "job state".
job_field() { printf '%s\n' "$1" | sed -n "/^${TAB}$2 = /{s///p;q;}"; }

# Why launchd can't start a job, from its `launchctl print` output (empty: nothing says so). The
# same signs as LaunchdJob.cannotStartReason in Sources/LivePaperCore/Install/HelperJob.swift.
cannot_start_reason() {
  local out="$1" why="" code
  if [ "$(job_field "$out" state)" = running ]; then return 0; fi
  if [ "$(job_field "$out" "job state")" = "spawn failed" ]; then why="spawn failed"; fi
  code="$(job_field "$out" "last exit code")"
  case "$code" in 78|78:*) why="${why:+$why, }last exit code $code" ;; esac
  case "$(job_field "$out" properties)" in *"needs LWCR update"*) why="${why:+$why, }needs LWCR update" ;; esac
  case "$out" in *OS_REASON_CODESIGNING*|*"Launch Constraint Violation"*) why="${why:+$why, }launch constraint violation" ;; esac
  printf '%s' "$why"
}

cdhash() { { codesign -dvvv "$1" 2>&1 || true; } | sed -n '/^CDHash=/{s///p;q;}'; }
is_adhoc() { { codesign -dvvv "$1" 2>&1 || true; } | grep -q '^Signature=adhoc'; }

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

# The helper being replaced, to tell whether this build changes it.
OLD_HELPER_CDHASH=""
if [ -e "$DEST/$HELPER_REL" ]; then OLD_HELPER_CDHASH="$(cdhash "$DEST/$HELPER_REL")"; fi

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
# (LIVEPAPER_LSREGISTER: the self-test's stand-in, so a test install never reaches Launch Services.)
LSREGISTER="${LIVEPAPER_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# A registered helper keeps running the old binary until it restarts. The LaunchAgent fallback (its
# own label, a plain plist) simply restarts with the new one. The login item is restarted only when
# that can work: restarting an ad-hoc-signed helper that changed only gets the launch refused, and
# launchd's own repair after that can leave the job unable to start at all ("spawn failed",
# EX_CONFIG) until LivePaper registers it again.
if launchctl print "$FALLBACK_JOB" >/dev/null 2>&1; then
  echo "▸ restarting the helper (LaunchAgent)"
  launchctl kickstart -k "$FALLBACK_JOB" >/dev/null 2>&1 || true
fi
HELPER_NOTE=""     # why the login item needs registering again (empty: it doesn't)
HELPER_PID=""      # the helper process running before LivePaper is launched
if JOB="$(launchctl print "$LOGIN_JOB" 2>/dev/null)"; then
  WHY="$(cannot_start_reason "$JOB")"
  if [ "$(job_field "$JOB" state)" = running ]; then HELPER_PID="$(job_field "$JOB" pid)"; fi
  if [ -n "$WHY" ]; then
    HELPER_NOTE="launchd can't start it ($WHY)"
  elif [ -n "$OLD_HELPER_CDHASH" ] && [ "$OLD_HELPER_CDHASH" = "$(cdhash "$DEST/$HELPER_REL")" ]; then
    echo "▸ restarting the helper (unchanged in this build)"
    launchctl kickstart -k "$LOGIN_JOB" >/dev/null 2>&1 || true
    sleep 1
    WHY="$(cannot_start_reason "$(launchctl print "$LOGIN_JOB" 2>/dev/null || true)")"
    if [ -n "$WHY" ]; then HELPER_NOTE="launchd can't start it ($WHY)"; HELPER_PID=""; fi
  elif is_adhoc "$DEST/$HELPER_REL"; then
    HELPER_NOTE="this build changes the ad-hoc-signed helper, and launchd only starts the one recorded when the login item was registered"
    if [ -n "$HELPER_PID" ]; then HELPER_NOTE="$HELPER_NOTE; the previous build's helper keeps running until then"; fi
  else
    echo "▸ restarting the helper"
    launchctl kickstart -k "$LOGIN_JOB" >/dev/null 2>&1 || true
  fi
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
if [ -n "$HELPER_NOTE" ]; then
  echo "! the helper's login item has to be registered again: $HELPER_NOTE."
  echo "  This script can't do that (only LivePaper.app itself can talk to SMAppService); launching LivePaper"
  echo "  does it by itself (macOS may show \"Login Item Added\")."
fi
if [ "$LAUNCH" = 1 ]; then
  open "$DEST"
  if [ -n "$HELPER_NOTE" ]; then
    # Wait (at most 30 s) for the app to register the helper again and for this build's to run.
    STARTED=""
    for _ in $(seq 1 60); do
      JOB="$(launchctl print "$LOGIN_JOB" 2>/dev/null || true)"
      PID="$(job_field "$JOB" pid)"
      if [ "$(job_field "$JOB" state)" = running ] && [ -n "$PID" ] && [ "$PID" != "$HELPER_PID" ]; then STARTED="$PID"; break; fi
      sleep 0.5
    done
    if [ -n "$STARTED" ]; then
      echo "✓ LivePaper registered the helper again; it runs (pid $STARTED, registered by build $(job_field "$JOB" "parent bundle version"))"
    else
      echo "! the helper doesn't run yet; see \"$CLI\" doctor (LivePaper's Settings › Lock › Repair Helper tries again)"
    fi
  fi
else
  echo "  open it with: open \"$DEST\"   (first launch walks you through setup)"
  echo "  check it with: \"$CLI\" doctor"
fi
