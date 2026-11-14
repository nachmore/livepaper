#!/bin/bash
# Fills a built LivePaper.saver with a small test playlist for scripts/dev/saverhost-lp.swift runs.
#
#   scripts/dev/make-test-playlist.sh [--saver PATH] [--mode sequence|shuffle|single] [--cycle MIN]
#                                     [--scenes web,video] [--empty]
#
#   --saver PATH   bundle to fill (default: build/LivePaper.saver, from scripts/build-saver.sh)
#   --mode M       playlist mode (default: sequence, so the web scene plays first)
#   --cycle MIN    cycleMinutes (default: 0 = never change while running)
#   --scenes LIST  comma-separated subset of: web, video (default: web,video)
#   --empty        publish a playlist with no scenes (exercises the built-in fallback)
#
# Scenes: scripts/dev/test-scene.html (a stand-in for a compiled web scene with a minimal
# LivePaper.host bridge) and a 4 s H.264 clip rendered by scripts/dev/make-test-video.swift
# (AVAssetWriter + CoreGraphics — no window server). Nothing here launches a GUI process.
#
# This deliberately modifies Contents/Resources/Playlist AFTER build-saver.sh signed the bundle,
# exactly like the app's publish step does (see Saver/README.md, "Publishing into a signed bundle").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SAVER="$ROOT/build/LivePaper.saver"
MODE=sequence
CYCLE=0
SCENES="web,video"
while [ $# -gt 0 ]; do
  case "$1" in
    --saver) SAVER="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --cycle) CYCLE="$2"; shift 2 ;;
    --scenes) SCENES="$2"; shift 2 ;;
    --empty) SCENES=""; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in shuffle|sequence|single) ;; *) echo "--mode must be shuffle, sequence or single" >&2; exit 2 ;; esac
[[ "$CYCLE" =~ ^[0-9]+$ ]] || { echo "--cycle must be a whole number of minutes" >&2; exit 2; }
[ -f "$SAVER/Contents/Info.plist" ] || { echo "no saver bundle at $SAVER (run scripts/build-saver.sh first)" >&2; exit 1; }

# Same fallback as build-saver.sh when Xcode's license hasn't been accepted.
if ! xcrun swiftc --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

DEV="$ROOT/build/dev"
mkdir -p "$DEV"
VIDEO_TOOL="$DEV/make-test-video"
VIDEO="$DEV/test-video.mov"
if [ ! -x "$VIDEO_TOOL" ] || [ "$ROOT/scripts/dev/make-test-video.swift" -nt "$VIDEO_TOOL" ]; then
  xcrun swiftc -O -o "$VIDEO_TOOL" "$ROOT/scripts/dev/make-test-video.swift"
  rm -f "$VIDEO"
fi
[ -f "$VIDEO" ] || "$VIDEO_TOOL" "$VIDEO" --size 640x400 --seconds 4 --fps 30

PLAYLIST="$SAVER/Contents/Resources/Playlist"
rm -rf "$PLAYLIST"
mkdir -p "$PLAYLIST"

entries=()
IFS=',' read -ra wanted <<< "$SCENES"
for scene in ${wanted[@]+"${wanted[@]}"}; do
  case "$scene" in
    web)
      cp "$ROOT/scripts/dev/test-scene.html" "$PLAYLIST/test-web.html"
      entries+=('{"id": "test-web", "name": "Test web scene", "kind": "web", "file": "test-web.html", "clock": "top"}') ;;
    video)
      cp "$VIDEO" "$PLAYLIST/test-video.mov"
      entries+=('{"id": "test-video", "name": "Test video", "kind": "video", "file": "test-video.mov", "clock": "top", "fit": "fill"}') ;;
    "") ;;
    *) echo "unknown scene '$scene' (use web, video)" >&2; exit 2 ;;
  esac
done

joined=""
for e in ${entries[@]+"${entries[@]}"}; do joined="${joined:+$joined,
    }$e"; done
cat > "$PLAYLIST/playlist.json" <<JSON
{
  "schema": 1,
  "generation": 1,
  "mode": "$MODE",
  "cycleMinutes": $CYCLE,
  "showClock": true,
  "performance": "automatic",
  "scenes": [
    $joined
  ]
}
JSON

echo "✓ test playlist ($MODE, ${#entries[@]} scene(s)) in $PLAYLIST"
if codesign --verify --strict "$SAVER" >/dev/null 2>&1; then
  echo "  codesign --verify: still valid"
else
  echo "  codesign --verify: seal broken by the post-signing change (expected; see Saver/README.md)"
fi
