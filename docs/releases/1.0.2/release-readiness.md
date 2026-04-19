# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `1.0.2`
- Channel: `prod`
- Date: `2026-04-19`
- Verified by: `Nabil`
- Commit: `TBD`
- Tag: `v1.0.2`
- Build: `Azure #255` or `GitHub Actions #4`
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

Notes:

*

---

# Recording Flows

Verify the full recording workflow.

* [x] full display recording
* [x] single window recording
* [x] custom area recording
* [x] countdown start
* [x] countdown cancel
* [x] stop flow
* [x] menu bar control
* [x] recording indicator overlay

Notes:

*

---

# Permissions

Verify permission prompts and recovery flows.

* [x] screen recording permission request
* [x] screen recording recovery flow
* [x] camera permission flow
* [x] accessibility prompt

Notes:

*

---

# Overlay / Cursor / Zoom

Verify overlay behavior and cursor/zoom features.

* [x] overlay show/hide
* [x] overlay manual move
* [x] overlay position persistence
* [x] overlay styling options
* [x] overlay linked-to-recording mode
* [x] cursor sidecar capture
* [x] cursor visibility toggle in export
* [x] cursor scaling and highlight
* [x] zoom factor
* [x] zoom follow strength

Notes:

*

---

# Preview / Export

Verify preview playback and export pipeline.

* [x] inline preview playback
* [x] 16:9 preview/export
* [x] 1080p export
* [x] 1440p export
* [x] 2160p export
* [x] MP4 export
* [x] MOV export
* [ ] GIF export
* [x] background image export
* [x] background color export
* [x] save folder selection

Notes:

*

---

# Licensing

Verify licensing and paywall behavior.

* [x] free trial depletion
* [x] paywall display
* [x] license activation
* [x] expired updates messaging

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

Notes:

*

---

# Release Artifact Verification

Verify the generated release artifacts before publishing.

* [x] DMG launches correctly
* [x] app icon and metadata appear correctly
* [x] auto-updater configuration verified
* [x] update channel configuration verified
* [x] application launches without console errors

Notes:

*

---

# Release Decision

Complete this section after all checks.

* [x] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* None