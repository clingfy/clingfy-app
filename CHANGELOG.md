## [1.1.0] - 2026-09-20

Clingfy 1.1.0 is two releases in one. On macOS it adds **auto-subtitles** — transcribed on the Mac itself, editable, burned in or written as `.srt`/`.vtt` — and fixes a bug that had been *deleting* colour-corrected exports since 1.0.5. On Windows the beta stops being a recorder with an editor bolted on: the zoom lane is editable, the inline preview finally shows what the exported file will actually look like, recordings no longer carry the yellow capture border, and HEVC exports are really HEVC.

**Clingfy for Mac now requires macOS 13 or later** (it was 10.15). The speech-recognition engine behind subtitles sets a build-level platform minimum that cannot be gated at runtime. macOS 13 was chosen over 14 deliberately — transcription is slower on 13, but nobody on it is frozen out. If you are on macOS 10.15, 11 or 12, 1.0.7 is your last update.

The Windows build remains a **beta and still ships unsigned**.

### Highlights
- **Auto-subtitles on macOS.** A Subtitles panel transcribes your recording on-device (nothing is uploaded), shows the cues in an editable list, plays them in the live preview, and lets you choose where they go on export: Off, Burn in, File, or Both. Cues reflow onto the edited timeline, so trims and reorders carry the subtitles with the footage.
- **A colour-corrected export is no longer deleted by Clingfy itself.** The final validation step compared the graded file against an *un*graded reference, charged your deliberate colour change to a budget sized for tiny pipeline error, and deleted the finished export — reported to you as "export failed", with no mention of colour. Exposure at a quarter of one slider was enough to trigger it. Present since colour correction shipped in 1.0.5.
- **Windows: the editor preview now shows what the export will produce.** Six separate things it was getting wrong are fixed — a hardcoded 1.5x zoom that ignored your slider and your on/off toggle, cursor data it could not read at all (so no zoom and no click halo on any real recording), camera intro/outro animations that played only in the exported file, a camera bubble that did not grow with the zoom, a zoom-emphasis pulse that rendered nowhere, and a bubble border and size drawn at export scale on a much smaller preview surface.
- **Windows: the zoom lane is editable.** Add a zoom segment, drag its edges, delete one the detector found, with undo/redo. Edits survive a restart, appear in the preview, and are honoured by the export. Deleting every segment really exports unzoomed instead of quietly falling back to the detected zooms. The file format is shared with macOS, so a project edited on one platform opens with its zoom edits intact on the other.
- **Windows: recordings no longer have a yellow border around them.** Windows Graphics Capture draws a yellow rectangle around whatever it is capturing, and every Windows recording shipped with it. Capture now runs borderless, for display, window and area recordings alike.
- **Windows: picking HEVC gives you HEVC.** "HEVC (H.265)" is the default in the export dialog, and Windows was silently handing everyone H.264 from the same UI that produces a real H.265 file on macOS.
- **The screen picker names your monitors, and can flash a number on each one.** The display list read "Screen 1", "Screen 2" — a positional label that identifies nothing. Rows now carry the real OS monitor name, and an Identify button flashes the matching number on the glass of every physical monitor.

### New Features
- Added **auto-subtitles** on macOS: on-device transcription, an editable cue list, captions in the live preview, and four export destinations (Off / Burn in / File / Both) writing `.srt` and `.vtt` next to the video. You choose whether the source is the microphone or the screen audio. Cues whose footage you cut are marked "Cut". The speech model downloads once on first use (~600 MB, with progress and a Stop that works), and a bundled caption font means Arabic and other non-Latin text renders instead of empty boxes. Every unavailable case gets its own sentence rather than a generic error — too-old macOS, an Intel Mac (slower, not blocked), a recording with no audio.
- **Settings › Storage now shows the speech model and lets you delete it.** Generating subtitles downloads a model that nothing in the app had disclosed — on one machine 859 MB, invisible to the very page that charts disk usage. The card lists both buckets (model weights plus the compiled Core ML cache, which nothing had ever counted) and Delete removes both and reports what was freed. It unloads the model from memory first, and refuses while a transcription is running. Subtitles you have already generated are kept.
- **Undo and redo for subtitle edits.** Correcting a cue is now reversible, with its own Undo/Redo pair in the timeline bar alongside Zoom, Clips and Colour — where the absence had read as a broken feature rather than an unbuilt one. "Generate again" is covered too: it replaces the whole transcript, including every hand correction, and is now one undo away instead of unrecoverable.
- **Clingfy tells you when a subtitle was too long for the frame.** A cue that does not fit is drawn shortened with an ellipsis, while the `.srt` / `.vtt` beside it and the caption editor both keep the whole sentence. The export now says how many cues that happened to. Portrait exports are the common case, because the text scales with the canvas height while the wrap box is a fraction of its width.
- **Windows: manual zoom segments.** Add, move, trim, delete and undo/redo segments in the zoom lane, persisted to the project and applied by the export — including a scripted export, which reads the saved edits directly.
- **Windows: recordings capture the real cursor shape.** Every Windows export previously drew one hardcoded white arrow — an I-beam over text, a pointing hand over a link, a resize cursor on a window edge all came out as the same arrow. This is record-time only: recordings made before this build keep the arrow, and the arrow stays the fallback.
- **Windows: speaker-to-microphone bleed can be cancelled at export.** Recording on speakers instead of headphones makes the mic pick up a delayed copy of the system audio, so the mix plays that audio twice — once clean, once as a smeared echo, worse the more mic gain you add. Windows had no cancellation stage at all and the toggle in the UI did nothing. A headphone recording comes back bit-for-bit unchanged, and your own voice is kept when you talk over the system audio. The preview does not run this pass yet, so preview audio will not match the exported mix.
- **Windows: device lists refresh themselves.** Plugging in a microphone, a webcam or a monitor mid-session left every list stale until you noticed and hit refresh. The app now listens for audio endpoint, camera and display changes, debounced so one dock connect does not trigger a storm of re-enumerations.
- **Identify your displays** from the screen picker, on both platforms — a number flashed on each monitor's glass, and again on the one you pick so the choice confirms itself. Hidden when you only have one display. The "Main display" row, which highlighted but did nothing when clicked, now works.
- **Windows: the camera bubble grows with the screen zoom.** The "scale with screen zoom" setting is on by default and had been a no-op on Windows. At a 2.0x zoom with the default multiplier the bubble now renders at 1.35x, in both the preview and the export.
- **Windows: the camera bubble's zoom-emphasis pulse renders.** A 2 Hz throb for as long as a zoom segment is active, at the strength set in the editor. The control had round-tripped to disk for months with nothing drawing it. Off by default; preview and export share a clock, so the bubble grows and shrinks at the same instants in both.
- **Windows: camera intro and outro animations play in the editor**, not only in the exported file — fade, pop and slide in; fade, shrink and slide out. Parking the playhead at 0:00 with a fade intro shows a partly-faded bubble, which is what the export does at that instant.
- **Windows: the app tells you when the live camera bubble cannot be shown.** On machines where the overlay cannot be hidden from the capture, showing it would burn the camera into the recording and double it at export, so it is suppressed — previously with no explanation at all. The warning makes clear the camera is still being recorded and still appears in the finished video.
- **Windows: audio devices that are not running at 48 kHz now work** — a 44.1 kHz USB interface, or anything you have changed in the Sound control panel. Recording used to refuse the device outright and the edited preview played silent video with no notice. Devices already at the expected format take exactly the old path.
- **Windows: HEVC export**, with an automatic fall back to H.264 on machines with no HEVC encoder rather than a failed export. The "copy the source file verbatim" fast path no longer bypasses your codec choice.

### Improvements
- **Keyframes are pinned every two seconds on Windows**, matching what macOS already asks for, at all three encoder sites — the recording, the export and the camera sidecar. Scrubbing, jumping across a cut and audio re-sync now cost a bounded, predictable amount of work, and exported files seek better in other players. This is a hint some hardware encoders ignore, and no playback threshold was retuned here, so the improvement is real but not guaranteed on every GPU.
- **The app sizes its chrome from the window's height as well as its width.** A 1920x1080 display at Windows' default 125% scaling gives the app 1536x816 logical pixels, which read as a roomy window: chrome rendered about 9% larger than the app's own default window uses, with less vertical room left for the preview and timeline.
- Cursor positions in the Windows preview glide between samples instead of snapping.

### Bug Fixes
- Fixed **colour-corrected exports being deleted** at the last step and reported as a failed export (macOS). Two commits: the first stopped the deletion, the second restored a working colour check — grading the reference the same way the writer grades the frames — rather than leaving the check blind. The two camera-composite export paths still skip the colour check deliberately, so those paths are safe from deletion but are not colour-verified.
- **Windows: the inline preview could not read the cursor track its own recorder writes.** It required a field the recorder has never written, so on every real recording it never zoomed, never drew the click halo, never scaled the camera with the zoom, and force-disabled your cursor toggle with a "cursor file missing" message.
- **Windows: the inline preview ignored your zoom settings**, always showing 1.5x regardless of the 1.0–3.0 slider and continuing to zoom after you switched the zoom effect off. The exported file had always honoured both. The click highlight now also ramps to full at your chosen zoom level instead of topping out partway.
- **Windows: in the editor preview, the camera bubble's border, shadow and minimum size were drawn at export scale** on a much smaller preview surface — roughly 1.5x too heavy at a 1080p export and 3x at 4K, with the bubble itself up to 32% oversized in vertical (reel) formats. The export and the live on-screen bubble were unaffected.
- **Windows: a camera bubble you dragged was rendered vertically mirrored.** Drag it to the top of the editor canvas and it appeared at the bottom of both the preview and the export. Corner presets were always correct.
- **Windows: where you dragged and resized the camera bubble during a recording is now carried into the editor and the export.** It was thrown away at stop, so every export re-placed the bubble bottom-right at the default size. Bubble size is also scaled correctly on high-DPI displays, where it previously seeded about a third too small at 150%.
- **Windows: reopening a project restores its canvas.** A saved recording previewed with none of its framing — no padding, no corner radius, no background, and no camera bubble — until you happened to touch some unrelated canvas control, at which point everything appeared. The saved canvas was restored into the app but never sent to the preview, and once sent it was dropped on arrival because the preview session did not exist yet.
- **Windows: a recording that could not start now reports a refusal instead of crashing.** Any failure while opening the video encoder — an unwritable output path, no GPU, Media Foundation refusing the configuration — hit a self-deadlock in the cleanup path and threw out of the recording-start call rather than returning its error. Deterministic, not a race.
- **Windows: the live camera bubble no longer freezes on screen for the rest of the session** when the graphics adapter wedges while camera frames happen to be stopped — during a pause, at end of stream, or after a resume from sleep. The dead bubble is hidden immediately and the fallback renderer is swapped in without waiting for a frame.
- **Windows: capture exclusion is re-verified after you drag the camera bubble**, and after a placement or display-scaling change. On builds where a window move silently drops that exclusion, the bubble could start appearing inside the recorded video, then a second time at export.
- **A sidebar-rail resize rebuilt the whole pane instead of changing its width.** In release builds that cost a full subtree remount and reset the pane's scroll position; in debug builds, a tooltip showing while the width settled threw a layout error that broke tooltips, menus and autocomplete for the rest of the session. This is also the candidate cause of the intermittent "clips lane missing from the editor" report.
- **Opening a project by file path** — Explorer/Finder double-click, file association, or a path on the command line — ran the open during the UI build, so the editor's first frame was drawn after a burst of internal framework errors.
- Fixed **a `<` in subtitle text swallowing the rest of the cue** in every WebVTT player. Anything after the `<` — `if x < y then` renders as `if x ` — vanished on playback while the file looked perfect in a text editor. Recordings of code are a core use case, so this was ordinary text, not an exotic one.
- Fixed **subtitle files being written empty, and write failures being reported to nobody**. Clearing every cue — the only way to remove a transcript — produced a 0-byte `.srt`, which a platform reads as a broken subtitle track rather than an absent one. And if the `.srt` could not be written at all, the export still said "Export successful", even with the destination set to *Subtitle file*, where that file is the whole deliverable.
- Fixed **`.srt` and `.vtt` being written next to a GIF**, where nothing can read them — two inert files whose presence suggested the GIF was captioned. Burn-in is the destination that works for GIF.
- **Windows: fixed subtitle sidecars landing in the wrong folder.** A path containing a folder with a dot in its name put the `.srt` and `.vtt` one directory above the video, named after the folder.
- Fixed **a subtitle correction being lost** if you quit, closed the recording, opened another one or switched tab within about a third of a second of typing it. The edit never reached the project: reopening showed the original text, with no sign anything had been thrown away.
- Fixed **the Subtitles panel vanishing entirely** when the check for whether subtitles can run failed — no notice, no explanation, and no way to retry short of reopening the recording. It now says so and offers Try again.
- Fixed **subtitles reporting themselves as still running after they had finished**, which left the Generate button refusing a second transcription.
- Fixed **a long transcript hitching the editor**. Opening a 30-minute recording's subtitles built every cue's text field at once; a 400-cue transcript now builds only the rows near the viewport.
- Fixed **reopening a recording that has subtitles discarding a canvas or colour edit** made while it was still loading — the restore ran with pure defaults over the change, and cleared the colour history so it could not be undone back.
- Fixed **opening a second recording while the first was still saving**, which wrote the new recording's blank defaults — neutral grade, no padding, no background — into the previous recording's project. Its colour grade and background were gone the next time it was opened.
- **Windows: fixed the app hanging when a recording is started again straight after stopping one.** A lock cycle between the recording indicator and the recording engine could leave the app never returning from the second start.
- **Windows: the yellow capture border is gone** from display, window and area recordings.

### Refactoring / Internal
- The Windows camera compositor was reduced to one pure render plan that both the preview and the export leg draw through, replacing two divergent copies of the geometry.
- Release-lane fixes: the Windows publish step had no way to report a failed upload, the macOS signing-evidence step validated the wrong artifact, the lanes were missing AWS credentials, and Sparkle now installs from its own tarball after Homebrew disabled the cask.
- Subtitle track settings (language, style, enabled) survive a cue correction instead of reverting to defaults, and a project file with missing or duplicated cue ids is refused rather than loading into a caption list that silently rewrites the wrong row. Neither was reachable through the app today.
- A controller notified after teardown no longer trips an assertion in debug builds. Release builds were unaffected.
- Windows native test isolation and CI timeouts, plus opt-in teardown tracing in the recording engine to characterise a bounded hang under investigation.
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
