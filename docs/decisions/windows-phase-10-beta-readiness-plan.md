# Windows Phase 10 — beta polish / shipping readiness: plan & inventory

Status: **DESIGN LOCKED** (10.0, docs-only — no production code in this slice).
Owner: Windows port. Predecessors: Phases 0–9 (record → preview → export loop,
cursor/zoom/click effects, full camera overlay incl. chroma + animations — see
`docs/windows-port.md`).

Goal: get the Windows app from "a Release folder that works on the dev box" to
"a build a private/public beta tester can install, run, break, and report —
and that we can fix and update remotely."

This doc is the output of a six-dimension codebase inventory (permissions UX,
diagnostics/log export, installer/packaging, updater, crash/error mapping,
beta-blocker sweep) plus a completeness pass (licensing, privacy/consent,
power events, minimum OS, GPU variance, distribution channel). File:line
references were verified against `develop` at the time of writing.

## 1. What "beta-ready" means here

A tester on a clean Windows 10/11 machine (no Visual Studio, no dev tools) can:

1. Download and run a signed (or knowingly-unsigned) per-user installer.
2. Complete a first-run experience that tells the truth about Windows.
3. Record (display/window/area, mic, system audio, camera) → preview → export.
4. When something fails, see an actionable message — never a silent no-op,
   a raw `BAD_MODE`, or a dead button.
5. Export a diagnostics bundle in one click and get it to us.
6. Receive a fix: the app can tell them an update exists and hand them the
   new installer.

Everything in the slice plan traces back to one of those six.

## 2. Current state after Phases 5–9 (the short version)

**Solid (don't rebuild):**

- Permission plumbing: WinRT `AppCapabilityAccess` probes for mic/camera,
  `ms-settings:` deep links, recording-start preflight that only gates
  mic/camera on Windows (`windows/runner/Permissions/`,
  `permissions_router.cpp`, `lib/core/permissions/recording_start_preflight_rules.dart`).
- Camera readiness layer with 7-state precedence resolver
  (`camera_readiness.{h,cpp}`, Phase 9.1).
- Error-code contract synced three ways (`native_error_codes.h` ↔ `.dart` ↔
  Swift) with router reply-on-every-path discipline and structured
  `recordingFailed/recordingWarning/previewFailed` senders
  (`workflow_event_publisher.cpp`).
- Dart logging pipeline: JSONL daily logs with 30-day pruning
  (`file_log_sink.dart`), Sentry with `enableNativeCrashHandling=true`, the
  crashpad trio (`sentry.dll`, `crashpad_handler.exe`, `crashpad_wer.dll`)
  ships in the Release folder.
- Per-user data hygiene: recordings under `%LOCALAPPDATA%\Clingfy`, temp under
  `%TEMP%\clingfy_*`, exports under `Videos\Clingfy` — installer-friendly, no
  install-dir writes.
- Single-instance + `.clingfyproj` forwarding (`single_instance.{h,cpp}`),
  cold-start argv pickup; only the Explorer file *association* is missing.
- `getCaptureDiagnostics` real on Windows (minus free-space keys).

**Broken or missing for a beta (the four clusters):**

1. **Shipping infrastructure doesn't exist.** No installer (no
   .iss/.wxs/.msix anywhere), no Windows code signing, stock Flutter icon +
   lowercase "clingfy" branding (`Runner.rc:92-99`, `main.cpp:77`), no VC++
   runtime bundling, updater is a hardcoded `false`
   (`misc_router.cpp:26`) behind a visible Check-for-Updates button,
   `ops/release` is 100% macOS (no Windows *release* pipeline — plan for local
   PowerShell scripts; build/test CI for Windows now exists, see
   `.github/workflows/ci.yml`).
2. **Diagnostics die exactly where we need them.** Native logs write to
   CWD-relative `build\windows-poc\` (silently dropped for an installed app,
   `device_probe_log.cpp:16-19`); native logs never reach Dart/Sentry (no
   `InvokeMethod("log")` anywhere in `windows/runner`); the three
   Settings → Diagnostics buttons are `storage_router.cpp` no-op stubs — one
   shows a **fake success toast**; no one-click log export; no Windows PDB
   upload, so crashpad minidumps won't symbolicate.
3. **Failures are silent.** Mic open failure → silent no-audio recording
   (`recording_engine.cpp:317-345`); WASAPI device invalidation mid-record →
   silent forever-spin (`wasapi_audio_capture.cpp:283-294`); encoder death →
   nothing until Stop; crash mid-recording strands the MP4 in `%TEMP%` with
   no salvage (macOS has `RecordingFailureRecovery`; Windows has none);
   unmapped error codes render verbatim (`home_error_mapper.dart:89-90`);
   a C++ throw in any router handler kills the process (no dispatch barrier).
4. **The UI lies on Windows.** macOS-TCC-shaped onboarding ("macOS requires
   this", dead Restart App button, always-granted Accessibility step);
   reveal/open-folder buttons that no-op behind real UX (export toast,
   settings, storage pane showing 0 B); a zoom track that renders empty while
   the export silently applies auto-zoom; settings that silently do nothing
   (quality preset, file template, cursor highlight, exclude-recorder-app);
   hardcoded-English native toasts for AR/RO locales
   (`cacheLocalizedStrings` is a no-op).

**Verification debt (claims we must not ship on):**

- The **NVIDIA and AMD Phase 5.7 preview verdicts never ran**
  (`windows-phase-5-stress-verdict.md:116-139`) despite being the documented
  Phase 5 ship gate. Intel Iris Xe is the only PASS.
- **Native C++ crash capture is unverified** — crashpad files exist, but no
  forced-native-crash → Sentry-event-received test has ever been done.
- **Licensing end-to-end on Windows is unverified** — export is gated by
  entitlements (`license_controller.dart:106,237-261`), the backend binds
  per-platform, and nobody has run activate/validate/consume-trial on a clean
  Windows box. Beta testers need an entitlement provisioning answer.
- **Telemetry consent**: Sentry is always-on with no user-facing opt-out;
  logs carry recordingIds/paths/device names. Beta needs a
  disclose-or-opt-out decision and a privacy-policy check.

## 3. Locked decisions (D1–D10)

- **D1 — Installer = Inno Setup, per-user, NOT MSIX.** MSIX would mutate the
  assumptions the port is built on (unpackaged-Win32 permission semantics per
  `windows-port.md` §Permissions handling, `MachineGuid` licensing reads,
  `%LOCALAPPDATA%` data). Per-user (`PrivilegesRequired=lowest`, install under
  `%LOCALAPPDATA%\Programs\Clingfy`) avoids UAC during install AND during
  every future update. Bundles the VC++ CRT (missing-CRT failures are
  pre-telemetry and look like "never launched"). Registers the HKCU
  `.clingfyproj` association (receive side already built) and an uninstall
  entry with an explicit leftover policy for `%LOCALAPPDATA%\Clingfy`,
  `%APPDATA%\com.clingfy`, `%TEMP%\clingfy_*`.
- **D2 — Updater for the private beta = manual check against a static feed;
  full WinSparkle only at public beta.** Wire `checkForUpdates` to an HTTPS
  fetch of `appcast-windows.xml`/`latest.json` on the existing Azure Front
  Door (infra already serves the macOS appcast), version-compare against the
  `Runner.rc`/package_info version, emit `{type:'updateAvailable', version,
  build}` through a new `UpdaterEventPublisher` (the
  `WorkflowEventPublisher` pattern) replacing the `NoopStreamHandler`, and on
  tap open the signed installer download. This satisfies the entire existing
  Dart contract with no DLL vendoring. WinSparkle (background checks, its own
  dialogs, EdDSA enclosures) is the public-beta endpoint — and must replicate
  macOS's no-auto-start-in-DEBUG guard.
- **D3 — Code signing decided out-of-band, never in-repo.** Target Azure
  Trusted Signing or an OV cert (accepting early SmartScreen friction); a
  private beta may ship unsigned **only** with explicit SmartScreen
  instructions in the tester guide. Signing material follows the
  `SPARKLE_KEY_PATH` out-of-band rule.
- **D4 — Native logs move to `%LOCALAPPDATA%\Clingfy\logs` + a native→Dart
  log bridge.** Kill the CWD-relative `build\windows-poc\` paths (collapse
  the three duplicated `LogDeviceProbe` copies while there); add the Windows
  equivalent of macOS `NativeLogger.swift` (`InvokeMethod("log")`) so native
  ERRORs reach Sentry through the existing `telemetry_service` path. The
  three log-reveal handlers in `storage_router.cpp` become real
  (`ShellExecuteW`/`SHOpenFolderAndSelectItems`) with macOS error-code parity
  (`LOG_FILE_NOT_FOUND`/`LOG_FILE_UNAVAILABLE`).
- **D5 — One-click "Export diagnostics".** Zip Dart `Logs/` + native logs +
  the latest project manifest, then reveal the zip. That zip is the answer to
  "how do beta logs reach us"; the mailto flow stays as the transport for
  now. Includes a PII pass over what the logs contain before telling testers
  to send them.
- **D6 — No silent degradation.** Mic open failure, camera unavailable at
  start, WASAPI device invalidation mid-record, and an encoder write-error
  threshold all emit `recordingWarning`/`recordingFailed` through the
  existing publisher. `HomeErrorMapper` gets cases for every code that can
  reach it (`BAD_MODE`, `BAD_ARGS`, `NO_CAMERA`, `CAMERA_INPUT_ERROR`,
  `EXPORT_DISK_FULL`, `FILE_NOT_FOUND`, `WINDOWS_NOT_IMPLEMENTED`).
  `GetDiskFreeSpaceExW` lights up the existing disk-full UX
  (`getCaptureDiagnostics` free-space keys, `getStorageSnapshot`, an export
  pre-pass) **and** a recording-start free-space check on the `%TEMP%` drive.
  `MethodRouter::Dispatch` gets a try/catch barrier that replies a structured
  error instead of killing the process.
- **D7 — Permissions UX is forked by platform in Dart, copy points at
  pages not toggles.** Windows onboarding = Welcome + Mic/Camera (+ a
  one-line "Windows needs no screen-recording permission"), the Windows
  banner asset, no dead Restart App button. Settings → Permissions shows
  mic + camera only. ~12 l10n strings get Windows variants ("Windows
  Settings > Privacy & security"); because WinRT can't distinguish the
  global toggle from the desktop-apps toggle, copy must reference the privacy
  **page**, never a specific toggle. Camera readiness
  (`CameraReadinessCode`) gets surfaced to Dart (new bridge method or an
  extension of `getPermissionStatus`) so denial guidance can be specific.
  Keep the persisted onboarding step index compatible (clamp it).
- **D8 — The zoom editor must stop lying: surface auto-zoom read-only for
  beta.** Feed the native auto-zoom segments to `getZoomSegments` so the
  track shows what the export will do; keep manual editing
  (`saveManualZoomSegments`/`previewSetZoomSegments`) hidden/disabled on
  Windows for beta. Full manual zoom editing is post-beta. Same honesty
  sweep hides or disables the no-op settings (quality preset, file-name
  template, capture frame rate, exclude-recorder-app,
  exclude-mic-from-system-audio, cursor highlight, recording-time audio
  mix/gain) rather than letting them silently do nothing.
  (Do NOT implement exclude-recorder-app via `SetWindowDisplayAffinity` — it
  inherits the 9.3.2 hybrid-GPU invisible-window failure mode.)
- **D9 — Dev and prod get separate identities at the installer level.**
  Separate app name ("Clingfy Dev"), install dir, mutex/receiver id (the
  hardcoded `com.clingfy.clingfy` in `main.cpp:14-16` becomes per-config),
  and feed URL. Without this, a tester with both installs gets silent
  single-instance exits and cross-build project-open forwarding.
- **D10 — Hardware/OS gates are release criteria, not slice work.** Before
  invites: run the NVIDIA + AMD 5.7 preview verdict sessions (the AMD
  shared-handle path is historically the most timing-sensitive; budget real
  time if it fails); run a forced-native-crash → Sentry round-trip on an
  installed build; run the licensing activate/validate/consume smoke on a
  clean box; declare minimum OS = Windows 10 1903+ (WGC), **x64-only**
  (Windows-on-ARM untested/unsupported for beta), and document the Media
  Feature Pack requirement for N/KN editions (MFStartup fails there).

## 4. Slice plan (PR-sized) + acceptance criteria

Order chosen so diagnosability lands first (every later slice and every beta
ticket benefits), shipping infrastructure lands once there's something worth
shipping, and verification gates run on the real artifacts.

### 10.1 — Diagnostics + failure visibility  (`feature/windows-phase-10-1-diagnostics`)

Native log relocation to `%LOCALAPPDATA%\Clingfy\logs` (D4), native→Dart log
bridge, real log/reveal/storage handlers (kills the fake-success toast),
`GetDiskFreeSpaceExW` everywhere it's owed (D6), recording-start +
export disk checks, silent-degradation warnings (mic/WASAPI/encoder),
`HomeErrorMapper` completeness, `MethodRouter` dispatch barrier, one-click
Export-diagnostics zip (D5).
**Accept:** on a staged Release copy launched from Explorer outside the repo
(no installer exists until 10.5 — the property under test is
CWD-independence), native logs land in `%LOCALAPPDATA%`; "Reveal Today's
Log" opens Explorer at the real file;
unplugging the mic mid-record shows a warning toast; pulling the disk to <1GB
fails the export with the localized disk-full message; the diagnostics zip
contains Dart + native logs; a deliberately-thrown C++ exception in a router
replies an error instead of crashing. ctest + the Dart test suite green; new
contract entries in `bridge_contract_coverage_test.cpp`.

### 10.2 — Windows permissions UX  (`feature/windows-phase-10-2-permissions-ux`)

D7 in full: forked onboarding, Windows l10n variants (en/ar/ro), settings
collapse, camera-readiness surfacing, emit-or-delete decision for the unused
permission error codes (`native_error_codes.h:42-50`), fix the stale
`permission_probe.h:61` comment, implement-or-hide `relaunchApp`.
**Accept:** Windows first-run shows no macOS copy, no dead buttons; denying
camera in Windows Settings then starting a recording produces a specific,
actionable in-app explanation; existing permission widget tests forked per
platform and green.

### 10.3 — Honest-UI sweep  (`feature/windows-phase-10-3-honest-ui`)

D8: auto-zoom segments surfaced read-only, manual zoom UI hidden on Windows;
no-op settings hidden/disabled; area-region persistence across restart (fix
deferred 7.4 #1 — persist natively or clear Dart prefs on launch);
`IsBorderRequired=false` attempt (best-effort, deferred 7.4 #2);
`hero_panel.dart` strings into .arb; wire `cacheLocalizedStrings` so native
toasts localize.
**Accept:** the zoom track shows the segments the export renders; restarting
the app with a saved area selection either records or never claims it can;
no visible control silently no-ops; AR locale shows no English toasts from
native paths exercised in smoke.

### 10.4 — Crash salvage + symbol pipeline  (`feature/windows-phase-10-4-crash-salvage`)

Provisional manifest at record start (status `recording`) + next-launch sweep
marking interrupted projects failed (macOS `RecordingFailureRecovery`
parity); PDB retention in Release builds + a minimal standalone
`sentry-cli` symbol-upload script (10.5's release script absorbs it); the
forced-native-crash verification harness; the missing Dart `recordingFailed`
handling test.
**Accept:** kill -9 during a recording → next launch shows the interrupted
project with a failed state instead of a stranded `%TEMP%` file; a forced
native crash from a staged Release copy launched outside the repo appears in
Sentry symbolicated. (The same crash check re-runs on the real installed
build in the 10.7 release checklist.)

### 10.5 — Branding + installer  (`feature/windows-phase-10-5-installer`)

Real `app_icon.ico` from `assets/icons/app-logo-1024.png`
(flutter_launcher_icons windows block), `Runner.rc` strings + window title →
"Clingfy", dist staging script (clean copy, excludes `runner_bridge.lib` +
`native_assets.json`, verifies the crashpad trio + `dartjni.dll` decision),
Inno Setup per-user installer per D1, dev/prod identity per D9, signing per
D3, local PowerShell publish script to the existing Azure release storage.
**Accept:** on a clean VM with no VS: install → record → export → uninstall;
right-click "Open in Clingfy" on a `.clingfyproj` recording folder opens the
app (revised during the 10.5 smoke: recordings are directories and Windows
fires extension associations for files only, so the original "double-click
opens the app" criterion is unsatisfiable as written); Task Manager/taskbar/
file Properties all say "Clingfy"; uninstall leaves only the documented
leftovers.

### 10.6 — Updater  (`feature/windows-phase-10-6-updater`)

D2: real `checkForUpdates` (static feed fetch + version compare),
`UpdaterEventPublisher`, feed URL delivery to native (CMake define or Dart
handoff — decide in-slice), honest Settings → About button (working check on
Windows, never silent-false), `relaunchApp` if the chosen flow needs it,
appcast/latest.json publish added to the release script. Contract tests
updated (`bridge_contract_coverage_test.cpp`, `router_stub_shapes_test.cpp`).
**Accept:** with a staged feed advertising a newer version, the app surfaces
"update available" and lands the tester on the new installer; with a current
version it reports up-to-date; dev builds don't prompt from the prod feed.

### 10.7 — Beta closeout  (`feature/windows-phase-10-7-beta-closeout`)

Run the full smoke matrix (§5) on the gate hardware (D10); licensing
end-to-end smoke + the beta entitlement provisioning decision; telemetry
consent/disclosure decision implemented (at minimum: disclosure in the
tester guide + About); tester guide (install incl. SmartScreen, known
issues, how to report, where the diagnostics zip goes); Sentry release
tagging so a report maps to an exact build; `docs/windows-port.md` Phase 10
closeout section.
**Accept:** the beta release checklist (§6) is fully green.

### Parallel track P — hardware verdicts (no branch; real machines)

NVIDIA + AMD Phase 5.7 preview stress verdicts
(`windows-phase-5-stress-verdict.md`), hw-vs-sw encoder check per GPU
(`mf_dxgi_manager.h:17-18` documents the silent software fallback), one
multi-hour + pause-heavy soak (memory/handle growth, `%TEMP%` accumulation).
Can start any time; **must** be done before invites (D10).

## 5. Final smoke matrix

Machine classes, full pass: Intel iGPU (done for preview), NVIDIA dGPU, AMD
dGPU, hybrid (the WDA-failure laptop). Machine classes,
install/first-run/uninstall-only (no recording — VM GPU capture is out of
scope): a clean Win10 1903-era VM, a clean Win11 VM. RDP sessions and
HDR-display hosts are documented-unsupported for beta (WGC restrictions /
SDR washout) — listed in the tester guide, not the matrix. Beta is
**x64-only**; Windows-on-ARM (Prism emulation) is untested/unsupported and
says so in the tester guide.

Full pass, per machine: install (signed path + SmartScreen path) → first-run
onboarding → record display/window/area with mic + system audio + camera →
pause/resume → in-app camera preview (+ floating where the GPU allows) →
device-loss mid-record (camera unplug; mic unplug) → inline WYSIWYG preview
(cursor, zoom, camera styling, chroma) → export MOV/MP4/GIF with progress +
cancel → mirror/opacity/border/shadow → chroma key → intro/outro completes →
no-camera and camera-denied fallbacks → reveal/export-diagnostics buttons →
disk-full export → update check against a staged feed → uninstall.

At least one full-pass machine runs a **mixed-DPI dual-monitor** pass:
primary at 100%, secondary at 150% (or 200%), record display/window/area on
the **secondary** monitor, and verify cursor position, zoom focus, and area
coordinates in the export. DPI/multi-monitor is a primary breakage axis for
a screen recorder and is not otherwise exercised by the matrix.

## 6. Beta release checklist

- [ ] All 10.1–10.6 slices merged; ctest + Dart suites green locally.
- [ ] NVIDIA + AMD preview verdicts PASS recorded in the stress-verdict doc.
- [ ] Forced native crash from an installed build is symbolicated in Sentry.
- [ ] Licensing activate/validate/consume-trial passes on a clean Windows box;
      beta entitlement provisioning decided and documented.
- [ ] Telemetry disclosure (or opt-out) shipped; privacy policy covers
      Windows crash/telemetry collection.
- [ ] Signed installer (or documented unsigned flow) downloaded and installed
      on a machine that has never seen the repo.
- [ ] Update path proven end-to-end: vN installed → feed advertises vN+1 →
      tester lands on the vN+1 installer → vN+1 installs over vN cleanly
      (no file-lock failure) → app relaunches with settings, license
      activation, and existing projects intact.
- [ ] Smoke matrix (§5) executed on the gate hardware; results recorded.
- [ ] Tester guide published (install, SmartScreen, known issues, minimum OS
      = Win10 1903+ x64-only, Media Feature Pack note for N editions, how to
      report, diagnostics zip flow).
- [ ] Sentry release tagging maps every report to an exact build.
- [ ] Known-issues list in the tester guide matches §7.

## 7. Deferred (post-beta, documented in the tester guide where visible)

Sprite-accurate cursor shapes; manual zoom-segment editing; live
cursor-highlight halo; export halo; device hot-plug refresh
(`screen_recorder/events` stays no-op); `WM_DISPLAYCHANGE` selection clear;
recording indicator / pre-recording bar; power/session transition handling
(sleep, lid-close, Win+L mid-record — documented as known limitation for
beta, watchdog post-beta); 48 kHz-only mic constraint (beta ships the loud
warning from 10.1; resampler decision rides on beta telemetry); HEVC →
H.264 silent fallback; GIF opaque-only; background image (`pickImage`);
window resize pinned to initial size; kAppWindow = one HWND; Phase 9
deferred edges (squircle, `scaleWithScreenZoom`, chroma+shadow veil call,
zoom pulse, burned-in mode, parse dedup); preview cursor/zoom POC-renderer
replacement with the export renderers (the auto-zoom track honesty in 10.3
is the beta-sized cut; full WYSIWYG parity for cursor/zoom is post-beta).

## 8. Cross-cutting risks

- **MethodResult-must-reply** remains the standing footgun for every new
  handler (MSVC won't flag a missing enum case; the future hangs silently).
  The 10.1 dispatch barrier reduces crash blast radius, not hang risk —
  every new switch still needs its `default:`.
- **AMD shared-handle failure means a per-GPU code path fork**, not a
  one-line fix (NT-handle+keyed-mutex crashes ANGLE on Intel). If the AMD
  verdict fails, re-plan before invites.
- **Stale docs mislead scoping**: `windows-port.md` Phase 8 claims the
  preview draws no cursor/zoom, but a POC-era renderer DOES draw a divergent
  approximation (`preview_compositor.cpp:289-352`). 10.3 must scope from the
  code, not the doc; fix the doc in 10.3.
- **Windows CI** now exists (a path-scoped `windows-latest` job in
  `.github/workflows/ci.yml`: `flutter build windows` + the headless `ctest`
  suite; the armed pixel probes still only run on the dev box). It runs only
  when `windows/**` or shared code changes. Earlier this was blocked because
  macOS runners can't build the Windows runner and GH credits were tight;
  macOS CI now runs on every PR, so the added `windows-latest` cost (2×, vs
  macOS's 10×) is affordable. The release script should still run the suite
  as a gate for release builds.
- **`.env` files are public-repo-tracked**: feed URLs are fine there;
  signing keys and the Sparkle/EdDSA key never are (out-of-band, same as
  macOS).
- **Fail-open permission probes** (`ProbeCapability` returns true on WinRT
  API absence) + the TOCTOU window between preflight and device open mean
  permission UX can never promise — 10.1's degradation warnings are the
  backstop.
- **Flavorless Windows builds** meet per-env installers in 10.5 — the
  dev/prod split lives in installer identity + feed URL, not `--flavor`.

## 9. Key references

- Phase history + deferred lists: `docs/windows-port.md`
- Preview architecture + stress gate: `docs/decisions/windows-phase-5-*.md`
- Permission semantics for unpackaged Win32: `docs/windows-port.md` §Permissions
- macOS updater reference: `macos/Runner/Platform/Updates/UpdaterController.swift`,
  `ops/release/` (appcast pipeline)
- Event publisher pattern for the updater: `windows/runner/Bridge/workflow_event_publisher.{h,cpp}`
- Error contract: `windows/runner/Bridge/native_error_codes.h` ↔
  `lib/core/bridges/native_error_codes.dart`
- Project memory: CI billing exhausted (admin-merge flow), MTA requirement
  for camera enumeration, WDA-success-but-invisible on hybrid GPUs,
  MachineGuid licensing binding.
