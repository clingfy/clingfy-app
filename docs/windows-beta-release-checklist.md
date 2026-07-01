# Clingfy Windows — Private Beta Release Checklist

Phase 10.7 (Windows beta closeout). Engineering-side companion to
`docs/windows-beta-tester-guide.md`. This file is the release gate: a beta
invite goes out only when §1 (smoke matrix) has passed on the gate
hardware in §2 and every box in §3 (release gates) is checked.

Process: run the matrix on each gate machine from an **installed build**
(never `flutter run`), record per-machine results in §2, and file
anything that fails as a slice before invites. Per the 10.0 plan, the
gates here re-run checks that already passed on the dev box — passing on
one Intel machine is not a release signal.

## 1. Final beta smoke matrix

All rows run against an installed build of the release candidate.
"Verified (dev box)" = the slice-level smoke already passed on the
development machine (Intel Iris Xe) on the date shown; the matrix re-runs
everything on the gate hardware.

| # | Area | Steps | Expected | Verified (dev box) |
|---|------|-------|----------|--------------------|
| 1 | Install / uninstall / reinstall | Silent install (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`) → use app → install same build again → uninstall | Installs per-user with no UAC; Start Menu entry; upgrade-in-place keeps settings; uninstall removes binaries + shortcuts + association but preserves recordings/exports/logs/prefs | 2026-06-12 (10.5) |
| 2 | License validation (clean machine) | On a machine that has never run Clingfy: activate a beta key, restart app, export once | Key activates, survives restart, export ungated; clear error on a key already bound elsewhere | — (open gate, §3) |
| 3 | Diagnostics export | Settings → Diagnostics → Export Diagnostics | `clingfy-diagnostics-*.zip` built and revealed in Explorer; contains logs/devices/permissions/app info + sanitized project manifest (paths/device ids redacted in the manifest ONLY — logs and device inventory ship as-is) | 2026-06-10 (10.1) |
| 4 | Update check | Settings → About → Check for Updates against the published feed (same version → up-to-date; staged newer feed → dialog + Download opens installer URL; dead feed → check failed) | All three states render honestly; no silent no-op | 2026-06-12 (10.6, staged feed) |
| 5 | Display recording | Record each attached display, with pause/resume | Correct display captured; pause gap absent from output; in-app pause/stop controls work (NOTE: there is no native recording-indicator overlay on Windows — deferred post-beta) | 2026-06-12 |
| 6 | Window recording | Record a window; move/resize it mid-recording; minimize/restore | Window content captured; initial size kept on resize; no crash | (Phase 7 smokes) |
| 7 | Area recording | Pick an area on each monitor; record; restart app and confirm re-pick is required | Area cropped correctly (DPI-aware); stale area cleared on restart by design | (Phase 7/10.3 smokes) |
| 8 | Camera recording | Record with camera on: in-app preview, floating-bubble toggle, mirror/shape/border/shadow/chroma styling in post | Camera in preview + export exactly alike (WYSIWYG); floating bubble appears or falls back honestly; screen.mov never contains the bubble | 2026-06-10 (Phase 9) |
| 9 | Preview / reopen project | Stop → preview opens; close app; reopen via right-click on the bundle folder → "Open in Clingfy Dev" (channel-specific label; Windows 11: under "Show more options"); scrub/pause/seek | Preview plays with camera composited; reopen works from the Explorer verb and from inside the app | 2026-06-12 (#172) |
| 10 | MOV / MP4 / GIF export | Export the same project in all three formats; play results in Films & TV/VLC and a browser (GIF) | Correct extension + container; plays; GIF animates; camera/cursor/zoom composited in all three | 2026-06-12 (GIF #169 + smoke) |
| 11 | Cursor / zoom / click rings | Record with deliberate clicks + movement; export | Cursor drawn (arrow), auto-zoom segments fire near clicks, click rings render; all under the same zoom transform | (Phase 8 smokes) |
| 12 | Permission-denied paths | Deny camera + mic in Windows Settings (privacy page); run onboarding fresh (clear the `onboarding_seen_v1` pref); try recording with camera/mic enabled | Onboarding = Welcome + Mic/Cam only; settings rows show status detail + working ms-settings deep links; recording starts screen-only with a localized warning toast, never silently | 2026-06-10 (10.2) |
| 13 | Device-loss paths | Close the captured window mid-recording; unplug monitor being recorded; unplug camera mid-recording; unplug mic mid-recording | Window/display loss → partial recording finalized + warning (keep-partial policy); camera loss → camera-only stop, screen continues; mic loss → warning, recording continues | (7.4 / 9.2 / 10.1 smokes) |

## 2. Hardware verdict checklist (gates invites — 10.0 plan D10)

The Phase 5.7 preview stress verdict procedure: install the candidate
build, run ≥ 1 Record → Stop, then drive **≥ 200 open/close preview
cycles** and extract the verdict from
`%LOCALAPPDATA%\Clingfy\Logs\phase5_cycles.log` via
`tools\phase5_extract_verdict.ps1 -MinCycles 200`. PASS requires every
cycle's `close_to_unregister_ms` ≤ 1000 ms (the extraction script gates
on the MAX, stricter than the verdict doc's p99 wording), zero
zero-frame cycles, no crash, and flat GPU memory; fewer than
`-MinCycles` cycles records WARN. Record verdicts in
`docs/decisions/windows-phase-5-stress-verdict.md`.

- [x] **Intel integrated GPU** — Iris Xe PASS, 2026-05-28 (12-cycle
      session, p99 = 1 ms; formal 200-cycle run still worth repeating on
      the release candidate).
- [ ] **NVIDIA machine** — never run. The DXGI legacy shared-handle path
      is documented but untested on NVIDIA.
- [ ] **AMD machine** — never run. Historically the most timing-sensitive
      shared-handle behavior; budget real time if it fails.
- [ ] **Mixed-DPI dual monitor** — on at least one full-pass machine:
      primary at 100%, secondary at 150% (or 200%); record display,
      window, AND area **on the secondary monitor**; verify cursor
      position, zoom focus, and area coordinates in the export.
- [ ] **Webcam + mic + system audio** — full matrix row 8 plus
      simultaneous mic + loopback capture on real peripherals (48 kHz
      constraint: a non-48 kHz device must produce the warning, not
      silence).

## 3. Release gates (state as of 2026-06-12)

Shipped and verified:

- [x] Installer end-to-end: silent install / upgrade-over-install /
      uninstall preserving user data (10.5 smoke).
- [x] `.clingfyproj` right-click "Open in Clingfy {channel}" verb
      (label is per-channel; Win11: under "Show more options"), filtered
      to bundle folders; uninstall removes it (#172 smoke).
- [x] App icon embedded in runner + installer (#171).
- [x] Update-check client honest in all three states (#173 smoke).
- [x] Crash salvage: kill mid-recording → tombstone + temp cleanup;
      window-close mid-recording → finalized bundle (10.4, dev box).
- [x] Tester guide + known-issues list published (this document's
      sibling, `docs/windows-beta-tester-guide.md`).

Open — must close before invites:

- [ ] **Publish the Windows feed.** Live probe 2026-06-12: the dev Front
      Door serves the macOS `appcast.xml` (HTTP 200) but
      `downloads/windows/latest-windows.json` is **404 — never
      published** (so are the installer + `.sha256` blobs). Until a real
      `local_release.ps1 … -Publish` run uploads them, every installed
      build's Check for Updates reports "update check failed". Re-probe
      both channels after the first publish; `05_smoke.ps1` covers this
      automatically in the publish path.
- [ ] NVIDIA + AMD stress verdicts (§2).
- [ ] Mixed-DPI dual-monitor pass (§2).
- [ ] **Forced-native-crash → Sentry round-trip from an installed
      build** (`CLINGFY_CRASH_TEST=1` + hidden diagnostics button +
      `upload_symbols.ps1`): exercised on a staged copy in 10.4,
      deliberately re-run here on the real installed artifact.
- [ ] **Licensing on a clean box**: activate / validate / consume-trial
      on a machine that never saw the repo (matrix row 2). Depends on:
- [ ] **Beta entitlement provisioning decision** — how testers get
      keys/entitlements on Windows (open product call, blocks row 2).
- [ ] **Telemetry consent/disclosure decision** — Sentry crash/telemetry
      runs without an in-app disclosure today; ship a disclosure or an
      opt-out, and cover Windows in the privacy policy.
- [ ] **Signing decision** — Azure Trusted Signing / OV cert, or ship the
      beta unsigned (the tester guide documents the SmartScreen bypass;
      `-RequireSignature` stays off until material exists; a
      half-configured cert pair hard-fails the lane by design).
- [ ] Sentry release tagging spot-check: one report from an installed
      build maps to the exact version+build.

Not beta-blocking, tracked:

- [ ] **Inno Setup license tier** — Inno 6.5+ prints "Non-commercial use
      only" on unlicensed installs (`ops/release/windows/RUNBOOK.md`);
      verify the license before any **commercial** ship. Manual operator
      check; no automated gate exists.
- [ ] Runner.rc cosmetic strings PR (FileDescription/window
      title/copyright → "Clingfy"); `CompanyName`/`ProductName` stay
      frozen — they are the path_provider data-directory identity.
- [ ] D9 per-channel mutex/data-dir identity (dev + prod currently share
      both; tester guide warns against side-by-side installs).

## 4. Cutting the beta build

```powershell
# from the repo root, on the release branch
pwsh ops/release/windows/workflows/local_release.ps1 -Channel dev -Clean -RunTests -Publish
```

Rules that bite: pubspec `version: X.Y.Z+N` with **N ≤ 65535** (never
port the macOS epoch build-number strategy); on `release/*` branches the
branch name must match the pubspec version (`00_version_guard`); prod
artifacts are version-only (`Clingfy_Setup_1.0.4.exe`), dev carries the
build (`Clingfy_Dev_Setup_1.0.4+5.exe`); publish uses `az` with
`--auth-mode login` and purges the Front Door paths; signing material is
env-only (`WIN_SIGN_CERT_THUMBPRINT` preferred — see
`ops/release/windows/RUNBOOK.md`).
