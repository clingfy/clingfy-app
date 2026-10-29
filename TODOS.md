# TODOS

The one place for open work: deferred tasks captured during reviews, plus the
small loose ends (things flagged, left unverified, or waiting on a decision)
that would otherwise be lost between sessions. Each item has enough context to
pick up cold. Larger planned features live in `docs/editing-platform-plan.md`.

Loose ends carry a kind in their heading: **verify** (someone checks the real
app, no code), **decide** (a product or engineering call), **code** (a change).
When an item closes, strike it through or mark it DONE with the commit or PR,
or move it to *Recently closed* at the bottom. Do not delete it.

Loose ends last revised 2026-10-16 against `develop` at `abe470e` (1.2.0).

## Editor — captions

### ~~Arabic subtitles have not been checked in a real exported video~~ — DONE 2026-10-26

Checked by eye in a real export. `caption_proof_bitmaps.dart` now also renders
"مرحبا Clingfy!" and a two-line mixed cue, and writes the `.srt` with the real
serializer. `CaptionBurnInProofTests` burned them into a video through the
export writer loop, and the frames were extracted and looked at:
- the letters join;
- an Arabic-first line reads right to left, with its "!" or "." at the left;
- each line of a two-line cue has its own direction, the bidi rule for a
  line break.

**Found and fixed: libass disagreed with the video.** The `.srt` played in
libass (mpv, ffmpeg, many players) laid every line out left to right. So
"مرحبا Clingfy" had the Arabic word on the left there, and on the right in the
video. Right-to-left lines in the `.srt` and `.vtt` are now wrapped in an RTL
embedding (U+202B … U+202C). Rendered with libass, all four cues now match the
burn-in. Browsers and other bidi-rule players are unchanged.

The editor's own text field still has one direction for a two-line mixed cue.
That is the per-line editor parked in the backlog.

### ~~Intel Macs are refused for subtitles while the copy promises a slow path~~ — DONE (5a1ef67, closed #448 on 2026-10-26)

Decided: explicitly unsupported. The copy now says so in all three languages
("Subtitles need a Mac with Apple silicon…"), and `docs/features.md` says
"Requires Apple silicon". The capability's reason was renamed from
`intelSlowPath`, a name that described what did not happen.

### ~~Smaller caption follow-ups~~ — DONE 2026-10-26
- **Caption migration with more than one cue:** now pinned. Three cues, Arabic
  and mixed text and a two-line cue, survive in order with their text and times
  (`post_state_store_test.dart`).
- **Editing a two-line subtitle that mixes scripts:** moved to the feature
  backlog. It needs a per-line editor, and export and preview are already
  correct (#601).

### Windows has no transcription engine — code (Windows machine)

Windows answers `captionsCapability` with `platformNotSupported`
(`misc_router.cpp:99-112`), so auto-subtitles are macOS only.
`docs/windows-port-editing-features.md:392` plans whisper.cpp. Brief it in
`docs/windows-machine-work.md` when it is picked up. The duplicate
Auto-subtitles row in `docs/features.md` is already merged into one.

## Export — colour

### ~~Dark recordings have never been checked in QuickTime after the colour fix~~ — DONE 2026-10-29

Measured in Apple's decoder (AVFoundation, which QuickTime uses), on two sources.
Each was exported through the real engine, with `mov-<label>.mov` in
`testExportsGifProofsForVisualInspection`:
- **A synthetic dark terminal**, with shadow steps at levels 0–48 on a #1e1e1e
  background. The export matches its source within 2 code values at every step.
- **A real recording of this Mac's dark-mode screen**, against its own recording:

| Recording level | Export mean diff | Mean abs diff |
|---|---|---|
| 0–15 | +2.51 | 2.52 |
| 16–31 | −0.01 | 0.12 |
| 32–47 | +0.04 | 0.28 |
| 48–63 | +0.10 | 0.49 |

Nothing is crushed. The deepest blacks lift by about 2.5 values, the small lift
the 1.961 curve accepts by design (`docs/decisions/macos-export-transfer-curve.md`),
and invisible to the eye.

### ~~Smaller colour follow-ups~~ — DONE 2026-10-26
- The 1.961 curve decision, with its revisit trigger, is now in
  `docs/decisions/macos-export-transfer-curve.md`.
- That record also notes why full-range buffers were not adopted (#372) and the
  `clearPixelBuffer` rework they would need. The *RESOLVED (1.0.7)* entry below
  points to it.

### ~~Grade the validator's reference on the two CAMERA paths~~ — DONE 2026-10-26

**Decided:** the camera bubble stays ungraded on export; only the screen is graded, as
in the live preview.

- **Part 1 (#629): every camera renders inline.** A plain square camera skipped the
  inline renderer, and the writer graded the whole canvas, bubble and padding included.
  It now renders inline, where only the screen is graded.
  `testASquareCameraRendersInlineSoTheGradeSkipsTheBubble` pins this. Under the old
  routing, exposure −1 took the bubble from 0.99 to 0.35 red.
- **Part 2: the inline validator measures graded exports.** Its reference grades the
  screen sub-image before the camera and background are composited, as
  `InlineCameraRenderer.render` does. The screen is declared in the working colour
  space; a bare `CIImage(cgImage:)` read the generator's GenericRGB tag and applied a
  gamma-1.8 conversion the writer never does. The skip is gone.
  - `ColorGradeValidatorMarginTests` now sweeps every grade with a circle camera on the
    light fixture and a square camera on the dark one, both over padding and a
    background.
  - Identity floor: 0.0155 / 0.0143. Worst graded residual: 0.0245, under 2× the floor,
    against a 0.14 / 0.18 budget.
  - An ungraded reference would read up to 0.31 and delete the export. Removing the
    screen grade from the reference fails the sweep.
- **The pre-styled branch was dead.** Nothing in production has produced
  `cameraAssetIsPreStyled == true` since #33. So `validateFinalStyledCameraExport`, its
  crop logic, its test seam and its two tests were removed rather than fixed. The styled
  pass itself is listed in the backlog for a cleanup PR.

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
- **Range:** full-range buffers were deliberately not adopted. The file
  declares limited range and contains it (#372). See
  `docs/decisions/macos-export-transfer-curve.md`.

## Export — engine

### An export crashed once inside CVPixelBufferPoolCreatePixelBuffer — code (watch)

*Seen once, 2026-10-29,* in the test host during a combined run of the export
suites, in `ColorGradeValidatorMarginTests.testGradeMarginsWithPaddingOnALightModeUIFixture`.
`EXC_BREAKPOINT` in `CFDictionaryGetValue`, reached from
`CVPixelBuffer::setDefaultAttachments` → `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes`
← `makePooledPixelBuffer` (`ExportMemory.swift:46`) ← `awaitPooledPixelBuffer` ←
`renderNextFrame` (`LetterboxExporter.swift:~2494`), on the writer's request queue.
That is the pool's default-attachments dictionary being read while invalid.

It did not reproduce in five more runs: three of the same combined suite (one on
develop without the change under test), and two of that class alone. It is in
the no-camera writer path, which that change did not touch. Likely a rare race
around the pool, the writer's lifetime, or buffer attachments
(`VideoColorPipeline.tag(pixelBuffer:)` sets four propagated attachments on every
rendered buffer).

**To close:** if it is seen again, in a test run or a user report, compare the
stack. With two sightings, look for the pool used after its writer
finished or cancelled, or a buffer being tagged while it returns to the pool.

## Export — GIF

### ~~GIF output checked by eye only at Small and Large~~ — DONE 2026-10-26

`ExportEngineTests.testExportsGifProofsForVisualInspection` exports every
`<size>-<label>.mov` in `/tmp/clingfy-gif-proof` through the real single-pass
engine; it skips when the folder is empty. The sources were made with ffmpeg:
moving gradients, a Macbeth colour chart, large text and small text.

| Source | Preset | GIF | Frames | Length | Size |
|---|---|---|---|---|---|
| 1080p, 8 s | Medium | 720×406 | 120 | 8.00 s | 1.7 MB |
| 4K, 8 s | Large | 1080×608 | 120 | 8.00 s | 5.9 MB |
| 1080p, 55 s | Medium | 720×406 | 825 | 55.00 s | 19.9 MB |

- **Colour:** the 24 chart patches match the source as AVFoundation decodes
  it, which is what the editor shows: mean 0.7, worst 2.0 code values.
- **By eye at 3×:** gradients are smooth with faint wide steps and no noisy
  dither. Edges are clean, with no halos. Small text is soft at Medium, as
  expected from the downscale, but legible.
- **Timing:** the long clip's delays add up to exactly 55.00 s.
- **Size:** a long Medium GIF of moving gradients is about 20 MB. That is the
  worst case for the format.

## Recording — camera (macOS)

### Camera-start safeguards have never been seen working on a real device — verify (needs a USB camera)

> **2026-10-29:** "claim the webcam in another app" does not trigger a refusal on macOS
> 26. A separate process held the FaceTime camera, with a running session and a
> configuration lock, while Clingfy recorded a camera take. macOS shared the camera,
> and the take recorded and finished `ready`. What is left is the unplug case: pull a
> USB camera during Start.

*From the camera-start work of 2026-07-30 (#386, #387).*

The readiness guard, the unwind after a refused start, and the 20-second camera
start timeout all exist, and since #393 they are proven by tests against a fake
coordinator (`macos/RunnerTests/RunnerTests.swift:577`, `:622`, `:655`, `:680`).
None of them has been observed firing on real hardware: no issue, log or release
note records it. The only field incident (the lost take of 2026-07-27,
`CameraRecorder.swift:246-247`) happened before they existed.

**To close:** force a bad camera start on a device. For example, claim the
webcam in another app, or unplug a USB camera (the Osmo Pocket 3 was the original
case) during Start. Then confirm a clear error appears instead of a spinner, the
log shows the `CameraRecorder` refusal or timeout, and a second attempt records.
Note the result here.

## Recording — capture (macOS)

### ~~Recording captures at full display resolution for every quality~~ — DECIDED 2026-10-26

The premise was wrong. `CaptureStartConfigBuilder` captures every recording at
`.native`, and no UI sets a recording quality: `setRecordingQuality` has no
Dart caller. The output size is chosen at export. So `.best` only ever runs
at native size, where it is load-bearing: it makes a scaled HiDPI display
sample its backing store instead of upscaling the point-size framebuffer.

Kept `.best`, and recorded why in the test comment
(`testNativeQualityStreamConfigurationKeepsExplicitPixelSize`). Also fixed: the
metadata stamped the quality preference (`fhd` by default) on files captured
at native size. It now stamps `native`, and nothing read the old value.

One take was measured on the built-in display, 3024×1964 at `.best`: app CPU
43%, WindowServer 75%, GPU 50%, 510 MB. If quality presets ever drive capture
again, revisit `.best` for output sizes below the display's point size.

### ~~Pause/resume segment merge may silently re-encode~~ — DONE 2026-10-17

The fallback was `AVAssetExportPresetHighestQuality`, which writes **H.264**.
The capture is HEVC, so a paused take that hit the fallback came back as H.264
at about half the bitrate, with nothing in any log. Measured on synthetic
segments tagged like ScreenCaptureKit's output: colour was never at risk.
`screen.mov` is BT.709-tagged, never sRGB-tagged; the old wording here was
wrong. Both presets kept the 709 tags and the pixel values, so the cost was
codec and quality, not colour. The fallback is now
`AVAssetExportPresetHEVCHighestQuality`, which keeps HEVC, the tags and the
pixels. Every attempt is logged: the preset, a failed passthrough's error, the
time taken, and a per-segment codec/size/track summary. A re-encode is logged
at WARNING, and the final-video log names the codec.
`RecordingSegmentMergerTests` merges real segments and pins the parts that
matter most: passthrough first, HEVC on both paths, the three BT.709 tags, the
duration, and a preset order that cannot fall back to another codec. The
unchanged pixels were measured once, on flat test patches, and are not pinned.
The log lines are not pinned either.

Still unknown: how often passthrough fails in the field. The code found
nothing that changes segment format mid-recording, since the stream's size is
fixed at start. Segments of different sizes even pass through: AVFoundation
reads the result, scaling the odd segment, though ffmpeg chokes on it. The new
warning line is how to find out.

### ~~Both segment-merge presets failing makes a paused recording unreachable~~ — DONE 2026-10-19

When every preset fails, `RecordingSegmentMerger.mergeOrSalvage` publishes the
first **usable** segment as `screen.mov`: one with a video track, a positive
duration, and that plays. In practice that is the first segment, which the
cursor and audio timelines start with. A broken segment is skipped, because
publishing it would turn a loud failure into a "ready" take that cannot play. The take finishes `ready`, is listed,
and opens; Finder accepted it in the live check. The other segments, with their
cursor, mic and system files, stay untouched in `capture/`. They are recorded in
`capture/segments.unmerged.json`: every segment's files and timing, the
published index, and a readable reason. The user gets a warning saying so, sent
through the same path as the camera salvage.

The audio sidecars needed one more fix. A successful stop's reset deletes every
audio file the recorder still tracks, so the parts set aside are now released
from it (`SourceAudioRecorder.keepArtifacts`). Verified on a real paused take
with the debug-only `CLINGFY_FORCE_SEGMENT_MERGE_FAILURE=1` switch. If no part
is usable on its own, the take still fails, as before. Its audio files and the
manifest (`publishedSegmentIndex: null`) are kept, though, instead of being
deleted by the failure path.

Known gap: on a camera take, the camera's sync after a salvage is not right.
See "The recording metadata never lists its segments" below.

### ~~Rejoin the parts a salvaged recording set aside~~ — DONE 2026-10-25

At launch, `SalvagedTakeRepairSweep` (in `Capture/Project/SalvagedTakeRepairer.swift`)
gives every project with a `segments.unmerged.json` another try, in the
background and one project at a time.
- **Screen:** it joins the parts with passthrough, then HEVC, then H.264 (the
  stop had no H.264 step). It rebuilds the cursor and audio on the same
  measured durations and rewrites `screen.segments` and `endedAt`.
- **Camera:** it joins the camera parts and rebuilds `camera/meta.json` from
  the manifest and the start stub. It restores the camera block, and the
  editor's camera visibility as it was. The stop now notes that visibility in
  the camera manifest before turning the camera off.
- **Status:** a take whose join failed outright, or that a later launch marked
  failed, becomes ready again.

How it stays safe:
- Everything is built in `.repair/`, and `commit.json` is written before
  anything moves. A move that fails stops the commit before any part is
  deleted, and the commit is retried at the next launch.
- A part before the published one stays out, so edits made on the published
  part do not shift.
- So do parts, or cursor and audio files, that cannot be used. They stay on
  disk, and the manifest is kept, marked joined, listing them.
- Attempts are capped at three, plus one per new app version. A camera out of
  attempts is dropped from `project.json`, so the take still opens.
- A Finder open of a project being repaired waits for it. Clearing cached
  recordings is refused until the sweep ends. A recording running at launch
  defers the repair to the next launch.
- Flutter learns what was joined from `getStartupRecoveryReport`, which macOS
  now answers. The notice has an Open button.
- Clip edits saved on the shorter take get the joined footage as a clip at
  the end.

Also fixed: a stop that dropped the camera left `camera/raw.mov` named in
`project.json`. Finder refused the take, and the next launch marked it failed.

Verified:
- 15 `SalvagedTakeRepairerTests`, plus Dart tests for the report, the notice
  and the clip growth.
- Breaking the commit stop, the published-part rule, the later camera drop and
  the clip growth each fails its test.
- Live: a real paused camera take was split into a salvaged layout and
  repaired at launch in 0.2 s, by passthrough. Screen 8.6 s, system audio and
  camera restored, status ready, parts gone, notice logged.

### ~~A salvaged stop followed by its repair, live end to end~~ — DONE 2026-10-26

A real paused take recorded with `CLINGFY_FORCE_SEGMENT_MERGE_FAILURE=1`
published part 1 (3.84 s), set part 2 aside (4.14 s) with its cursor and
system audio, and sent the warning. After a relaunch without the switch, the
repair joined it into one 7.99 s `screen.mov` by passthrough. The take was
ready, the parts were gone, and Flutter logged the notice.

### ~~Repair follow-ups~~ — DONE 2026-10-26
- **A stuck repair:** a project gets 30 minutes. The repair is then stopped:
  both merge exports now cancel with their task, and nothing commits once
  stopped. If it ignores the stop, it is left behind after 10 s, which
  releases its Finder open and the startup report.
- **A recording starting:** this now stops a repair under way, before it
  commits. The attempt is not counted, and that project and the rest are
  tried at the next launch.
- **Captions:** decided, no message. A transcript made on the shorter take
  still covers its first part, and transcribing again covers the rest, as
  with any edit to the audio.

### ~~A cursor-merge failure throws away a screen merge that succeeded~~ — DONE 2026-10-19

The cursor merge is now best effort, like the audio merge. A sidecar problem
finishes the take without cursor data (and removes any partial `cursor.json`)
instead of failing a Stop whose `screen.mov` was already written.

### ~~The recording metadata never lists its segments~~ — DONE 2026-10-19 (camera sync on paused takes)

Two bugs broke the camera on paused takes. Both were there since separate
camera recording shipped (057f38ca).

1. **No segment list on camera takes.** The facade wrote `screen.segments`
   after the camera's asynchronous stop, by which time the backend had reset
   and reported none. Camera sync always fell back to a window anchored at the
   metadata write time. On a paused take, every part but the last showed
   camera footage from later in the take. Even an unpaused take was off by
   the stop/merge latency, about 0.9s in the live check. `backendDidFinish`
   now captures the list synchronously, before the reset, and hands it in.
   `endedAt` is the last segment's real end.
2. **The camera stopped recording after resume.** The overlay is re-shown
   after the camera segment starts, and a new `AVCaptureVideoPreviewLayer`
   added a connection to the running session, which stopped the movie output
   ("Recording Stopped", flagged as a successful finish). Every paused camera
   take recorded about 0.4s after its first resume and nothing more. The
   coordinator now reuses one preview layer. A segment that ends on its own
   mid-take is logged at ERROR.

Verified live on a paused take. Camera part 2 is 3.54s against the screen's
4.02s; it used to be about 0.2s. The sync resolves from
`screen.metadata.segments`, with each part mapped to the camera footage from
the same wall-clock moment. An unpaused take maps screen 0 to camera 0.32s,
which matches the camera starting 0.318s earlier.

### ~~Screen and camera segment times are stamped at different points~~ — DONE 2026-10-26

Both sides are now timed from their start callbacks.
- **Screen:** each segment starts when its recording output's
  `recordingOutputDidStartRecording` fires, stamped before the hop to the main
  actor, and ends one file duration later (`SegmentWallClock`). The old way,
  without the callback, remains the fallback.
- **Camera:** its stretches were already timed from `didStart`, `didPause`
  and `didResume` (2026-10-19).

On a live paused take, the screen starts moved by 17 ms and 22 ms against the
old derived times. The camera still starts 336 ms before the screen at the
first start, and 54 ms after it at resume. Those are real start times, which
camera sync maps, not stamping skew.

Not measured: whether a start callback matches the first frame, which needs
a clap or a flash seen by both screen and camera. That is a by-eye check:
- the camera bubble in sync with the screen after a resume;
- in the editor and in an export.

### Pause and resume on a real macOS 13-14 Mac — verify

The AVFoundation backend runs on macOS 13-14, and wherever ScreenCaptureKit
fails to start. Its pause and resume were fixed on 2026-10-19 without a 13-14
Mac. Pause was confirmed live by forcing the backend on macOS 26: the take
reached "paused" 23ms after the request. Resume was not, because screen
capture through this backend then stopped starting on that Mac (next item).
**To close:** on macOS 13 or 14, pause, resume and stop one take with the
camera on. Check that it finalizes, that `screen.meta.json` has one segment per
stretch, and that the camera bubble lines up in both parts.

### AVFoundation screen capture fails on this macOS 26 Mac — verify

*Found 2026-10-19, narrowed 2026-10-20.* Forcing this backend on macOS 26.1
recorded a few takes. Then every start failed:
- **2026-10-19:** "No active/enabled connections". That crashed the app until
  #609.
- **2026-10-20:** a start that runs, then fails about 2s later with
  `AVFoundationErrorDomain -11800` wrapping OSStatus `-12780`, with no video
  written. Screen recording is allowed (`CGPreflightScreenCaptureAccess` is
  true).

The failures began right after the memory and disk exhaustion of
2026-10-19. During it macOS killed `tccd` and killed `replayd` 33 times, and
the Mac has not been rebooted since 2026-09-30, so the cause is most likely
damaged system capture state, not code. That is unproven.

Measured in a host without the permission: the connection still reports
active, and the session then fails with a runtime error `'what'` and no
frames.

Since 2026-10-20 the backend:
- checks permission and a live connection before recording;
- logs the session runtime error and the finish error in full;
- reports "macOS is not providing the screen… Restart your Mac" in place of
  "The operation could not be completed".

This matters on macOS 15+ only when ScreenCaptureKit fails to start with an
invalid-parameter error and this backend is the fallback.

**To close:** reboot this Mac, force the backend once (`CaptureBackendFactory`,
`if false, #available(macOS 15.0, *)`), and record. If it records, it was
system state. If not, the new logs say why.

### ~~Other mid-recording overlay rebuilds may still stop the camera~~ — DONE 2026-10-25 (#623)

The two rebuilds not checked are now deferred while a recording holds the
camera (`CameraCaptureCoordinator`):
- **A camera device change** waits for the end of the take. That covers a
  pick made during a pause, and a hot-plug re-send.
- **A chroma-key frame output** is not added mid-take; the bubble shows the
  plain camera until the end.
- **The recording connection's mirror** keeps the take's value.

`CameraRecorderTests` pin each one. Projects recorded before the segment-list
fix keep their empty lists, accepted: their camera falls back to the end-anchored
window, as it always did.

### ~~Smaller capture follow-ups~~ — DONE 2026-10-26

- **"No microphone" stays off:** native coverage existed for the predicate
  (`CaptureStartConfigBuilderTests`: disabled, sentinel ids, an unknown
  device). The facade wrapper that stamps `micEnabled` now has its own test,
  `testTheFacadeRecordsNoMicrophoneForEveryWayOfChoosingNone`.

## Logging — macOS

### ~~Logs written just before a crash or quit can be lost~~ — DONE 2026-10-16

macOS native now writes each line to disk when it is logged, into a daily
`logs_<date>.native.jsonl` companion. Dart writes its own file synchronously,
with no queue. On quit native writes an `App terminating` line, and an
uncaught exception leaves its name, reason and stack. See `docs/logging.md`.

The proposed fix, a flush on terminate, would not have saved the 2026-07-30
line: it was in an unrun main-queue block, not in the pending buffer. Sharing
one file was ruled out too. Dart's append mode seeks once instead of appending
atomically, and was measured overwriting another writer's line.

## Editor - layout

### The clips lane is below the fold in the editor, at every window height tested — verify (Windows machine)

> **2026-10-26: clean on macOS at 2× scale, the "second machine, different scale" asked for below.**
> A take was opened in the editor and the render tree dumped. At the default 1280×748 window,
> the timeline starts at 483.4 in the 732-tall workspace column, and the viewport (offset 109,
> 139.6 tall) ends at exactly 732. At the minimum 960×640 window, it starts at 349 of 592 and the
> viewport (106.3 + 136.7) ends at exactly 592. No `_RenderLayoutBuilder was mutated` or overflow
> was logged. The layout is shared Flutter code, so what is left is the original Windows sighting:
> confirm on Windows at 125%, then close.

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

### ~~A recording Start/Stop/Start can hang~~ — CAUSE FOUND, fixed 2026-09-19

- **It was an ABBA lock inversion between `RecordingEngine::mutex_` and
  `RecordingIndicatorController::provider_mutex_`.** Two threads, two locks,
  opposite order, both bare non-recursive `std::mutex` with no timeout:

  | thread | holds | then wants |
  |---|---|---|
  | main, inside `Start()` | `mutex_` (`recording_engine.cpp:227`) | `provider_mutex_` — `Show()` at `recording_engine.cpp:1304` |
  | overlay, inside `WM_PAINT` | `provider_mutex_` (`recording_indicator_controller.cpp:172`) | `mutex_` — `duration_provider_()` calls `ElapsedSeconds()` at `recording_engine.cpp:2187` |

- **Why only the SECOND Start.** The overlay thread and its 250 ms tick are
  created lazily by the first `Show()`. Teardown only calls `Hide()`, which
  stores a flag and posts a message — it retires nothing. So during Start #1
  `provider_mutex_` is uncontended; by Start #2 there is a live thread taking
  the two locks the other way round.
- **Why it was silent.** Both waiters are on different threads, so MSVC's
  same-thread relock check never fires — no exception, no HRESULT, no crash.
  `Show`, `Paint` and `ElapsedSeconds` log nothing, and `NativeLogPublisher`
  buffers to memory when there is no Flutter channel (always, in a test).
- **Why the sandbox change moved the odds without fixing it** (see the table
  that used to be here): per-PID dirs only changed how long `Stop` holds
  `mutex_` during teardown, which is exactly the width of the window in which
  the overlay thread gets parked.
- **Fix:** `Paint` no longer invokes the provider under `provider_mutex_`. The
  new `CurrentElapsedSeconds()` copies the `std::function` out, releases the
  lock, then calls it. Pinned by
  `windows/runner_tests/recording_indicator_provider_lock_test.cpp`, which
  re-enters the lock from inside the provider — it throws
  `resource deadlock would occur` if anyone re-inlines the lock.
- **Not test-only.** The cycle is armed on every stop-then-start in the
  shipping app, not just under test contention.
- **What is still NOT proven.** The CI evidence shows the process blocked
  somewhere after `[teardown] teardown complete`; "therefore inside Start #2"
  is an inference. `Stop` runs ~90 untraced lines after `TeardownPipeline`
  returns (`FillCameraWriterFields`, `MarkStopped`, `WriteRecordingProject`,
  `CleanupSessionTempFiles`). If the hang recurs after this fix, instrument
  that tail first — it is the one region the existing trace has never
  discriminated.
- **Evidence:** CI run 35457817219 (job 105936728845), `***Timeout 300.02 sec`,
  with one complete teardown trace and 300 s of silence after it. Earlier
  43-minute timeout on run 35007670584 is the same signature.

### ~~`TeardownPipeline` can join a thread from itself~~ — MISDIAGNOSED, and the symptom is gone

- **It was never a self-join.** The entry's reasoning was: `resource deadlock
  would occur` is `EDEADLK`, "which C++ raises for exactly one reason: a thread
  joining itself". That is not true on MSVC, where a non-recursive `std::mutex`
  re-locked by the thread that already owns it throws the identical
  `std::system_error`. Both paths produce the same string, and the message
  alone cannot tell them apart.
- **Direct evidence, observed 2026-09-20.** The guard test added with the
  indicator lock fix (`recording_indicator_provider_lock_test.cpp`) re-enters a
  `std::mutex` on one thread, with no `std::thread` anywhere in the test, and
  fails with:
  `C++ exception with description "resource deadlock would occur" thrown in the test body.`
- **What actually threw it:** `MfSinkWriterEncoder::Open` called the public
  `Cancel()` on each of its failure paths while still holding `mutex_`. Under
  the contention this repro creates, `Open` fails constantly — there are no
  free capture devices — so nearly every contended Start took that path. Fixed
  in #509 (`a234ab9`, 2026-09-16), which split out `CancelLocked()` for callers
  that already hold the lock. The measurement in this entry was taken the same
  day, before that landed.
- **Re-measured 2026-09-20 with the entry's own recipe**, three rounds:

  | | documented 2026-09-16 | now |
  |---|---|---|
  | `resource deadlock` throws per process | 17-20, every round | **0** |
  | failed tests per process | 35-41 | 4-6 |

  The remaining 4-6 are ordinary device-contention failures — two processes
  cannot both own the screen and the microphone, so `Start` legitimately fails.
  They are not deadlocks and they reproduce identically on an unmodified build.
- **Do not conflate with the CI hang.** That was a separate bug, also fixed:
  an ABBA lock inversion between `RecordingEngine::mutex_` and the indicator's
  `provider_mutex_`. See the entry above. This entry and that one shared a
  symptom family and nothing else.


## Windows — capture exclusion

### The other four capture-excluded windows never re-verify WDA after a mutation (Windows machine)

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

### Should the live camera bubble hide while a recording is paused? — decide (product call, Windows)

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

### Camera intro/outro may run on a different time base in the preview vs the export (UNTRIMMED clips only) (Windows machine)

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

### Log files lose their beginning while the app is still running (Windows machine)

> **NARROWED 2026-09-30.** Two of the three evidence points turned out not to be
> loss at all, and five candidate causes inside the app are now closed — four of
> them pinned by tests in `test/core/logging/file_log_sink_test.dart`. What is
> left is one real, unexplained sighting. Read "What is no longer evidence"
> before spending time here; it is where the previous two attempts went.

- **What:** a day's log file is rewritten mid-session, losing everything written before some point. The app never recovers the lost lines; it keeps appending after them.
- **The one sighting that still stands:** `logs_2026-07-27.jsonl` was 313,453 bytes / 917 rows at 22:31 local, and 3,439 bytes / 7 rows four minutes later, with appends continuing normally afterwards (back to 138 KB / 294 rows within minutes). Nothing explains that yet. It predates the logging unification, and has not recurred in any file on the Windows box since.

**What is no longer evidence — do not re-chase these.**

- **"No `Logger initialized` line, and a first row later than the session's own id."** This was listed as the truncation signature. It is the normal **midnight rollover** shape: the sink recomputes the daily filename on every flush, so a session that crosses local midnight writes its start line into the previous day's file and continues into the next one, which legitimately has no start line. `logs_2026-09-16.jsonl` on the Windows box shows exactly this for session `2026-09-15T20:16:42Z`. Pinned now by *"the post-midnight file legitimately has no session-start line"*.
- **"A file contains the previous day's timestamps."** Filenames use the **local** date (`_dateStamp(DateTime.now())`), rows carry **UTC** (`_nowUtcIso()` → `toUtc()`). At UTC+3 every file legitimately opens with rows stamped 21:00 the day before. The second sighting — `logs_2026-07-28.jsonl` carrying sessionId `2026-07-27T22:12:15Z` — is this, not loss: that is local 01:12 on the 28th, the right file.

**Closed inside the app, with tests where a test was possible.**

- *A crash-and-restart cycle reopening the path without append* — the entry's own leading hypothesis, never actually exercised. `init()` on an existing same-day file does not shorten it, and the next append extends it. Pinned.
- *Pruning reaching the live file* — `_pruneOldLogs` holds the sink's only `delete()`. Pinned at `retentionDays: 1`, the tightest cutoff.
- *A clock jumping backwards across midnight* re-points the sink at a file that already has content. It appends. Pinned.
- *Lines lost in the write queue* — `_processQueue` snapshots, clears, then awaits, so anything enqueued during the await lands in the next batch. 200 appends produce exactly 200 lines, none dropped, none duplicated. Pinned.
- *Lines dropped before the sink is ready* — `append` is a no-op before `init`, but `Log.init` awaits `FileLogSink().init()` and then drains a pre-init buffer before emitting its own start line (`logger_service.dart:159-180`). Nothing is dropped. Not separately pinned; the ordering is the proof.

**Also ruled out by reading, unchanged from before:** `FileLogSink` only ever appends (`FileMode.append`, `file_log_sink.dart:125`); `_rollToCurrentDate` constructs a `File` object and creates nothing. On macOS the native side only reads the path. **On Windows too** — `storage_router.cpp` only stats and reveals the logs dir; its one `fs::remove_all` (:228) is gated to `.clingfyproj` directories under the recordings root and cannot reach `Logs/`. There is no log-clearing UI; `logsBytes` is display-only.

- **So the writer is still outside the app's logging path,** and that conclusion is now much better supported. Candidates, in the order worth testing: a second app instance sharing the file, an external tail/editor/sync tool rewriting it, or a crash-and-restart cycle at the OS level.
- **How to settle it cheaply:** watch the size while using the app and note what is on screen when it drops — `while :; do stat -c '%s %y' "$LOGS/logs_$(date +%F).jsonl"; sleep 5; done`. One drop caught in the act ends this entry. Without one there is nothing further to deduce from inside the repo; every in-app path is now either pinned or read.
- **Start at:** `lib/core/logging/file_log_sink.dart`, `lib/core/logging/logger_service.dart:159`.
- **Effort:** human ~2h / CC ~30min once the drop is caught in the act.

### Confirm a Bluetooth SPEAKER is warned about — verify (needs a Bluetooth speaker, macOS)
- **What:** Verify that a Bluetooth loudspeaker (not a headset) triggers the speaker-bleed warning.
- **Why:** This is the last unresolved half of the old "disambiguate Bluetooth and USB routes" item. `AudioOutputRouteProbe` now prefers `kAudioStreamPropertyTerminalType`, which resolved the headset case on real hardware — a JBL WAVE100TWS earbud reports `'hdph'` and correctly produces no warning, verified live. A Bluetooth *speaker* has never been measured: if it reports `'spkr'` or a USB-AC speaker code it is already handled, but if it reports `'hdph'` or `0` the warning will be missed, and a missed warning ruins an unrepeatable take.
- **Also unmeasured:** USB headsets and USB desk speakers. Both fall back to the transport type, which returns `unknown` for USB, i.e. no warning either way.
- **How (10 seconds per device):** connect the device, run `tools/audio/probe_audio_output_route.swift`, and add the row to that file's header table. Only extend `routeFromTerminalType` for codes actually observed — mapping from the USB spec alone is how a confident wrong answer gets shipped.
- **Start at:** `macos/Runner/Capture/Audio/AudioOutputRoute.swift` (`routeFromTerminalType`), `macos/RunnerTests/RunnerTests.swift` (`testTerminalTypeResolvesRoutesTransportTypeCannot`).
- **Effort:** human ~15min / CC ~10min once a row exists.

### Windows AAC profile-level is pinned to "2ch / 48 kHz" while the rate is configurable (Windows machine)
- **What:** Both Media Foundation AAC writers hardcode `MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = 0x29`, which specifies AAC-LC at **2 channels, 48 kHz**, while the surrounding encoder config (`mf_encoder_config.h`) validates and permits **44.1 kHz** as well.
- **Why:** A 44.1 kHz export would declare a profile level that does not describe the stream it contains. Today nothing reaches that path, so this is latent, not live.
- **Re-checked 2026-09-20, and the reason it is latent CHANGED.** This entry used to say WASAPI "hard-rejects any endpoint that is not 48 kHz float32 stereo". That stopped being true in #468, which opens the stream with `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` so a 44.1 kHz interface records instead of failing — so the stated gate ("becomes real the moment WASAPI accepts a wider range") has already been crossed. It is still latent for a different reason: the shared-mode engine resamples INTO the canonical 48 kHz float32 stereo pipeline format, and both `AudioEncoderConfig` call sites (`recording_engine.cpp:519`, `export_pipeline.cpp:786`) use the 48 kHz default, so the encoder never sees another rate. The live trigger is now narrower and more specific: `AudioEncoderConfig::sample_rate_hz` being set to anything but 48000, not anything about the capture device.
- **Context:** Found by the completeness sweep during the 2026-07-26 macOS export `-11861 "Cannot Encode Media"` investigation. The macOS side of that bug class was the same shape: an encoder parameter fixed independently of the source. macOS is now fixed via `AACEncoderSettings`; Windows has no equivalent single source of truth.
- **Do NOT "fix" this speculatively.** Changing a profile-level indicator without a stream that actually exercises it is how a working encoder gets broken. Wait until 44.1 kHz is genuinely reachable, then derive the indicator from the configured rate and channels.
- **Start at:** `windows/runner/Encoding/mf_sink_writer_encoder.cpp:220-232`, the sibling MF writer, and `windows/runner/Encoding/mf_encoder_config.h:45-57`.
- **Effort:** human ~1h / CC ~15min once reachable.

## Feature backlog (not started, partial or parked)

*Swept 2026-10-20* from the roadmap and plan docs, the decision and Windows
docs, the code (reserved modes, no-op handlers, hidden UI) and the history,
then checked against the code: each item below is genuinely not done.
Windows transcription is tracked under *Editor — captions*.
Tags:
- **code:** buildable as specified.
- **idea:** needs a product decision first.
- **parked:** deliberately deferred, and why.
- **(Windows machine):** build and test it on Windows. Ask a Windows session
  for a brief in `docs/windows-machine-work.md` when one is picked up.

### Captions and on-device models

- **Subtitle translation** — idea, macOS + Windows, not started (decide). Whisper's `large-v3-turbo` cannot translate, so this needs a second engine; `Caption.translatedText` is serialized and never filled. Choose the engine (on-device or cloud), then the UI: a target language, and a burn-in and sidecar per language. Moved from *Editor — captions* 2026-10-26. *Source:* lib/core/timeline/model/edit_track.dart:247-294, :367-369

- **Word-level caption editing (click a word to edit, drag to retime)** — parked, macOS, deferred. `CaptionWord` timings are stored, and reflow-on-split uses them; click-to-edit was never built. Only on real user demand (2026-08-04 eng review, R2). *Source:* lib/core/timeline/model/edit_track.dart:201-222

- **Per-line editor for a two-line subtitle that mixes scripts** — parked, macOS. The text field has one direction for all lines, so line 2 shows in line 1's order while being edited; export and preview are correct (#601). *Source:* lib/app/home/post_processing/widgets/post_captions_section.dart

- **LocalModelManager as a real subsystem** — code, macOS + Windows, partial. Only per-variant reporting shipped. Still missing: per-variant delete (delete() removes every model), on-demand download with progress outside a transcription job, hash checks, versioning, offline state and per-model licence notes. DeepFilterNet, M2M-100 and Windows whisper.cpp all depend on it. *Source:* docs/editing-platform-plan.md:324-334; macos/Runner/Services/CaptionModelStore.swift:212; lib/core/bridges/native_bridge.dart:1141

- **Hardware-aware 'Auto' speech-model choice** — code, macOS, not started. The plan's default 'Auto' Whisper model, picked by hardware, was never built. The variant is a manual persisted preference with no safe value to reset to. *Source:* docs/editing-platform-plan.md:495-497 (§A.7.1)


### Audio

- **High Quality voice cleanup (DeepFilterNet)** — code, macOS + Windows, not started. The UI offers only Off / Light / Balanced. The highQuality wire value parses but runs RNNoise because DeepFilterNet has not been vendored. Blocked on LocalModelManager. *Source:* macos/Runner/Capture/Audio/AudioEnhancementPipeline.swift:12-43; windows/runner/Capture/Export/mic_cleanup.h:12; docs/editing-platform-plan.md:675-679

- **Per-source audio: system-audio gain and per-source normalize (Phase 1b)** — code, macOS + Windows, not started. Phase 1a shipped in #588, but gain and normalize still apply only to the mic, and system audio is fixed at unity on both platforms. Needs micGainDb/systemGainDb on the bridge, system gain baked in at export, and two Windows tests rewritten. *Source:* docs/editing-platform-plan.md:531-608; macos/Runner/Capture/Export/LetterboxExporter.swift:4073-4120; windows/runner/Capture/Export/export_audio.h:104-112

- **Audio limiter (AudioTrack.limiter is unimplemented)** — code, macOS + Windows, not started. AudioTrack.limiter (default true) is saved and loaded, but no native code reads it. The only ceilings in the audio chain are hard clips. *Source:* lib/core/timeline/model/edit_track.dart:626-642; docs/editing-platform-plan.md:602-603

- **True LUFS loudness normalize, and normalize audible in the preview** — code, macOS + Windows, not started. Normalize matches sample peak despite the targetLoudnessDbfs name, and it runs only at export. The preview hardcodes autoNormalizeOnExport: false, so you cannot hear it in the editor. *Source:* macos/Runner/Preview/InlinePreviewView.swift:729; docs/editing-platform-plan.md:597-602

- **Echo canceller redesign (pause detection that does not depend on level)** — parked, macOS, deferred. v6 failed acceptance (11x bursts during double-talk), so echo removal shipped as an experimental opt-in toggle, off by default. The redesign waits until users ask for it. *Source:* PR #266; lib/core/recording/settings/recording_settings_controller.dart:64; lib/l10n/app_en.arb:744

- **Stop embedding muxed audio in screen.mov (preview/export audio parity, #217)** — parked, macOS, parked. The preview applies a gain tap to the muxed audio in screen.mov, while export mixes the separated mic and system sources. Removing the embed has to ship together with a preview fix, and the issue needs rewriting first. *Source:* GitHub issue #217; docs/editing-platform-plan.md:610-625, :859-863


### Editor

- **Persistent scissors tool mode (Premiere-style razor)** — parked, macOS + Windows. Modifier-click cutting shipped instead (hold Option); a sticky blade tool fought the timeline's scroll/pan and trim gestures. Only on real user demand (2026-06-28 eng review). *Source:* lib/app/home/preview/widgets/video_timeline.dart; lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart

- **Frame preview on the clip lane during cut-hover** — idea, macOS + Windows. Hover-peek is wired only on the ruler strip, so a modifier-click cut on the lane area does not show the frame first. Needs the ruler path's coalescing and peek-end hardening. *Source:* lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart:489-494

- **One undo history across editing domains** — parked, macOS + Windows, parked. There are four separate EditSessions, so undoing a colour change cannot undo a clip split. Deliberately parked until a user complains. *Source:* docs/editing-platform-plan.md:31-36, :873-876, :912-914

- **Editable zoom lane lines up with the ruler under cuts and reorders** — code, macOS, partial. Only the display-only lane maps segments onto the edited timeline. The editable lane shows raw source-time segments, so on a cut or reordered project the pills do not line up with the ruler. *Source:* lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart:436-447; lib/core/zoom/zoom_editor_controller.dart:313-335


### Recording

- **Follow-mouse recording across displays** — code, macOS + Windows, not started. DisplayTargetMode.followMouse and its strings exist, but the UI never offers it. macOS resolves it the same as mouse-at-start, followMouseMonitor is never used, and Windows rejects it. *Source:* lib/core/models/app_models.dart:739; macos/Runner/Capture/Targeting/CaptureTargetResolver.swift:55; macos/Runner/Capture/ScreenRecorderFacade.swift:212; lib/l10n/app_en.arb:15-16

- **User-configurable recording filename template** — code, macOS + Windows, not started. Dart always sends the hardcoded '{appname}_{date}_{time}' and no UI lets the user change it, although features.md lists a template as shipped on macOS. The Windows setter is a no-op. *Source:* lib/app/home/home_actions.dart:76; windows/runner/Bridge/Routers/recording_router.cpp:426; docs/features.md:122


### Export

- **Higher default bitrate when effects force a re-encode of screen content** — idea, macOS + Windows, not started. Plan rule: text-, UI- and code-heavy screen video that has to be re-encoded should default one bitrate step above camera footage. Nothing implements it. *Source:* docs/editing-platform-plan.md:845-848

- **Chroma key plus camera shadow: suppress or mask the shadow** — idea, macOS + Windows, not started (decide). With chroma key and a shadow preset both on, the baked shadow shows through the keyed area as an 18-32% tint. Suppressing or masking it is an open product call. *Source:* docs/windows-port.md:504-507; docs/windows-beta-tester-guide.md:136-138


### Engine and tech debt

- **Metal/CIImage replacement for AVVideoCompositionCoreAnimationTool** — parked, macOS, parked. A future spike. The ~100-CALayer ceiling has never been hit, so nothing is blocked on it. *Source:* docs/editing-platform-plan.md:852-855

- **Finish the ScreenRecorderFacade strangler (coordinators into RecordingEngine)** — code, macOS, not planned. The facade is still a ~3,000-line orchestrator. Moving the camera, overlay, cursor and indicator coordinators into RecordingEngine was judged a large slice with little payoff. *Source:* docs/windows-port-inventory.md:485-503


### Longer horizon

- **AI-assisted recording workflows** — idea, both, not started. A roadmap entry with no design or code behind it. *Source:* docs/features.md:138-145

- **Collaborative recording tools** — idea, both, not started. A roadmap entry with no design or code behind it. *Source:* docs/features.md:138-145


### Windows parity (Windows machine)

- **Windows capture quality and frame-rate control** — code, not started. setRecordingQuality and setCaptureFrameRate are no-ops, so the Quality and frame-rate group is hidden on Windows. Windows always records at the display's resolution and frame rate. *Source:* windows/runner/Bridge/Routers/recording_router.cpp:425, :430; lib/app/home/recording/widgets/recording_output_section.dart:46-49

- **Windows 'Exclude Clingfy from capture'** — code, not started. setExcludeRecorderApp is a no-op and the toggle is hidden. The obvious WDA approach risks the hybrid-GPU blank-window failure. *Source:* windows/runner/Bridge/Routers/recording_router.cpp:219-223, :427; lib/app/home/recording/widgets/recording_options_sidebar.dart:531-534

- **Windows live cursor highlight while recording** — code, not started. setCursorHighlightEnabled and setCursorHighlightLinkedToRecording are no-ops, so there is no live cursor halo on Windows and the Pointer control is hidden. *Source:* windows/runner/Bridge/Routers/camera_overlay_router.cpp:304-305; lib/app/home/recording/widgets/recording_options_sidebar.dart:430-433

- **Windows fixed-target zoom (draggable focus point)** — code, partial. Manual zoom segments shipped (#471), but previewGetZoomCapabilities reports fixedTargetPreview, fixedTargetExport and cursorSamples as false, so the macOS draggable focus UI is not offered. *Source:* windows/runner/Bridge/Routers/preview_router.cpp:38-54; docs/features.md:75

- **Windows area selection remembered across restarts** — parked, deferred. The crop region lives only in process memory, so Dart clears the saved area at launch and the user has to pick it again. macOS saves it natively. *Source:* lib/app/home/overlay/overlay_controller.dart:260-266; windows/runner/Capture/windows_selection_state.cpp:40; docs/windows-port.md:728-732

- **Windows 'Reveal area' overlay** — code, not started. revealAreaRecordingRegion is a no-op, so the Reveal Area button is hidden on Windows. *Source:* windows/runner/Bridge/Routers/devices_router.cpp:395-397; lib/app/home/recording/widgets/recording_source_section.dart:285-287

- **Windows window capture follows resizes and covers whole apps** — parked, deferred. The encoder stays at the window's starting size, so a window that grows is cropped. 'App (all windows)' captures a single HWND. *Source:* windows/runner/Capture/wgc_display_capture_backend.cpp:234-236, :523; docs/windows-port.md:719-722

- **Windows recording across sleep, lid-close and Win+L** — code, partial. KeepAwake blocks idle sleep and resume only rebuilds the preview. Session changes (lid-close, Win+L) mid-recording are a documented beta limitation, and no WTS or power notifications are handled; a watchdog is planned for after the beta. *Source:* windows/runner/flutter_window.cpp:213-226; docs/decisions/windows-phase-10-beta-readiness-plan.md:355-357

- **Windows crash salvage of the video (fragmented MP4)** — parked, deferred. The MF sink writer writes non-fragmented MP4, so a hard crash leaves an unplayable file and Windows only cleans up and shows a notice. Salvage would need MFTranscodeContainerType_FMPEG4, which is untested with hardware encoders and the preview. Decide using crash telemetry. *Source:* windows/runner/Services/recovery_sweep.h:23-25; docs/windows-port.md:174-191

- **Windows colour-grade parity with Core Image** — code, not started. At strong grades the D2D colour matrix chain differs from Core Image by up to 2.77 (tolerance 0.002). ColorGradeGoldenTest is excluded from CI until it is fixed. The fixtures are committed; the fix needs a Windows machine. *Source:* .github/workflows/ci.yml:703-714; windows/runner/Graphics/color_grade_effect.cpp; docs/editing-platform-plan.md:864-869

- **Windows uncut preview: mic gain and voice cleanup audible before the first cut** — code, partial. An uncut project plays through MediaPlayer, which can only attenuate, so gain and cleanup are heard only once a cut or trim switches to the edited audio path. gain_processor exists but has no host on the passthrough path. *Source:* lib/app/home/post_processing/widgets/post_audio_section.dart:145-156; docs/decisions/windows-editing-step4-7-preview-audio.md:135-160

- **Windows preview speaker-echo removal** — code, not started. Windows applies the mic echo canceller only at export, while the macOS preview plays the echo-cancelled mic. With echo removal on, the Windows preview does not match its export. *Source:* windows/runner/preview/preview_engine.h; windows/runner/Bridge/Routers/export_router.cpp:563; macos/Runner/Preview/InlinePreviewView.swift:1117

- **Windows true squircle (superellipse) camera mask** — parked, deferred. 'Squircle' is drawn as a rounded rect with a minimum 0.3 corner fraction (the code says 'true superellipse deferred'). macOS draws a real squircle path. *Source:* windows/runner/Capture/Camera/camera_bubble_painter.cpp:78-79, :101-115

- **Windows in-app live camera bubble: chroma key** — code, not started. The floating DComp bubble, the inline preview and the export apply chroma key, but the in-app Flutter bubble does not, because it needs a shader. *Source:* lib/app/home/widgets/camera_overlay_bubble.dart:193-195; docs/decisions/windows-camera-bubble-renderer-architecture.md:246-248

- **Experimental burned-in desktop camera bubble mode** — idea, parked. A mode that burns the live bubble into screen.mov, with previewBurnedIn honoured by the compositors, was considered and shelved. The double-composite guard makes it safe to add later. *Source:* docs/windows-port.md:501-503

- **Windows mic-out-of-loopback cancellation ('Listen to this device')** — idea, not started. With 'Listen to this device' on, the mic plays to the render endpoint and leaks into the system-audio loopback. Removing it would need the reverse of the export-time speaker-bleed canceller. *Source:* windows/runner/Bridge/Routers/recording_router.cpp:225-237

- **Windows hardware-accelerated preview decode (GPU end to end)** — code, not started. The preview reader uses CPU advanced video processing. Pairing it with the D3D manager measured about 1 fps because of GPU-to-CPU readback, so keeping frames on the GPU needs the compositor's upload seam redesigned. *Source:* GitHub issue #296; windows/runner/preview/preview_source_reader.cpp:95-106

- **Windows automatic updates (WinSparkle, in-app download, release notes)** — parked, deferred. Only a manual 'Check for Updates' exists; it opens the installer URL in the browser. There are no background checks, no in-app download or SHA check, and no release notes, and WinSparkle is not integrated (planned for the public beta). *Source:* windows/runner/Updater/; lib/app/settings/sections/about_settings_section.dart:72; docs/windows-port.md:357-362

- **Windows code signing and public beta release gates** — parked, deferred. The private beta ships unsigned (SmartScreen warning) and the Inno Setup licence has not been checked. Invites wait on NVIDIA/AMD stress results, a mixed-DPI dual-monitor pass, and a clean-machine licensing smoke test that is blocked on beta keys. *Source:* docs/windows-beta-release-checklist.md:90-95, :102-104, :122-157; docs/features.md:135-136


## Recently closed

Loose ends checked on 2026-10-16 and found done. Kept so they are not re-raised.

- **Windows camera layouts: side-by-side, stacked, background** (2026-10-29,
  W7 in `docs/windows-machine-work.md`). They fell back to a bottom-right
  bubble. Now macOS's frames (value for value with `CameraLayoutResolver`), a
  painter that takes any w x h, and backgroundBehind drawn under the screen in
  both the export and the preview.

- **Windows export audio tiers above 192 kbps** (2026-10-29, W6 in
  `docs/windows-machine-work.md`). Measured: the Windows 11 AAC encoder MFT
  accepts and produces 256 and 320 kbps. Windows now offers macOS's 192 / 256 /
  320 ladder, asks the encoder first and steps down where an older one refuses.

- **Windows hover frame-peek on the ruler** (2026-10-29, W5 in
  `docs/windows-machine-work.md`). `previewPeekTo` was a no-op on Windows, so
  hovering the ruler never showed the frame. It now seeks the preview, as
  macOS does; Dart keeps the playhead and seeks back on hover end.

- **Windows 'Screen under mouse' target** (2026-10-29, W4 in
  `docs/windows-machine-work.md`). The picker offered it and the engine refused
  it with `BAD_MODE`. `RecordingEngine::Start` now records the display under the
  cursor at start (`devices::MonitorUnderCursor`), as macOS does. Follow-mouse
  is not offered and stays refused.

- **Windows export destination pre-flight** (2026-10-29, W3 in
  `docs/windows-machine-work.md`). `ExportDestinationProblem` checks the
  folder before any work: drive or share not connected (said apart from a
  missing folder), folder gone, not a folder, or a failed probe write. It runs
  in `ExportPassthroughCopy`, so the byte-copy path is covered too, and the
  reply matches macOS (`EXPORT_ERROR`, reason as message, folder as details).

- **The GIF length cap has a Windows native backstop** (2026-10-29, W2 in
  `docs/windows-machine-work.md`). `RenderComposedExport` works out the
  exported length from the clips and the file (`GifExportedDurationMs`, value
  for value with Swift) and refuses over 60 s + 100 ms slack before any encoder
  or output file exists. The reply is `EXPORT_GIF_TOO_LONG` with
  `{durationMs, maxDurationMs}`, the macOS shape, and it is never retried as a
  device loss. A long recording trimmed under 60 s still exports, and MP4 / MOV
  are untouched. Pinned by `gif_export_policy_test.cpp`, `ExportPipelineTest`
  (the refusal leaves no file, trim, MP4/MOV, passthrough mapping) and
  `ReplyForExportOutcomeGifTooLongEmitsMacShapedDetails`.

- **Windows GIF size presets, long-edge cap and drift-free timing** (2026-10-29,
  W1 in `docs/windows-machine-work.md`). Small / Medium / Large cap the encoded
  long edge at 480 / 720 / 1080 (unknown or empty: 1080), value for value with
  `GifExportPolicy.swift`. The frame is composited at the full canvas and the
  WIC encoder downscales it (Fant), so padding and camera keep their
  proportions; `resolveExportSize` reports the encoded size. Delays come from
  `GifDelayAccumulator`, so a 15 fps GIF stamps 7, 6, 7… and a 10 s export is
  1000 cs, not 1050. Pinned by `gif_export_policy_test.cpp`,
  `ResolveExportPixelSizeTest` and `ExportPipelineTest.GifSizePresetsCapTheEncodedLongEdge`
  (decoded size per preset and the cumulative delay).

- **The dead pre-styled camera pass is deleted** (2026-10-29). `runStyledPass`, the
  styled intermediate renderer and its validation, and the `cameraAssetIsPreStyled`
  / placement-source-rect plumbing are gone, along with the non-inline camera
  branch of `CompositionBuilder`: about 1,300 lines across three files. All were
  unreachable since #33. An independent review found no behaviour change, and the
  combined export, camera and validator suites pass (185).

- **No-camera exports graded their background and padding, unlike the preview**
  (fixed 2026-10-26, decided: grade the screen only). The composition now renders
  the screen on a transparent canvas, and the writer composites the ungraded
  background under it after the grade; the validator does the same.
  `testAScreenOnlyExportLeavesThePaddingUngraded` pins it (under the old path,
  exposure −1 took the padding from 0.50 to 0.18), and a padded sweep in
  `ColorGradeValidatorMarginTests` measures the validator.

- **Camera segments had no merge fallback and were orphaned on failure**
  (fixed 2026-10-25).
  - While a recording holds the camera, `CameraCaptureCoordinator` defers
    anything that would stop the take: a camera change (resume re-show,
    hot-plug), a chroma-key frame output, and the recording connection's
    mirror. It applies them when the take ends. Until then the overlay shows
    the plain preview instead of an empty chroma bubble.
  - The camera merge uses the screen merger's composition and tries
    passthrough, then HEVC, then H.264.
  - Parts that cannot be joined are kept, with a manifest.
  - Review also found and fixed a second stop overwriting the first one's
    completion.

- **The screen merger matched audio tracks by position** (fixed 2026-10-25).
  `RecordingSegmentMerger.buildComposition` now:
  - keys audio by role (codec, channels, sample rate), so a part missing its
    system audio no longer shifts the mic into that track;
  - clamps every insert to the track's own range;
  - skips only a segment with no duration. A segment with audio but no
    picture keeps its time, because the cursor, source audio and camera
    timelines count it.

  Two identical formats still match by order. Live: a two-part take merged
  by passthrough to exactly the sum of its parts.

- **Native sends to Flutter happened off the main thread** (fixed 2026-10-24).
  `FlutterMainThread` (`PlayerEventHandler.swift`) wraps each event sink at
  `onListen`: the player, workflow, screen-recorder and updater channels.
  Also hopped to main:
  - export progress (the prepasses report from render queues);
  - the preview's AVPlayer status and ready-for-display observers;
  - the end-of-playback handler;
  - camera connect and disconnect.

  On main a send still runs at once, so ordering is unchanged. Live: a paused
  take, stop and preview open logged no "non-platform thread" warnings.

- **A recording failure told the user nothing** (fixed 2026-10-22). It read
  "A recording error occurred: " with no reason after the colon, for two
  reasons:
  - Windows sends the code ahead of the reason.
  - macOS sends the code itself as the message when a native error has none
    (`RecordingFinalizer.errorMessage`: `message ?? code`).

  `HomeErrorMapper` now shows the native reason. With none, or with only the
  code, it shows a whole sentence that points to Settings › Diagnostics.
  Export errors and output-file errors had the same hole and get the same fix.

- **Single-pass GIF export** (done 2026-10-20). Frames go from the export's
  render loop straight to the GIF encoder, with no temp MOV. On a 10 s 1080p
  clip it is about 30% faster (3.5 s → 2.5 s) and the GIF is 63% smaller,
  because the codec noise is gone. Tests pin frames, delays and size against the
  old render-then-convert path, uncut, cut and reordered. The numbers are in
  `docs/decisions/macos-gif-export.md`.

- **No GIF duration limit** (decided and shipped 2026-10-20). The cap is
  60 s of exported duration, after cuts. The dialog disables Export and says
  why, and the macOS exporter refuses before rendering. Nothing is trimmed
  silently. The Windows backstop is open, above.

- **Split and cut, colour, and voice cleanup** (checked 2026-10-20). Split
  and cut shipped in v1.0.5 on both platforms, and so did colour (Auto enhance
  and manual sliders). Voice cleanup (RNNoise) shipped in v1.0.6 on both
  platforms, with a Windows preview gap until the first cut. Auto-subtitles
  shipped on macOS in v1.1.0 (#424), with later language and model pickers and
  Arabic burn-in. GIF size presets shipped on macOS in 1.0.7 (#326). An older
  list called subtitles "not started" and voice cleanup "volume done, noise
  not"; both were wrong.

- **Every launch logged an uncaught exception from AppDelegate.** It called
  `super.applicationDidFinishLaunching`, which `FlutterAppDelegate` does not
  implement: Flutter observes the notification instead. The call raised out of
  AppKit's launch notification. Since 2026-10-20 super is called only if Flutter
  implements it. Checked on launches: the old build logs the exception, the new
  one does not.

- **Pausing on macOS 13-14 left the take impossible to stop.** The pause and
  resume callbacks had Swift names that bound to no selector, so AVFoundation
  never called them. Pause and stop then waited forever. Fixed on 2026-10-19,
  together with what that exposed:
  - The resume was guarded on `isRecordingPaused`, which read false after a
    confirmed pause, so it now uses the delegate's own state.
  - A repeated pause or resume is answered.
  - Per-stretch screen segments are recorded for camera sync.
  - The cursor pause runs on its queue.
  - A raised screen-recording start no longer crashes.
  - The project-root walk no longer loops forever outside a project. A test
    hit that loop, and the swap filled the disk.

  A real 13-14 Mac is still needed; see "Pause and resume on a real macOS 13-14
  Mac".

- **Camera started about 1s after the screen on resume.** A pause now pauses the
  camera file in place, and a resume continues the same file. Measured live on
  2026-10-19: the camera resumed 109ms after the resume request, against about
  1.1s before. Camera stretch 2 started 11ms after screen part 2, and the
  stretches sum to raw.mov exactly (5.403s). If the file cannot be continued,
  because the pause or resume was refused, did not confirm within 2s, or the
  file ended while paused, the camera falls back to a new file as before.

- **Camera coordinator seam, so the start failure paths are testable.** Done in
  #393 (`CameraCaptureCoordinating`, `CameraCaptureCoordinator.swift:19`, with
  tests at `RunnerTests.swift:577-680`).
- **"No microphone" must not open a microphone.** #384 was reverted by #388 and
  relanded by #390 after the Windows mixer fix #389. It passed on a device in #392.
- **Export colour curve.** Decided in #391: encode with gamma 1.961, the curve
  Apple's decoders apply. The preview was not changed. (Only the QuickTime check
  above, item 3, is still open.)
- **Some exports skipped the colour encode.** The `AVAssetExportSession` final
  path was deleted in #395 and its last use removed in #403. Every export now
  takes the manual reader/writer path and logs `finalRenderPath`.
- **A colour-graded export was deleted by its own validator.** Fixed in ba4cb80
  and #514. The dead `CompositionParams.colorGrade` field was removed in #599.
- **AWS release authentication.** Both prod lanes authenticate through OIDC and
  shipped 1.2.0. The old Azure lanes were deleted in #599. Prod releases need a
  reviewer's approval with no admin bypass (2026-10-14/16).
