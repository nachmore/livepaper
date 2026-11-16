#!/bin/bash
# Tests scripts/ci/publish-release.sh against a fake `gh` that answers like GitHub (run by CI; also:
# bash scripts/ci/test-publish-release.sh). The cases are the first nightly (no tag, no release yet)
# and a later one (both exist), each checked by the gh commands the script ran.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/publish-release.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/livepaper-pub.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

# A repository with one commit, and the packaged files for it.
REPO="$TMP/repo"; mkdir -p "$REPO/.github/workflows"
git -C "$REPO" init -q -b main
echo "name: CI" > "$REPO/.github/workflows/ci.yml"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m "First"
SHA="$(git -C "$REPO" rev-parse HEAD)"
DIST="$TMP/dist"; mkdir -p "$DIST/app/LivePaper.app/Contents"
plutil -create xml1 "$DIST/app/LivePaper.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.1.0-nightly "$DIST/app/LivePaper.app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 7 "$DIST/app/LivePaper.app/Contents/Info.plist"
(cd "$DIST/app" && ditto -c -k --keepParent LivePaper.app "$DIST/LivePaper-nightly.zip")
echo dmg > "$DIST/LivePaper-nightly.dmg"
rm -rf "$DIST/app"
(cd "$DIST" && shasum -a 256 LivePaper-nightly.zip LivePaper-nightly.dmg > SHA256SUMS)

# The fake: GitHub's answers depend on whether the nightly exists ($FAKE/exists). Like the real gh,
# a failed `gh api` prints GitHub's error body on stdout and exits 1.
FAKE="$TMP/fake"; mkdir -p "$FAKE/bin"
export FAKE SHA   # read by the fake
cat > "$FAKE/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$FAKE/log"
exists() { [ -e "$FAKE/exists" ]; }
case "$*" in
  "api repos/o/r/git/ref/heads/main"*) echo "$SHA commit" ;;
  "api repos/o/r/git/ref/tags/nightly"*)
    if exists; then echo "$SHA commit"; else
      echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api -X DELETE repos/o/r/git/refs/tags/nightly"*)
    if exists; then rm -f "$FAKE/exists"; else
      echo '{"message":"Reference does not exist","status":"422"}'; echo "gh: Reference does not exist (HTTP 422)" >&2; exit 1; fi ;;
  "release view nightly"*)
    if exists; then echo published; else echo "release not found" >&2; exit 1; fi ;;
  "release delete nightly"*) rm -f "$FAKE/exists" ;;
  "release create nightly"*) touch "$FAKE/exists" ;;
  *) echo "unexpected: gh $*" >&2; exit 3 ;;
esac
GH
chmod +x "$FAKE/bin/gh"

# run <name> <nightly exists before: 0|1> <want in the gh log>… [!<must not be in it>]
run() {
  local name="$1" before="$2"; shift 2
  rm -f "$FAKE/log" "$FAKE/exists"; touch "$FAKE/log"
  [ "$before" = 1 ] && touch "$FAKE/exists"
  local rc=0 out
  out="$(cd "$REPO" && PATH="$FAKE/bin:$PATH" GH_TOKEN=x CHANNEL=nightly VERSION=0.1.0-nightly TAG=nightly \
    ASSET_BASE=LivePaper-nightly BUILD_NUMBER=7 GITHUB_SHA="$SHA" GITHUB_REPOSITORY=o/r SIGNING=adhoc \
    "$BASH" "$SUT" "$DIST" 2>&1)" || rc=$?
  local problems=""
  [ "$rc" = 0 ] || problems="$problems exit $rc;"
  local want
  for want in "$@"; do
    case "$want" in
      !*) ! grep -qF -- "${want#!}" "$FAKE/log" || problems="$problems ran '${want#!}';" ;;
      *) grep -qF -- "$want" "$FAKE/log" || problems="$problems didn't run '$want';" ;;
    esac
  done
  [ -e "$FAKE/exists" ] || problems="$problems no nightly afterwards;"
  if [ -z "$problems" ]; then PASS=$((PASS + 1)); echo "✓ $name"
  else FAIL=$((FAIL + 1)); echo "✗ $name:$problems"
    while IFS= read -r line; do echo "    $line"; done <<< "$out"; sed 's/^/    log: /' "$FAKE/log"; fi
}

run "first nightly: creates it, deletes nothing" 0 "gh release create nightly" "!DELETE" "!release delete"
run "later nightly: replaces the release and its tag" 1 "gh release delete nightly --cleanup-tag --yes" "gh release create nightly"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
