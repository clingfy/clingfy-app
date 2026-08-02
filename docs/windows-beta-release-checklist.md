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
| 14 | Voice cleanup — export | Record with a mic in a slightly noisy room (fan/AC/keyboard) + system audio; in post → Audio, enable Voice Cleanup (Balanced); export; play the result | Background noise stripped from the mic in the export; the raw recording is untouched; cleaned voice stays lip-synced (no ~20 ms drift) | — (engine/export code + CI; on-device pending) |
| 15 | Voice cleanup — live preview (WYSIWYG) | Cut the timeline (so the preview is stitched), enable cleanup, play the edited preview | Preview mic is denoised too, matching the export; a brief background pass runs after enabling before it applies | — (on-device pending) |
| 16 | Voice cleanup — Light vs Balanced | With cleanup on, switch Light ↔ Balanced (in both the edited preview and an export) | Audibly different: Light leaves the voice more natural / more residual room tone, Balanced strips more | — (unit-verified balanced<light<noisy; on-device pending) |
| 17 | Voice cleanup — threading edges | Toggle cleanup on/off DURING edited-preview playback; rapidly flip Light↔Balanced a few times while playing; enable on a longer recording then immediately close the preview / switch projects mid-compute | Audio keeps playing and becomes/stops being denoised without a freeze, silence-stall, hang, or crash; settles on the last choice; no leftover `clingfy-preview-miccleanup-*.mp4` in `%TEMP%` after close | — (2× adversarial concurrency review; NOT headless-testable — needs eyes) |
| 18 | Voice cleanup — gating | Open a system-audio-only recording (no mic) in post → Audio | Voice Cleanup control hidden and the "no mic audio" notice shown; a separated mic recording shows the control (depends on §2 mic+system separation working) | **2026-07-30 PASS** — control hidden + "No mic audio track found" notice. Verified on a release build (9111a29) recording made with "No microphone": no `mic.m4a` in the bundle at all, `micActive: false`. Note this row FAILED until #390: "No microphone" did not stop the app opening the default mic (a real take shipped an 81 s sidecar at −52.1 dB), and the resulting decodable-but-silent sidecar made `hasMicAudio` true. The gate itself was always correct — it had a mic sidecar to find. |
| 19 | Editing — clips / reorder / mix | Cut + delete a middle segment then replay across the cut; drag-reorder clips then play and export; raise mic-only gain on a separated recording | Video stays locked to audio across the cut (no lag); reorder plays/export in timeline order; gain raises the mic only, system steady | PARTIAL 2026-07-30 — separation itself VERIFIED on device: a mic+system take produced mic -34.4 dB and system -22.1 dB as distinct tracks, and a mic-only take correctly omitted `system.m4a`. Mic-only GAIN still unverified: on an UNCUT preview it is inaudible BY DESIGN (D6 - MediaPlayer.Volume cannot amplify), so judge it on a CUT timeline or in the export. For a scripted pass `tools/make_smoke_fixtures.ps1` builds `smoke-separated-mic-system` with mic 440 Hz @ -20 dBFS vs system 880 Hz @ -12 dBFS, so "mic only" is audible as ONE tone moving. |

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

## 3. Release gates (state as of 2026-08-01)

> **Re-probe before trusting an item here.** The 2026-06-12 pass recorded the
> Windows feed as "404 — never published". It had been live for weeks by the
> time anyone acted on that line, and acting on it overwrote a published
> artifact. Dates on entries are when they were last CHECKED, not when they
> were written.

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

- [x] **Publish the Windows feed.** RE-PROBED 2026-07-28: BOTH channels
      are live. prod serves `1.0.6+7` (published 2026-07-23); dev is
      published continuously by the Azure lane
      (`azure-pipelines/windows-dev-channel.yml`), whose `counter()` was
      at ~100. The 2026-06-12 "404 — never published" note was stale by
      six weeks and is what led to a local publish that OVERWROTE the
      pipeline's own `1.0.6+7` artifact (same name: the counter is seeded
      at 7 and pubspec also reads 1.0.6+7). #377 added an overwrite guard
      so that cannot recur silently.
      **Do not publish from a workstation** — the pipeline owns this
      feed.
- [ ] NVIDIA + AMD stress verdicts (§2).
- [ ] Mixed-DPI dual-monitor pass (§2).
- [x] **Forced-native-crash → Sentry round-trip from an installed
      build** — DONE 2026-07-29 on the real installed artifact. Crash
      ingested, and the stack SYMBOLICATED: 15 of 16 frames named with
      line numbers, top frame
      `clingfy::bridge::routers::misc::…HandleDebugForceNativeCrash`
      → `MethodRouter::Dispatch` → `StandardMethodCodec::…`. The one
      unnamed frame is `ucrtbase.dll` CRT internals.
      **Trap worth knowing:** `upload_symbols.ps1` only runs from
      `local_release.ps1`'s `if ($Publish)` branch, so a build shared
      OUTSIDE the publish path has no symbols uploaded and reports every
      `clingfy.exe` frame as `<NO SYMBOL>` (seen once, 11 of 13). #377
      added the missing upload step to the DEV pipeline, which had never
      uploaded symbols at all — so every beta crash was unsymbolicated.
- [ ] **Licensing on a clean box**: activate / validate / consume-trial
      on a machine that never saw the repo (matrix row 2). Depends on:
- [x] **Beta entitlement provisioning decision** — DECIDED 2026-07-27:
      **time-boxed subscription keys**, dated to the beta window. They
      expire on their own, so access ends without revoking anything or
      chasing testers afterwards. Needs no client change — `subscription`
      is already a `LicensePlan` and the client already honours
      `updates_expires_at` / `isUpdatesExpired`. Rejected: lifetime keys
      (a permanent gift, revocation is a per-tester support conversation);
      trial-only (export-limited, so testers stop exercising the export
      paths that most need testing); a dedicated `beta` plan (cleanest
      long-term but costs an enum value, client handling, tests and
      backend work for a temporary need).
      **Still to do (backend/ops, not app code):** generate the keys and
      mail them. Row 2 stays blocked until that happens.
- [x] **Telemetry consent/disclosure decision** — SHIPPED 2026-07-27
      (#362): first-run disclosure + an opt-out in Settings › Diagnostics,
      default opt-out (report, and disclose). Root cause worth remembering:
      the pre-existing "Share anonymous usage analytics" toggle gated
      **PostHog only** — Sentry initialised unconditionally whenever a DSN
      was compiled in, so a user who turned analytics off was still sending
      crash reports and had never been told. Opting out now skips
      `SentryFlutter.init` entirely rather than filtering, because
      `beforeSend` cannot stop the out-of-process native crash handler.
      Flip `kCrashReportingDefaultEnabled` for consent-first.
      **Still open:** the privacy policy itself does not cover Windows —
      that is a document edit, not code.
- [x] **Signing decision** — DECIDED 2026-07-27: **ship the private beta
      UNSIGNED**, and revisit before any public/commercial ship. A
      certificate is a cost the project is not taking on yet, and the gate
      never required a signed build — only a decision. The tester guide
      already documents the SmartScreen bypass, `-RequireSignature` stays
      off, and a half-configured cert pair still hard-fails the lane by
      design, so nothing silently ships half-signed.
      **Consequence to expect:** every tester sees a SmartScreen warning on
      first run. That is the price of this choice, not a bug report.
- [x] Sentry release tagging spot-check — DONE 2026-07-29:
      `clingfy@1.0.6+7+ab92530` on the crash event itself, mapping to
      exact version + build + commit.
      **It was broken until #374:** every Windows build tagged
      `clingfy@++<commit>` (no version at all), because the lane never
      passed FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER as dart-defines —
      the `--build-name` / `--build-number` FLAGS do not reach
      `String.fromEnvironment`. Guarded by #375, which logs an error at
      startup if the tag ever degrades again.

Not beta-blocking, tracked:

- [ ] **Inno Setup license tier** — Inno 6.5+ prints "Non-commercial use
      only" on unlicensed installs (`ops/release/windows/RUNBOOK.md`);
      verify the license before any **commercial** ship. Manual operator
      check; no automated gate exists.
- [x] Runner.rc cosmetic strings — DONE (#398: FileDescription/window
      title/copyright → "Clingfy") and finished 2026-08-02 by re-casing
      `ProductName` to "Clingfy" (dev: "Clingfy Dev"). Safe because NTFS
      is case-insensitive: `%APPDATA%\com.clingfy\clingfy` and `...\Clingfy`
      are the same directory, verified on a real volume before the change.
      `ProductName` may still only be RE-CASED, never renamed, and
      `CompanyName` stays `com.clingfy` — it is the parent directory, so
      changing it would orphan both channels at once.
- [x] D9 per-channel mutex/data-dir identity — DONE 2026-07-27 (#373)
      and completed 2026-08-01 (#394). All five identities fork: the
      single-instance mutex, the settings store (Runner.rc ProductName →
      path_provider), recordings, logs and the preset-thumbnail cache.
      prod's identity is byte-for-byte unchanged and pinned by tests;
      anything unrecognised resolves to prod, because guessing dev for a
      released build would point it away from the user's recordings.
      The native LOG path was missed in #373 — the edit added the include
      but not the use — and was fixed in #394; its test now asserts the
      path AGREES WITH the identity helper rather than restating the
      literal, which is what let the miss survive review.
      Side-by-side installs are now safe; the tester-guide warning can be
      relaxed.

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
