# Left-open points (macOS)

One place to track the loose ends that earlier work left behind: things that
were flagged, deferred, or left unverified, and that nothing else tracks as a
task. Each entry says what it is, the evidence for its status, and what would
close it.

Last revised 2026-10-16 against `develop` at `abe470e` (app version 1.2.0).

**How to use this file.** When an item is closed, move it to *Closed* at the
bottom with the commit or PR that closed it; don't delete it. Add new items with
the date and where they came from. Larger planned work belongs in
`docs/editing-platform-plan.md`, and component-level debt in `TODOS.md`; this file
is for the small, easy-to-lose things in between.

Kinds: **verify** (needs someone to check the real app, no code), **decide**
(needs a product or engineering call), **code** (needs a change).

---

## Open

### 1. Camera-start safeguards have never been seen working on a real device — verify

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

### 2. Logs written just before a crash or quit can be lost — code

*From the same session (it was task #12). A crash's explaining log line never
reached disk.*

macOS has no flush on terminate or abort. `AppDelegate.swift` has no
`applicationWillTerminate`, and nothing under `macos/Runner` installs an
uncaught-exception or signal handler. Native log lines travel through
`DispatchQueue.main.async` into the method channel and wait in memory when the
channel is gone (`NativeLogger.swift:241-249`). On the Dart side,
`FileLogSink._processQueue` writes asynchronously (`file_log_sink.dart:113-125`).
`NativeLogger.flushPending()` is the startup handshake, not a terminate flush.
(TODOS.md's "Log files lose their beginning" is a different, Windows-side
problem.)

**To close:** on terminate, and optionally on an uncaught exception or fatal
signal, drain NativeLogger's pending lines and the Dart sink's queue
synchronously, or write straight to the log file. Add a test that the queue is
empty after the terminate path runs.

### 3. Dark recordings have never been checked in QuickTime after the colour fix — verify

*From the export-colour work (#383, #391, #395).*

The export encodes with gamma 1.961, chosen because Apple's decoders
(QuickTime, Preview, Safari, Messages) were crushing shadows with the spec curve
(`ColorTransferFunctions.swift:146`). That choice rests on decoder measurements
and unit tests. #391 asked for a real dark-clip check, and #395 and #396 both
still call it pending. The 1.0.7 release check used a bright sRGB chart, not dark
content, and no later release doc covers shadows.

**To close:** record a dark-mode or terminal clip, export it, and compare the
shadows in QuickTime against the screen. If shadows look right, close this. If
they look lifted or crushed, reopen the curve decision. The code comment names
the trade-off and a revisit trigger (`ColorTransferFunctions.swift:141-145`).

### 4. Recording captures at full display resolution for every quality — decide

*From the same session (it was task #10).*

`captureResolution = .best` is set for every quality
(`CaptureBackendScreenCaptureKit.swift:2071-2075`). The output size does follow
the chosen quality, so a 720p recording is 720p. But on a 5K display, ScreenCaptureKit
still samples the screen at 5K and downscales. That costs GPU, memory and power,
and nobody has measured the sharpness it buys. The repo itself records this as
unsettled: "Whether it should be conditional on quality is an open question,
deliberately not decided by this test" (`macos/RunnerTests/RunnerTests.swift:8691-8696`).

**To close:** measure CPU/GPU, power and sharpness at 720p and 1080p on a 5K
display with `.best` against `.automatic`/`.nominal`. Then either make it
conditional on quality, or keep `.best` and record why. Either way, update that
test comment.

### 5. Pause/resume segment merge may silently re-encode — verify + code

*Found while revising this list. Not raised in the original session.*

The final export has one render path, and it always applies the colour encode
(#395, #403; `LetterboxExporter.swift:3653-3672`). But at capture time, merging
paused/resumed screen segments still uses `AVAssetExportSession`. It tries
`Passthrough` first and falls back to `HighestQuality`
(`CaptureBackendScreenCaptureKit.swift:406-410`). If that fallback ever runs,
the screen file is re-encoded before the editor sees it, and nobody has checked
what that does to its colour tags or quality. The fallback is also silent: no log
line says which preset ran, so there is no way to tell from the field whether it
ever happens.

**To close:** log which preset completed the merge. If the fallback turns out to
be reachable, check that a re-encoded segment keeps its sRGB tagging. Or remove
the fallback if passthrough is the only acceptable outcome.

### 6. Arabic subtitles have not been checked in a real exported video — verify

*From the captions RTL fix, #601 (2026-10-16).*

The fix is proven by tests and by the subtitle bitmap the export burns in, but no
one has exported a video with Arabic subtitles and watched it. In the test run
the save dialog could not be driven.

**To close:** in a dev build, add cues for pure Arabic, mixed ("مرحبا Clingfy!")
and a two-line mixed cue. Export with burn-in plus an `.srt` file. Check the
video and open the `.srt` in a player. Letters should join, and word order and
punctuation should match how the editor shows the line.

### 7. Intel Macs are refused for subtitles while the copy promises a slow path — decide

*Open issue #448, the only open one of the 1.1.0 captions batch (#439–#465).*

**To close:** decide whether Intel Macs get subtitles (slowly) or are
explicitly unsupported, and make the copy say the same thing as the code.

---

## Smaller follow-ups

- **The colour-curve decision only lives in code comments.** The 1.961 choice
  is documented in `ColorTransferFunctions.swift:104-146` and `TODOS.md:129-151`,
  but there is no entry in `docs/decisions/`. Optional: write one, keeping the
  "revisit if Windows or browser playback becomes the primary target" trigger.
- **Full-range video buffers were deliberately not adopted.** The range was
  measured as a non-issue: the file declares limited range and contains limited
  range, and the earlier "full range" theory was a red herring (#372, closed).
  The only written record is that closed PR. Optional: add one line to TODOS.md's
  *RESOLVED (1.0.7)* entry. Also note that moving to planar buffers would mean
  reworking `clearPixelBuffer`, which currently memsets a 32BGRA buffer
  (`LetterboxExporter.swift:275-281`).
- **No native test that "no microphone" stays off.** The reland (#390) is on
  develop and tested on the Dart side (`home_actions_permission_preflight_test.dart`),
  and it passed on a device (#392). But no XCTest covers
  `effectiveMicCaptureEnabled` (`ScreenRecorderFacade.swift:973`).
- **Editing a two-line subtitle that mixes scripts.** The editor's text field
  has one direction for all lines, so line 2 shows in line 1's order while being
  edited. Export and preview are correct (#601). Documented in
  `post_captions_section.dart`. Fixing it would need a per-line editor.
- **Caption migration is only tested with one cue.** The `post/state.json`
  migration tests use a single-cue fixture (`test/core/timeline/post_state_store_test.dart:50-58`).
  Optional: add a multi-cue fixture so "every cue survives" is pinned.

---

## Closed

Checked on 2026-10-16 and found done. Kept so they are not re-raised.

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
