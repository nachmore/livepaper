#!/bin/bash
# Installs pinned, checksum-verified shellcheck and actionlint for CI's Linux x86-64 lint job and
# puts them on $GITHUB_PATH. (On a Mac use Homebrew instead: brew install shellcheck actionlint.)
#
#   scripts/ci/install-linters.sh <dir>
#
# To update: change a version below, download the new archive and replace its sha256
# (actionlint publishes actionlint_<version>_checksums.txt with each release).
set -euo pipefail

SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198   # = shellcheck-v0.11.0.linux.x86_64.tar.xz
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8   # = actionlint_1.7.12_linux_amd64.tar.gz

[ $# = 1 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "✗ Linux x86-64 only (got $(uname -s)-$(uname -m))" >&2; exit 1; }
BIN="$(mkdir -p "$1" && cd "$1" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch <url> <sha256> <file>
fetch() {
  curl -fsSL --retry 3 --proto '=https' -o "$TMP/$3" "$1"
  echo "$2  $TMP/$3" | sha256sum -c --quiet - || { echo "✗ checksum mismatch for $1" >&2; exit 1; }
}

fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" \
  "$SHELLCHECK_SHA256" shellcheck.tar.xz
tar -xJf "$TMP/shellcheck.tar.xz" -C "$TMP"
install -m 755 "$TMP/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$BIN/shellcheck"

fetch "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
  "$ACTIONLINT_SHA256" actionlint.tar.gz
tar -xzf "$TMP/actionlint.tar.gz" -C "$TMP" actionlint
install -m 755 "$TMP/actionlint" "$BIN/actionlint"

if [ -n "${GITHUB_PATH:-}" ]; then echo "$BIN" >> "$GITHUB_PATH"; fi
"$BIN/shellcheck" --version | sed -n 's/^version: /✓ shellcheck /p'
echo "✓ actionlint $("$BIN/actionlint" --version | head -n1)"
