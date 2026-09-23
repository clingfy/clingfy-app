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

* [ ] `dart format --output=none --set-exit-if-changed .`
* [ ] `flutter analyze test`
* [ ] `flutter analyze lib`
* [ ] `flutter build macos --flavor dev`
* [ ] `flutter build macos --flavor prod`

Notes:

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

* [ ] release tooling documented in `ops/release/README.md`
* [ ] `README.md` updated
* [ ] `LICENSE` added
* [ ] `LICENSING.md` added
* [ ] `CONTRIBUTING.md` added
* [ ] `SECURITY.md` added

Notes:

*

---

# Release Artifact Verification

Verify the generated release artifacts before publishing.

* [ ] DMG launches correctly
* [ ] app icon and metadata appear correctly
* [ ] auto-updater configuration verified
* [ ] update channel configuration verified
* [ ] application launches without console errors

Notes:

*

---

# First production run of the GitHub Actions lanes

**`release-macos-prod.yml` and `release-windows-prod.yml` have never executed — 0 runs
ever.** 1.1.0 is their first run, so it doubles as their first test. Everything below was
established by a pre-flight audit on 2026-09-19, before any dispatch.

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