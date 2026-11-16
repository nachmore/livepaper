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
# it does at launch when needed; this script says when to launch it (docs/RESEARCH.md §6).
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

is_adhoc() { { codesign -dvvv "$1" 2>&1 || true; } | grep -q '^Signature=adhoc'; }
# The executable process $1 runs, as the kernel knows it (empty: it was deleted). Note that
# `codesign -dvvv <pid>` describes the file now at that path, not the code that runs: whether that
# is still the same code only `codesign --verify <pid>` says ("the code on disk does not match what
# is running" otherwise; docs/RESEARCH.md §6.1).
running_executable() { { codesign -dvvv "$1" 2>&1 || true; } | sed -n '/^Executable=/{s///p;q;}'; }
real_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")") || printf '%s\n' "$1"; }

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
# (LIVEPAPER_LSREGISTER: the self-test's stand-in, so a test install never reaches Launch Services.)
LSREGISTER="${LIVEPAPER_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# A registered helper keeps running the old binary until it restarts. The LaunchAgent fallback (its
# own label, a plain plist) simply restarts with the new one. The login item is restarted only when
# that can work: launchd starts it only as the code it recorded when the item was registered (for
# ad-hoc code its cdhash), and a refused start sets off launchd's own repair, which can leave the job
# unable to start at all ("spawn failed", EX_CONFIG) until LivePaper registers it again. What was
# recorded is what runs now — so the new helper is compared with the running process, never with the
# file this install replaced (that may be a build that never ran) — and a stopped ad-hoc login item
# is never started from here.
if launchctl print "$FALLBACK_JOB" >/dev/null 2>&1; then
  echo "▸ restarting the helper (LaunchAgent)"
  launchctl kickstart -k "$FALLBACK_JOB" >/dev/null 2>&1 || true
fi
NEW_HELPER="$(real_path "$DEST/$HELPER_REL")"
HELPER_NOTE=""     # why the login item needs LivePaper.app (empty: it doesn't)
HELPER_PID=""      # the helper process running before LivePaper is launched
if JOB="$(launchctl print "$LOGIN_JOB" 2>/dev/null)"; then
  WHY="$(cannot_start_reason "$JOB")"
  PID="$(job_field "$JOB" pid)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then HELPER_PID="$PID"; fi
  if [ -n "$WHY" ]; then
    HELPER_NOTE="launchd can't start it ($WHY)"
  elif [ -n "$HELPER_PID" ]; then
    RUNNING="$(running_executable "$HELPER_PID")"
    if [ -n "$RUNNING" ] && [ "$(real_path "$RUNNING")" != "$NEW_HELPER" ]; then
      echo "! the helper that runs belongs to another copy of LivePaper (${RUNNING%/Contents/Helpers/LivePaperHelper}); left alone." \
           "Use Settings › Lock › Use This Copy’s Helper in this one to move it here." >&2
    elif [ -n "$RUNNING" ] && codesign --verify "$HELPER_PID" >/dev/null 2>&1; then
      echo "▸ the helper already runs this build's code (unchanged); nothing to restart"
    elif is_adhoc "$NEW_HELPER"; then
      HELPER_NOTE="the running helper isn't this build's, and launchd only starts the ad-hoc-signed helper recorded when the login item was registered; the running one keeps going until then"
    else
      # A Team ID-signed helper: launchd starts the new build under the same requirement.
      echo "▸ restarting the helper"
      launchctl kickstart -k "$LOGIN_JOB" >/dev/null 2>&1 || true
      sleep 1
      WHY="$(cannot_start_reason "$(launchctl print "$LOGIN_JOB" 2>/dev/null || true)")"
      if [ -n "$WHY" ]; then HELPER_NOTE="launchd can't start it ($WHY)"; HELPER_PID=""; fi
    fi
  elif is_adhoc "$NEW_HELPER"; then
    HELPER_NOTE="it isn't running, and only LivePaper knows whether launchd would accept this build's ad-hoc-signed helper (a refused start can break the job)"
  else
    echo "▸ starting the helper"
    launchctl kickstart "$LOGIN_JOB" >/dev/null 2>&1 || true
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
  echo "! the helper's login item needs LivePaper.app: $HELPER_NOTE."
  echo "  This script can't register it again (only LivePaper.app itself can talk to SMAppService); launching LivePaper"
  echo "  starts it, or registers it again, by itself (macOS may then say a login item was added)."
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
