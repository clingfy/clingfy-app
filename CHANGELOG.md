## [Unreleased]

### New Features
- Added **Voice Cleanup**, on-device background-noise removal for the microphone. Turn it on in the post-processing Audio panel and pick **Light** or **Balanced**; fans, room tone, and street noise drop away while your voice stays intact. It applies to the microphone only — system, game, and music audio are never touched — and you hear the result in the preview exactly as it will export. Off by default. macOS only for now; the Windows build gets it once the noise-suppression engine is ported.

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
