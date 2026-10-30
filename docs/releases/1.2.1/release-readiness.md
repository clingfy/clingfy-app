# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `v1.2.1`
- Channel: `prod`
- Date: `2026-10-29`
- Verified by: `TBD`
- Commit: `TBD`
- Tag: `v1.2.1`
- Build: `TBD` (the run id of the lane that built it)
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

* 2026-10-29, on `release/1.2.1` at prepare time: format and both analyzes clean,
  1721 Flutter tests pass. Both flavours built as Release; the bundles read
  1.2.1 with `com.clingfy.clingfy.dev` / `com.clingfy.clingfy`, and the dev
  Release build launched without errors. The pipeline rebuilds and signs; these
  are the prepare-time results, not the shipped artifacts.

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
---

# Windows beta notes (1.2.1)

develop was merged into this branch on 2026-10-30 so 1.2.1 ships the Windows
parity work on both platforms from one tree.

* Parity work W1-W13 (#635-#651) is in. The owner tested the Windows build on
  the dev box on 2026-10-30 before the merge.
* The live cursor highlight (#647) and Reveal Area outline (#648) are built
  but their controls stay **hidden** in this release (owner's call). Unhide
  them later by removing the `!isWindows()` gates in
  `recording_options_sidebar.dart` and `recording_source_section.dart`.
* "Exclude Clingfy from capture" is not built on Windows
  (`setExcludeRecorderApp` is a no-op).
* The Windows build ships unsigned, as before. Signing is not planned.
* The merge brings Windows-only native code plus shared Dart changes
  (#650 removed the Windows post-audio export notice). Re-run the macOS
  smoke on the merged tree before the prod build.
