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
