#!/bin/bash
# Tests scripts/ci/version-from-ref.sh (run by CI; also: bash scripts/ci/test-version-from-ref.sh).
# Runs the script with the bash this file runs under — /bin/bash on macOS is 3.2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/version-from-ref.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/livepaper-vfr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

# expect <name> <VERSION file contents> <ref> <exit status> [key=value …] [stderr~TEXT]
expect() {
  local name="$1" version="$2" ref="$3" status="$4"; shift 4
  printf '%s\n' "$version" > "$TMP/VERSION"
  local out err rc=0
  out="$("$BASH" "$SUT" --version-file "$TMP/VERSION" "$ref" 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
  local problems=""
  [ "$rc" = "$status" ] || problems="$problems exit $rc (want $status);"
  local want
  for want in "$@"; do
    case "$want" in
      stderr~*) case "$err" in *"${want#stderr~}"*) ;; *) problems="$problems stderr lacks '${want#stderr~}';" ;; esac ;;
      *) printf '%s\n' "$out" | grep -qxF -- "$want" || problems="$problems missing '$want';" ;;
    esac
  done
  if [ "$status" = 0 ]; then
    # Exactly the documented keys, each once, nothing else on stdout.
    local keys
    keys="$(printf '%s\n' "$out" | sed 's/=.*//' | tr '\n' ' ')"
    [ "$keys" = "channel version base_version tag asset_base prerelease make_latest " ] || problems="$problems keys: $keys;"
  else
    [ -z "$out" ] || problems="$problems printed outputs on failure;"
  fi
  if [ -z "$problems" ]; then PASS=$((PASS + 1)); echo "✓ $name"
  else FAIL=$((FAIL + 1)); echo "✗ $name:$problems"; echo "    stdout: $(printf '%s' "$out" | tr '\n' ' ')"; echo "    stderr: $err"; fi
}

expect "main → nightly" "0.1.0" refs/heads/main 0 \
  channel=nightly version=0.1.0-nightly base_version=0.1.0 tag=nightly asset_base=LivePaper-nightly \
  prerelease=true make_latest=false
expect "VERSION whitespace is ignored" "  0.1.0  " refs/heads/main 0 version=0.1.0-nightly
expect "beta tag" "0.1.0" refs/tags/v0.1.0-beta.2 0 \
  channel=beta version=0.1.0-beta.2 base_version=0.1.0 tag=v0.1.0-beta.2 asset_base=LivePaper-0.1.0-beta.2 \
  prerelease=true make_latest=false
expect "beta 10" "1.20.3" refs/tags/v1.20.3-beta.10 0 version=1.20.3-beta.10 tag=v1.20.3-beta.10
expect "stable tag" "0.1.0" refs/tags/v0.1.0 0 \
  channel=stable version=0.1.0 base_version=0.1.0 tag=v0.1.0 asset_base=LivePaper-0.1.0 \
  prerelease=false make_latest=true
expect "feature branch → ci" "0.1.0" refs/heads/feat1/ci 0 \
  channel=ci version=0.1.0 tag= asset_base=LivePaper-0.1.0-ci prerelease=false make_latest=false
expect "pull request → ci" "0.1.0" refs/pull/12/merge 0 channel=ci version=0.1.0
expect "ci accepts a suffixed VERSION" "0.1.0-dev" refs/heads/topic 0 channel=ci version=0.1.0-dev

expect "stable tag ≠ VERSION" "0.1.0" refs/tags/v0.2.0 1 "stderr~tag v0.2.0 is version 0.2.0 but VERSION at this commit says 0.1.0"
expect "beta tag ≠ VERSION" "0.1.0" refs/tags/v0.1.1-beta.1 1 "stderr~VERSION at this commit says 0.1.0"
expect "beta.0" "0.1.0" refs/tags/v0.1.0-beta.0 1 "stderr~not a release tag"
expect "beta leading zero" "0.1.0" refs/tags/v0.1.0-beta.01 1 "stderr~not a release tag"
expect "beta without number" "0.1.0" refs/tags/v0.1.0-beta 1 "stderr~not a release tag"
expect "rc tag" "0.1.0" refs/tags/v0.1.0-rc.1 1 "stderr~not a release tag"
expect "two-part tag" "0.1.0" refs/tags/v0.1 1 "stderr~not a release tag"
expect "tag without v" "0.1.0" refs/tags/0.1.0 1 "stderr~not a release tag"
expect "leading zero" "0.1.0" refs/tags/v0.01.0 1 "stderr~not a release tag"
expect "nightly tag ref" "0.1.0" refs/tags/nightly 1 "stderr~not a release tag"
expect "release needs plain VERSION" "0.1.0-dev" refs/tags/v0.1.0 1 "stderr~VERSION must be a plain X.Y.Z"
expect "nightly needs plain VERSION" "0.1" refs/heads/main 1 "stderr~VERSION must be a plain X.Y.Z"
expect "ci rejects a broken VERSION" "one" refs/heads/topic 1 "stderr~VERSION must look like 1.2.3"
expect "unknown ref kind" "0.1.0" refs/notes/commits 1 "stderr~unsupported ref"
expect "bare branch name" "0.1.0" main 1 "stderr~unsupported ref"

# Usage errors.
rc=0; "$BASH" "$SUT" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then PASS=$((PASS + 1)); echo "✓ no ref → usage"; else FAIL=$((FAIL + 1)); echo "✗ no ref → exit $rc (want 2)"; fi
rc=0; "$BASH" "$SUT" --version-file "$TMP/missing" refs/heads/main >/dev/null 2>&1 || rc=$?
if [ "$rc" = 1 ]; then PASS=$((PASS + 1)); echo "✓ missing VERSION file"; else FAIL=$((FAIL + 1)); echo "✗ missing VERSION file → exit $rc (want 1)"; fi
# The repository's own VERSION is one CI can build (a branch may carry a suffixed one; main's
# nightly needs a plain X.Y.Z, which the workflow's version step checks on main itself).
rc=0; err="$("$BASH" "$SUT" refs/heads/ci-self-check 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 0 ]; then PASS=$((PASS + 1)); echo "✓ this checkout's VERSION"; else FAIL=$((FAIL + 1)); echo "✗ this checkout's VERSION → exit $rc: $err"; fi

echo "$PASS passed, $FAIL failed (bash $BASH_VERSION)"
[ "$FAIL" = 0 ]
