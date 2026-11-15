#!/bin/bash
# Packages a built LivePaper.app for distribution (docs/RELEASING.md) and verifies the result.
#
#   scripts/ci/package.sh <LivePaper.app> <out-dir> <name>
#       → <out-dir>/<name>.zip   the app, zipped with ditto (keeps signatures and symlinks)
#         <out-dir>/<name>.dmg   drag-to-install disk image: LivePaper.app + an /Applications link
#         <out-dir>/SHA256SUMS   `shasum -a 256` of both (verify with `shasum -a 256 -c SHA256SUMS`)
#   scripts/ci/package.sh --checksums <out-dir>
#       → rewrites <out-dir>/SHA256SUMS for every .zip and .dmg there (after stapling the dmg)
#
# Environment: LIVEPAPER_DMG_SIGN_IDENTITY — codesign the disk image with this identity (Developer
# ID releases; the app inside is signed by scripts/build.sh). Ad-hoc builds leave the image unsigned.
#
# The image is checked by attaching it with -nobrowse -noautoopen (no Finder window, nothing is
# opened) and detaching it again. Nothing here launches a GUI process.
set -euo pipefail

usage() { sed -n '2,15p' "$0" >&2; exit 2; }
fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

checksums() {
  local dir="$1" files=() f
  for f in "$dir"/*.zip "$dir"/*.dmg; do [ -f "$f" ] && files+=("$(basename "$f")"); done
  [ "${#files[@]}" -gt 0 ] || fail "no .zip or .dmg in $dir"
  (cd "$dir" && shasum -a 256 -- "${files[@]}" > SHA256SUMS && shasum -a 256 -c --strict SHA256SUMS >/dev/null)
  step "SHA256SUMS"
  sed 's/^/  /' "$dir/SHA256SUMS"
}

if [ "${1:-}" = --checksums ]; then
  [ $# -eq 2 ] && [ -d "$2" ] || usage
  checksums "$2"
  exit 0
fi
[ $# -eq 3 ] || usage
case "$1" in -h|--help) usage ;; esac
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
NAME="$3"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "unsafe package name '$NAME'"
[ "$(basename "$APP")" = LivePaper.app ] || fail "expected a LivePaper.app (got $APP)"
[ -f "$APP/Contents/Info.plist" ] || fail "$APP is not an app bundle — run scripts/build.sh first"
codesign --verify --deep --strict "$APP" || fail "$APP has an invalid signature"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
SHORT="$(plist "$APP" CFBundleShortVersionString)"
BUILD="$(plist "$APP" CFBundleVersion)"
ZIP="$OUT/$NAME.zip"
DMG="$OUT/$NAME.dmg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/livepaper-package.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
rm -f "$ZIP" "$DMG" "$OUT/SHA256SUMS"

# Same app, same version, valid signature: what a user gets out of the zip or the image.
check_copy() {
  local copy="$1" what="$2"
  [ -d "$copy" ] || fail "$what: LivePaper.app is missing"
  codesign --verify --deep --strict "$copy" || fail "$what: the signature doesn't verify"
  [ "$(plist "$copy" CFBundleShortVersionString)" = "$SHORT" ] && [ "$(plist "$copy" CFBundleVersion)" = "$BUILD" ] \
    || fail "$what: version differs from $APP"
}

step "$NAME.zip (LivePaper $SHORT, build $BUILD)"
ditto -c -k --keepParent "$APP" "$ZIP"
mkdir "$WORK/unzipped"
ditto -x -k "$ZIP" "$WORK/unzipped"
[ "$(ls "$WORK/unzipped")" = LivePaper.app ] || fail "$ZIP should hold exactly LivePaper.app"
check_copy "$WORK/unzipped/LivePaper.app" "$NAME.zip"

step "$NAME.dmg"
STAGE="$WORK/dmg"
mkdir "$STAGE"
ditto "$APP" "$STAGE/LivePaper.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil occasionally reports "Resource busy" on CI runners; retry a few times.
for attempt in 1 2 3 4; do
  if hdiutil create -quiet -volname LivePaper -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"; then break; fi
  [ "$attempt" = 4 ] && fail "hdiutil create failed"
  echo "  hdiutil create failed (attempt $attempt); retrying" >&2
  sleep $((attempt * 5))
done
if [ -n "${LIVEPAPER_DMG_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$LIVEPAPER_DMG_SIGN_IDENTITY" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
fi
hdiutil verify -quiet "$DMG"
MOUNT="$WORK/mnt"
mkdir "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || fail "$NAME.dmg: the Applications link is missing"
check_copy "$MOUNT/LivePaper.app" "$NAME.dmg"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

checksums "$OUT"
size() { du -h "$1" | cut -f1 | tr -d ' '; }
echo "✓ $OUT: $NAME.zip $(size "$ZIP") · $NAME.dmg $(size "$DMG") · app $(du -sh "$APP" | cut -f1 | tr -d ' ')"
