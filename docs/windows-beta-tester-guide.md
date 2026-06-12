# Clingfy Windows — Private Beta Tester Guide

Phase 10.7 (Windows beta closeout). This is the tester-facing guide; the
engineering-side smoke matrix and release gates live in
`docs/windows-beta-release-checklist.md`.

## Requirements

- Windows 10 version 1903 (build 18362) or newer, **x64 only**
  (Windows-on-ARM is untested and unsupported for the beta).
- Windows **N/KN editions**: install the
  [Media Feature Pack](https://support.microsoft.com/topic/media-feature-pack-for-windows-10-n-and-windows-10-kn-editions-7d950064-4dcf-3970-1efd-6c2dd64a73e7)
  first — Clingfy records and encodes through Media Foundation, which those
  editions ship without.
- A per-user install: no administrator rights and no UAC prompt at any
  point (install, update, or uninstall).

## Installing

1. Download the installer you were sent
   (`Clingfy_Dev_Setup_<version>+<build>.exe` for the beta channel).
   Beta builds may be **unsigned**: if Windows SmartScreen shows
   "Windows protected your PC", click **More info → Run anyway**.
2. Run the installer. It installs to
   `%LOCALAPPDATA%\Programs\Clingfy Dev` and adds a Start Menu entry
   (desktop shortcut is an opt-in checkbox).
3. Updating: install a newer build over the existing one — it upgrades in
   place and preserves all recordings and settings. You can also use
   Settings → About → **Check for Updates**: when a newer build exists
   you get an "Update available" dialog whose **Download update** button
   opens the installer download in your browser.
4. Uninstalling (Settings → Apps, or right-click the Start Menu entry →
   Uninstall) removes the app, shortcuts, and file association — it
   deliberately **keeps** your recordings, exported videos, settings,
   and logs.

> Please don't install the dev and prod channels side by side: they
> currently share their single-instance lock and data folders, so
> launching the second app silently exits — nothing visible happens
> while the first one is running.

## Activating your license

Settings → **License**, press **Activate license key** (or "Activate key
or upgrade"), and in the dialog type the rest of your beta key — the
`CLINGFY-` prefix is pre-filled, you enter the `XXXX-XXXX-XXXX` part —
then press **Activate key**. Licenses are bound to the machine
(Windows' `MachineGuid`), so a key activated on one PC must be
deactivated before it can be used on another. If you see
`LICENSE_NOT_FOUND` with a key that works on a Mac, that is expected —
licenses are bound per device, not per person; ask for a Windows key.

Without a key you can still export a limited number of times on the
trial; activating removes the limit. Please activate early so license
paths get tested too.

## Where your data lives

| What | Where |
|---|---|
| Recordings (project bundles) | `%LOCALAPPDATA%\Clingfy\recordings\<id>.clingfyproj\` |
| Exported videos (default) | `Videos\Clingfy` (changeable in Settings) |
| Native logs | `%LOCALAPPDATA%\Clingfy\Logs` |
| App logs (JSONL) | `%APPDATA%\com.clingfy\clingfy\Logs\logs_YYYY-MM-DD.jsonl` |
| In-flight capture temps | `%TEMP%\clingfy_<session>.…` (cleaned up automatically) |

Tip: a recording is a *folder* ending in `.clingfyproj`. Double-clicking
it opens the folder (Windows treats it as a directory); to open it in
Clingfy, **right-click → "Open in Clingfy Dev"** (on Windows 11 it's
under "Show more options").

## Exporting diagnostics (please attach to every report)

Settings → **Diagnostics** → **Export Diagnostics**. The app builds
`clingfy-diagnostics-<timestamp>.zip` (recent app + native logs, device
inventory, permission states, capture diagnostics, app info, and a
sanitized copy of your newest project manifest) and opens an Explorer
window with the zip selected. Attach that zip to your report.

Privacy note: the project manifest in the zip has file paths and device
ids redacted, but the **log files and device inventory are included
as-is** — they can contain your Windows user name in paths and your
device model names. Skim the zip before sending if that matters to you.

## What to report, and how

Send reports to the channel you were invited through (or
`contact@clingfy.com`) with:

1. **Steps** — what you did, in order.
2. **Expected vs. actual** — one line each.
3. **The diagnostics zip** (see above), exported right after the problem.
4. **Machine info** — GPU model(s) (note if it's a dual-GPU laptop),
   number of monitors and their scaling (e.g. "primary 100%, secondary
   150%"), Windows version/edition, and camera/microphone models if the
   problem involves them.

High-value areas to exercise: every recording mode (display / window /
area), camera on and off, pause/resume, exports in all three formats
(MOV / MP4 / GIF), unplugging devices mid-recording, denying camera/mic
permission in Windows Settings, and multi-monitor setups with different
scaling.

## Known limitations in this beta

Recording & devices

- **Floating camera bubble is opt-in.** The live camera preview shows
  inside the app window by default. While recording with the camera on,
  the recording panel offers **"Use floating camera bubble"** (and the
  inverse, "Can't see the camera? Use in-app preview"). The bubble
  depends on a Windows capture-exclusion feature that silently fails on
  some hybrid-GPU laptops — if it doesn't appear, switch back to the
  in-app preview.
- Microphone / system audio need a 48 kHz device format (the Windows
  default). An incompatible device is skipped with a warning instead of
  being resampled.
- The system's yellow capture border stays visible during recording.
- There is no floating recording-indicator overlay yet — control
  recording (pause/resume/stop) from the app window.
- A crash mid-recording cannot salvage the video: on next launch you get
  a "recording was interrupted" notice and the unplayable remnants are
  cleaned up.

Editing & export

- **Smart zoom is automatic-only** (driven by clicks). The zoom timeline
  is read-only on Windows; manual zoom segment editing is not available
  yet.
- Cursor, smart zoom, and click rings render **in the export**, not in
  the preview player (the post-processing panels say "applied on
  export"). The camera bubble, including chroma key, *is* shown live in
  the preview; camera intro/outro animations are export-only.
- With chroma key + a camera shadow enabled together, a faint shadow
  tint can show through the keyed (transparent) region.
- The camera joins a moment after the screen recording starts, so the
  very first instants of a clip have no camera frames (matches macOS).
- The exported cursor is a standard arrow (no I-beam/hand shapes); click
  rings are included, but there is no cursor highlight halo.
- Backgrounds are solid colors only (no image/preset backgrounds), and
  GIF exports are fully opaque (the format has no partial transparency).
- An area selection is not remembered across an app restart — re-pick it.

App & updates

- Update checks live only in **Settings → About** (no update chip
  anywhere else, and no background checks in the beta).
- Some macOS settings (capture frame rate, cursor highlight, image
  backgrounds, exclude-mic-from-system-audio) are hidden on Windows
  because they don't apply yet — that's deliberate, not a bug.
