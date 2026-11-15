# Releasing LivePaper

Everything is built and published by GitHub Actions ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml));
a person only decides *when* to release, by pushing a tag.

| You push | CI builds and tests, then | Release on GitHub | Version shown in the app |
|---|---|---|---|
| a pull request, or any branch | uploads the zip and dmg as workflow artifacts | — | `0.1.0` |
| `main` | replaces the rolling **nightly** pre-release (tag `nightly`, re-created at the new commit) | [Nightly](https://github.com/nachmore/livepaper/releases/tag/nightly) | `0.1.0-nightly` |
| tag `v0.1.0-beta.2` | creates a versioned **pre-release** | `LivePaper 0.1.0-beta.2` | `0.1.0-beta.2` |
| tag `v0.1.0` | creates the **release**, marked *Latest* | `LivePaper 0.1.0` | `0.1.0` |

`0.1.0` stands for the [`VERSION`](../VERSION) file. The build number (`CFBundleVersion`, shown in
brackets in the app) is always the number of commits on the built commit — see [Versions](#versions).

## What CI does

The workflow runs on every push (any branch, `v*` tags) and every pull request, in three jobs:

1. **Lint** (Ubuntu): [shellcheck](https://www.shellcheck.net) on every shell script and
   [actionlint](https://github.com/rhysd/actionlint) on the workflow (pinned, checksum-verified
   downloads: `scripts/ci/install-linters.sh`), and the tag → version tests under bash 5.
2. **Build and test** (`macos-26`, Xcode 26.6 selected explicitly — the job fails with the list of
   installed Xcodes if an image update removed it): works out the channel and version from the ref
   (`scripts/ci/version-from-ref.sh`, so a bad tag fails in seconds), runs its tests under macOS's
   bash 3.2, `swift build`, `swift run LivePaperSelfTest` (failures become annotations; the opt-in
   render-server and AI-agent tests stay off), the universal release build `scripts/build.sh`, and
   `scripts/ci/package.sh`, which makes and verifies the zip, the dmg and `SHA256SUMS`. The zip is
   uploaded as an artifact on its own (30 days), all three together for the publish job (7 days).
   The SwiftPM `.build` directory is cached; only pushes to `main` save it.
3. **Publish** — only for pushes of `main` and of release tags in `nachmore/livepaper`, after both
   jobs above passed. It is the only job with `contents: write` and the only one that sees secrets;
   it never runs for pull requests. Ad-hoc: it publishes exactly the files the build job made.
   Developer ID: it rebuilds with the certificate, notarizes and staples (see [Signing](#signing)).
   `scripts/ci/publish-release.sh` then talks to GitHub with the preinstalled `gh` and the
   workflow's `GITHUB_TOKEN`.

A newer push to the same branch or pull request cancels the older run's build. Publishing is never
cancelled half-way: publishes of the same ref queue, and a newer one waiting replaces an older one.
Re-run only the newest run of `main`: an older run's re-run publishes nothing (the nightly never
goes backwards), but while it waits it can take the place of the newest run's queued publish.

**Nightly** is one release, tagged `nightly`. Each run replaces it — the old release and its tag
are deleted and a new pre-release `Nightly 0.1.0 (build 142, abc1234)` is created at the new commit
with `LivePaper-nightly.zip`, `LivePaper-nightly.dmg`, `SHA256SUMS` and notes: install steps, then the
commits since the previous nightly. (Replacing rather than editing is deliberate: GitHub doesn't let
a workflow's token create or edit a release whose commit has other `.github/workflows/` files than
`main`, and an edited nightly would still point at its old commit. For a few seconds per push there
is no nightly; people watching releases get a notification per nightly.) It never goes backwards:
re-running an older run whose commit the nightly has already passed publishes nothing, and an older
commit whose workflows differ from `main`'s newest leaves the nightly to that newer commit's run.
Stable download links:
`https://github.com/nachmore/livepaper/releases/download/nightly/LivePaper-nightly.dmg` (and `.zip`).

**Betas and releases** get `LivePaper-<version>.zip`, `.dmg` and `SHA256SUMS`, a short install header,
the commits since the previous beta or release (for a release: since the previous release, so the
notes cover all its betas) and then GitHub's generated notes for the same range (pull requests, new
contributors, the full-changelog link; GitHub only lists pull requests, hence the commit list). The
first beta and the first release have no predecessor: their notes list the history instead, without
GitHub's part (its automatic starting point could be the nightly). Re-running a failed publish
replaces the assets of the release it already created and leaves its notes alone. For the same
GitHub rule, a tag whose `.github/workflows/` differ from `main`'s current ones may not be publishable
by CI (the job warns): tag `main`'s newest commit, as `scripts/release.sh` does. (A GitHub App or
personal token with the *Workflows* permission would lift the rule; the workflow deliberately uses
only `GITHUB_TOKEN`.)

## Cutting a beta or a release

From an up-to-date `main` with a clean working tree:

```sh
scripts/release.sh beta              # tags v<VERSION>-beta.<next N>, e.g. v0.1.0-beta.1
scripts/release.sh beta 0.2.0        # commits VERSION 0.2.0 first, then tags v0.2.0-beta.1
scripts/release.sh stable            # tags v<VERSION>, e.g. v0.1.0
scripts/release.sh stable --dry-run  # shows what it would do
```

It checks origin (`git fetch origin main`, `git ls-remote --tags`; nothing is pushed), picks the
next free beta number, refuses versions that go backwards or already exist, asks before it commits
or tags (`--yes` skips the question), makes an annotated tag locally and prints the push command,
for example:

```sh
git push origin v0.1.0-beta.1
```

(`git push --atomic origin main <tag>` when there is a new VERSION commit or main has unpushed
commits.) `--push` runs it for you. Until you push, the undo command it prints (`git tag -d <tag>`,
plus `git reset --hard HEAD~1` when it made a VERSION commit) takes everything back; a tag that was
made but never pushed blocks the next run until you push or delete it. Watch the
run under *Actions*; the release appears when the publish job finishes (5–10 minutes ad-hoc, plus
notarization with Developer ID).

**The tag must match VERSION.** CI only accepts `vX.Y.Z` and `vX.Y.Z-beta.N` (N ≥ 1, no leading
zeros) where `X.Y.Z` is the `VERSION` file *at the tagged commit*; anything else fails the run
before it builds (for example `tag v0.2.0 is version 0.2.0 but VERSION at this commit says 0.1.0`).
To fix a wrong tag that you pushed: `git push origin :refs/tags/<tag>` and `git tag -d <tag>`, then tag
the right commit. (A tag that published a release should stay; release the next version instead.)

**After a release**, bump `VERSION` for the next cycle (or let `scripts/release.sh beta 0.2.0` do it
when you cut the first beta): nightlies are labelled with `VERSION`, so until then they read
`0.1.0-nightly` although 0.1.0 is out.

## Versions

* `VERSION` holds the next or current release, a plain `X.Y.Z` (`scripts/build.sh` also accepts
  development suffixes like `0.1.0-dev`, but nightlies and releases need the plain form).
* `CFBundleShortVersionString` is `VERSION`, or what CI passes in `LIVEPAPER_VERSION`: `X.Y.Z`,
  `X.Y.Z-beta.N` or `X.Y.Z-nightly`. `scripts/build.sh` only accepts `VERSION` itself or
  `VERSION-<suffix>`.
* `CFBundleVersion` is numeric: the commit count of the built commit (`LIVEPAPER_BUILD` overrides
  it; CI passes it explicitly so the build and publish jobs agree). It must grow, because the app
  replaces the installed screen saver when the numbers differ, so CI checks out the full history
  (`build.sh` warns about shallow clones). Builds of the same commit — say a nightly and a beta —
  share a number: the code is the same, but going from one to the other doesn't refresh the
  installed screen saver, which keeps the version string (and signature) it was installed with
  until a build with a higher number arrives.

## Signing

### Ad-hoc (the default)

Without secrets everything is ad-hoc signed, as `scripts/build.sh` does locally. That's a valid
signature (macOS requires one), but not one from an identified developer, so Gatekeeper blocks the
downloaded app the first time. The notes of every ad-hoc release say how to open it anyway:

* open LivePaper once, then **System Settings › Privacy & Security** › *Security* › **Open Anyway**
  (and confirm with your password), or
* `xattr -dr com.apple.quarantine /Applications/LivePaper.app` in Terminal.

### Developer ID and notarization (optional)

Set all six repository secrets (*Settings › Secrets and variables › Actions*) and the publish job
switches to Developer ID by itself: it imports the certificate into a temporary keychain (random
password, deleted afterwards even when the job fails), builds with
`LIVEPAPER_SIGN_IDENTITY` (hardened runtime, secure timestamps), notarizes the app with
`xcrun notarytool submit --wait`, staples it, packages it, signs, notarizes and staples the dmg too,
and re-writes `SHA256SUMS`. Setting only some of the secrets fails the publish job with the list of
missing ones rather than quietly publishing an unsigned build. Pull requests never see them.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12_BASE64` | Your *Developer ID Application* certificate **with its private key**, exported from Keychain Access as a `.p12`, base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password you gave the `.p12` when exporting it |
| `MACOS_SIGN_IDENTITY` | The identity's full name, e.g. `Developer ID Application: Jane Doe (AB12CD34EF)` (`security find-identity -v -p codesigning`), or its SHA-1 |
| `NOTARY_KEY_ID` | An App Store Connect API key's ID (*Users and Access › Integrations › App Store Connect API*, a Team key with the *Developer* role) |
| `NOTARY_ISSUER_ID` | The Issuer ID shown above that list |
| `NOTARY_KEY_P8_BASE64` | The key's `AuthKey_<ID>.p8` (downloadable once), base64-encoded: `base64 -i AuthKey_<ID>.p8 \| pbcopy` |

With the GitHub CLI, for example: `gh secret set MACOS_CERT_P12_BASE64 < <(base64 -i DeveloperID.p12)`.
For extra protection you can make them secrets of an *environment* that only `main` and `v*` tags
may use, and add `environment: <name>` to the publish job.

## Repository settings

* **Actions** must be enabled (*Settings › Actions › General*). The default `GITHUB_TOKEN`
  permissions can stay read-only: the publish job asks for `contents: write` itself.
* Don't turn on **immutable releases**, and don't protect the `nightly` tag with a ruleset (or let
  GitHub Actions bypass it): every push to `main` deletes and re-creates the nightly release and tag.
* Forks: the publish job is limited to `nachmore/livepaper`, so a fork's `main` builds but doesn't
  publish. To try releases in a fork, change the `github.repository` condition there.

## Checking changes locally

Nothing here pushes, tags remotely or opens anything:

```sh
scripts/ci/lint.sh                         # shellcheck + actionlint (brew install shellcheck actionlint)
scripts/ci/test-version-from-ref.sh        # the ref → version rules
scripts/ci/version-from-ref.sh refs/tags/v0.1.0-beta.2

# What CI's build job does, for a nightly, into /tmp/lp-dist:
eval "$(scripts/ci/version-from-ref.sh refs/heads/main)"
LIVEPAPER_VERSION="$version" scripts/build.sh --out /tmp/lp-build
scripts/ci/package.sh /tmp/lp-build/LivePaper.app /tmp/lp-dist "$asset_base"
CHANNEL=$channel VERSION=$version TAG=$tag ASSET_BASE=$asset_base SIGNING=adhoc \
  BUILD_NUMBER="$(git rev-list --count HEAD)" GITHUB_SHA="$(git rev-parse HEAD)" \
  GITHUB_REPOSITORY=nachmore/livepaper scripts/ci/publish-release.sh --dry-run /tmp/lp-dist
```

`package.sh` checks the image by attaching it with `-nobrowse -noautoopen` (no Finder window) and
detaching it again. `publish-release.sh --dry-run` prints the `gh` commands and the release notes
instead of running them.

## Troubleshooting

* **"/Applications/Xcode_26.6.app is not installed on this runner"** — GitHub updated the image.
  Pick an installed Xcode with Swift ≥ 6.2 from the
  [image's README](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
  and change `XCODE_VERSION` in the workflow (and `runs-on` for a newer image).
* **A self-test fails only in CI** — the runner is a clean, slower Mac: no customised wallpaper or
  screen saver, no AI tools, no battery, a login shell you don't control. Tests must not depend on
  any of that; they run against temporary directories (README › Development).
* **Notarization rejected** — the job prints `notarytool log` for the submission; usually a binary
  without the hardened runtime or a secure timestamp.
* **`hdiutil: … Resource busy`** — known runner flakiness; `package.sh` retries creating and
  detaching the image, otherwise re-run the job.
* **"main has moved on to a commit with other workflow files"** — a newer push changed the
  workflow before this run published; the newer run publishes the nightly. Not an error.
