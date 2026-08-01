# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `v1.0.7`
- Channel: `prod`
- Date: `2026-08-01`
- Verified by: `Nabil Alhafez`
- Commit: `216f1d0`
- Tag: `v1.0.7`
- Build: `Azure prod run TBD` (paste the run number from the pipeline)
- Status: `In progress` — Windows artifact published and verified; manual flows below still open

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
* [x] auto-updater configuration verified
* [x] update channel configuration verified
* [ ] application launches without console errors

## Windows prod publish (verified 2026-08-01)

Published from `release/1.0.7` @ `216f1d0`. Feed:
`https://clingfyreleases.blob.core.windows.net/updates/downloads/windows/latest-windows.json`

| check | result |
|---|---|
| feed reachable + parses | 200, `1.0.7+8`, `channel: prod`, `platform: windows-x64` |
| installer served | 200, 33 390 336 B, matches feed `sizeBytes` |
| **sha256 of the downloaded bytes** | `e9de2b97…2ab55` — matches feed *and* `.sha256` sidecar |
| installer version resource | `FileVersion 1.0.7.8`, `ProductVersion 1.0.7+8`, `ProductName Clingfy` |
| signature | `NotSigned` — expected, decision D3 (no certificate yet) |
| prior release still served | `Clingfy_Setup_1.0.6.exe` → 200 (no orphaned installs) |
| dev feed untouched | still `1.0.6+111` on the dev account |

Updater verified by running the **shipped** parser and decision logic
(`windows/runner/Updater/update_feed.cpp`) against the live feed body, not by
inspection — the smoke step only proves the blob is reachable, and ctest only
proves the logic is self-consistent. Neither would catch a renamed field or a
mispublished channel, which would leave every installed 1.0.6 silently
believing it is current:

| current version | decision |
|---|---|
| prod `1.0.6+7` (the shipped population) | `kUpdateAvailable` |
| prod `1.0.7+8` | `kNoUpdate` (no re-offer) |
| prod `1.0.8+9` | `kNoUpdate` (no downgrade) |
| **dev** build against the prod feed | `kError` (channel isolation holds) |

Not verified here — needs a machine: installing the .exe, first launch,
icon/console errors, and an in-app update from an installed 1.0.6.

Notes:

* The prod lane's version guard ran for the first time this release
  (`Version guard passed: 1.0.7`). It had silently skipped every previous
  release — see `ops/release/windows/RUNBOOK.md` §3.

---

# Release Decision

Complete this section after all checks.

* [ ] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* None