# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `v1.1.0`
- Channel: `prod`
- Date: `2026-09-20`
- Verified by: `Nabil Alhafez`
- Commit: `TBD` (filled at build)
- Tag: `v1.1.0`
- Build: `TBD` (filled at build)
- Status: `In progress`

Possible status values:

- `In progress`
- `Blocked`
- `Approved`
- `Released`

---

# Automated Checks

Run these first.

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze test
flutter analyze lib
flutter build macos --flavor dev
flutter build macos --flavor prod
```

Checklist:

* [x] `dart format --output=none --set-exit-if-changed .`
* [x] `flutter analyze test`
* [x] `flutter analyze lib`
* [x] `flutter build macos --flavor dev`
* [x] `flutter build macos --flavor prod`

Notes: all five re-run on 323a267, after `develop` was merged in again for
#566 (export sleep assertion), #567 (export backpressure), #569 (recording
sleep hold), #563 (word timings dropped from `post/state.json`) and #564
(per-project subtitle destination). Clean: 388 files formatted with no
changes, no analyzer issues in `lib` or `test`, both flavours archived
(Release-dev 122.6 MB, Release-prod 108.1 MB), and the Dart suite at 1556.
The only build output is RNNoise's SSE2 `#warning`, expected on this
toolchain. Re-run these if anything lands on the branch after this commit —
they are cheap, and they are the only items on this page a machine can
answer.

Everything below this section still needs a human at a Mac. The driver
cannot reach the native overlay windows where Stop lives, so a
start-then-stop recording loop breaks at the one button that matters.
Worth weighting toward EXPORT this time: five of the six changes merged
since the branch was cut touch the export or recording path, including
four render hot paths and the export completion itself. A colour-graded
export with captions on a long recording is where a regression would hide.

*

---

# Recording Flows

Verify the full recording workflow.

* [ ] full display recording
* [ ] single window recording
* [ ] custom area recording
* [ ] countdown start
* [ ] countdown cancel
* [ ] stop flow
* [ ] menu bar control
* [ ] recording indicator overlay

Notes:

*

---

# Permissions

Verify permission prompts and recovery flows.

* [ ] screen recording permission request
* [ ] screen recording recovery flow
* [ ] camera permission flow
* [ ] accessibility prompt

Notes:

*

---

# Overlay / Cursor / Zoom

Verify overlay behavior and cursor/zoom features.

* [ ] overlay show/hide
* [ ] overlay manual move
* [ ] overlay position persistence
* [ ] overlay styling options
* [ ] overlay linked-to-recording mode
* [ ] cursor sidecar capture
* [ ] cursor visibility toggle in export
* [ ] cursor scaling and highlight
* [ ] zoom factor
* [ ] zoom follow strength

Notes:

*

---

# Preview / Export

Verify preview playback and export pipeline.

* [ ] inline preview playback
* [ ] 16:9 preview/export
* [ ] 1080p export
* [ ] 1440p export
* [ ] 2160p export
* [ ] MP4 export
* [ ] MOV export
* [ ] GIF export
* [ ] background image export
* [ ] background color export
* [ ] save folder selection

Notes:

*

---

# Licensing

Verify licensing and paywall behavior.

* [ ] free trial depletion
* [ ] paywall display
* [ ] license activation
* [ ] expired updates messaging

Notes:

*

---

# Repo / Docs Hygiene

Ensure repository documentation and release tooling are in place.

* [x] release tooling documented in `ops/release/README.md`
* [x] `README.md` updated
* [x] `LICENSE` added
* [x] `LICENSING.md` added
* [x] `CONTRIBUTING.md` added
* [x] `SECURITY.md` added

Notes: all six present. `ops/release/README.md` (176 lines) documents the
current tooling including the per-provider credential categories, and was
last updated 2026-09-22.

`README.md` was NOT actually updated for this release and is ticked only
because it has been now. Its feature list omitted auto-subtitles — the
headline feature of 1.1.0 — and it said nothing about the release raising the
macOS floor from 10.15 to 13, which is a hard gate a reader needs before they
download. Both added.

*

---

# Release Artifact Verification

Verify the generated release artifacts before publishing.

* [ ] DMG launches correctly
* [x] app icon and metadata appear correctly
* [x] auto-updater configuration verified
* [x] update channel configuration verified
* [x] application launches without console errors

Notes: verified on 2026-09-23 against the PUBLISHED artifact — downloaded
`https://clingfy.com/updates/downloads/Clingfy_1.1.0.dmg` (51 MB, served
2026-09-20T16:21:59Z) and mounted it, rather than inspecting a local build.

Metadata, all internally consistent and matching the appcast:
`CFBundleShortVersionString` 1.1.0, `CFBundleVersion` 1001,
`CFBundleIdentifier` com.clingfy.clingfy (the prod id, not `.dev`),
`LSMinimumSystemVersion` 13.0 — which matches both the changelog's macOS 13
claim and the appcast's `minimumSystemVersion`, while 1.0.7 and 1.0.6 stay at
10.15 so users on older macOS are correctly held back. `AppIcon.icns` present
and referenced by `CFBundleIconFile`.

Gatekeeper: `spctl -a -t install` → **accepted**, `source=Notarized Developer
ID`, `Developer ID Application: TIIN S.R.L. (46LWU2HLR5)`, hardened runtime on
(`flags=0x10000(runtime)`), signed with a secure timestamp. The notarization
ticket is stapled to the DMG (`stapler validate` passes), not to the inner
`.app` — which is the normal shape.

Updater chain verified end to end rather than by inspection: the shipped
binary carries `SUFeedURL=https://clingfy.com/updates/appcast.xml`,
`SUEnableAutomaticChecks=true`, and an `SUPublicEDKey` that MATCHES the repo's
— so the EdDSA signatures on the live appcast entries are ones this build can
actually verify. Both feeds return HTTP 200 (prod `clingfy.com/updates`, dev
`dev.clingfy.com/updates`), and the prod feed lists 1.1.0, 1.0.7 and 1.0.6, so
history is intact.

"Launches without console errors" was checked on a `--flavor dev` debug run,
not on this DMG (launching the signed prod build here would have muddied the
dev install's state). It starts clean apart from two known dev-only lines: the
Sentry release-tag warning, which only appears because `flutter run` passes no
`FLUTTER_BUILD_NAME`/`NUMBER` — the release lanes do — and a 503 from
`aws.dev.clingfy.ai`, which is the dev API deliberately parked at zero tasks
(`clingfy-labs infra/aws/dev-park.sh`). Neither exists in a release build
against the prod API.

* Everything else on this page still needs a human. The driver cannot reach the
  native overlay windows where **Stop** lives, so no recording flow, permission
  prompt or overlay item above can be automated from here — and the export
  items need a save dialog (`NSSavePanel`), which is equally out of reach.

---

# First production run of the GitHub Actions lanes

**Both lanes have since run, successfully.** `release-macos-prod.yml` completed at
2026-09-20T16:11:15Z and `release-windows-prod.yml` at 2026-09-20T16:24:24Z; tag `v1.1.0`
exists and the appcast entry is dated 16:21:32 the same day. 1.1.0 is SHIPPED.

The paragraph that stood here said they "have never executed — 0 runs ever" and that 1.1.0
would be their first run. That was written by the pre-flight audit on 2026-09-19, *before*
any dispatch, and stayed on the page afterwards — where it reads as current and says the
opposite of the truth. Everything below is still the pre-flight record and is accurate as
history.

Note for the next release: `pubspec.yaml` is still `1.1.0+9`, unchanged since the tag,
while 35 commits sit on `main` beyond it. See #572 — nothing can ship until the version
moves, and the prod lane's Step 0.5 overwrite guard will refuse rather than clobber.

## Fixed before the cut

* [x] **Windows in-app updater pointed at a deleted host.** The feed host is not dead Azure
  config despite the name it carried at the time: `01_build.ps1` passes the env file through
  `--dart-define-from-file`, and `lib/core/updater/windows_update_feed.dart` reads it via
  `String.fromEnvironment` to build the feed URL. It is **compiled into the installer**.
  The key was then called `AZ_CDN_ENDPOINT` and it held
  `clingfyreleases.blob.core.windows.net/updates`, which stopped resolving when Azure was
  decommissioned on 2026-09-15. The lane would have gone **green** regardless, because the
  smoke test builds its URL from `AWS_PUBLIC_ENDPOINT` — a different address than the one
  in the binary. Corrected to `clingfy.com/updates`; `ENV_PROD_B64` and `ENV_DEV_B64`
  re-uploaded 2026-09-19. The key has since been renamed to `CLINGFY_UPDATE_FEED_HOST`
  (8a4e3ca1) and the Dart fallback to the old name deleted in #556, so a build today reads
  that name and nothing else. **An installer already cut cannot be fixed after the fact**,
  so confirm the env payload carries `CLINGFY_UPDATE_FEED_HOST=clingfy.com/updates` before
  dispatch — `01_build.ps1` hands the file to Flutter whole and never prints the value, so
  no build log will show it.
* [x] **A failed download could erase the update history.** `s3_download_if_exists()`
  returned `1` (= genuinely absent) when `head-object` found the appcast but the `cp`
  failed. `restore_release_history.sh` then declares "first release" and republishes an
  appcast containing only the new build. Fixed in #519; `azure.sh` carried the mirror
  image (an unconditional `return 0`, so a failure read as success) and was fixed too.
* [x] **The workflow header claimed a reviewer gate that does not exist.** Corrected in
  #519 — see below.

## Confirmed sound

* [x] OIDC trust pins the prod lanes to `@refs/heads/release/*`, not `refs/heads/main`,
  so the credentials step works from this branch.
* [x] All six Apple secrets present on the `production` environment, and
  `AWS_RELEASE_ROLE_ARN` / `AWS_REGION` set there.
* [x] Both prod workflows exist on `main` (the default branch) and are offered for
  dispatch.
* [x] `CHANGELOG.md` `## [1.1.0]` extracts 13,992 bytes of real notes, not the
  "Bug fixes and performance improvements" placeholder.
* [x] No name collision: `Clingfy_1.1.0.dmg` and `Clingfy_Setup_1.1.0.exe` both 404 on
  the CDN, so the overwrite guard will not trip.

## Accepted risks — decided, not overlooked

* **No required reviewer on the `production` environment** (`protection_rules: []`,
  `deployment_branch_policy: null`). Nothing stands between clicking "Run workflow" and an
  immutable publish, and the role has no `s3:DeleteObject` by design, so a mistaken
  publish can only be superseded by a higher version, never removed. Offered and
  declined 2026-09-19.
* **A re-cut of 1.1.0 serves stale bytes from Cloudflare.** Only CloudFront is
  invalidated on publish. Re-running with `allow_overwrite=true` leaves Cloudflare PoPs
  serving the first DMG while the appcast carries the second one's signature, which
  Sparkle rejects. Prod artifacts are named by version alone, so a re-cut reuses the URL.
  Mitigations, neither applied: purge Cloudflare in the prod lanes (needs
  `CLOUDFLARE_API_TOKEN` in this repo — it currently exists only in clingfy-labs), or
  give prod artifacts build-numbered names. **If 1.1.0 needs re-cutting, purge
  `clingfy.com/updates/downloads/<artifact>` by hand first.**

## Windows publisher required the wrong CLI

`ops/release/windows/04_publish.ps1` demanded the **Azure** CLI before it
knew which provider it was publishing to, and never checked for the AWS CLI at
all -- the wrong tool required, the right one unverified. Dormant only because
`windows-latest` ships `az`, so the Windows dev lane published straight through it.

Fixed on this branch. The check could not simply be made conditional in place:
`Initialize-WindowsReleaseContext` leaves `StorageProvider` as `$null`
(`_config.ps1:289`) and `Import-AzurePublishSettings` is what sets it
(`_config.ps1:323`), so any dispatch above that call reads `$null` and always takes
the Azure branch. The check now sits after it and mirrors
`require_release_storage_cli()` in `ops/release/lib/env.sh:259`.

* [ ] publish log shows `aws: <path>`, not `az: <path>`

## Windows prod publish

* [ ] before dispatch: `ENV_PROD_B64` decodes to a `.env.prod` carrying
  `CLINGFY_UPDATE_FEED_HOST=clingfy.com/updates`. No build log can show this — `01_build.ps1`
  hands the env file to Flutter as a path (`--dart-define-from-file=$($Ctx.EnvFile)`, :142) and
  never echoes its contents, and the only loader that logs a key at all, `Import-DotenvFallback`
  (`_config.ps1:64-76`), prints the name and not the value, for `$script:AzureLegacyKeys` +
  `$script:StorageProviderKeys` only (:306-307) — neither of which contains the feed host. So the
  host compiled into the installer never appears in the lane's output. As of 2026-09-21 the secret
  still carried the pre-rename `AZ_CDN_ENDPOINT`, which nothing has read since #556; a build cut
  from that secret compiles an empty host, so `windowsUpdateFeedUrl()` returns null and every
  update check fails with `UPDATE_FEED_NOT_CONFIGURED` — and the lane still goes green, because
  `05_smoke.ps1` checks the feed under `AWS_PUBLIC_ENDPOINT`, not the binary.
* [ ] `Clingfy_Setup_1.1.0.exe` reachable at `clingfy.com/updates/downloads/windows/`
* [ ] `latest-windows.json` updated and served
* [ ] in-app "check for updates" resolves on a freshly installed 1.1.0

## macOS prod publish

* [ ] appcast still lists 1.0.7 and earlier (history not erased)
* [ ] `Clingfy_1.1.0.dmg` downloads and mounts
* [ ] stapled DMG validated, not the `.app`
* [ ] Sparkle offers the update to an installed 1.0.7

---

# Release Decision

Complete this section after all checks.

* [ ] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* None