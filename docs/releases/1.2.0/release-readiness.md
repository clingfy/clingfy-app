# Release Readiness — 1.2.0

Cut from `develop` on 2026-09-24 at `1.2.0+10`.

1.2.0 is a reliability release. Nothing new is on screen; what changed is that
Clingfy stops getting in the way — a backend error no longer revokes Pro, a
long export or recording is no longer killed by idle sleep, caption edits are
about ten times cheaper, and an export can no longer stop silently under
memory pressure. Full list in `CHANGELOG.md`.

---

# What a machine already settled

These were run on the release commit and need no human. Re-run them if
anything lands on this branch afterwards; they are cheap, and they are the
only items on this page that can be answered without a Mac and a keyboard.

* [x] `dart format --output=none --set-exit-if-changed .`
* [x] `flutter analyze lib`
* [x] `flutter analyze test`
* [x] `flutter build macos --flavor dev`
* [x] `flutter build macos --flavor prod`
* [x] `flutter test` (Dart suite)
* [x] `xcodebuild test -only-testing:RunnerTests` (native suite)

Notes: all seven run on e69ff05, the commit this branch was cut at. Clean: 388
files formatted with no changes, no analyzer issues in `lib` or `test`, both
flavours archived (Release-dev 122.6 MB, Release-prod 108.1 MB), Dart suite
1557, native suite 963 including the heavy export tests the CI fast lane
skips. The only build output is RNNoise's SSE2 `#warning`, expected on this
toolchain and unrelated to this release.

---

# Where to aim this pass

Weight the effort toward EXPORT and RECORDING. Of the changes in 1.2.0, five
touch those paths, including four render hot paths and the export completion
itself:

- #566 export holds a sleep assertion for its whole run
- #569 recording holds one too, including display sleep
- #567 four render loops no longer abandon a frame under memory pressure
- #563 word timings no longer written to `post/state.json`
- #564 subtitle destination is per-recording

**The single highest-value check on this page**, because no automated test can
prove it: after an export finishes, does the Mac go to sleep normally? Two
sleep assertions were added in this release. A leaked one is invisible until
the battery is flat, and it is the exact failure the design was built to
avoid — so it is worth confirming by hand rather than trusting the reasoning.

Second: **pause and resume a recording.** #569 fixed the shipping backend
dropping sleep protection for the length of a pause. Confirm a paused
recording still resumes cleanly and the display does not sleep meanwhile.

Third: **correct a caption on a long transcript.** #563 should make this
noticeably faster, and the `.clingfyproj` bundle noticeably smaller.

Fourth, Windows only: **Alt+Tab away from the timeline and click back.** #577
fixed the scissors tool staying armed over the whole timeline. Selecting,
dragging a clip and scrubbing must all still work.

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

---

# Permissions

Verify permission prompts and recovery flows.

* [ ] screen recording permission request
* [ ] screen recording recovery flow
* [ ] camera permission flow
* [ ] accessibility prompt

Notes:

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

---

# Licensing

Verify licensing and paywall behavior.

* [ ] free trial depletion
* [ ] paywall display
* [ ] license activation
* [ ] expired updates messaging

Notes:

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

---


---

---

# Release Artifact Verification

Against the built DMG, before dispatch.

* [ ] DMG mounts and the app launches
* [ ] app icon and metadata appear correctly (`CFBundleShortVersionString` 1.2.0, prod bundle id, `LSMinimumSystemVersion` 13.0)
* [ ] Gatekeeper accepts it (`spctl -a -t install` → accepted, notarized Developer ID)
* [ ] notarization ticket stapled to the DMG (`xcrun stapler validate`)
* [ ] `SUFeedURL` is the prod appcast and `SUPublicEDKey` matches the repo
* [ ] appcast advertises 1.2.0 and still lists 1.1.0 and earlier
* [ ] in-app "check for updates" resolves on a freshly installed 1.2.0

Notes: these were all verifiable by script for 1.1.0 — download the published
DMG, mount it, read the bundle plist, run `spctl` and `stapler`, and fetch the
appcast. Worth doing the same way rather than by eye.

---

# What could NOT be automated, and why

Everything in the sections above this line needs a human at a Mac. The
Flutter driver reaches the main window's widget tree only: target and display
selection, camera config, settings, the paywall, and the whole
post-processing surface. It cannot reach the separate native windows — the
floating recording indicator (which is where **Stop** lives), the camera
overlay bubble, the area-selection overlay, save dialogs (`NSSavePanel`), or
permission prompts.

So a start-then-stop recording loop breaks at the one button that matters,
and every export item needs a save dialog. Visual and pixel correctness —
orientation, colour, dither, chroma-key edges, "does the zoom look right" —
stays a human judgement regardless.

---

# Release Decision

* [ ] all sections above complete or consciously waived
* [ ] `release/1.2.0` merged to `main`
* [ ] `release-macos-prod.yml` dispatched and green
* [ ] `release-windows-prod.yml` dispatched and green
* [ ] appcast and download page verified live

Notes:
