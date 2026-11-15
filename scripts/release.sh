#!/bin/bash
# Tags a LivePaper beta or release; CI builds and publishes it (docs/RELEASING.md).
#
#   scripts/release.sh beta   [X.Y.Z] [--yes] [--no-fetch] [--dry-run] [--push]
#   scripts/release.sh stable [X.Y.Z] [--yes] [--no-fetch] [--dry-run] [--push]
#
#   beta      tags vX.Y.Z-beta.N with the next free N (1, 2, …) → a GitHub pre-release
#   stable    tags vX.Y.Z → the GitHub release marked latest
#   X.Y.Z     the version to release (default: the VERSION file). When it differs from VERSION, a
#             "Version X.Y.Z" commit updates VERSION first; it can't go below VERSION or an
#             existing release.
#   --yes       don't ask before committing and tagging
#   --no-fetch  don't contact origin (by default: `git fetch origin main` and `git ls-remote --tags`
#               to see what is already published; nothing is ever pushed without --push)
#   --dry-run   show what would happen; change nothing
#   --push      push the commit (if any) and the tag to origin afterwards
#
# Requirements: on main, a clean working tree, not behind origin/main. The tag is annotated and
# local; the script prints the `git push` command that publishes it (CI runs on the pushed tag).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
usage() { sed -n '2,19p' "$0" >&2; exit 2; }
fail() { echo "✗ $*" >&2; exit 1; }

KIND="" WANT="" YES=0 FETCH=1 DRY=0 PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    beta|stable) [ -z "$KIND" ] || usage; KIND="$1" ;;
    --yes|-y) YES=1 ;;
    --no-fetch) FETCH=0 ;;
    --dry-run|-n) DRY=1 ;;
    --push) PUSH=1 ;;
    -h|--help) usage ;;
    [0-9]*) [ -z "$WANT" ] || usage; WANT="$1" ;;
    v[0-9]*) fail "give the version without the v: scripts/release.sh $KIND ${1#v}" ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$KIND" ] || usage
[ "$DRY" = 0 ] || [ "$PUSH" = 0 ] || fail "--dry-run and --push don't go together"

NUM='(0|[1-9][0-9]*)'
SEMVER_RE="^$NUM\\.$NUM\\.$NUM\$"
CURRENT="$(tr -d '[:space:]' < VERSION)"
[[ "$CURRENT" =~ $SEMVER_RE ]] || fail "VERSION must be a plain X.Y.Z to release from (it is '$CURRENT')"
VERSION="${WANT:-$CURRENT}"
[[ "$VERSION" =~ $SEMVER_RE ]] || fail "the version must look like 1.2.3, without a prefix or suffix (got '$VERSION')"

# vercmp A B → prints -1, 0 or 1 (numeric X.Y.Z comparison; bash 3.2 has no sort -V).
vercmp() {
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"; read -r -a b <<< "$2"
  for i in 0 1 2; do
    if [ "${a[i]}" -gt "${b[i]}" ]; then echo 1; return; fi
    if [ "${a[i]}" -lt "${b[i]}" ]; then echo -1; return; fi
  done
  echo 0
}

# MARK: The repository ----------------------------------------------------------------------------

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
[ "$BRANCH" = main ] || fail "release from main (you are on ${BRANCH:-a detached HEAD})"
[ -z "$(git status --porcelain --untracked-files=normal)" ] || { git status --short >&2; fail "the working tree isn't clean"; }

REMOTE_TAGS=""
if [ "$FETCH" = 1 ]; then
  git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote (use --no-fetch to release from a local repository)"
  echo "▸ checking origin"
  git fetch --quiet --no-tags origin main || fail "couldn't fetch origin main (offline? use --no-fetch)"
  REMOTE_TAGS="$(git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||')" || fail "couldn't list origin's tags"
  git merge-base --is-ancestor origin/main HEAD || fail "main is behind or has diverged from origin/main: pull first"
fi
# Tags here and on origin, one per line.
ALL_TAGS="$(printf '%s\n%s\n' "$(git tag --list 'v*')" "$REMOTE_TAGS" | sed '/^$/d' | sort -u)"
has_tag() { printf '%s\n' "$ALL_TAGS" | grep -qxF -- "$1"; }

# The newest stable release so far must not be newer than this one.
LATEST=""
while IFS= read -r t; do
  [[ "$t" =~ ^v$NUM\.$NUM\.$NUM$ ]] || continue
  v="${t#v}"
  if [ -z "$LATEST" ] || [ "$(vercmp "$v" "$LATEST")" = 1 ]; then LATEST="$v"; fi
done <<< "$ALL_TAGS"

[ "$(vercmp "$VERSION" "$CURRENT")" != -1 ] || fail "$VERSION is lower than VERSION ($CURRENT)"
has_tag "v$VERSION" && fail "v$VERSION is already released; release a higher version (scripts/release.sh $KIND X.Y.Z)"
if [ -n "$LATEST" ] && [ "$(vercmp "$VERSION" "$LATEST")" != 1 ]; then
  fail "$VERSION isn't newer than the latest release ($LATEST)"
fi

if [ "$KIND" = beta ]; then
  N=0
  while IFS= read -r t; do
    case "$t" in "v$VERSION-beta."*) ;; *) continue ;; esac
    n="${t#"v$VERSION-beta."}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$n" -gt "$N" ] && N="$n"
  done <<< "$ALL_TAGS"
  TAG="v$VERSION-beta.$((N + 1))"
else
  TAG="v$VERSION"
fi
has_tag "$TAG" && fail "$TAG exists already"

# MARK: Plan -------------------------------------------------------------------------------------

BUMP=0; [ "$VERSION" != "$CURRENT" ] && BUMP=1
AHEAD=0
if [ "$FETCH" = 1 ]; then AHEAD="$(git rev-list --count origin/main..HEAD)"; fi
echo "LivePaper $KIND release"
echo "  version   $VERSION$([ "$BUMP" = 1 ] && echo " (VERSION $CURRENT → $VERSION: a new commit)")"
if [ "$BUMP" = 1 ]; then AT="the new commit"; else AT="$(git rev-parse --short HEAD)"; fi
echo "  tag       $TAG (annotated, at $AT)"
[ -n "$LATEST" ] && echo "  previous  v$LATEST"
[ "$AHEAD" != 0 ] && echo "  note      main is $AHEAD commit(s) ahead of origin/main; they are pushed with the tag"
[ "$FETCH" = 0 ] && echo "  note      --no-fetch: origin wasn't checked for newer commits or existing tags"

if [ "$DRY" = 1 ]; then echo "(dry run: nothing changed)"; exit 0; fi
if [ "$YES" = 0 ]; then
  [ -t 0 ] || fail "not a terminal: pass --yes to proceed"
  printf 'Proceed? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "nothing changed"; exit 1 ;; esac
fi

# MARK: Commit, tag ------------------------------------------------------------------------------

if [ "$BUMP" = 1 ]; then
  printf '%s\n' "$VERSION" > VERSION
  git add VERSION
  git commit --quiet -m "Version $VERSION"
  echo "▸ committed VERSION $VERSION ($(git rev-parse --short HEAD))"
fi
# CI must accept the tag for this commit (same rule as the workflow).
check="$(scripts/ci/version-from-ref.sh "refs/tags/$TAG" 2>&1 >/dev/null)" || { echo "$check" >&2; fail "CI would reject $TAG"; }
if [ "$KIND" = beta ]; then MESSAGE="LivePaper $VERSION beta ${TAG##*.}"; else MESSAGE="LivePaper $VERSION"; fi
git tag --annotate "$TAG" --message "$MESSAGE"
echo "▸ tagged $TAG ($(git rev-parse --short "$TAG^{commit}"))"

PUSH_CMD=(git push origin "$TAG")
if [ "$BUMP" = 1 ] || [ "$AHEAD" != 0 ] || [ "$FETCH" = 0 ]; then PUSH_CMD=(git push --atomic origin main "$TAG"); fi
if [ "$PUSH" = 1 ]; then
  echo "▸ ${PUSH_CMD[*]}"
  "${PUSH_CMD[@]}"
  echo "✓ pushed: CI builds and publishes $TAG"
else
  echo
  echo "To publish it (CI builds, tests and releases the tag):"
  echo "  ${PUSH_CMD[*]}"
  echo "To undo instead: git tag -d $TAG$([ "$BUMP" = 1 ] && echo " && git reset --hard HEAD~1")"
fi
