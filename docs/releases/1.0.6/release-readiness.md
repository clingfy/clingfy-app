# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `v1.0.6`
- Channel: `prod`
- Date: `2026-07-22`
- Verified by: `Nabil`
- Commit: `ff5d172`
- Tag: `v1.0.6`
- Build: `Azure #255` or `GitHub Actions #4`
- Status: `Released`

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

* [X] `dart format --output=none --set-exit-if-changed .`
* [X] `flutter analyze test`
* [X] `flutter analyze lib`
* [X] `flutter build macos --flavor dev`
* [X] `flutter build macos --flavor prod`

Notes:

*

---

# Recording Flows

Verify the full recording workflow.

* [X] full display recording
* [X] single window recording
* [X] custom area recording
* [X] countdown start
* [X] countdown cancel
* [X] stop flow
* [X] menu bar control
* [X] recording indicator overlay

Notes:

*

---

# Permissions

Verify permission prompts and recovery flows.

* [X] screen recording permission request
* [X] screen recording recovery flow
* [X] camera permission flow
* [X] accessibility prompt

Notes:

*

---

# Overlay / Cursor / Zoom

Verify overlay behavior and cursor/zoom features.

* [X] overlay show/hide
* [X] overlay manual move
* [X] overlay position persistence
* [X] overlay styling options
* [X] overlay linked-to-recording mode
* [X] cursor sidecar capture
* [X] cursor visibility toggle in export
* [X] cursor scaling and highlight
* [X] zoom factor
* [X] zoom follow strength

Notes:

*

---

# Preview / Export

Verify preview playback and export pipeline.

* [X] inline preview playback
* [X] 16:9 preview/export
* [X] 1080p export
* [X] 1440p export
* [X] 2160p export
* [X] MP4 export
* [X] MOV export
* [ ] GIF export
* [X] background image export
* [X] background color export
* [X] save folder selection

Notes:

*

---

# Licensing

Verify licensing and paywall behavior.

* [X] free trial depletion
* [X] paywall display
* [X] license activation
* [X] expired updates messaging

Notes:

*

---

# Repo / Docs Hygiene

Ensure repository documentation and release tooling are in place.

* [X] release tooling documented in `ops/release/README.md`
* [X] `README.md` updated
* [ ] `LICENSE` added
* [ ] `LICENSING.md` added
* [x] `CONTRIBUTING.md` added
* [ ] `SECURITY.md` added

Notes:

*

---

# Release Artifact Verification

Verify the generated release artifacts before publishing.

* [X] DMG launches correctly
* [X] app icon and metadata appear correctly
* [X] auto-updater configuration verified
* [X] update channel configuration verified
* [X] application launches without console errors

Notes:

*

---

# Release Decision

Complete this section after all checks.

* [X] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* None