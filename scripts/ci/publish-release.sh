#!/bin/bash
# Publishes packaged builds as a GitHub release with the preinstalled `gh` (docs/RELEASING.md).
#
#   scripts/ci/publish-release.sh [--dry-run] <dist-dir>
#
# <dist-dir> holds <asset_base>.zip, <asset_base>.dmg and SHA256SUMS (scripts/ci/package.sh).
# Environment — the outputs of scripts/ci/version-from-ref.sh, plus:
#   CHANNEL, VERSION, TAG, ASSET_BASE   nightly | beta | stable; LivePaper version; tag; file stem
#   BUILD_NUMBER, GITHUB_SHA, GITHUB_REPOSITORY, GITHUB_SERVER_URL (default https://github.com)
#   SIGNING                             developer-id | adhoc (ad-hoc notes explain how to open the app)
#   GH_TOKEN                            a token with contents: write (the workflow's GITHUB_TOKEN)
#
#   nightly  the rolling pre-release "nightly", replaced (release and tag) by one for this commit
#            with notes listing the commits since the previous nightly — never backwards: re-running
#            an older run publishes nothing.
#   beta     a versioned pre-release for tag vX.Y.Z-beta.N (never "latest").
#   stable   the release for tag vX.Y.Z, marked latest.
#   beta and stable notes: an install header, the commits since the previous beta or release (for
#   stable: the previous release), then GitHub's generated notes; the very first one lists the
#   history instead. Re-running the job replaces the assets of an existing release (notes stay).
#
# --dry-run prints the gh commands instead of running them and needs no network (NIGHTLY_PREVIOUS
# may name the previous nightly's commit, DRY_RUN_STATE=published pretends the release exists,
# DRY_RUN_MAIN names main's newest commit and DRY_RUN_WORKFLOWS_DIFFER=1 pretends its workflows differ).
# Run from the repository checkout (git history is used).
set -euo pipefail

DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ $# = 1 ] && [ -d "$1" ] || { sed -n '2,25p' "$0" >&2; exit 2; }
DIST="$(cd "$1" && pwd)"

fail() { echo "✗ $*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=Publish::$*" >&2; exit 1; }
step() { echo "▸ $*"; }
notice() { echo "! $*"; [ -z "${GITHUB_ACTIONS:-}" ] || echo "::notice title=Publish::$*"; }
case "${CHANNEL:-}" in nightly|beta|stable) ;; *) fail "nothing to publish for channel '${CHANNEL:-}'" ;; esac
for v in VERSION TAG ASSET_BASE BUILD_NUMBER GITHUB_SHA GITHUB_REPOSITORY SIGNING; do
  [ -n "${!v:-}" ] || fail "$v is not set"
done
[ "$DRY" = 1 ] || [ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is not set"
case "$SIGNING" in developer-id|adhoc) ;; *) fail "SIGNING must be developer-id or adhoc (got '$SIGNING')" ;; esac
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA must be a full commit hash"
[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" ] || fail "the checkout ($(git rev-parse --short HEAD)) isn't GITHUB_SHA"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
REPO_URL="$SERVER/$GITHUB_REPOSITORY"
SHORT="$(git rev-parse --short=7 "$GITHUB_SHA")"

# gh, or in --dry-run the command it would run. Read-only lookups go through `query` instead.
gh_do() {
  if [ "$DRY" = 1 ]; then printf '  [dry-run] gh'; printf ' %q' "$@"; echo; else gh "$@"; fi
}
# A failed lookup prints nothing: `gh api` writes GitHub's error body to stdout (a 404 for a tag
# that doesn't exist yet), which callers would otherwise read as an answer.
query() {
  [ "$DRY" = 1 ] && return 1
  local out
  out="$(gh "$@" 2>/dev/null)" || return 1
  printf '%s\n' "$out"
}

# MARK: Assets ------------------------------------------------------------------------------------

ZIP="$ASSET_BASE.zip"; DMG="$ASSET_BASE.dmg"
ASSETS=("$ZIP" "$DMG" SHA256SUMS)
for f in "${ASSETS[@]}"; do [ -s "$DIST/$f" ] || fail "$DIST/$f is missing"; done
# Exactly these files, unchanged since they were summed.
[ "$(cd "$DIST" && awk '{print $2}' SHA256SUMS | sort | tr '\n' ' ')" = "$(printf '%s\n' "$ZIP" "$DMG" | sort | tr '\n' ' ')" ] \
  || fail "SHA256SUMS should list exactly $ZIP and $DMG"
(cd "$DIST" && shasum -a 256 -c --strict --quiet SHA256SUMS) || fail "SHA256SUMS doesn't match the files"
# The app in the zip is the version we are about to call it.
plist_in_zip() { unzip -p "$DIST/$ZIP" LivePaper.app/Contents/Info.plist | plutil -extract "$1" raw -o - -; }
[ "$(plist_in_zip CFBundleShortVersionString)" = "$VERSION" ] || fail "$ZIP holds LivePaper $(plist_in_zip CFBundleShortVersionString), not $VERSION"
[ "$(plist_in_zip CFBundleVersion)" = "$BUILD_NUMBER" ] || fail "$ZIP holds build $(plist_in_zip CFBundleVersion), not $BUILD_NUMBER"
FILES=(); for f in "${ASSETS[@]}"; do FILES+=("$DIST/$f"); done

# MARK: Notes -------------------------------------------------------------------------------------

NOTES="$(mktemp "${TMPDIR:-/tmp}/livepaper-notes.XXXXXX")"
trap 'rm -f "$NOTES" "$NOTES.previous"' EXIT
# Commit subjects become Markdown. Outside `code spans` (left as they are): < > & are escaped so a
# subject can't turn into HTML, and an @handle goes in backticks so it doesn't notify anyone.
md_subjects() {
  perl -pe 's{(\x60[^\x60]*\x60)|([<>&])|(?<![A-Za-z0-9\x60])\@([A-Za-z0-9][A-Za-z0-9_-]*)}{defined $1 ? $1 : defined $2 ? ($2 eq "<" ? "&lt;" : $2 eq ">" ? "&gt;" : "&amp;") : "\x60\@$3\x60"}ge'
}
# commit_list <git log arguments…>: up to 100 commit subjects as a Markdown list.
commit_list() {
  local total
  total="$(git rev-list --count --no-merges "$@")"
  git log --no-merges --max-count=100 --format="* %s (%h)" "$@" | md_subjects
  [ "$total" -le 100 ] || echo "* … and $((total - 100)) more"
}

{
  case "$CHANNEL" in
    nightly) printf '%s\n\n' "Rolling build of \`main\`, replaced on every push. For something steadier, use the [latest release]($REPO_URL/releases/latest)." ;;
    beta)    printf '%s\n\n' "Pre-release of LivePaper ${VERSION%%-*} for testing." ;;
  esac
  echo "**LivePaper $VERSION** · build $BUILD_NUMBER · commit [\`$SHORT\`]($REPO_URL/commit/$GITHUB_SHA)"
  echo
  echo "### Install"
  echo
  echo "Download **$DMG**, open it and drag LivePaper onto Applications (or unzip **$ZIP** and move"
  echo "LivePaper.app to Applications). Then open LivePaper: setup walks you through the rest."
  echo "Requires macOS 14 or later; the live lock screen needs macOS 26. To check a download, run"
  echo "\`shasum -a 256 -c --ignore-missing SHA256SUMS\` where you saved it (with SHA256SUMS)."
  if [ "$SIGNING" = adhoc ]; then
    echo
    echo "> [!IMPORTANT]"
    echo "> This build is **not notarized** by Apple (it is ad-hoc signed), so the first time you open it macOS"
    echo "> says it can't verify LivePaper and won't open it. If you trust this download (it came from this"
    echo "> repository's Releases page), either:"
    echo ">"
    echo "> * open LivePaper once, then go to **System Settings › Privacy & Security**, scroll down to"
    echo ">   *Security* and click **Open Anyway** next to the LivePaper message (confirm with your password), or"
    echo "> * run \`xattr -dr com.apple.quarantine /Applications/LivePaper.app\` in Terminal, then open it."
    echo ">"
    echo "> **Updating:** open LivePaper (the copy in Applications) once after replacing it. macOS keeps starting"
    echo "> the helper (your lock shortcut) only as the build that registered it, so when an update changes the"
    echo "> helper the shortcut doesn't work until LivePaper registers it again — which it does by itself when it"
    echo "> opens; macOS may then say LivePaper can run in the background."
  fi
  echo
} > "$NOTES"

# MARK: Publish -----------------------------------------------------------------------------------

# Prints the release's state ("draft" or "published") when TAG has one, else nothing.
release_state() {
  if [ "$DRY" = 1 ]; then echo "${DRY_RUN_STATE:-}"; return 0; fi
  query release view "$1" --json isDraft --jq 'if .isDraft then "draft" else "published" end' || true
}

# The commit that ref $1 (tags/nightly, heads/main) points at on GitHub; empty when it doesn't exist.
remote_commit() {
  if [ "$DRY" = 1 ]; then
    case "$1" in tags/nightly) echo "${NIGHTLY_PREVIOUS:-}" ;; *) echo "${DRY_RUN_MAIN:-$GITHUB_SHA}" ;; esac
    return 0
  fi
  local ref
  ref="$(query api "repos/$GITHUB_REPOSITORY/git/ref/$1" --jq '.object.sha + " " + .object.type' || true)"
  if [ "${ref#* }" = tag ]; then   # an annotated tag: its commit
    ref="$(query api "repos/$GITHUB_REPOSITORY/git/tags/${ref%% *}" --jq .object.sha || true)"
  fi
  echo "${ref%% *}"
}

# GitHub doesn't let a workflow's GITHUB_TOKEN create or edit a release whose commit has other
# .github/workflows/ files than the default branch (REST: "Create a release", "Update a release").
# True when this commit's workflows are main's current ones.
workflows_match_main() {
  local tip changed
  tip="$(remote_commit heads/main)"
  [ -n "$tip" ] || { echo "  couldn't read main's current commit" >&2; return 1; }
  [ "$tip" = "$GITHUB_SHA" ] && return 0
  if [ "$DRY" = 1 ]; then [ -z "${DRY_RUN_WORKFLOWS_DIFFER:-}" ]; return; fi
  git cat-file -e "$tip^{commit}" 2>/dev/null || git fetch --quiet --no-tags origin "$tip" 2>/dev/null || true
  if git cat-file -e "$tip^{commit}" 2>/dev/null; then
    git diff --quiet "$GITHUB_SHA" "$tip" -- .github/workflows
    return
  fi
  changed="$(query api "repos/$GITHUB_REPOSITORY/compare/$GITHUB_SHA...$tip" \
    --jq '[.files[]?.filename | select(startswith(".github/workflows/"))] | length' || echo unknown)"
  [ "$changed" = 0 ]
}

# The version tag the notes start from: for stable the previous stable release, for a beta the
# previous beta or release. Empty when there is none.
previous_version_tag() {
  local t seen=0 re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$'
  [ "$CHANNEL" = stable ] && re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
  # Newest first; versionsort.suffix sorts 1.0.0-beta.N before 1.0.0.
  for t in $(git -c versionsort.suffix=-beta. tag --list 'v*' --sort=-v:refname); do
    if [ "$t" = "$TAG" ]; then seen=1; continue; fi
    [ "$seen" = 1 ] && [[ "$t" =~ $re ]] && { echo "$t"; return 0; }
  done
  return 0
}

TITLE="LivePaper $VERSION"
[ "$CHANNEL" = nightly ] && TITLE="Nightly ${VERSION%%-*} (build $BUILD_NUMBER, $SHORT)"
STATE="$(release_state "$TAG")"
step "$CHANNEL: $TITLE → $TAG (${STATE:-new release}; $SIGNING)"

if [ "$CHANNEL" = nightly ]; then
  PREV="$(remote_commit tags/nightly)"
  known() { git cat-file -e "$1^{commit}" 2>/dev/null; }
  if [ -n "$PREV" ] && [ "$PREV" != "$GITHUB_SHA" ] && known "$PREV" && git merge-base --is-ancestor "$GITHUB_SHA" "$PREV"; then
    # A re-run of an older workflow run: never move the nightly backwards.
    notice "the nightly already has $(git rev-parse --short=7 "$PREV"), which is newer than $SHORT: nothing to publish"
    exit 0
  fi
  if ! workflows_match_main; then
    notice "main has moved on to a commit with other workflow files, and GitHub won't let this run's token publish a release for $SHORT: the nightly is left to the run for main's newest commit"
    exit 0
  fi
  if [ -n "$PREV" ] && [ "$PREV" = "$GITHUB_SHA" ] && [ "$DRY" = 0 ] \
      && query release view nightly --json body --jq .body > "$NOTES.previous" && [ -s "$NOTES.previous" ]; then
    # A re-run after this commit was published: keep the notes, which list its changes.
    mv "$NOTES.previous" "$NOTES"
  elif [ -n "$PREV" ] && [ "$PREV" != "$GITHUB_SHA" ] && known "$PREV" && git merge-base --is-ancestor "$PREV" "$GITHUB_SHA"; then
    { echo "### Changes since the previous nightly"; echo; commit_list "$PREV..$GITHUB_SHA"; echo
      echo "[All changes]($REPO_URL/compare/$PREV...$GITHUB_SHA)"; } >> "$NOTES"
  else
    # The first nightly, or main was rewritten since the previous one.
    { echo "### Recent changes"; echo; commit_list --max-count=30 "$GITHUB_SHA"; echo
      echo "[History]($REPO_URL/commits/$GITHUB_SHA)"; } >> "$NOTES"
  fi
  rm -f "$NOTES.previous"
  # Replace the release and its tag rather than edit them: editing goes through the old commit,
  # which GitHub refuses once main's workflows have changed since (see workflows_match_main), and
  # a moved tag would be subject to the same rule. Assets, notes and checks are all ready by now.
  if [ -n "$STATE" ]; then
    gh_do release delete nightly --cleanup-tag --yes
  elif [ -n "$PREV" ]; then
    gh_do api -X DELETE "repos/$GITHUB_REPOSITORY/git/refs/tags/nightly" --silent
  fi
  gh_do release create nightly "${FILES[@]}" --target "$GITHUB_SHA" --title "$TITLE" --notes-file "$NOTES" \
    --prerelease --latest=false
  if [ "$DRY" = 0 ]; then
    now="$(remote_commit tags/nightly)"
    [ "$now" = "$GITHUB_SHA" ] || fail "the nightly tag points at ${now:-nothing}, not $GITHUB_SHA"
  fi
else
  if ! workflows_match_main; then
    # Try anyway (GitHub may accept workflows that match another branch), but say why it may fail.
    msg="$TAG's .github/workflows differ from main's current ones: GitHub may refuse to let the workflow's token publish it (404 or 403 below). Then tag main's current commit instead (scripts/release.sh), or attach this run's packages to a release by hand."
    echo "! $msg" >&2
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning title=Publish::$msg"
  fi
  if [ -n "$STATE" ]; then
    # A re-run: the release (maybe a draft left by a failed upload) gets the new assets; its notes stay.
    gh_do release upload "$TAG" "${FILES[@]}" --clobber
    if [ "$CHANNEL" = beta ]; then
      gh_do release edit "$TAG" --title "$TITLE" --prerelease --draft=false
    else
      gh_do release edit "$TAG" --title "$TITLE" --prerelease=false --draft=false --latest
    fi
  else
    args=(release create "$TAG" "${FILES[@]}" --verify-tag --title "$TITLE" --notes-file "$NOTES")
    START="$(previous_version_tag)"
    if [ -n "$START" ]; then
      # Our commit list (main is mostly merged locally, and GitHub's generated notes only list pull
      # requests), then GitHub's: pull requests, new contributors, the full-changelog link.
      { echo "### Changes since $START"; echo; commit_list "$START..$GITHUB_SHA"; echo; } >> "$NOTES"
      args+=(--generate-notes --notes-start-tag "$START")
    else
      # The first one. (Not --generate-notes: GitHub's default starting point could be the nightly.)
      { echo "### Changes"; echo; commit_list "$GITHUB_SHA"; echo; echo "[History]($REPO_URL/commits/$TAG)"; } >> "$NOTES"
    fi
    if [ "$CHANNEL" = beta ]; then args+=(--prerelease --latest=false); else args+=(--latest); fi
    gh_do "${args[@]}"
  fi
fi

if [ "$DRY" = 1 ]; then
  echo "  [dry-run] notes:"; sed 's/^/    | /' "$NOTES"
else
  echo "✓ $REPO_URL/releases/tag/$TAG"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Published [$TITLE]($REPO_URL/releases/tag/$TAG) ($SIGNING)." >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
