#!/bin/bash
# Developer ID signing and notarization for release builds (docs/RELEASING.md).
#
#   scripts/ci/signing.sh mode            prints mode=developer-id or mode=adhoc (for $GITHUB_OUTPUT)
#   scripts/ci/signing.sh import          temporary keychain with the Developer ID certificate
#   scripts/ci/signing.sh notarize FILE   submits FILE (.zip or .dmg), waits, fails unless Accepted
#   scripts/ci/signing.sh staple PATH     staples the ticket to an .app or .dmg and validates it
#   scripts/ci/signing.sh cleanup         deletes the keychain and the API key (safe to repeat)
#
# Environment (GitHub secrets; never printed):
#   MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, MACOS_SIGN_IDENTITY   — import (and mode)
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_P8_BASE64             — notarize (and mode)
# All six set → developer-id; none → adhoc; anything in between is an error, so a half-configured
# repository fails loudly instead of quietly publishing an unsigned build.
# State (the keychain, the key file) lives in $RUNNER_TEMP (else $TMPDIR)/livepaper-signing.
# Nothing here launches a GUI process: security, codesign, xcrun notarytool/stapler and spctl only.
set -euo pipefail

CERT_VARS=(MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD MACOS_SIGN_IDENTITY)
NOTARY_VARS=(NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_P8_BASE64)
STATE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
STATE="${STATE%/}/livepaper-signing"
KEYCHAIN="$STATE/signing.keychain-db"

fail() { echo "✗ $*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=Signing::$*" >&2; exit 1; }
step() { echo "▸ $*"; }
mask() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$1"; return 0; }
require() {
  local v missing=()
  for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
  [ "${#missing[@]}" = 0 ] || fail "missing secrets: ${missing[*]}"
}
# Writes base64 secret $1 (variable name) decoded to file $2, readable by this user only.
decode_to() {
  ( umask 077; printf '%s' "${!1}" | tr -d ' \r\n' | base64 -D > "$2" ) || fail "$1 is not valid base64"
  [ -s "$2" ] || fail "$1 decodes to nothing"
}

cmd_mode() {
  local v set=0 total=0
  for v in "${CERT_VARS[@]}" "${NOTARY_VARS[@]}"; do
    total=$((total + 1)); [ -n "${!v:-}" ] && set=$((set + 1))
  done
  if [ "$set" = 0 ]; then
    echo "mode=adhoc"
    echo "  signing: ad-hoc (no Developer ID secrets configured)" >&2
  elif [ "$set" = "$total" ]; then
    echo "mode=developer-id"
    echo "  signing: Developer ID + notarization" >&2
  else
    require "${CERT_VARS[@]}" "${NOTARY_VARS[@]}"
  fi
}

cmd_import() {
  require "${CERT_VARS[@]}"
  command -v security >/dev/null || fail "security(1) not found (macOS only)"
  mkdir -p "$STATE"; chmod 700 "$STATE"
  [ ! -e "$KEYCHAIN" ] || cmd_cleanup
  local password p12="$STATE/cert.p12" line
  password="$(openssl rand -base64 32)"; mask "$password"
  decode_to MACOS_CERT_P12_BASE64 "$p12"

  step "temporary keychain"
  # Remember the search list so cleanup restores it exactly.
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$STATE/search-list"
  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"   # locks after 6 h (a job's maximum) or on sleep
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
    || { rm -f "$p12"; fail "couldn't import MACOS_CERT_P12_BASE64 (wrong MACOS_CERT_PASSWORD, or not a .p12 with the private key?)"; }
  rm -f "$p12"
  # Let codesign use the key without a UI prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  local list=()
  while IFS= read -r line; do [ -n "$line" ] && list+=("$line"); done < "$STATE/search-list"
  security list-keychains -d user -s "$KEYCHAIN" ${list[@]+"${list[@]}"}

  # The identity must be usable for code signing (valid, with its private key, chain trusted).
  # (MACOS_SIGN_IDENTITY may be the certificate's name or its SHA-1 hash, like codesign accepts.)
  if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF -e "\"$MACOS_SIGN_IDENTITY\"" -e ") $MACOS_SIGN_IDENTITY "; then
    echo "  identities in the imported certificate:" >&2
    security find-identity -v -p codesigning "$KEYCHAIN" | sed 's/^/    /' >&2
    fail "MACOS_SIGN_IDENTITY doesn't match a valid code-signing identity in MACOS_CERT_P12_BASE64"
  fi
  case "$MACOS_SIGN_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "! MACOS_SIGN_IDENTITY isn't a 'Developer ID Application' identity; notarization will likely reject it" >&2 ;;
  esac
  step "signing identity ready"
}

# The App Store Connect API key, decoded once into the state directory → $KEY_FILE.
KEY_FILE=""
api_key() {
  require "${NOTARY_VARS[@]}"
  mkdir -p "$STATE"; chmod 700 "$STATE"
  KEY_FILE="$STATE/AuthKey_${NOTARY_KEY_ID//[^A-Za-z0-9]/}.p8"
  [ -s "$KEY_FILE" ] || decode_to NOTARY_KEY_P8_BASE64 "$KEY_FILE"
  grep -q "BEGIN PRIVATE KEY" "$KEY_FILE" || fail "NOTARY_KEY_P8_BASE64 isn't a base64-encoded .p8 private key"
}

cmd_notarize() {
  [ $# = 1 ] && [ -f "$1" ] || fail "notarize needs an existing .zip or .dmg (got '${1:-}')"
  local file="$1" out id status rc=0
  api_key
  step "notarizing $(basename "$file") (this usually takes a few minutes)"
  out="$STATE/notary-$(basename "$file").json"
  # --wait polls until Apple has an answer; --timeout bounds it (the job has its own timeout too).
  xcrun notarytool submit "$file" --key "$KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 45m --output-format json > "$out" || rc=$?
  id="$(plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  echo "  submission ${id:-?}: ${status:-unknown} (notarytool exit $rc)"
  if [ "$status" != Accepted ]; then
    cat "$out" >&2 || true
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --key "$KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
    fi
    fail "notarization of $(basename "$file") ended with status '${status:-unknown}' (log above)"
  fi
}

cmd_staple() {
  [ $# = 1 ] && [ -e "$1" ] || fail "staple needs an .app or .dmg (got '${1:-}')"
  local target="$1"
  step "stapling $(basename "$target")"
  local attempt
  for attempt in 1 2 3; do   # the ticket can take a moment to propagate after Accepted
    if xcrun stapler staple -q "$target"; then break; fi
    [ "$attempt" = 3 ] && fail "stapler couldn't staple $(basename "$target")"
    sleep $((attempt * 15))
  done
  xcrun stapler validate -q "$target" || fail "stapled ticket on $(basename "$target") doesn't validate"
  case "$target" in
    *.app) spctl --assess --type execute -v "$target" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature -v "$target" ;;
  esac
}

cmd_cleanup() {
  if [ -e "$KEYCHAIN" ]; then
    if [ -f "$STATE/search-list" ]; then
      local list=() line
      while IFS= read -r line; do [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && list+=("$line"); done < "$STATE/search-list"
      security list-keychains -d user -s ${list[@]+"${list[@]}"} || true
    fi
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
    echo "▸ temporary keychain deleted"
  fi
  rm -rf "$STATE"
}

case "${1:-}" in
  mode) shift; cmd_mode "$@" ;;
  import) shift; cmd_import "$@" ;;
  notarize) shift; cmd_notarize "$@" ;;
  staple) shift; cmd_staple "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
