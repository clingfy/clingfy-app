## [1.0.7] - 2026-08-01

Clingfy 1.0.7 adds **GIF export** and fixes colour end to end — from what the screen recorder captures, through the editor, to the file you share. Exports were encoded with a transfer curve they didn't declare, recordings were captured in your display's colour space but labelled as a narrower one, and the camera bubble was processed a second time the screen wasn't. Each of those quietly drained colour out of the result. All three are corrected. Alongside them: colour-grade undo/redo, a pre-recording bar that warns you about a quiet mic or speaker bleed *before* you record instead of after, and audio that survives Bluetooth microphones.

### Highlights
- **GIF export**, with Small / Medium / Large size presets — share a loop without leaving the app.
- **Colour is accurate now, capture to export.** Recordings are captured in sRGB instead of inheriting your display's wider space while being labelled otherwise, so saturated colour — brand reds, logos, syntax themes, charts — no longer arrives washed out. Verified against a reference chart: every patch now lands within a few levels of the colour that was actually on screen.
- **Exported colour matches the preview.** Exports declared one colour transfer and encoded another; the mismatch showed as a washed-out or shifted picture in every player. Fixed on every export path, including GIF, and the camera overlay no longer comes out darker than the screen behind it.
- **Colour grade undo/redo** — step back through grading changes instead of resetting and starting again.
- **The pre-recording bar warns you first.** A too-quiet microphone or system audio bleeding into your mic is called out before you hit record, not discovered in the export.

### New Features
- Added **GIF export** on macOS, with Small / Medium / Large presets that trade size against fidelity.
- Added **undo/redo for colour grading**, with the same history affordance the timeline uses.
- The pre-recording bar now surfaces **quiet-microphone and speaker-bleed warnings**, so a bad audio setup is visible before the take rather than after it.
- Clingfy now tells you it sends **crash reports**, and lets you turn them off in Settings › Diagnostics. The notice appears after your first export — not on launch, where a dialog about diagnostics is meaningless to someone who hasn't used the app yet.

### Improvements
- **System audio is captured by default**, and the recording bundle now reports honestly which audio sources it actually contains.
- The display list refreshes when screens are connected or disconnected, and your chosen device is no longer lost when the list changes.
- Audio device and route changes are pushed by CoreAudio instead of polled, so the app notices a headset appearing without a delay.
- Post-processing audio controls are gated on what the **recording** contains rather than whatever microphone happens to be plugged in now.
- Audio warnings collapse to a headline with detail on hover, instead of a wall of text on the bar.

### Bug Fixes
- Fixed exported colour on every path: the transfer function is now the one the file declares, the gamma matches what Apple's decoder applies, GIF transcoding undoes the export transfer rather than double-applying it, and no export path skips colour encoding.
- Fixed **recordings being captured in the display's colour space while labelled as BT.709**. On a wide-gamut Mac the file described itself incorrectly, so saturated colour was reinterpreted and shipped desaturated. Recordings made before this release keep the old data — re-record to get accurate colour.
- Fixed the **camera overlay coming out darker than the screen behind it**. The overlay was colour-processed once more than the rest of the frame, most visibly in midtones.
- Fixed AAC audio on **Bluetooth microphones**: the output bitrate and sample rate are derived from the real mix instead of an assumed 48 kHz, which had produced distorted or silent audio on some headsets.
- Fixed audio output route detection, which classified by transport and could mislabel a device; it now classifies by terminal type.
- A camera that fails or stalls at start no longer aborts the app, and a take is kept when the camera fails to finalize — you lose the camera, not the recording.
- A failed stop can no longer resurrect a finished recording session.
- The microphone level meter no longer re-frames the floating bar as it moves.

### Refactoring / Internal
- The export now has a single final render path. A second, rarely-taken path skipped colour encoding entirely, and the post-export validator was comparing against an un-encoded reference — scoring a correct export as drifted and an incorrect one as clean.
- Removed a leftover `AVAssetExportSession` probe from the writer path, and collapsed three copies of the output-container decision into one.
- Windows port (internal beta): audio capture, per-channel app identity, release-lane and telemetry fixes. Not user-facing on macOS.
- Owner-only internal and test device modes for analytics.

## [1.0.6] - 2026-07-22

Clingfy 1.0.6 is an audio release. It adds **Voice Cleanup** — on-device background-noise removal for your microphone — and, under it, a reworked audio pipeline that records the mic and system audio as separate tracks and previews the exact mix you'll export. Your clip and color edits now also survive a restart.

### Highlights
- **Voice Cleanup:** remove fans, room tone, and street noise from your mic with one tap — Light or Balanced. Mic only; your system, game, and music audio are never touched. Previewed live exactly as it exports. Off by default.
- **Separated audio + WYSIWYG preview:** the mic and system audio are captured as independent tracks and mixed at export, so the preview plays the true export mix instead of the recording's baked-in track.
- **Edits persist:** clip cuts and color grades are saved per recording and restored when you reopen a project.

### New Features
- Added **Voice Cleanup** in the post-processing Audio panel (Light / Balanced), on-device and private — nothing is uploaded. It cleans the microphone track only and the preview matches the export.
- The microphone and system audio are now recorded as **separate sources** in the project and mixed at export, unlocking mic-only processing without touching system audio.
- Added an opt-in **speaker-to-mic echo removal** for recordings made with speakers: it cancels the delayed copy of the system audio that bleeds into the mic during pauses. Off by default.
- **Clip and color edits persist** across app restarts, saved per recording.

### Improvements
- The editor preview now plays the **same mic + system mix the export produces**, so what you hear is what you get.
- You can keep **editing the timeline while an export runs**.
- Mic gain is baked into the mic track at export, so boosting the mic no longer distorts the rest of the mix.
- Loudness normalization and per-export audio gain/volume act on the voice track only.

### Bug Fixes
- Fixed the zoom lane drifting off the edited ruler under cuts.
- Export now checks the destination folder before rendering, so an unplugged drive fails immediately with a clear message instead of after a full render.
- Fixed a preview flicker and audio glitch when switching Voice Cleanup modes, and a case where a clip delete could hide the camera overlay.

### Internal
- Unified the macOS / Windows logging into one JSONL contract.
- Continued the **Windows beta**: **Voice Cleanup is now complete on Windows** — the on-device engine plus export, live-preview (WYSIWYG), and Light/Balanced strength, matching macOS — alongside separated mic/system audio, the camera-bubble renderer, and clip-editing playback. The Windows build ships **unsigned** for now (a signed build comes later), so it remains in beta and is not yet publicly released.

## [1.0.5] - 2026-07-01

Clingfy 1.0.5 grows the post-recording editor into a light video editor. It adds one-tap and manual **color correction** and a full **clip-editing timeline** — split, cut, trim, and reorder your recording — shown live in the preview and baked faithfully into the exported file. Under the hood, work also continued on the in-progress Windows build.

### Highlights
- **Color correction:** auto-enhance in one tap, or hand-tune exposure, contrast, saturation, temperature, and tint. The live preview matches the export.
- **Clip editing:** split a recording into clips, delete the parts you don't want, trim clip edges, and drag clips into a new order — all on the timeline, with undo/redo.
- Editing plays back **smoothly in the preview** (no pause at cut points) and exports exactly as previewed, keeping zoom, cursor, camera, and color aligned with audio in sync.

### New Features
- Added **color correction** to post-processing: a one-tap Auto enhance plus manual sliders for exposure, contrast, saturation, temperature, and tint. Adjustments stream into the live preview as you drag and are baked into MOV/MP4/GIF exports so the result matches what you see.
- Added a **clip-editing timeline**: split at the playhead, Option-click to cut anywhere (scissors tool), remove a selected clip (including via Backspace/Delete), drag a clip's end edge to trim, and drag clips to reorder them. Undo/redo covers every edit.
- The preview **plays through your cuts and reordering** in real time and the export bakes them in — zoom, cursor highlight, camera overlay, and color grade stay glued to the correct source moments, with audio kept in sync.

### Improvements
- Cut and reordered playback in the preview is now smooth end-to-end, with no stall at clip boundaries.
- Added a runtime-configurable log level (an environment variable plus a **Verbose logging** toggle in Settings) to make troubleshooting easier.

### Bug Fixes
- Fixed GIF export mistakenly saving as a `.mov` file.
- Fixed reopening a `.clingfyproj` project after it was renamed in Finder.
- Fixed editing-preview issues found in testing: seeking/scrubbing across cuts now lands on the correct frame, and reordered clips play back in the right order without skipping or jumping the playhead.

### Refactoring / Internal Changes
- Built a portable editing foundation shared across platforms — a unified timeline model with undo/redo and a serialization codec — that the clip and color features are built on.
- Continued the in-progress **Windows** build (beta track, not yet part of the shipped macOS app): recording, camera overlay, cursor and smart zoom, window/area capture, and MP4/MOV/GIF export now work on Windows.

### Docs / CI / Tooling
- Added a Windows-port handoff for the editing features (what's done on macOS, what's left to build on Windows, and the pitfalls to design around).
- Hardened the release publish step by guarding the CDN cache purge behind an endpoint check.
- Added the 1.0.5 release-readiness checklist.


## [1.0.4] - 2026-05-24

Clingfy 1.0.4 focuses on better-looking canvases and far more achievable high-resolution exports. It adds preset backgrounds with three procedural styles, makes your canvas settings stick when you reopen a recording, dramatically shrinks the disk space exports need, and improves error messages when storage runs out. Several visual and reliability bugs are also fixed.

### Highlights
- New preset backgrounds: Abstract Waves, Graphic Mesh, and Radial Glow.
- Padding, corner radius, and background now persist when you reopen a recording.
- Exports use far less temporary disk space — high-resolution recordings that previously required hundreds of GB or more now fit on a typical SSD.
- Clearer disk-full error messages with exact storage requirements.

### New Features
- Added three procedural canvas backgrounds — **Abstract Waves**, **Graphic Mesh**, and **Radial Glow** — with palette selection, intensity and softness sliders, and a randomize button. The live preview matches the final export.
- Added five built-in palettes: Blue Purple, Sunset, Aurora, Forest, and Mono.
- Canvas appearance (padding, corner radius, and background — color, image, or preset) is now saved per recording and restored when you reopen it.

### Improvements
- Reduced the disk space required for export by switching the screen pre-pass to a hardware-encoded HEVC intermediate. Estimated temp space on a 37-minute recording: 1080p30 dropped from ~88 GB to ~5 GB, 4K60 from ~705 GB to ~37 GB, and 8K60 from ~3.4 TB to ~57 GB.
- Improved the disk-full error message during export so it shows exactly how much space is required, how much is available, and the shortfall.

### Bug Fixes
- Fixed exports losing background color and rounded corners when recording with a camera.
- Fixed sharp 90° corners in the inline preview area so the rounded preview border now renders cleanly on macOS.
- Fixed the daily log file so sessions that cross midnight start a new file instead of appending to the previous day's, and older log files are pruned after 30 days.

### Refactoring / Internal Changes
- Continued a large internal restructure of the macOS recording engine, splitting it into smaller, individually tested components for better maintainability. No user-facing behavior change.

### Docs / CI / Tooling
- Added the 1.0.4 release-readiness checklist.


## [1.0.3] - 2026-05-10

## Highlights
* Added advanced zoom editing with **follow cursor** and **fixed target** modes.
* Added a draggable fixed-target zoom overlay for precise zoom positioning.
* Replaced the bottom zoom inspector with a floating pill toolbar so selecting a zoom segment no longer shrinks or resizes the timeline.
* Made zoom creation simpler by allowing users to create zoom segments directly from the timeline.
* Added a clear **New Recording** button with confirmation instead of relying on a small timeline close button.
* Improved responsive behavior across the timeline, preview controls, and left sidebar.
* Fixed Space key playback behavior while editing zoom segments.
* Improved audio settings behavior when no audio is available.


## [1.0.2] - 2026-04-19

Clingfy 1.0.2 focuses on reliability, editing flexibility, and polish. This release adds pause/resume recording, introduces a more powerful separate camera source workflow for editing and export, improves storage visibility and cleanup controls, and refreshes key parts of the UI. It also fixes several recording and export issues, including start failures, preview flicker, camera placement drift, export brightness/washout problems, and temp-disk related export failures.

### Highlights
- Pause and resume recordings
- New separate camera source workflow with better post-processing control
- Storage usage section and safer storage handling
- Major export reliability, color, and preview stability fixes

### New Features
- Added pause and resume controls while recording, including support in the recording indicator.
- Added a storage usage section with storage preflight checks and safer cached recording cleanup actions.
- Introduced a separate recorded camera source workflow, enabling more flexible camera editing and improved export control.
- Added project-based recording folders with `.clingfyproj` package support and Finder integration on macOS.

### Improvements
- Refreshed the editor shell and dark surface styling for a cleaner, more consistent look.
- Polished the home screen and storage area with improved layout, charts, spacing, and inline tooltips.
- Improved post-processing and recording controls with better dropdown sizing, sidebar organization, timeline polish, and more consistent sliders.
- Improved microphone level feedback and interaction in the recording UI.
- Completed localization updates across the app.
- Increased the default post-processing cursor size from 1.0x to 1.5x for better visibility.

### Bug Fixes
- Improved recording start reliability when storage is low, when selected microphones fail, and when ScreenCaptureKit returns start or invalid-parameter errors.
- Improved failure recovery by surfacing clearer start errors, preserving partial failures, and flushing cursor data on unexpected recording stops.
- Fixed export issues affecting separate camera workflows, including black output, camera drift, Y-position errors, timeline sync, background color issues, and styled shadow geometry mismatches.
- Fixed preview and post-processing issues including inline preview races, camera drag flicker, pane-resize playback instability, and stuck busy states after canceling countdowns.
- Fixed export quality issues including brightness/washout problems, red color shifts, letterbox regressions, unnecessary prepass failures, temp-disk exhaustion, and manual export frame retention.
- Fixed export dialog behavior so cancel/restore states are dismissed and restored more reliably when background export completes.

### Refactoring / Internal Changes
- Hardened export memory handling with scoped prepass cleanup and per-frame memory checkpoints.
- Refined internal preview/export synchronization and camera placement diagnostics.
- Cleaned up internal controller and UI implementation details for maintainability.

### Docs / CI / Tooling
- Updated GitHub Actions and Codemagic pipelines.
- Fixed failing and stale tests, and refreshed Flutter unit test coverage.
- Resolved analyzer warnings and formatting issues.
- Added and updated the 1.0.2 release-readiness checklist and template.


## [1.0.1] - 2026-03-21

- Bug fixes and performance improvements for v1.0.1.


## [1.0.0] - 2026-03-14

- Initial stable release.
