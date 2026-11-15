#!/bin/bash
# Maps a git ref to LivePaper's release channel and version (docs/RELEASING.md).
#
#   scripts/ci/version-from-ref.sh [--version-file FILE] <ref>
#
#   refs/heads/main            → nightly: version X.Y.Z-nightly, tag "nightly" (rolling pre-release)
#   refs/tags/vX.Y.Z-beta.N    → beta:    version X.Y.Z-beta.N (N ≥ 1), pre-release
#   refs/tags/vX.Y.Z           → stable:  version X.Y.Z, the latest release
#   any other branch / PR ref  → ci:      version from VERSION, nothing is published
#
# X.Y.Z must equal the VERSION file (default: the repository's) — a tag that disagrees fails with
# exit 1, as does any other tag. Prints key=value lines for $GITHUB_OUTPUT on stdout:
#   channel, version (CFBundleShortVersionString → LIVEPAPER_VERSION), base_version (VERSION),
#   tag (empty for ci), asset_base (file name stem of the zip/dmg), prerelease, make_latest
# and a one-line summary on stderr. Bash 3.2 compatible; no network, no git needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version-file) [ $# -ge 2 ] || { echo "--version-file needs a path" >&2; exit 2; }; VERSION_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) [ -z "$REF" ] || { echo "one ref only (got '$REF' and '$1')" >&2; exit 2; }; REF="$1"; shift ;;
  esac
done
[ -n "$REF" ] || { echo "usage: $0 [--version-file FILE] <ref>" >&2; exit 2; }
fail() { echo "✗ $*" >&2; exit 1; }

[ -r "$VERSION_FILE" ] || fail "can't read $VERSION_FILE"
BASE="$(tr -d '[:space:]' < "$VERSION_FILE")"
NUM='(0|[1-9][0-9]*)'
RELEASE_RE="^$NUM\\.$NUM\\.$NUM\$"
TAG_RE="^v($NUM\\.$NUM\\.$NUM)(-beta\\.([1-9][0-9]*))?\$"
ANY_RE='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'   # what scripts/build.sh accepts

# A release needs a plain X.Y.Z VERSION; CI builds accept anything build.sh does.
need_release_version() {
  [[ "$BASE" =~ $RELEASE_RE ]] || fail "VERSION must be a plain X.Y.Z for a $1 (got '$BASE')"
}

case "$REF" in
  refs/heads/main)
    need_release_version "nightly build"
    channel=nightly; version="$BASE-nightly"; tag=nightly; asset_base=LivePaper-nightly
    prerelease=true; make_latest=false ;;
  refs/tags/*)
    name="${REF#refs/tags/}"
    [[ "$name" =~ $TAG_RE ]] || fail "'$name' is not a release tag: use vX.Y.Z or vX.Y.Z-beta.N (N ≥ 1, no leading zeros)"
    tagged="${BASH_REMATCH[1]}"
    beta="${BASH_REMATCH[6]:-}"
    need_release_version "release"
    [ "$tagged" = "$BASE" ] || fail "tag $name is version $tagged but VERSION at this commit says $BASE — bump VERSION first (scripts/release.sh) or tag the right commit"
    tag="$name"
    if [ -n "$beta" ]; then
      channel=beta; version="$BASE-beta.$beta"; prerelease=true; make_latest=false
    else
      channel=stable; version="$BASE"; prerelease=false; make_latest=true
    fi
    asset_base="LivePaper-$version" ;;
  refs/heads/*|refs/pull/*)
    [[ "$BASE" =~ $ANY_RE ]] || fail "VERSION must look like 1.2.3 (got '$BASE')"
    channel=ci; version="$BASE"; tag=""; asset_base="LivePaper-$BASE-ci"; prerelease=false; make_latest=false ;;
  *) fail "unsupported ref '$REF' (expected refs/heads/…, refs/pull/… or refs/tags/…)" ;;
esac

printf '%s=%s\n' channel "$channel" version "$version" base_version "$BASE" tag "$tag" \
  asset_base "$asset_base" prerelease "$prerelease" make_latest "$make_latest"
echo "$REF → $channel ${version}${tag:+ (tag $tag)}" >&2
