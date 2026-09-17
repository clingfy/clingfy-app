# TODOS

Deferred work captured during reviews. Each item has enough context to pick up cold.

## Editor — clip lane

### Persistent scissors tool mode (Premiere-style razor)
- **What:** A button-activated cut tool that stays active across multiple cuts without holding a modifier.
- **Why:** Some users coming from Premiere/Final Cut expect a sticky "blade" tool (select tool ↔ razor tool).
- **Context:** Deferred in the 2026-06-28 eng review of the scissors-split feature. We shipped modifier-click instead (hold Option → cut at pointer) because a persistent opaque overlay fought the timeline's scroll/pan and the trim-handle gestures, and put interaction state in lib/core where it didn't belong. The modifier-click approach delivers the same cut-at-pointer with none of those conflicts. See the design doc `*-scissors-split-design-*.md` in the gstack project dir for the full rationale (objections 1-4).
- **Pros:** Familiar to pro-editor users; no key to hold for long cutting sessions.
- **Cons:** Modal UX (the friction casual users complain about); reintroduces the gesture-conflict landmines the modifier approach avoided.
- **Start at:** `lib/app/home/preview/widgets/video_timeline.dart` (mode state would live local in `_VideoTimelineState`, next to `_panModeEnabled`), `lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart` (a non-opaque hit layer inside `TimelineScrollableCanvas`).
- **Depends on:** The modifier-click cut layer landing first (this is its evolution).
- **Gate:** Only build on real user demand.

### Frame-preview (previewPeekTo) on the clip lane during cut-hover
- **What:** Extend the hover→`previewPeekTo` pipeline to the clip-lane region, not just the ruler, while cut-hovering.
- **Why:** Today hover-peek is wired only on the ruler strip (`timeline_editor_viewport.dart:489-494`). With modifier-click cutting, hovering the lane shows a guide line but not the actual frame you're about to cut on — so cuts on the lane area are "blind."
- **Context:** Raised by the outside-voice review (2026-06-28). Enhancement, not required for the scissors-split feature to work.
- **Pros:** You see the exact frame under the cut point anywhere on the timeline, not just on the ruler.
- **Cons:** More hover→native traffic on the lane; needs the same coalescing/peek-end hardening the ruler path already has.
- **Start at:** `lib/app/home/preview/widgets/video_timeline.dart` (`onHoverSeek`/`previewPeekTo` wiring), `lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart`.
- **Depends on:** Scissors-split cut layer (shares the cut-hover state).

## Editor — captions

### Word-level caption editing (click a word to edit, drag to retime)

- **What:** Click an individual word in a caption to edit just that word, and drag
  a word's boundary to retime it, rather than editing the whole cue as one string.
- **Why:** `CaptionWord` (`lib/core/timeline/model/edit_track.dart:201-222`) exists
  and its own doc comment says it "powers click-to-edit and reflow-on-split."
  Half of that shipped: reflow-on-split uses the timings when a cue's audio is cut
  in half. The click-to-edit half did not. Without this entry, the next person
  reads that comment and assumes the feature exists.
- **Context:** Deferred in the 2026-08-04 eng review (scope reduction R2). v1 ships
  cue-level text editing, which satisfies the actual need — fixing a
  mis-transcribed product name — at a fraction of the UI. Per-word timings are
  stored by ASR regardless, so this is additive later, not a rewrite. The reason to
  wait is that nobody has seen real transcription quality on real Clingfy
  recordings yet; if Whisper turns out to be accurate enough that people rarely
  edit, this is UI nobody wanted.
- **Pros:** Precise corrections without retyping a sentence; retiming without
  touching text.
- **Cons:** Substantially more interaction surface (per-word hit targets, drag
  handles inside a text run, RTL word order), and it fights the cue-level editor
  you would already have shipped.
- **Start at:** `lib/app/home/post_processing/widgets/post_captions_section.dart`
  (once it exists), `CaptionWord` in `edit_track.dart:201`.
- **Depends on:** the cue-level caption editing UI shipping first.
- **Gate:** Only build on real user demand, same rule as the persistent-scissors
  item above.
- **Effort:** human ~2d / CC ~2h.

## Export — colour

### Grade the validator's reference on the two CAMERA paths

The direct (screen-only) path is DONE: `evaluateFinalExportReferenceRender` now
grades its own reference via `gradeReferenceImage`, so a graded export is measured
again instead of skipped. Measured across the whole slider range, every grade
collapses onto the identity floor — light-mode SLIDER MAX went 0.2784 → 0.0032,
exposure −1.00 went 0.4789 → 0.0015, and the worst residual anywhere is 0.0252 on
the dark fixture against a 0.18 budget. `ColorGradeValidatorMarginTests` pins it.

**Two paths still SKIP when a grade is active, and both should eventually measure.**

**1. The inline-camera reference** (`evaluateFinalExportReferenceRender`, the
`inlineCameraRenderPlan != nil` branch).
- Its reference is not a sampled composition frame but a re-composite via
  `InlineCameraRenderer.makeCompositedImage`, and the writer grades only the SCREEN
  sub-image there — `CameraStyledIntermediatePipeline.swift:927-932` deliberately
  leaves the camera bubble and resolved background ungraded to match the live
  preview. So the grade has to go on the screen input, not the composite.
- **Watch the margins.** Inline compositions render the screen on a transparent
  background. If `AVAssetImageGenerator` hands back an OPAQUE image, grading it
  grades the padding margins too — pixels the writer effectively leaves alone
  because alpha-0 survives its filter chain. Measure `screenImage.alphaInfo` and the
  minimum alpha in the margin on a padded fixture BEFORE grading the whole frame.
- **There is also a pre-existing colour-space wrinkle here**, worth fixing in the
  same pass: the branch feeds a GenericRGB-tagged CGImage straight into
  `CIImage(cgImage:)`, so Core Image applies a gamma-1.8 → sRGB conversion the
  writer never does (pure blue 0,0,255 → 5,51,255, up to ~0.2 — wider than the
  budget). Declare `.colorSpace: VideoColorPipeline.workingColorSpace`
  unconditionally so identity and graded share one baseline, and re-baseline the
  inline exporter tests in the same change rather than keeping a known-wrong
  ungraded path for byte-identity's sake.

**2. `validateFinalStyledCameraExport`.**
- Same skip, and it also deletes the export.
- It CROPS to the camera bubble, and the two sides are cropped out of images at very
  different resolutions: the reference off the composition, the final off a 64-capped
  sample. `cropCandidates` scales the rect by image width and snaps with `.integral`,
  so on a 960x540 canvas a 160px bubble becomes an ~11px window whose rounding is ~9%
  of the crop — and a grade multiplies that misalignment by its own gain. The direct
  path has no crop and no such amplifier, so do NOT assume the direct path's 0.0252
  residual carries over.
- `_testValidateFinalStyledCameraExport` does not accept a `colorGrade` yet. Add it
  (plus `captions:`/`keptRanges:`) and build a pre-styled-camera fixture —
  `cameraAsset:` non-nil with `cameraParams:` set so `comp.validationInfo` is
  populated and `comp.inlineCameraRenderPlan == nil` — then print that validator's
  crop-pair deltas per grade alongside an identity control. If the graded row is more
  than ~3x its own identity control, the crop alignment is the cause and the bubble
  crop needs padding, not a looser threshold.

**Do not un-skip either one without a fixture that measures it first.** Un-skipping a
validator that calls `removeFileIfExists` with nothing measured behind it is exactly
how the original defect shipped.

**Do not "fix" this by forcing full-resolution reference sampling.** That was tried on
paper and is backwards: the final file is always sampled with `videoComposition: nil`,
so it is ALWAYS 64-capped by `sampleFrameImage`, and it was graded at full resolution
by the writer before that. Both sides are already grade-then-downsample in that order,
which is what has to match — forcing the reference full-size breaks the symmetry.

**Still unanswered:** should the pre-styled camera bubble receive the grade at all?
The inline path explicitly does not grade it; the pre-styled path grades it as part of
the whole canvas. Those disagree today, and that is a product question, not a
validator one.

**Also still open:** `CompositionParams.colorGrade` (`CompositionBuilder.swift:1217`)
is still declared and never read. Deleting it is behaviourally inert — nothing compares
two `CompositionParams` — but `docs/editing-platform-plan.md:369-375` still names
`CompositionBuilder` as the export-bake seat. Decide whether the composition will ever
be grade-aware before removing the field.

### RESOLVED (1.0.7) — exported video did not match the inline preview's colour

Filed 2026-07-28 (#369), closed by the 1.0.7 cycle. Kept for the measurements,
which are the only recorded numbers for this defect.

- **The symptom, measured:** sampling matching wallpaper patches (decoded to sRGB
  so both are compared in one space) gave export-minus-preview deltas of roughly
  `+9 +7 +9`, `+5 +11 +9`, `+16 +17 +14` (R G B, 0-255). The export was lifted
  overall and **midtones lifted most** — one patch went green `68 -> 79` while red
  in the same patch went `29 -> 34`. That is a transfer-function signature, not a
  matrix error, which is what pointed at the right fix.
- **Fixed by:** #380 and #383 (encode into the transfer the file declares), #391
  (use the gamma Apple's decoder actually applies), #395 (route every export
  through the path that encodes colour), #396 (GIF undoes the export transfer),
  #402 (camera overlay was encoded twice), #404 (record in sRGB so the BT.709 tag
  on `screen.mov` is honest). CHANGELOG 1.0.7: "Exported colour matches the
  preview... Fixed on every export path, including GIF."
- **Do not re-open on the dual tagging.** `VideoColorPipeline.tag(pixelBuffer:)`
  (`CompositionBuilder.swift:118-140`) still attaches
  `kCVImageBufferCGColorSpaceKey = sRGB` alongside a 709 transfer tag. That is now
  **intentional**: sRGB is the working space, and
  `ColorTransferFunctions.encodeForExport` puts the data into the 709 transfer the
  file declares. The original TODO listed this as suspicious; it is the design.
- **Caveat that is still true:** recordings made before 2026-08-02 hold P3 data
  under a 709 tag. Re-exporting an old project still looks desaturated. Expected,
  and recorded in the CHANGELOG.

## Editor - layout

### The clips lane is below the fold in the editor, at every window height tested

> **STATUS 2026-09-15 — DOES NOT REPRODUCE on develop @ `a01467f`. Not closed.**
> Re-measured with the same project and the same window size, and the ruler, clips
> lane and zoom lane all render fully on screen. Details in "Re-measured" below.
> Left open rather than deleted because the 2026-09-12 sighting was a human looking
> at a real screen, and because every Dart file behind this layout is byte-identical
> between that sighting and this clean result.
>
> **2026-09-16: that byte-identical diff is no longer evidence of "nothing changed".**
> #496 fixed an INTERMITTENT layout exception that was present on both dates, so the
> same code legitimately misbehaves one day and not the next. See "Candidate cause"
> below — it fits, it is not proven, and its one weak spot is named there. Close this
> entry once a second machine confirms a clean editor; re-open with a DPI-aware
> capture if it returns.

- **What:** open a recording, and the timeline toolbar and transport bar render but the
  TimelineEditorViewport (ruler + clips/zoom lanes) sits below the bottom of the window.
  No cutting, trimming, reordering or zoom editing is reachable.
- **Measured 2026-09-12, Release AND Debug builds, project rec_1784676792947794 (26 s, 1 clip):**
  - 1550x830 window on a 1536x864 display (1080p at Windows' default 125% scaling): lane not visible.
  - 1550x830 after the density fix below (chrome ~8% smaller): still not visible.
  - **2062x1118 window on a 2048x1152 display: STILL not visible** - the toolbar sits ~50 px from
    the window bottom. That is what rules out "the window is just too short".
- **Not a lane-visibility toggle.** `_showClipsLane = true` and `_showZoomLane = true` are the
  defaults (`video_timeline.dart:101-105`), and the debug log confirms the lane is live:
  `[ClipsLane] clip editor attached (1 clips, dur=26082ms)`.
- **Not a RenderFlex overflow.** A Debug build produced ZERO overflow or constraint assertions
  across the whole session, at both window sizes. Whatever clips the viewport is not a Flex
  overflow, so the usual yellow-stripe signal never fires and Release clips silently.
- **Structure, for whoever picks this up:** `home_shell.dart:600` is
  `Column[ Expanded(pane row), SizedBox(innerGap), TimelineBar() ]`. The pane row carries
  `ConstrainedBox(minHeight: HomeDesktopPaneDimensions.workspaceMinHeight = 520)`, which a tight
  Expanded constraint should override. `TimelineBar` -> `VideoTimeline` builds
  `Column[ TimelineToolbar, gap, TimelineTransportBar, gap, TimelineEditorViewport ]`
  (`video_timeline.dart:~540-612`), and the viewport computes its own height as
  `ruler + lanes*laneHeight + gaps` (`timeline_editor_viewport.cpp:155-160` / `:412-420`).
  The toolbar and transport render; only the viewport does not.
- **Re-measured 2026-09-15, develop @ `a01467f`, Debug build, same project
  rec_1784676792947794.** The lane renders. Two window sizes, both DPI-aware captures:
  - **1937x1037 real px** (client 1919x990) — this IS the "1550x830 on a 1536x864 display"
    case above, written in real pixels rather than virtualized ones. Ruler 0:00-0:25,
    Clips lane with the clip labelled "1", Zoom lane with three segments. All visible.
  - **1250x800 real px** (client 1232x753) — the smallest window the app allows
    (`kMinimumDesktopWindowSize = Size(960, 640)`, `lib/app/bootstrap/desktop_window.dart:8`).
    Same three, all visible. If the defect were height-driven it would show here first.
  - The render tree agrees and always did: `VideoTimeline` sits at column offset
    (0, 525.3) with height 251.5 = header 48.0 + 5.5 + transport 42.2 + 5.5 +
    **viewport 150.3**, inside a tight 776.8-tall `home_workspace_column` whose five
    children sum to exactly 776.8. No overflow, nothing clipped, viewport on screen.
  - **No layout fix landed in between, and this is checked, not assumed.**
    `git diff eef38a5 a01467f -- lib/` returns exactly one file:
    `lib/core/bridges/native_bridge.dart` (the unrelated project-open drain fix,
    #493). `eef38a5` is the density fix #484 — i.e. the very commit this entry's own
    "after the density fix ... still not visible" line was measured against. So every
    Dart file that produces this layout is **byte-identical** between the 2026-09-12
    sighting and the 2026-09-15 clean result. Same code, same project, same window
    size, opposite outcome. (Native changed over that window — #486-#490 — but that
    is the camera render-plan seam in `Capture/Camera/`, which has no part in
    Flutter-side timeline layout.)
  - That is the useful lead for whoever picks this up: since the code is identical,
    the difference has to be environmental or in the original measurement. Prime
    suspects, in order: display scale / which monitor the window was on (this box has
    a 1920x1080 @125% primary and a 2560x1440 @125% secondary), and the possibility
    that the 09-12 numbers were themselves read through a DPI-unaware tool — the same
    trap documented below, which produces this exact symptom.

- **BEWARE the instrument — this cost an afternoon.** An initial re-measurement
  "reproduced" the bug perfectly, matching this entry detail for detail including a
  convincing inverse-height ladder. It was an artifact. Screenshots were taken from a
  **DPI-unaware** PowerShell: `GetWindowRect`/`GetClientRect` returned virtualized
  1550x830 / 1536x792 while the real window was 1937x1037 / client 1919x990, the
  capture bitmap was allocated at the virtualized size, and `PrintWindow` **crops**
  into an undersized DC instead of scaling. That silently removed the bottom ~20% of
  every screenshot — exactly where the viewport lives. Before trusting any capture
  here, call `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  as the FIRST statement, and multiply any size a DPI-unaware tool quotes by the
  display scale. When a screenshot and the render tree disagree, suspect the capture.
  (Unrelated red herring: `debugDumpRenderTree` prints `device pixel ratio: 1.3` because
  it formats to one decimal. The real ratio is 1.25. There is no double-scaling defect.)

- **The widget test does NOT cover this.**
  `test/app/home/preview/widgets/timeline/timeline_viewport_visibility_test.dart` (#491)
  pins the viewport on screen at 1550x830 under the real Windows `ResponsiveShellScope`
  and is green — it was green while this entry described a live bug, and it would stay
  green if the bug returned in whatever form the harness does not model. Do not read
  that suite passing as evidence about this entry either way.

- **Candidate cause found 2026-09-16: the pane-remount layout exception fixed by #496.**
  Not proven — but it is the first hypothesis that fits the awkward facts, and it is
  falsifiable, so it beats "unexplained".
  - #496 fixed `_buildPane` swapping the pane child's widget TYPE when
    `preserveChildLayout` flipped. `Widget.canUpdate` failed, the pane was
    deactivated and remounted, its GlobalKey was retaken, and
    `Element._activateRecursively` re-adopted any showing `OverlayPortal`
    (a Material `Tooltip`) into the root `_RenderTheater` — calling
    `markNeedsLayout` from inside `DesktopSplitLayout`'s
    `LayoutBuilder.performLayout` (`desktop_pane_layout.dart:379-382`).
  - **Why the byte-identical diff above is not evidence against it.** That defect
    was present on BOTH dates. It is intermittent: it needs an OverlayPortal
    actually showing at the instant the rail width settles. So identical code
    producing a sighting one day and not the next is exactly what it predicts —
    which is what made the 09-15 "does not reproduce" so confusing.
  - **The subtree matches.** The LayoutBuilder that throws is the one laying out
    every pane slot, including `desktop_pane_slot_homeWorkspaceColumn` → the
    `home_workspace_column` whose child 5 IS the timeline. A `performLayout` that
    throws mid-way leaves that subtree incomplete.
  - **It also explains who saw it.** Seven occurrences were logged on this machine
    in a single day during ordinary use (hovering sidebar buttons). Automated
    driving — open by argv, screenshot, resize — almost never hovers, which is
    why the bug reproduced for a human and not for a scripted repro.
  - **The honest weakness, stated so nobody treats this as closed.** The 09-12
    symptom was SELECTIVE: toolbar and transport rendered, only the viewport did
    not. A layout abort would be expected to disturb the whole column, not just its
    last child. Until that is explained, this is a lead, not a cause.
  - **What would settle it:** on a pre-#496 build, make the exception fire with a
    project open and see whether the viewport disappears. Attempted 2026-09-16 and
    NOT achieved — the exception could not be provoked on demand (a synthetic
    cursor park did not raise a real tooltip; the natural occurrences all came from
    ordinary interactive use). Do not repeat the synthetic-hover approach; drive it
    by hand, or add a temporary counter at the `_activateRecursively` site.

- **Next step:** confirm on a second machine, ideally one at a different display scale
  (this box is 125%). If it stays clean, close this entry. If it returns, capture it
  DPI-aware and dump the render tree (`debugDumpRenderTree()`) with a project open to
  find who gives the viewport a zero/negative height box or which ancestor clips it —
  reading the widget code did not settle it, and three plausible theories were each
  disproved by measurement. Also check the log sink for
  `_RenderLayoutBuilder was mutated` around the sighting: since #496 landed that
  should be absent, and if the lane ever goes missing WITH that error absent, the
  candidate above is refuted.
- **Severity:** if this reproduces on a tester's machine it blocks the whole editor, which is the
  half of the product that is not the recorder. Worth confirming on a second machine before the
  beta invite, since it did not reproduce as a simple height problem. Severity is unchanged by
  the 09-15 re-measurement — a defect that cannot be reproduced is not the same as one that is
  understood, and this one is still not understood.
- **Effort:** unknown. The 09-12 investigation cost ~1h and disproved the obvious causes without
  finding the real one; the 09-15 re-measurement cost an afternoon, most of it spent chasing a
  false repro manufactured by the capture tool.

## Windows — recording engine teardown

### A recording Start/Stop/Start can hang — in product code, cause still unknown

- **What:** `RecordingEngineTest.StartAfterStopIsAllowed` hangs indefinitely.
  Silent: no exception, no log, the process stops. Same test and same signature
  as the 43-minute CI timeout on run 35007670584.
- **It is in the TEST BODY, not the harness — measured, not assumed.** Fixture
  probes showed `[fixture] SetUp done` with no `TearDown begin`, so the block is
  inside the body's real `Start` -> `Stop` -> `Start` on the engine. This is a
  product path: stop a recording, immediately start another.
- **Repro:** two `runner_tests` processes running
  `--gtest_filter=RecordingEngineTest.*` concurrently, so they contend for the
  real capture devices. See the frequency table below.
- **SEVEN hypotheses refuted by measurement.** Each looked right and each was
  wrong; do not re-chase them without new evidence:
  1. sidecar `Cancel()` mutex contention — `Cancel: locking` -> `locked` printed
  2. `FinalizeAudioSidecars` blocking — `FinalizeAudioSidecars done` printed
  3. `IMFSinkWriter::Finalize` blocking — `IMFSinkWriter returned` printed
  4. DXGI device-manager release — `dxgi_manager released` printed
  5. teardown generally — `teardown complete` printed, every time
  6. shared test sandbox as the CAUSE — still hangs with per-process dirs
  7. fixture cleanup (`remove_all`) — `TearDown begin` never reached
- **Where it has NOT been narrowed past:** after `Stop()`'s teardown completes.
  Remaining candidates are the rest of `Stop` (project-bundle write, workflow
  events, temp cleanup) and the SECOND `Start`. Probes for those were added but
  the run that carried them went 25/25 clean, so they never fired.
- **Test isolation changes the ODDS, measured over seven runs:**

  | sandbox | hang first seen at iteration |
  |---|---|
  | shared `%TEMP%clingfy_engine_test_recordings` | 5, 2, 4, 1 |
  | per-process (PID-suffixed) | 15, 14, none in 25 |

  Every shared-dir run hung by iteration 5; no per-PID run hung before 14. The
  per-PID change has landed, so the repro is now RARER — budget more iterations.
  It is a flakiness reduction, NOT a fix: rounds 6 and 7 hung with it in place.
- **Severity:** a hang in Start/Stop is an app that never returns from stopping a
  recording. Under contention here; a headless CI runner reaches it too.
- **Next step:** re-run the recipe with the `Stop:`/`Start: enter` probes until it
  hangs (expect 15+ iterations). If it lands on `Start: enter`, the bug is
  restarting capture too soon after releasing the device — which is exactly what
  this test's name describes. A debugger would be faster than printf from here;
  this machine has no cdb/windbg/procdump.
### `TeardownPipeline` can join a thread from itself (`resource deadlock would occur`)

- **What:** under capture/audio device contention, most `RecordingEngineTest`
  Start/Stop cases throw
  `C++ exception with description "resource deadlock would occur"`.
  That is `EDEADLK` from `std::thread::join()`, which C++ raises for exactly one
  reason: **a thread joining itself**. So `RecordingEngine::TeardownPipeline`
  (`recording_engine.cpp:1960`) is reachable from a thread it then tries to join.
- **10-second repro (2026-09-16).** Run two copies of the recording tests at once
  so they contend for the real screen/audio devices:

  ```bash
  EXE=./build/windows-tests/runner_tests/Debug/runner_tests.exe
  "$EXE" --gtest_filter='RecordingEngineTest.*' > a.log 2>&1 &
  "$EXE" --gtest_filter='RecordingEngineTest.*' > b.log 2>&1 &
  wait; grep -c "resource deadlock" a.log b.log
  ```

  Measured over three rounds: **17-20 deadlock throws and 35-41 failed tests per
  process, every round.** A single process passes cleanly (963 ms), so this is
  device contention, not test ordering.
- **Likely path:** `TeardownPipeline` is called from failure/callback sites, not
  just from `Stop`. The target-loss handler at `recording_engine.cpp:1844`
  ("window closed" / "display disconnected") tears down from what is plausibly a
  capture-backend callback thread. Note the ordering inside `TeardownPipeline`:
  `camera_floating_->Stop()`, `capture_backend_->Stop()`, `mic_capture_->Stop()`,
  `loopback_capture_->Stop()` all run BEFORE the joins, so a blocking `Stop()`
  never reaches them at all.
- **NOT the same thing as the CI hang — do not conflate them.** The CI failure
  (run 35007670584, `RecordingEngineTest.StartAfterStopIsAllowed`) was a SILENT
  43-minute hang with no exception. This repro throws and FAILS in ~23ms. They
  may share a root cause — device absence on a headless runner and device
  contention here could reach the same failure path — but that is a hypothesis,
  not a finding.
- **Ruled out by measurement:** the fixture's shared sandbox
  (`%TEMP%\clingfy_engine_test_recordings`, `recording_engine_test.cpp:39`) is a
  real cross-process isolation smell — every process `remove_all`s the same
  directory — but making it per-PID left the deadlock counts **identical**
  (19/18 → 20/18). It is not the cause. Worth tidying for `ctest -j`, but do not
  sell it as a fix.
- **Severity:** in a test it is a failed assertion. In the app, an exception
  escaping a capture callback during teardown is a crash, and teardown runs on
  the path that finalizes the user's recording. Worth understanding before the
  beta widens.
- **Next step:** capture a stack at the throw (run under a debugger with
  `--gtest_filter='RecordingEngineTest.StopReturnsToIdle'` and the contending
  process running) to confirm which thread calls `TeardownPipeline`. Fix shape,
  once confirmed: never join the calling thread — compare
  `std::this_thread::get_id()` against each thread id and defer or detach — but
  do not change teardown threading on the hypothesis alone.

## Windows — capture exclusion

### The other four capture-excluded windows never re-verify WDA after a mutation

- **What:** the ADR (`docs/decisions/windows-camera-bubble-renderer-architecture.md:123-126`) says to re-verify `GetWindowDisplayAffinity` after any unavoidable window mutation — the Electron #47834 lesson. The DComp camera overlay now does, at all three of its mutation sites. Four other capture-excluded windows still call `SetWindowDisplayAffinity` exactly once at creation and then mutate freely:
  - `camera_floating_overlay.cpp` — `SetWindowPos` (:425), `SetWindowRgn` (:393), `WM_EXITSIZEMOVE` drag path (:125)
  - `recording_indicator_controller.cpp` — `SetWindowPos` (:336, :358), `SetWindowRgn` (:199), drag path (:103)
  - `pre_recording_bar_controller.cpp` — :341, :212
  - `pre_recording_bar_popover.cpp` — :203, :262
- **Why not folded into the camera fix:** none of these has the DComp overlay's `wda_excluded_` one-way latch or its hide-on-loss policy, so there is nothing to re-verify *into*. Giving them one is a design decision about what a bar/indicator should do when exclusion is lost mid-recording — hide (and lose the recording UI) or keep showing (and burn into the capture). That is a product call, not a few lines.
- **Severity:** the same class as the camera bug, and the indicator/bar are on screen for the whole recording. Worth deciding rather than leaving implicit.
- **Effort:** human ~1 day / CC ~2h once the hide-vs-show policy is chosen.

## Windows — preview/export parity

### ~~Camera border width and shadow blur are raw pixels on both surfaces (preview reads ~3x heavier)~~ — DONE

Fixed. The wire value stays absolute export-canvas px (no wire change, so macOS is
untouched) and the painter resolves it onto whatever surface it is drawing, via
`CameraBubblePainter::Style::effect_scale` =
`short_side(surface) / short_side(export)`. The bubble's 96px min-side floor —
the other non-proportional term, which bound for most of the size-factor band in
portrait/reel916 — takes the same scale through a defaulted
`ComputeCameraBubbleRect(..., min_side_px)` parameter.

Residual, deliberately not fixed here: the LIVE overlay has the same class of
defect internally (`ComputeFloatingRect` scales the bubble by `dpi_scale` while
`ResolveOverlayBubbleStyle` passes `border_width` through unscaled), so at 150%
display scaling the live bubble's border is proportionally thinner than at 100%.
Separate surface, separate fix, and macOS shares the absolute constants — raise
it with macOS in scope rather than diverging one platform at a time.

### Should the live camera bubble hide while a recording is paused? (product call)

- **What:** `RecordingEngine::Pause` pauses the camera recorder and `CameraRecorder` drops every preview frame while paused, but nothing hides or stops the floating bubble. It stays on screen showing its last frame for an unbounded, user-controlled time.
- **Why it is on this list and not already fixed:** it surfaced while closing the frameless-park gap, which needed to know every way frames stop. The park fix makes the stale-pixels case safe (a parked presenter now hides its own window), but a PAUSE is not a fault — the bubble is deliberately still up, showing a frozen frame. Whether that is correct is a product decision, not a bug fix, so it was left alone rather than changed unasked.
- **The argument for hiding:** a paused recording showing a live-looking camera bubble misrepresents state, and it is the widest window in which a mid-session presenter swap would surface an empty bubble.
- **The argument against:** the bubble is also the user's placement handle; hiding it mid-session moves it out of reach and makes resume feel like a restart.
- **Start at:** `RecordingEngine::Pause` / `Resume`, mirroring the `wda_excluded()` gate `SetCameraPreviewFloating` already uses. macOS parity should be checked first — it may already have an answer.
- **Effort:** human ~2h / CC ~20min once the product call is made.

### Camera render-plan extraction (make derivation parity structural, not just tested)

> **STATUS 2026-09-14 — DONE. All six steps landed; both legs share one derivation.**
> #486 moved the style into the D2D-free header and made the painter retry term testable. #487 added
> `Capture/Camera/camera_render_plan.{h,cpp}` with 16 headless tests. #488 moved the preview leg onto it.
> #489 embedded `CameraRenderSpec` in both export carriers, deleting the bridge mapper and the 24-line
> copy hop. The final step moved the export leg on: `CameraExportRenderer::Prepare` went from 14
> parameters to 3, its eight cached members collapsed to one plan, and the pipeline's ~45-line
> hand-rolled derivation became one `CameraPlanForExportRequest` call.
>
> The two legs can no longer drift, because there is ONE derivation rather than two that agree.
> `CameraExportRenderer::Style` no longer appears anywhere under `Capture/Export/`.
>
> **Still open, and NOT closed by this work.** Deleting `render.camera = input.camera;` in
> `ExportPassthroughCopy` still passes the whole suite: that hop runs inside a function whose
> `PassthroughResult` does not expose the `RenderRequest`, so nothing headless observes it. Fix by
> extracting the gate-and-fill into a pure helper, or by widening the export pixel canary to cover the
> camera path.
>
> **Unclosed by design:** the macOS clamp divergence — macOS `clampPresentationFrame` shrinks to fit and
> insets by a border/shadow outset, while `camera_export_layout.cpp` only translates — and the live DComp
> overlay, which stays off the shared builder deliberately because it derives from a different wire model
> and clamps where this path does not.

- **What:** Both surfaces independently derive the same five things from their parsed composition — bubble rect, painter `Style`, `CameraAnimationParams`, slide edge, and the shape/radius/content-mode passed to `painter_.Prepare`. The derivations are currently line-for-line equivalent (audited field by field), but that equivalence is maintained by hand in two files.
- **Proposed seam — CORRECTED 2026-09-12 after an audit of both legs. The signature first written here was not a pure refactor; it was a behaviour change on both surfaces.** Two fixes are mandatory before any code moves:
  1. **`BuildCameraRenderPlan` needs `effect_scale`.** The preview passes an 8th argument to `ComputeCameraBubbleRect` (`kCameraBubbleMinSidePx * scale`) and sets `Style::effect_scale = scale`; the export passes neither and takes the 96.0 / 1.0 defaults. That is not drift — it is the preview leg's reason to exist (a 1280x720 texture against an up-to-4K export canvas) and four tests pin it. A builder taking only `(spec, canvas_w, canvas_h)` cannot produce the preview's plan, and dropping the scaling regresses reel-format previews ~32% oversize.
  2. **`ResolveCameraFrame` needs six inputs, not four.** Both `Draw` methods take `(ctx, frame_ms, total_duration_ms, screen_zoom, zoom_in_segment, zoom_segment_local_ms)`. The last two drive the zoom-emphasis pulse, and **both headers carry an explicit "Deliberately NOT defaulted" comment** saying a default would let a new call site compile while silently never pulsing. A 4-argument signature reintroduces exactly that hazard.
- **Most of the seam already exists.** ~~`ResolvePreviewCameraPlan(comp, canvas_w, canvas_h, effect_scale)` is already in `preview_camera_renderer.h`, already pure, and already pinned by `ResolvePreviewCameraPlanTest.IdentityScaleMatchesTheExportPlanExactly`.~~ **Superseded 2026-09-14:** that function and that whole test suite are gone. The generalised builder is `clingfy::capture::BuildCameraRenderPlan` in `Capture/Camera/camera_render_plan.h`, and the named test migrated to `BuildCameraRenderPlanTest.IdentityScaleMatchesTheExportPlanExactly`. The work is generalising that one and moving the export onto it — not building a new seam. Resolve the scale divergence **toward the preview**: `effect_scale` becomes a first-class plan input that the export passes as `1.0`, which is provably inert there (it multiplies only lengths).
- **The equivalence claim above holds, for a better reason than "audited by hand".** Both legs are fed by ONE parser — `ReadCameraComposition` produces a `PreviewCameraComposition`, the preview consumes it directly and the export runs the same struct through `ApplyCameraCompositionToExport`. Every default (size_factor 0.18, opacity 1.0, chroma_strength 0.4, …) is identical because there is one source, plus a guard test. The audit tried to disprove equivalence on all five derivations and could not.
- **`spec` should be the flattened nullable-colour form** (`PreviewCameraComposition`'s bool+value pairs), not `std::optional`. The optional form is already *derived from* the flattened one, so choosing flattened deletes a conversion rather than adding one.
- **Two absolute-pixel constants the seam cannot fix and must not try to:** `kSlideMarginPx = 1.0` is added raw and has no scale parameter, and the preview texture's aspect differs from the export canvas by ~0.25% because the two round independently. Both are sub-pixel in effect. Do not "correct" them inside the plan builder.
- **Out of scope, deliberately:** do NOT fold the live DComp overlay's `ResolveOverlayBubbleStyle` into the same builder. It derives from a different wire model and clamps opacity / corner_radius / chroma_strength where this path does not — unifying would silently add clamps to the export.
- **Original (superseded) proposal, for the record:** `BuildCameraRenderPlan(spec, canvas_w, canvas_h)` plus `ResolveCameraFrame(plan, clock_ms, total_ms, screen_zoom)`, in a D2D-free header.
- **Why it is NOT done yet:** the parse side was the surface that actually drifted (twice), and that is now unified with a mapper plus a guard test. The derivation side has never drifted, so this is hardening rather than a fix, and it is wide: it touches export_router, export_passthrough, export_pipeline, camera_export_renderer, preview_camera_renderer and their tests. Worth doing as its own commit so a regression bisects cleanly.
- **One real snag to fix while doing it:** the preview assigns its cached animation state INSIDE the `factory1 != nullptr && frame_bitmap_ != nullptr` guard, so a one-time bitmap-creation failure leaves `zoom_behavior_` / `layout_preset_` / `slide_edge_` stale. The pure plan build should be hoisted out of that guard. **Confirmed 2026-09-12 — but the recorded reason it is harmless was wrong.** It is not that `painter_ready_` "stays" false; `painter_ready_ = false` is written unconditionally one line *above* the guard and `Draw` short-circuits on it, so the stale members can never be consumed. The hoist is therefore safe, but only while that unconditional write and the `|| !painter_ready_` term in the rebuild predicate both survive. Move one and the staleness becomes reachable.
- **A second divergence in shape, not in result:** the export copies `anim_params_` into a local and mutates the copy; the preview mutates the member in place, so its cached struct carries the previous frame's `zoom_scale` across a painter rebuild. Not observable today (all three per-frame fields are overwritten before every use), but a `ResolveCameraFrame(const Plan&, …)` makes the export's shape the surviving one, which is the right outcome.
- **Cheap adjacent fix, done in the same change as this correction:** `preview_router` previewOpen re-implemented the export's camera asset conditions inline while claiming to mirror them. It now calls `ShouldCompositeCamera`. Same family of drift, and it was in the blast radius.
- **Note `CameraBubblePainter::Style` lives in a header that pulls in `d2d1_1.h`** — move it down into `camera_export_layout.h` with a painter-side alias, or the "pure" plan drags D2D into every test translation unit.
- **Effort:** human ~1 day / CC ~1h.

### ~~Camera zoom emphasis (the pulse) is not ported~~ — DONE

Ported. `cameraZoomEmphasisPreset` (`none`/`pulse`) + `cameraZoomEmphasisStrength`
now render on BOTH legs, running the macOS formula
`1 + strength*0.5*(1 - cos(2 pi * 2Hz * localTime))` for as long as a zoom
segment is active — a continuous throb, not a one-shot bump on the zoom edge.
Pure + tested as `ResolveCameraPulseScale`; it drops into the same multiplicative
`scale` product as the zoom and intro/outro scales, before the canvas clamp.

What actually unblocked it was the slice before this one, not this code: the
preview and the export now resolve segment membership through ONE
`ZoomSegmentStateAt` over ONE builder's segments, so both legs measure
`localTime` from the same backdated segment start. The deferral note below was
right that a per-click clock would have shipped a visible defect — at 2 Hz a
200 ms offset is ~144 degrees of phase — and that failure is now pinned by
`CameraPulseTest.PreviewAndExportAgreeOnPhaseForTheSameSegmentTime`, which
asserts the two clocks move the bubble in OPPOSITE directions at the same
instant.

The two "no macOS answer to copy" decisions were resolved as: (1) the pulse keys
off half-open segment MEMBERSHIP, never `zf.active` (which stays true through the
whole ease-out tail), so the throb ends exactly at `end_ms` on both legs; (2) the
pulse clock stays SOURCE-derived while the camera's intro/outro clock stays
EDITED — deliberately split, and split identically on both legs, so a cut inside
a zoom segment jumps the phase on the preview and the exported file in the same
way rather than desyncing them.

Residual, deliberately not closed here: the phase agreement is proven by
construction and by headless tests, but an on-device eyeball comparing an
exported file against the editor at the same timestamp has not been done — CI
cannot do it. Fold it into the camera on-device QA pass.

### ~~Camera intro/outro may run on a different time base in the preview vs the export (UNTRIMMED clips only)~~ — MEASURED 2026-09-11, latent not live

- **Settled the way the item asked: by measuring, not by fixing.** The divergence
  needs a non-zero container PTS base to exist. Windows recordings do not have one.
- **The measurement.** Every `.clingfyproj` on the dev box — **36 screen videos** —
  probed with `ffprobe -select_streams v:0 -show_entries stream=start_pts`:
  **`start_pts=0` on 36 of 36**, `time_base=1/30000` throughout. Not one non-zero base.
- **So the export's rebase is a no-op on these files.** `frame_ms =
  (timestamp - first_video_hns) / 10000` with `first_video_hns` resolving to 0
  is `timestamp / 10000`, which is exactly the container-relative clock the
  preview's `CurrentPlaybackUs()` already reports. The two sides agree.
- **The code already relies on this.** The reorder branch hardcodes
  `first_video_hns = 0` and justifies it in its own comment: *"The recorder
  writes from PTS 0"* (`export_pipeline.cpp`, the `if (reorder)` block). That
  assertion was never measured; it is now.
- **Durations do not split the two sides either.** 10 of the 36 have a video
  stream duration differing from the container duration by more than 50 ms
  (audio running longer). Both sides take the *container* duration — export from
  `MF_PD_DURATION` on the presentation descriptor, preview from
  `PlaybackSession().NaturalDuration()` — so the stream/container gap is the
  same number on both and cannot desynchronise them.
- **The one case still unmeasured: a macOS-produced bundle opened on Windows.**
  `RecordingProject::platform` is explicitly `"windows" today; "macos" when read
  from a Mac bundle`, so this is reachable, and AVAssetWriter is a different
  writer with no measurement behind it here. No camera-bearing bundle existed on
  the dev box to check (0 of 36 had `camera.mp4`/`camera.mov`). If a Mac
  recording ever shows a non-zero base, the fix is the one this item always
  proposed: rebase the preview clock the same way the export does, keeping one
  definition of "clip time" instead of two.
- **Do not "fix" the Windows path on this evidence.** Rebasing a clock whose base
  is provably zero adds a term that is always zero and a second place to get it
  wrong.
- **Reproduce:** `ffprobe -v error -select_streams v:0 -show_entries
  stream=start_pts,time_base -of csv=p=0 <bundle>/capture/screen.mov`

<details>
<summary>Original item (kept for the reasoning, which still applies to the macOS-bundle case)</summary>

### Camera intro/outro may run on a different time base in the preview vs the export (UNTRIMMED clips only)

- **What:** On a clip with no cuts, the preview and the export derive the animation clock from different sources, so a fade-in / slide-out could start and finish at slightly different absolute times on each side. Trimmed projects are NOT affected — both sides use the edited position and edited duration there, which is the case the animation port was built and reasoned about.
- **The specific divergence.** Export rebases to the first decoded video frame: `frame_ms = (timestamp - first_video_hns) / 10000` and `camera_total_ms = (duration_hns - first_video_hns) / 10000` (`windows/runner/Capture/Export/export_pipeline.cpp:1097-1103`, `:1385-1394`). The preview uses the MediaPlayer's own clock: `CurrentPlaybackUs()` and `PlaybackSession().NaturalDuration()` (`windows/runner/preview/preview_engine.cpp:1434-1446`). Those agree only when the container's PTS base is zero.
- **Why the export bothers to rebase**, per its own comment: raw `MF_PD_DURATION` keeps the container's PTS base, and an unrebased duration pushes the outro window past the last reachable `frame_ms`, so the outro never completes. That is the failure this rebasing exists to prevent — which is the reason to suspect the un-rebased preview side rather than the export.
- **Not observed, only derived.** Found by reading both clocks while wiring the preview animation (PR #419); no recording has been measured. Our own screen recordings may well have a zero PTS base, in which case the two agree today and this is latent rather than live. Do not "fix" it before measuring.
- **How to settle it:** open a real untrimmed recording, log `first_video_hns` from the export path and `NaturalDuration` / position from the preview path for the same file, and compare. Zero base and equal durations → close this as a non-issue and record that. Non-zero → rebase the preview clock the same way the export does, which keeps one definition of "clip time" instead of two.
- **Start at:** `windows/runner/preview/preview_engine.cpp` (where `emit_pos_ms` / `emit_dur_ms` are produced on the MediaPlayer path, around `CurrentPlaybackUs` / `NaturalDuration`) and the `first_video_hns` rebase in `windows/runner/Capture/Export/export_pipeline.cpp` (the rebasing it should match). Line numbers from the original item drifted out of date under #466–#473; search the identifiers instead.
- **Effort:** human ~2h / CC ~30min, most of it the measurement.

</details>

## Windows — bridge routers

### ~~Camera-composition arg-parsing dedupe (shared Bridge/Routers helper)~~ — DONE
- Landed with the intro/outro preview slice as
  `Bridge/Routers/camera_composition_args.{h,cpp}`, following the
  `color_grade_args` pattern. Both `preview_router`
  (previewSetCameraPlacement) and `export_router` (processVideo) now call
  `clingfy::bridge::ReadCameraComposition`.
- The prediction in this entry was correct twice over: after the
  missing-chroma bug, the two parsers had drifted AGAIN — neither read the four
  `cameraIntroPreset` / `cameraOutroPreset` / `cameraIntroDurationMs` /
  `cameraOutroDurationMs` keys, so the inline preview never animated while the
  export did. Covered by `camera_composition_args_test.cpp`.

### Log files lose their beginning while the app is still running

- **What:** The current day's log file is silently rewritten mid-session, losing everything written before some point. The app never recovers the lost lines; it just keeps appending after them.
- **Reproduced twice, with evidence.**
  - `logs_2026-07-27.jsonl` was 313,453 bytes / 917 rows at 22:31 local. Four minutes later: 3,439 bytes / 7 rows.
  - `logs_2026-07-28.jsonl` carries `sessionId 2026-07-27T22:12:15Z`, but its earliest surviving row is `22:14:39Z` — **2.4 minutes of that session's own output is missing from the front**, and the file contains no `Logger initialized` line even though `Log.init` emits one on every launch.
- **Therefore it is not launch-time truncation.** The loss happens while a session is running, and appends continue normally afterwards (the file was back to 138 KB / 294 rows within minutes).
- **Why it matters:** Diagnosis has now been blocked by this twice. The camera-finalize root cause is still unknown specifically because the deciding lines were destroyed while being investigated. Every logging improvement is worth less than it looks until this is fixed.
- **Ruled out, each by reading the code:** `FileLogSink` only ever appends (`FileMode.append`, `file_log_sink.dart:125`) and its single `delete()` (:183) is inside `_pruneOldLogs`, which compares the *filename* date against `today - 30 days` and so cannot touch the current file. `Log.init` (`logger_service.dart:159`) creates no file and truncates nothing. On macOS the native side only ever *reads* the path — `getTodayLogFilePath`, `revealTodayLogFile`, `revealLogsFolder` and `StorageDiagnosticsService` all stat or reveal, none write. `AppPaths.ensureDirectory` calls `createDirectory(withIntermediateDirectories:)`, which does not delete. There is no log-clearing UI; `logsBytes` is display-only.
- **So the writer is outside the app's logging path.** Candidates, in the order worth testing: a second app instance sharing the file, an external tail/editor/sync tool rewriting it, or a crash-and-restart cycle that reopens the path without append.
- **How to reproduce cheaply:** `while :; do stat -f "%z %m" logs_$(date +%F).jsonl; sleep 5; done` while using the app, and note what is on screen when the size drops.
- **Start at:** `lib/core/logging/file_log_sink.dart`, `lib/core/logging/logger_service.dart:159`.
- **Effort:** human ~2h / CC ~30min once the drop is caught in the act.

### Confirm a Bluetooth SPEAKER is warned about
- **What:** Verify that a Bluetooth loudspeaker (not a headset) triggers the speaker-bleed warning.
- **Why:** This is the last unresolved half of the old "disambiguate Bluetooth and USB routes" item. `AudioOutputRouteProbe` now prefers `kAudioStreamPropertyTerminalType`, which resolved the headset case on real hardware — a JBL WAVE100TWS earbud reports `'hdph'` and correctly produces no warning, verified live. A Bluetooth *speaker* has never been measured: if it reports `'spkr'` or a USB-AC speaker code it is already handled, but if it reports `'hdph'` or `0` the warning will be missed, and a missed warning ruins an unrepeatable take.
- **Also unmeasured:** USB headsets and USB desk speakers. Both fall back to the transport type, which returns `unknown` for USB, i.e. no warning either way.
- **How (10 seconds per device):** connect the device, run `tools/audio/probe_audio_output_route.swift`, and add the row to that file's header table. Only extend `routeFromTerminalType` for codes actually observed — mapping from the USB spec alone is how a confident wrong answer gets shipped.
- **Start at:** `macos/Runner/Capture/Audio/AudioOutputRoute.swift` (`routeFromTerminalType`), `macos/RunnerTests/RunnerTests.swift` (`testTerminalTypeResolvesRoutesTransportTypeCannot`).
- **Effort:** human ~15min / CC ~10min once a row exists.

### Windows AAC profile-level is pinned to "2ch / 48 kHz" while the rate is configurable
- **What:** Both Media Foundation AAC writers hardcode `MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = 0x29`, which specifies AAC-LC at **2 channels, 48 kHz**, while the surrounding encoder config (`mf_encoder_config.h`) validates and permits **44.1 kHz** as well.
- **Why:** A 44.1 kHz export would declare a profile level that does not describe the stream it contains. Today nothing reaches that path — the config defaults to 48 kHz and WASAPI capture hard-rejects any endpoint that is not 48 kHz float32 stereo — so this is latent, not live. It becomes real the moment 44.1 kHz is selectable or WASAPI accepts a wider range.
- **Context:** Found by the completeness sweep during the 2026-07-26 macOS export `-11861 "Cannot Encode Media"` investigation. The macOS side of that bug class was the same shape: an encoder parameter fixed independently of the source. macOS is now fixed via `AACEncoderSettings`; Windows has no equivalent single source of truth.
- **Do NOT "fix" this speculatively.** Changing a profile-level indicator without a stream that actually exercises it is how a working encoder gets broken. Wait until 44.1 kHz is genuinely reachable, then derive the indicator from the configured rate and channels.
- **Start at:** `windows/runner/Encoding/mf_sink_writer_encoder.cpp:220-232`, the sibling MF writer, and `windows/runner/Encoding/mf_encoder_config.h:45-57`.
- **Effort:** human ~1h / CC ~15min once reachable.

