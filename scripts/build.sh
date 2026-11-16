#!/bin/bash
# Builds build/LivePaper.app (ARCHITECTURE §2): the app, its helpers, the screen saver template,
# the runtime and the built-in scenes, ad-hoc signed inside-out and verified.
#
#   scripts/build.sh [--debug] [--out DIR]
#
#   (default)   universal (arm64 + x86_64) release build, stripped; dSYMs go to DIR/dSYMs/
#   --debug     fast incremental development build: this Mac's architecture, debug configuration;
#               the saver and the icon are rebuilt only when their sources changed
#   --out DIR   output directory (default: build/) → DIR/LivePaper.app
#
# Environment:
#   LIVEPAPER_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). With a real identity, e.g.
#                            "Developer ID Application: …", the hardened runtime and a secure
#                            timestamp are added (notarization is a separate step).
#   LIVEPAPER_BUILD          CFBundleVersion (default: the number of commits on HEAD)
#   LIVEPAPER_VERSION        CFBundleShortVersionString (default: the VERSION file). Must be VERSION
#                            itself or VERSION plus a suffix, e.g. 0.1.0-beta.2 (release automation).
#   LIVEPAPER_ARCHS          release architectures (default "arm64 x86_64")
#   LIVEPAPER_PER_ARCH=1     build each architecture separately and lipo them (automatic when the
#                            toolchain can't build several architectures at once)
#
# Version: CFBundleShortVersionString comes from the VERSION file at the repository root (or
# LIVEPAPER_VERSION); CFBundleVersion is always numeric.
# Nothing here launches a GUI process: SwiftPM, swiftc, lipo, strip, iconutil and codesign only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
DEBUG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) DEBUG=1; shift ;;
    --out) OUT="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Command Line Tools are enough. If the selected developer dir is an Xcode whose licence hasn't
# been accepted (the toolchain refuses to run), fall back to the CLT — same rule as build-saver.sh.
if ! xcrun swift --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "✗ VERSION must look like 1.2.3 (got '$VERSION')" >&2; exit 1
fi
# Release automation (scripts/ci/version-from-ref.sh) adds a channel suffix: 0.1.0-beta.2.
if [ -n "${LIVEPAPER_VERSION:-}" ] && [ "$LIVEPAPER_VERSION" != "$VERSION" ]; then
  suffix="${LIVEPAPER_VERSION#"$VERSION"-}"
  if [ "$suffix" = "$LIVEPAPER_VERSION" ] || ! [[ "$suffix" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "✗ LIVEPAPER_VERSION must be $VERSION or $VERSION-<suffix> (got '$LIVEPAPER_VERSION')" >&2; exit 1
  fi
  VERSION="$LIVEPAPER_VERSION"
fi
# CFBundleVersion must be numeric and must grow: at launch the app replaces the installed saver
# only with a higher build (InstallService.updateSaver); an explicit install replaces any other.
BUILD="${LIVEPAPER_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then echo "✗ the build number must be numeric (got '$BUILD')" >&2; exit 1; fi
if [ -z "${LIVEPAPER_BUILD:-}" ] && [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  echo "! shallow clone: build $BUILD counts only the fetched commits (fetch the full history or set LIVEPAPER_BUILD)" >&2
fi
IDENTITY="${LIVEPAPER_SIGN_IDENTITY:--}"
if [ "$DEBUG" = 1 ]; then ARCHS=("$(uname -m)"); else read -r -a ARCHS <<< "${LIVEPAPER_ARCHS:-arm64 x86_64}"; fi

APP="$OUT/LivePaper.app"
CACHE="$OUT/.cache"
STAGE="$OUT/.LivePaper.app.staging"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/livepaper-build.XXXXXX")"
trap 'rm -rf "$WORK" "$STAGE"' EXIT
mkdir -p "$OUT" "$CACHE"

PRODUCTS=(LivePaperApp LivePaperHelper livepaper LivePaperRenderd)
step() { echo "▸ $*"; }

# MARK: Swift products --------------------------------------------------------------------------

SWIFT_LOG="$CACHE/swift-build.log"

# `swift build "$@"`, output kept in $SWIFT_LOG (compiler warnings are noisy); the tail is shown on
# failure unless $QUIET_FAILURE is set.
swiftpm() {
  if swift build --package-path "$ROOT" "$@" >"$SWIFT_LOG" 2>&1; then return 0; fi
  [ -n "${QUIET_FAILURE:-}" ] || { tail -n 40 "$SWIFT_LOG" >&2; echo "✗ swift build $* failed (full log: $SWIFT_LOG)" >&2; }
  return 1
}

# Prints the directory holding universal (or, in debug, native) copies of every product.
build_swift() {
  local arch_flags=()
  for a in "${ARCHS[@]}"; do arch_flags+=(--arch "$a"); done
  if [ "$DEBUG" = 1 ]; then
    swiftpm || return 1
    swift build --package-path "$ROOT" --show-bin-path
    return
  fi
  # SwiftPM in Xcode 26+ builds all architectures in one go.
  if [ "${LIVEPAPER_PER_ARCH:-0}" != 1 ] && QUIET_FAILURE=1 swiftpm -c release "${arch_flags[@]}"; then
    swift build --package-path "$ROOT" -c release "${arch_flags[@]}" --show-bin-path
    return
  fi
  # Older SwiftPM (Command Line Tools only) can't: build each architecture separately and lipo.
  if [ "${LIVEPAPER_PER_ARCH:-0}" != 1 ]; then
    echo "  universal build failed ($(grep -m1 -i error "$SWIFT_LOG" || echo "see $SWIFT_LOG")); building per architecture" >&2
  fi
  local fat="$WORK/universal" bins=()
  mkdir -p "$fat"
  for a in "${ARCHS[@]}"; do
    swiftpm -c release --arch "$a" --scratch-path "$ROOT/.build/arch-$a" || return 1
    bins+=("$(swift build --package-path "$ROOT" -c release --arch "$a" --scratch-path "$ROOT/.build/arch-$a" --show-bin-path)")
  done
  for p in "${PRODUCTS[@]}"; do
    local slices=()
    for b in "${bins[@]}"; do slices+=("$b/$p"); done
    lipo -create "${slices[@]}" -output "$fat/$p"
    [ -d "${bins[0]}/$p.dSYM" ] && cp -R "${bins[0]}/$p.dSYM" "$fat/"   # first architecture's symbols only
  done
  echo "$fat"
}

step "Swift products (${ARCHS[*]}, $([ "$DEBUG" = 1 ] && echo debug || echo release))"
BIN="$(build_swift)" || exit 1
for p in "${PRODUCTS[@]}"; do
  [ -x "$BIN/$p" ] || { echo "✗ $BIN/$p is missing" >&2; exit 1; }
  for a in "${ARCHS[@]}"; do
    lipo "$BIN/$p" -verify_arch "$a" || { echo "✗ $p lacks $a (has: $(lipo -archs "$BIN/$p"))" >&2; exit 1; }
  done
done
# The CLI runs inside AI agents' shells and must never register with the window server.
if otool -L "$BIN/livepaper" | grep -E '/(AppKit|WebKit|SwiftUI)\.framework/' >/dev/null; then
  echo "✗ livepaper links AppKit/WebKit/SwiftUI; it must stay Foundation-only (ARCHITECTURE §9)" >&2; exit 1
fi

# MARK: Saver and icon (cached by source date) --------------------------------------------------

# True when $1 is missing or older than any of the remaining paths (files or directories).
stale() {
  local target="$1"; shift
  [ -e "$target" ] || return 0
  [ -n "$(find "$@" -newer "$target" -print -quit 2>/dev/null)" ]
}

SAVER_KIND="$([ "$DEBUG" = 1 ] && echo debug || echo release)"
SAVER_DIR="$CACHE/saver-$SAVER_KIND"
SAVER_STAMP="$SAVER_DIR/.built-$VERSION-$BUILD-$(IFS=-; echo "${ARCHS[*]}")"
if stale "$SAVER_STAMP" "$ROOT/Saver" "$ROOT/Sources/LivePaperCore/Playlist/PlaylistModel.swift" \
         "$ROOT/Sources/LivePaperCore/Playlist/DisplayLayout.swift" "$ROOT/Sources/LivePaperCore/Render/SceneNavigationGate.swift" \
         "$ROOT/scripts/build-saver.sh"; then
  rm -rf "$SAVER_DIR"; mkdir -p "$SAVER_DIR"
  saver_flags=(--out "$SAVER_DIR")
  [ "$DEBUG" = 1 ] && saver_flags+=(--debug)
  LIVEPAPER_VERSION="$VERSION" LIVEPAPER_BUILD="$BUILD" LIVEPAPER_ARCHS="${ARCHS[*]}" \
    "$ROOT/scripts/build-saver.sh" "${saver_flags[@]}"
  touch "$SAVER_STAMP"
else
  step "LivePaper.saver (up to date)"
fi

ICON="$CACHE/icon/AppIcon.icns"
if stale "$ICON" "$ROOT/App/Icon"; then
  step "AppIcon.icns"
  "$ROOT/App/Icon/make-icon.sh" "$CACHE/icon" >/dev/null
else
  step "AppIcon.icns (up to date)"
fi

# MARK: Assemble ---------------------------------------------------------------------------------

step "LivePaper.app $VERSION (build $BUILD)"
rm -rf "$STAGE"
C="$STAGE/Contents"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources" "$C/Library/LaunchAgents"

# The app's executable is "LivePaper" (the SwiftPM product is LivePaperApp so it doesn't clash with
# the `livepaper` CLI on case-insensitive volumes).
cp "$BIN/LivePaperApp" "$C/MacOS/LivePaper"
for p in LivePaperHelper livepaper LivePaperRenderd; do cp "$BIN/$p" "$C/Helpers/$p"; done
if [ "$DEBUG" = 0 ]; then
  # dSYMs first (they were made from the unstripped binaries), then strip like Xcode does for
  # Swift (keep dynamically referenced symbols; drop debug, Swift and local symbols).
  rm -rf "$OUT/dSYMs"; mkdir -p "$OUT/dSYMs"
  for p in "${PRODUCTS[@]}"; do [ -d "$BIN/$p.dSYM" ] && cp -R "$BIN/$p.dSYM" "$OUT/dSYMs/"; done
  strip -rSTx "$C/MacOS/LivePaper" "$C/Helpers/LivePaperHelper" "$C/Helpers/livepaper" "$C/Helpers/LivePaperRenderd"
fi

PLIST="$C/Info.plist"
cp "$ROOT/App/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LivePaper" -c "Set :CFBundleIconFile AppIcon" \
  -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
printf 'APPL????' > "$C/PkgInfo"
cp "$ROOT/App/LaunchAgents/com.nachmore.livepaper.helper.plist" "$C/Library/LaunchAgents/"
plutil -lint -s "$PLIST" "$C/Library/LaunchAgents/com.nachmore.livepaper.helper.plist"

# Runtime/ and Scenes/ without Finder litter or `livepaper check` output.
copy_tree() {
  cp -R "$1" "$2"
  find "$2" \( -name .DS_Store -o -name .check \) -prune -exec rm -rf {} +
}
copy_tree "$ROOT/Runtime" "$C/Resources/Runtime"
if [ -d "$ROOT/Scenes" ]; then copy_tree "$ROOT/Scenes" "$C/Resources/Scenes"; else mkdir "$C/Resources/Scenes"; fi
cp -R "$SAVER_DIR/LivePaper.saver" "$C/Resources/LivePaper.saver"
cp "$ICON" "$C/Resources/AppIcon.icns"
# codesign refuses bundles with resource forks / Finder info ("detritus").
xattr -cr "$STAGE"

# MARK: Sign inside-out --------------------------------------------------------------------------

step "codesign ($([ "$IDENTITY" = - ] && echo ad-hoc || echo "$IDENTITY"))"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" = - ]; then SIGN_FLAGS+=(--timestamp=none); else SIGN_FLAGS+=(--options runtime --timestamp); fi
# The linker already ad-hoc signs every Mach-O, so "replacing existing signature" is expected noise.
sign() {
  local out
  out="$(codesign "${SIGN_FLAGS[@]}" "$@" 2>&1)" || { echo "$out" >&2; echo "✗ codesign failed: ${*: -1}" >&2; exit 1; }
  echo "$out" | grep -v 'replacing existing signature' >&2 || true
}
# Nested code first, each explicitly with a stable identifier (no --deep: it would re-sign the
# saver with the app's settings and hide mistakes), then the app, whose seal covers them.
sign --identifier com.nachmore.livepaper.helper "$C/Helpers/LivePaperHelper"
sign --identifier com.nachmore.livepaper.cli "$C/Helpers/livepaper"
sign --identifier com.nachmore.livepaper.renderd "$C/Helpers/LivePaperRenderd"
sign "$C/Resources/LivePaper.saver"
sign "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Swap the finished bundle in (a half-built LivePaper.app is never left behind).
rm -rf "$APP"
mv "$STAGE" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# MARK: Summary -----------------------------------------------------------------------------------

size() { du -sh "$1" | cut -f1 | tr -d ' '; }
echo "✓ $APP"
echo "  version $VERSION (build $BUILD) · $(lipo -archs "$APP/Contents/MacOS/LivePaper") · $(size "$APP") total"
printf '  %-38s %s\n' \
  "Contents/MacOS/LivePaper" "$(size "$APP/Contents/MacOS/LivePaper")" \
  "Contents/Helpers/LivePaperHelper" "$(size "$APP/Contents/Helpers/LivePaperHelper")" \
  "Contents/Helpers/livepaper" "$(size "$APP/Contents/Helpers/livepaper")" \
  "Contents/Helpers/LivePaperRenderd" "$(size "$APP/Contents/Helpers/LivePaperRenderd")" \
  "Contents/Resources/LivePaper.saver" "$(size "$APP/Contents/Resources/LivePaper.saver")" \
  "Contents/Resources/Runtime" "$(size "$APP/Contents/Resources/Runtime")" \
  "Contents/Resources/Scenes ($(find "$APP/Contents/Resources/Scenes" -maxdepth 1 -name '*.lpscene' | wc -l | tr -d ' ') scenes)" \
    "$(size "$APP/Contents/Resources/Scenes")" \
  "Contents/Resources/AppIcon.icns" "$(size "$APP/Contents/Resources/AppIcon.icns")"
[ "$DEBUG" = 0 ] && echo "  dSYMs in $OUT/dSYMs"
echo "Install it with scripts/dev-install.sh"
