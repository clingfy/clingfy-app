# Clingfy Feature Reference

The canonical answer to "what can Clingfy do today?" — one row per user-facing
feature, with platform status. Update this file whenever a release ships
(alongside `CHANGELOG.md`).

- **Baseline:** macOS **v1.0.6** (2026-07-22). Anything newer is listed under
  [In development](#in-development-on-develop-unreleased).
- **Windows** is a beta port living in `windows/` — feature-complete for
  record → preview → edit → export, not yet publicly released. See
  `docs/windows-port.md` and `docs/windows-beta-tester-guide.md`.
- Engineering-level inventory (bridge methods, code locations):
  `docs/windows-port-inventory.md`.
- Marketing scripts derived from this file: `docs/marketing/reels-series.md`.

Status legend: ✅ shipped · 🚧 partial / with caveats · — not available yet.

## Recording

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Full-display recording | Record an entire display. | ✅ | ✅ |
| Window recording | Record a single app window. | ✅ | ✅ |
| Area recording | Draw a custom region and record just that. | ✅ | ✅ |
| Capture quality presets | Not available. Recording always captures at the display's native resolution; output size is chosen at export instead — see **Resolution presets** under Export. | — | — |
| Frame rate control | 30 or 60 fps. | ✅ | — |
| Pause & resume | Pause mid-recording and continue seamlessly. | ✅ | ✅ |
| Countdown timer | 3 / 5 / 10-second on-screen countdown before capture. | ✅ | ✅ |
| Auto-stop | Stop automatically after a set duration. | ✅ | ✅ |
| Floating recording indicator | Always-on-top pill with pause / resume / stop. | ✅ | — |
| Pre-recording control bar | Native bar to pick display / window / area, camera, mic, system audio before recording. | ✅ | — |
| Exclude Clingfy from capture | Keeps the recorder's own windows out of the video. | ✅ | — |
| Project bundles | Every recording is a reopenable `.clingfyproj` project. | ✅ | ✅ |

## Audio

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| System audio capture | Record what plays through the speakers. | ✅ | ✅ (48 kHz devices) |
| Microphone capture | Record the mic alongside the screen. | ✅ | ✅ |
| Microphone gain | Boost the mic up to +24 dB. Applied at export and previewed live (there is no capture-time input gain). | ✅ | 🚧 (export only) |
| Live mic level meter | dBFS meter while setting up. | ✅ | 🚧 |
| Exclude mic from system audio | Stops mic bleed into the system track. | ✅ | — |
| Export gain + volume | Per-export audio gain (dB) and volume. | ✅ | ✅ |
| Loudness normalization | One-click normalize to a loudness target at export. | ✅ | — |
| Live audio mix preview | Hear gain/mix changes while editing. | ✅ | ✅ |
| Voice cleanup | On-device background-noise removal for the mic (Light / Balanced), previewed live and baked at export. Mic only — system audio is never denoised. Off by default. | ✅ | — (engine not ported yet) |

## Camera overlay

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Live camera bubble | Floating webcam overlay while recording. | ✅ | 🚧 (opt-in) |
| Separate camera source | Camera records to its own file — re-place and restyle it in post. | ✅ | ✅ |
| Layout presets | Corners, side-by-side, stacked, background. | ✅ | 🚧 |
| Drag to position + size | Free placement, ~8–45 % of the canvas. | ✅ | 🚧 |
| Shapes | Circle / rounded rect / square / squircle. | ✅ | ✅ |
| Border, shadow, opacity, mirror, fit/fill | Full bubble styling. | ✅ | 🚧 |
| Glow highlight | Attention glow with strength control. | ✅ | 🚧 |
| Chroma key | Green/blue-screen removal with key color + strength. | ✅ | ✅ |
| Intro / outro animations | Fade, pop, slide in; fade, shrink, slide out. | ✅ | 🚧 (export-only) |
| Zoom emphasis + scale-with-zoom | Camera reacts to zoom segments. | ✅ | — |

## Cursor & zoom

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Cursor recorded as data | Cursor + clicks captured to a sidecar, re-rendered at export — not burned into pixels. | ✅ | ✅ |
| Cursor size at export | Scale the rendered cursor 0.5×–3×. | ✅ | 🚧 (arrow shape only) |
| Live cursor highlight | Halo around the cursor while recording, with strength control. | ✅ | — |
| Smart zoom | Click-driven automatic zoom suggestions. | ✅ | ✅ (automatic only) |
| Follow-cursor zoom | Zoom that tracks the cursor, with hysteresis smoothing. | ✅ | 🚧 |
| Fixed-target zoom segments | Manual segments with a draggable focus target. | ✅ | — |
| Zoom timeline editor | Add / move / resize segments, up to 3× magnification. | ✅ | — (zoom lane read-only) |

## Editing (new in v1.0.5)

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Split & cut clips | Split at the playhead or Option-click the timeline (scissors). | ✅ | ✅ |
| Delete & trim | Backspace/Delete removes a clip; drag a clip edge to trim. | ✅ | ✅ |
| Drag to reorder | Rearrange clips on the timeline. | ✅ | ✅ |
| Smooth edited playback | Preview plays through cuts and reorders with no stalls. | ✅ | ✅ |
| WYSIWYG export bake | Cuts export exactly as previewed — zoom, cursor, camera, and audio stay in sync. | ✅ | ✅ |
| Undo / redo | Full edit history for clip and color edits. | ✅ | ✅ |
| Color correction | One-click Auto enhance, plus manual exposure / contrast / saturation / temperature / tint. Live preview + export bake. | ✅ | ✅ |

## Canvas & layout

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Aspect presets | Auto / 4:3 / 1:1 / 16:9 / 9:16 canvas. | ✅ | 🚧 |
| Padding + corner radius | Frame the recording inside the canvas. | ✅ | ✅ |
| Solid background color | Color behind the letterboxed video. | ✅ | ✅ |
| Background image | Custom image behind the video. | ✅ | — |
| Procedural backgrounds | Abstract Waves / Graphic Mesh / Radial Glow presets with palettes, intensity, softness, randomize (v1.0.4). | ✅ | — |
| Per-recording canvas persistence | Padding, radius, and background restore when a project reopens (v1.0.4). | ✅ | — |

## Export

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Formats | MP4, MOV, animated GIF. | ✅ | ✅ |
| Codecs | HEVC or H.264. | ✅ | 🚧 |
| Resolution presets | Auto / 1080p / 1440p / 4K / 8K / custom. | ✅ | 🚧 |
| Bitrate control | Auto / low / medium / high. | ✅ | 🚧 |
| Fit modes | Letterbox or crop. | ✅ | 🚧 |
| Progress + cancel | Live progress dock; abort anytime. | ✅ | ✅ |
| Low temp-disk footprint | HEVC intermediate keeps long exports from eating the disk (v1.0.4: 4K60 ~705 GB → ~37 GB). | ✅ | — |
| Custom output path | Save dialog for the destination. | ✅ | ✅ |

## Projects, storage & app

| Feature | What it does | macOS | Windows (beta) |
|---|---|---|---|
| Reopenable projects | Open any `.clingfyproj` later and keep editing (Finder / Explorer integration). | ✅ | ✅ |
| Storage dashboard | Disk usage charts + safe cache cleanup. | ✅ | ✅ |
| Save folder + filename template | Choose where recordings go and how they're named. | ✅ | 🚧 (no template) |
| Crash recovery | Interrupted recordings are salvaged (macOS) or cleaned up with notice (Windows). | ✅ | 🚧 |
| Keyboard shortcuts | Configurable in-app shortcuts. | ✅ | ✅ |
| Terminal launcher | `clingfy` CLI opens the app from any terminal, optionally with a `.clingfyproj` (Windows installer can add it to PATH). | ✅ | ✅ |
| Light / dark theme | Native design systems per platform (macos_ui / fluent_ui). | ✅ | ✅ |
| Localization | English, Arabic, Romanian — UI and native surfaces. | ✅ | ✅ |
| Permissions onboarding | Guided flow for screen / mic / camera / accessibility grants. | ✅ | ✅ |
| Auto-updates | Sparkle on macOS; manual update check on Windows beta. | ✅ | 🚧 |
| Licensing | Free trial, then license activation; all built-in editing is covered by the base license. | ✅ | ✅ |
| Verbose logging | Settings toggle + `CLINGFY_LOG_LEVEL` env var for troubleshooting (v1.0.5). | ✅ | 🚧 |

## In development on `develop` (unreleased)

- **Windows Voice Cleanup** — the on-device RNNoise engine is built into the
  Windows target; wiring it into the Windows export/preview is the remaining
  work.
- **Windows beta launch** — installer, updater, and tester docs are ready;
  invites pending release gates.

## Roadmap (not started)

- Auto-subtitles + translation (on-device Whisper)
- AI-assisted recording workflows
- Collaborative recording tools

## Version history at a glance

| Version | Headline features |
|---|---|
| 1.0.6 (2026-07-22) | Voice Cleanup (mic noise reduction), separated mic/system audio + WYSIWYG preview, opt-in echo removal, clip/color edit persistence |
| 1.0.5 (2026-07-01) | Clip editing (split / cut / trim / reorder), color correction, verbose logging |
| 1.0.4 | Procedural backgrounds, per-recording canvas persistence, massive export temp-disk reduction |
| 1.0.3 | Follow-cursor + fixed-target zoom editing, floating zoom toolbar |
| 1.0.2 | Pause/resume, separate camera source, `.clingfyproj` projects, storage management |

Full details: [`CHANGELOG.md`](../CHANGELOG.md).
