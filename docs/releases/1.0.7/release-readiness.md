# Release Readiness

This checklist is used by maintainers before publishing a new **Clingfy** release.

It ensures that automated checks pass and that critical recording, export,
permissions, licensing, and updater flows are verified manually before shipping
an official build.

This checklist should be completed **for every release candidate**.

---

# Release Metadata

Fill this section before starting verification.

- Version: `v1.0.7`
- Channel: `prod`
- Date: `2026-08-01`
- Verified by: `Nabil Alhafez`
- Commit: **two** — the platforms were built from different commits.
  - Windows: `216f1d0`
  - macOS: `e60b838` (what tag `v1.0.7` points at)
  - The branch moved between the two publishes: `develop` was merged in to pick
    up the export/colour fixes. Everything Windows would have missed is
    macOS-only — `14a4af6` (#402 camera overlay encoded twice), `ff91a13` (#403
    export writer probe), `19dcd9b` (#404 sRGB capture) touch `macos/**` and
    nothing else, so the shipped Windows 1.0.7 is not short a fix. Checked, not
    assumed: `git show --stat` on each.
- Tag: `v1.0.7` → `e60b838`
- Build:
  - macOS: `776` — `CFBundleVersion` / appcast `sparkle:version`, set from
    `$(Build.BuildId)` by the prod lane.
  - Windows: `1.0.7+8` from pubspec. The Windows lane deliberately does **not**
    use `Build.BuildId`: `FILEVERSION` is 16-bit and the org-wide id is already
    past 65535.
  - Azure *run* numbers were not captured and cannot be recovered from the
    artifacts (1.0.6 recorded "Azure #255" while its `sparkle:version` was 619 —
    different counters). Left unrecorded rather than guessed.
- Status: `Released` — both artifacts are live, verified against the published
  feeds, tagged, and merged to `main` (#405) and `develop` (#406).
  Still unticked below, both needing a Mac in hand: **DMG launches correctly**
  and **app icon and metadata appear correctly**. Neither blocks the release
  that already shipped; they are the honest remainder.

Possible status values:

- `In progress`
- `Blocked`
- `Approved`
- `Released`

---

# Automated Checks

Run these first.

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze test
flutter analyze lib
flutter build macos --flavor dev
flutter build macos --flavor prod
```

Checklist:

* [x] `dart format --output=none --set-exit-if-changed .`
* [x] `flutter analyze test`
* [x] `flutter analyze lib`
* [x] `flutter build macos --flavor dev`
* [x] `flutter build macos --flavor prod`

Notes:

---

# Recording Flows

Verify the full recording workflow.

* [x] full display recording
* [x] single window recording
* [x] custom area recording
* [x] countdown start
* [x] countdown cancel
* [x] stop flow
* [x] menu bar control
* [x] recording indicator overlay

Notes:

* Maintainer reports the recorder verified on 2026-08-01. Ticked above are the
  flows with artefacts on disk to back them: five recordings captured today at
  the display's native 3024x1964, each finishing with manifest `status: ready`,
  one of them with a camera track and one with `capture/system.m4a` (48 kHz
  stereo, mean -30.9 dBFS — real audio, not a silent placeholder).
* Single-window, custom-area, countdown start/cancel, menu-bar control and the
  floating indicator overlay were confirmed by the maintainer on 2026-08-02.
  These are separate entry points from the full-display path above and have no
  on-disk artefact of their own; they rest on that confirmation.
* Colour was verified end to end against an sRGB reference chart rather than by
  eye. Recorded values vs authored: pure red (255,0,0) -> (253,0,0), pure green
  (0,255,0) -> (0,254,0), `#FF4D5D` -> (253,74,90), `#8957E5` -> (133,86,225),
  mid grey and white within 2. Every patch within 4 code values; the pre-fix
  behaviour would have been off by up to 117. Exporting that recording preserved
  it: red (253,2,0), green (0,254,2), `#FF4D5D` (254,75,91).

---

# Permissions

Verify permission prompts and recovery flows.

* [x] screen recording permission request
* [x] screen recording recovery flow
* [x] camera permission flow
* [x] accessibility prompt

Notes:

*

---

# Overlay / Cursor / Zoom

Verify overlay behavior and cursor/zoom features.

* [x] overlay show/hide
* [x] overlay manual move
* [x] overlay position persistence
* [x] overlay styling options
* [x] overlay linked-to-recording mode
* [x] cursor sidecar capture
* [x] cursor visibility toggle in export
* [x] cursor scaling and highlight
* [x] zoom factor
* [x] zoom follow strength

Notes:

*

---

# Preview / Export

Verify preview playback and export pipeline.

* [x] inline preview playback
* [x] 16:9 preview/export
* [x] 1080p export
* [x] 1440p export
* [x] 2160p export
* [x] MP4 export
* [x] MOV export
* [x] GIF export
* [x] background image export
* [x] background color export
* [x] save folder selection

Notes:

* Ticked from real exports produced today, all landing in `~/Movies/Clingfy/`:
  2560x1440 MOV (16:9, 1440p) from a 3024x1964 source, including one of the
  colour reference chart used to verify the gamut fix. Inline preview playback
  was exercised while scrubbing a project to a fixed timestamp for that check.
* **GIF export verified by hand on 2026-08-02**, at two presets: Large
  (1080x608) and Small (480x270), from a 9.7 s recording. Valid GIF87a,
  infinite loop (NETSCAPE2.0 count 0), 146 frames at 15.0 fps on the ideal
  decimation grid, long-edge caps correct for both presets.
* GIF **colour** is proven by test, not by that sample. The transcode now undoes
  the export transfer — without it GIFs shipped ~11 code values dark in the
  midtones — and `GifExportSessionTests` pins it with a mutation-checked case
  (removing the decode fails 117 against an expected 128). On the hand-exported
  sample the decode is visible but the margin is thin: the content is dark
  blues where the curve barely moves, and GIF's 256-colour quantization adds
  error of the same magnitude. Not a concern, just not what that sample proves.
  For a conclusive manual check, export a GIF of the colour reference chart
  recording (`rec_2026-08-01_22-00-32`) and the flat patches make it obvious.
* 1080p / 2160p / MP4 / background image / background colour were confirmed by
  the maintainer on 2026-08-02. MP4 shares the writer path with MOV, and the
  output-container decision is now a single map covered by tests.

---

# Licensing

Verify licensing and paywall behavior.

* [x] free trial depletion
* [x] paywall display
* [x] license activation
* [x] expired updates messaging

Notes:

*

---

# Repo / Docs Hygiene

Ensure repository documentation and release tooling are in place.

* [ ] release tooling documented in `ops/release/README.md`
* [ ] `README.md` updated
* [x] `LICENSE` added
* [x] `LICENSING.md` added
* [x] `CONTRIBUTING.md` added
* [x] `SECURITY.md` added

Notes:

* The four "added" rows are ticked from the files being present at the release
  commit — that is the whole claim those rows make, and it is checkable.
* The two left unticked are **judgment calls, not existence checks**:
  `ops/release/README.md` and `README.md` both exist, but "documented" and
  "updated" mean *current for this release*, which only the maintainer can say.
  Ticking them from `test -f` would have been the wrong kind of green.

---

# Release Artifact Verification

Verify the generated release artifacts before publishing.

* [ ] DMG launches correctly
* [ ] app icon and metadata appear correctly
* [x] auto-updater configuration verified
* [x] update channel configuration verified
* [x] application launches without console errors

## Windows prod publish (verified 2026-08-01)

Published from `release/1.0.7` @ `216f1d0`. Feed:
`https://clingfyreleases.blob.core.windows.net/updates/downloads/windows/latest-windows.json`

| check | result |
|---|---|
| feed reachable + parses | 200, `1.0.7+8`, `channel: prod`, `platform: windows-x64` |
| installer served | 200, 33 390 336 B, matches feed `sizeBytes` |
| **sha256 of the downloaded bytes** | `e9de2b97…2ab55` — matches feed *and* `.sha256` sidecar |
| installer version resource | `FileVersion 1.0.7.8`, `ProductVersion 1.0.7+8`, `ProductName Clingfy` |
| signature | `NotSigned` — expected, decision D3 (no certificate yet) |
| prior release still served | `Clingfy_Setup_1.0.6.exe` → 200 (no orphaned installs) |
| dev feed untouched | still `1.0.6+111` on the dev account |

Updater verified by running the **shipped** parser and decision logic
(`windows/runner/Updater/update_feed.cpp`) against the live feed body, not by
inspection — the smoke step only proves the blob is reachable, and ctest only
proves the logic is self-consistent. Neither would catch a renamed field or a
mispublished channel, which would leave every installed 1.0.6 silently
believing it is current:

| current version | decision |
|---|---|
| prod `1.0.6+7` (the shipped population) | `kUpdateAvailable` |
| prod `1.0.7+8` | `kNoUpdate` (no re-offer) |
| prod `1.0.8+9` | `kNoUpdate` (no downgrade) |
| **dev** build against the prod feed | `kError` (channel isolation holds) |

## macOS prod publish (verified 2026-08-02)

Published from `e60b838` (tag `v1.0.7`). Appcast:
`https://clingfyreleases.blob.core.windows.net/updates/appcast.xml`

| check | result |
|---|---|
| appcast top entry | `sparkle:shortVersionString 1.0.7`, `sparkle:version 776` |
| DMG served | 200, 52 121 219 B — matches the `enclosure length` for 776 |
| version ordering | 776 > 619 (the shipped 1.0.6), so installed Macs are offered the update |
| history preserved | 1.0.6 and 1.0.5 entries and their DMGs still served |

Not verified here — needs a Mac: installing the DMG, first launch, icon and
metadata. Those are the two unticked rows above.

Notes:

* The prod lane's version guard ran for the first time this release
  (`Version guard passed: 1.0.7`). It had silently skipped every previous
  release — see `ops/release/windows/RUNBOOK.md` §3.

---

# Release Decision

Complete this section after all checks.

* [x] Approved for release
* [ ] Blocked from release

Blocking issues:

* None

Follow-up issues after release:

* **Stale appcast entry with a signature that no longer matches its bytes.**
  The feed carries two `1.0.7` items, `776` and `775`, pointing at the *same*
  URL (`Clingfy_1.0.7.dmg`). The blob now holds the 776 bytes (52 121 219), so
  775's `edSignature` — cut for 52 121 035 — does not verify against what that
  URL serves. Sparkle picks the highest version, so real updates are unaffected;
  1.0.6 shipped with the same duplication (618/619). Worth fixing at the source:
  re-running a publish for a version that already has an entry appends rather
  than replaces, leaving an item that would fail signature verification if
  anything ever selected it.
* macOS prod lane runs **no tests** — the gap the Windows lane closed in #401
  with `-RunTests`. Did not bite this release (every macOS commit here landed
  through PR CI), but the lane that builds what users install still gates on
  nothing.
* `azure-pipelines/release-prod.yml` step `Step 0.5: Dev Channel Version Exists
  Guard` is misnamed — it is the prod **overwrite** guard, and reads as a
  dev-channel precondition.