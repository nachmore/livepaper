#!/bin/bash
# Builds LivePaper.saver (universal arm64 + x86_64, ad-hoc signed) — ARCHITECTURE §6.
#
#   scripts/build-saver.sh [--out DIR] [--debug]
#
#   --out DIR    output directory (default: build/) → DIR/LivePaper.saver
#   --debug      -Onone with debug info (default: -O, whole-module)
#
# Environment: LIVEPAPER_VERSION (CFBundleShortVersionString, default from Saver/Info.plist),
# LIVEPAPER_BUILD (CFBundleVersion), LIVEPAPER_ARCHS (default "arm64 x86_64").
#
# SwiftPM can't emit an MH_BUNDLE, so the saver is compiled directly with swiftc. It is
# self-contained: Saver/*.swift plus the shared playlist model and scene navigation gate, no LivePaperCore.
# The bundle ships with an empty Contents/Resources/Playlist/ that publishing fills in later
# (see Saver/README.md for why that doesn't need re-signing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
OPT=(-O -wmo)
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --debug) OPT=(-Onone -g); shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Command Line Tools are enough. If the selected developer dir is an Xcode whose license hasn't
# been accepted (swiftc refuses to run), fall back to the CLT.
if ! xcrun swiftc --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

SAVER="$OUT/LivePaper.saver"
read -r -a ARCHS <<< "${LIVEPAPER_ARCHS:-arm64 x86_64}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/livepaper-saver.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCES=("$ROOT"/Saver/*.swift "$ROOT/Sources/LivePaperCore/Playlist/PlaylistModel.swift"
         "$ROOT/Sources/LivePaperCore/Render/SceneNavigationGate.swift")
FRAMEWORKS=(-framework AppKit -framework ScreenSaver -framework WebKit -framework AVFoundation
            -framework QuartzCore -framework IOKit)

echo "▸ LivePaper.saver (${ARCHS[*]})"
SLICES=()
for arch in "${ARCHS[@]}"; do
  xcrun swiftc "${OPT[@]}" -swift-version 5 -module-name LivePaperSaver \
    -target "$arch-apple-macos14.0" \
    -parse-as-library -emit-executable -Xlinker -bundle \
    -o "$TMP/LivePaper-$arch" "${SOURCES[@]}" "${FRAMEWORKS[@]}"
  SLICES+=("$TMP/LivePaper-$arch")
done

rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources/Playlist"
lipo -create "${SLICES[@]}" -output "$SAVER/Contents/MacOS/LivePaper"
cp "$ROOT/Saver/Info.plist" "$SAVER/Contents/Info.plist"
[ -n "${LIVEPAPER_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LIVEPAPER_VERSION" "$SAVER/Contents/Info.plist"
[ -n "${LIVEPAPER_BUILD:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LIVEPAPER_BUILD" "$SAVER/Contents/Info.plist"
cp "$ROOT"/Saver/Resources/thumbnail.png "$ROOT"/Saver/Resources/thumbnail@2x.png "$SAVER/Contents/Resources/"

codesign --force --sign - --timestamp=none "$SAVER"
codesign --verify --strict "$SAVER"

echo "✓ $SAVER ($(lipo -archs "$SAVER/Contents/MacOS/LivePaper"))"
