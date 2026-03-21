# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `1.0.1`
- Channel: `prod`
- Date: `2026-03-21`
- Verified by: `Nabil`
- Commit: `TBD`
- Tag: `v1.0.1`
- Build: `Azure #255`
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
flutter analyze
flutter test
flutter build macos --flavor dev
flutter build macos --flavor prod
```

Checklist:

* [x] `flutter analyze`
* [x] `flutter test`
* [x] `flutter build macos --flavor dev`
* [x] `flutter build macos --flavor prod`

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

# Release Decision

Complete this section after all checks.

* [ ] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* None