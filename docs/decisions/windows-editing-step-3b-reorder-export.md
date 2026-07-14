# Windows editing — Step 3b: reorder / non-monotonic clip export

Status: **Design slice (pre-implementation)** — written 2026-07-10.
Track: editing-features port (clips), Step 3 (clip export bake), sub-step **3b**.
Parent handoff doc: [`docs/windows-port-editing-features.md`](../windows-port-editing-features.md) (§5.2/§5.3/§5.5, §6 build order).
Predecessor: Step 3a (monotonic cut/trim/delete-middle bake), shipped #215.

This document locks the numbered decisions (D1–D8) and the PR slicing for reorder
export, so implementation ships as small, test-backed, on-device-smoked PRs.

---

## 1. Problem

Reordering (arrange) or overlapping clips is currently **refused at export**. The
guard `ClassifyClipEdit` returns `kUnsupported` when the coalesced ranges are not
source-monotonic **or** not disjoint, and `ExportPassthroughCopy` turns that into
`PassthroughError::kUnsupportedClipEdits` and returns before the composition
pipeline is ever entered:

- `windows/runner/Capture/Export/export_passthrough.cpp:183` —
  `if (!clip_planner::IsSourceMonotonic(coalesced) || !disjoint) return ClipEditKind::kUnsupported;`
- `windows/runner/Capture/Export/export_passthrough.cpp:371-377` — the `kUnsupported`
  early return.

The refusal exists because the 3a export is a **single forward `IMFSourceReader::ReadSample`
loop** (`export_pipeline.cpp:742-793`, `MF_SOURCE_READER_ANY_STREAM`, zero
`SetCurrentPosition` calls) that re-stamps each kept source frame onto a compacted
edited PTS via `EditedMsForKeptSourceMs`. Reading the source forward while the edited
timeline demands a **later** source window before an **earlier** one would emit a
non-monotonic (invalid) output PTS. Audio is handled packet-granularly by the same
`EditedMsForKeptSourceMs` gate (`export_pipeline.cpp:~1094-1128`), which leaks up to
~21 ms at a seam and desyncs badly if a short/absent range sits mid-timeline.

## 2. Key finding — the substrate already exists

Step 3b is a **port of a shipped macOS feature**, not new algorithm design. The
reorder math, the wire parse, and their unit tests are already present and green on
**both** platforms:

- The shared planner is already reorder-complete. `clip_playback_planner.h` exposes
  `IsSourceMonotonic`, `AudioSlots(ranges, audio_duration_ms)` (full-slot advance +
  silence fill), `EditedMsForSourceMs(source_ms, active_index, ranges)` (the exact
  reorder re-stamp helper: preceding-durations base + offset), `SourceMsForEditedMs`,
  `ActiveIndexForEditedMs`, and `EditedDurationMs`. All are **implemented but not yet
  called by the export writer**.
- Reorder is unit-tested: `clip_playback_planner_test.cpp` has
  `ReorderRestampTilesEditedTimelineMonotonically`,
  `AudioSlotsAlignReorderedRangesToFullDurations`, `EditedSourceRoundTripAcrossReorder`,
  `IsSourceMonotonicResolution`, and the backward-snap trap
  `ReorderGapOvershootResolvesToEarlierSlotBySource` (26/26, a test-for-test mirror of
  macOS `ClipPlaybackPlannerTests`).
- The wire parser already preserves reorder order and truncates:
  `ReadClipRangesArg`/`ParseClipRanges` (`clip_args.h`), pinned by
  `clip_args_test.cpp:ParsesEnabledClipsInTimelineOrder`.
- The reordered ranges already reach the pipeline intact:
  `render.clip_ranges = input.clip_ranges` (`export_passthrough.cpp:497`).

**So 3b touches only the export writer and the guard — not the planner, not the wire
parse, not the Dart side.** Any change to a planner function would have to land on
both platforms in lockstep (`clip_playback_planner.h:42-44`); 3b requires **zero**
planner changes.

## 3. The macOS reference (what we are porting)

macOS uses **two different assembly mechanisms**, and porting both faithfully is the
crux:

| Stream | macOS (`LetterboxExporter.swift`, `CompositionBuilder.swift`) | Windows / Media Foundation analog |
| --- | --- | --- |
| **Video** | One fresh `AVAssetReader` **per kept range**, bounded to `[sourceIn,sourceOut)` via `windowReader.timeRange` (`:1743-1773`), read in **timeline order**; on drain, `currentEditedBaseMs += range.durationMs`, build the next bounded reader (`:2228-2264`). PTS re-stamped to `editedBase + clamp(srcMs − sourceIn, 0, durationMs)` (`:2291-2301`). | Single `IMFSourceReader` + `SetCurrentPosition(sourceIn)` per range; decode-and-discard to the range start (MF seeks land on the prior keyframe); read until source PTS ≥ `sourceOut`; same re-stamp. |
| **Audio** | `AVMutableComposition.insertTimeRange` **per `AudioSlot`** + `insertEmptyTimeRange` for the shortfall (`fillCompositionTrackWithKeptRanges:1544-1586`). Returns no audio track at all if nothing copied (`:1511-1533`). | `AudioSlots`-driven PCM copy at `editedStartMs` + synthesized **silent-sample gap** to full `durationMs`, in the MF/`audio_mixer` path. |
| **Effects** (zoom/cursor/camera) | Baked source-timed into the composition; each frame arrives at its **true source PTS**, so effects resolve automatically. **The export carries no smoothing state** → no explicit reset needed. | The Windows loop **does** carry mutable state (`prev_edited_ms` zoom smoother; forward-only camera reader). → must **reset the zoom smoother + re-prime the camera reader on each range boundary** (see D6). |

`AudioSlot` full-slot rule (`CompositionBuilder.swift:1122-1164`), already ported
verbatim to C++: `base` advances by `r.durationMs` (full), copying only
`copyDurationMs = min(sourceOutMs, audioMs) − sourceInMs` of real audio; the rest of
the slot is silence. Pinned expected values live in macOS `RunnerTests.swift:8675-8714`
and Windows `clip_playback_planner_test.cpp:237-274`.

## 4. Decisions

**D1 — Scope: lift reorder AND overlap; fully retire the guard.**
Confirmed with the maintainer (2026-07-10). Per-range windowed reads make overlapping
/nested source windows well-defined (each range reads its own source window
independently), which is exactly why macOS needs no overlap special-case. `ClassifyClipEdit`
collapses to `{kPassthrough, kBake}`. `ClipEditKind::kUnsupported`,
`PassthroughError::kUnsupportedClipEdits`, and its `ReplyForExportOutcome` case
(`export_router.cpp:~578`) become dead and are deleted. The four refusal tests
(`ClassifyClipEditTest.ReorderIsUnsupported` / `.OverlappingRangesAreUnsupported`,
`ReorderedClipsAreRefused`, `OverlappingClipsAreRefused`) are rewritten to expect
composition, mirroring `MonotonicClipCutRoutesToComposition`.

**D2 — Video read strategy: single `IMFSourceReader` + `SetCurrentPosition` per range.**
Iterate kept ranges in timeline order. For each range: seek to `source_in_ms`, decode
and discard until the decoded PTS reaches `source_in_ms` (MF seeks land on the prior
keyframe — screen recordings have sparse keyframes), then composite + write frames
until the decoded PTS reaches `source_out_ms`, re-stamping each to
`edited_start + clamp(frame_ms − source_in, 0, duration_ms)`. Reject alternatives: an
MF sequencer-source / topology would be a full rearchitecture of the hand-rolled
decode→D2D→sink-writer loop and does not fit; `SetCurrentPosition` is the direct analog
of macOS's per-range bounded `AVAssetReader`. The keyframe-discard cost is acceptable
(export is offline, not interactive).

**D3 — Audio stitch: `AudioSlots`-driven, decoupled from the video read.**
Audio is stitched separately from video (as on macOS: bounded readers for video,
composition inserts for audio). The interleaved `ANY_STREAM` pull cannot survive
per-range video seeking, so audio becomes its own slot-driven pass: for each
`AudioSlot` in timeline order, seek the audio reader to `source_in_ms`, copy exactly
`copy_duration_ms` of PCM to `edited_start_ms`, then emit a silent-sample gap of
`duration_ms − copy_duration_ms`. **Advance by the full `duration_ms`, never the copied
length** (§5.2 — the reorder-specific desync trap).

**D4 — Audio-track duration source.**
`AudioSlots` needs `audio_duration_ms`, but the loop currently reads only the video
`duration_hns` (`export_pipeline.cpp:368-379`). Probe the source audio stream's
duration and truncate to ms (`(int)(seconds * 1000.0)`, §5.1). macOS derives it as
`Int(sourceAudioTrack.timeRange.duration.seconds * 1000.0)` (`LetterboxExporter.swift:1551`).

**D5 — Progress from edited position.**
Under per-range reads the source PTS is non-monotonic, so the current
source-PTS ÷ `duration_hns` progress (`export_pipeline.cpp:730-740`) jumps around.
Re-derive progress from the cumulative **edited** position over `edited_total_ms`,
matching macOS (`progressDurationSeconds = editedDurationSeconds`,
`LetterboxExporter.swift:2029`).

**D6 — Effects sampled at true source PTS; Windows-specific resets on range boundary.**
Zoom, cursor, and camera keep sampling at each frame's true source `frame_ms` (already
the case: `export_pipeline.cpp:817-819` camera, `:859-879` zoom, `:929-937` cursor).
Unlike macOS's stateless baked ramps, the Windows loop carries mutable state, so on
each range advance (a potential **backward** source jump) it must: (a) reset the zoom
smoother/hysteresis (`prev_edited_ms`, zoom center); (b) re-prime/re-seek the camera
export renderer (macOS calls `invalidateCameraSamples()` then re-fetches). The camera
intro/outro **animation clock stays on EDITED time** (the Windows-3a refinement; macOS
bakes intro/outro on the source clock — a deliberate divergence, keep it). Route all
camera time through the one edited↔source helper and audit the off-tick call sites
(§5.5 — macOS missed 5).

**D7 — The monotonic video path stays byte-identical.**
The 3a single-forward-read video loop remains for `IsSourceMonotonic(coalesced) == true`.
The reorder read path (D2) is a **new branch** selected by `!IsSourceMonotonic`, so 3a's
proven monotonic behavior is untouched and the blast radius is bounded. (The audio path
is the one shared exception — see D3/§5, unified across both cases.)

**D8 — Audio slot base == video re-stamp base.**
The per-range video re-stamp `edited_start` MUST equal `AudioSlot.edited_start_ms` for
the same range (both are the cumulative full duration of preceding ranges). Derive both
from the same source so audio and video seams land on the same ms. macOS keeps them
equal by construction (`currentEditedBaseMs` == `editedStartMs`).

## 5. Load-bearing invariants (do not regress)

Carried from the macOS lessons (`docs/windows-port-editing-features.md` §5), all pinned
by tests:

- **§5.1 truncate, never round** every seconds→ms conversion — already satisfied at the
  parser and `frame_ms` (`export_pipeline.cpp:779`); keep it for the new audio-duration
  probe and the re-stamp offset.
- **§5.2 full-slot advance + explicit silence fill** — audio *and* the video re-stamp
  base advance by `duration_ms`, never `copy_duration_ms`.
- **Monotonic, gapless edited PTS** — the re-stamp tiles `[0, edited_total_ms)`; the
  `min(…, duration_ms)` offset clamp prevents an edge frame from colliding with the next
  range's first PTS.
- **Passthrough landmine** — a real edit must force `needs_composition`; a byte-copy must
  never ship the uncut source. Retiring the guard must **route** reorder/overlap to
  composition, never fall through to `fs::copy_file` (`export_passthrough.cpp:434`).
- **A/V share one origin** — the first written video frame anchors edited-time 0; audio
  is origin-shifted to match (`export_pipeline.cpp:702-711, ~1040-1055`). Emitting in
  timeline order preserves this.
- **Reporting uses the playing slot**, not `ActiveIndexForSourceMs` (backward-snap trap,
  `clip_playback_planner_test.cpp:281`) — relevant to any progress/telemetry that maps
  back to a slot.

## 6. PR slice plan

Each slice: headless tests where possible + device-gated (`D3D11`/MF) integration tests,
plus a manual on-device smoke by the maintainer. All ship squash-merged into `develop`.

1. **3b-1 — `AudioSlots` audio stitch (unify + de-risk).**
   Replace the packet-granular audio keep/drop with an `AudioSlots`-driven copy +
   silence-fill, for the **monotonic** case first (forward-only, no seeking). Add the
   audio-duration probe (D4). The guard still refuses reorder. This kills the ~21 ms
   monotonic seam leak and builds the audio machinery in isolation.
   Tests: existing monotonic audio device tests stay green
   (`HeadTrimWithAudioExportsDualStream`, `ClipMiddleCutDropsGapFrames`); add region-tone
   seam-accuracy + silence-fill assertions.

2. **3b-2 — Reorder read path + retire the guard (D1, D2, D5, D6, D8).**
   Add the `!IsSourceMonotonic` branch: per-range `SetCurrentPosition` video reads +
   backward audio-slot seeks + edited-progress + zoom/camera resets + `edited_start`
   base. Fully retire `kUnsupportedClipEdits`; rewrite the four refusal tests to expect
   composition. Overlap is handled here for free (D1).
   Tests: reorder video (encode source-region identity into frames → assert the later
   source window shows up in the earlier timeline slot = backward seek proven); reorder
   audio (clamped mid-timeline slot → silence in-slot, later audio not pulled early);
   an overlapping-ranges case. Device-gated with the `CLINGFY_REQUIRE_PIXEL_TESTS`
   canary so they can't silently skip on the known-good box.

3. **3b-3 — Camera off-tick audit + housekeeping / step 5.**
   Audit every camera time input for the edited↔source helper (§5.5). Keep
   `bridge_contract_coverage_test` honest (**no new bridge method** — reorder is a
   behavior change behind existing `exportVideo`; record this so nobody adds a phantom
   entry). Update `windows-port-editing-features.md` §2/§6 status and this doc's status.
   (May fold into 3b-2 if small.)

## 7. Risks

- Flipping the guard without the reorder read path would re-create the landmine as a
  **wrong-output** export (short file / non-monotonic PTS) — worse than an honest
  refusal. Mitigation: D2 lands in the same PR (3b-2) as the guard retire.
- Advancing audio by copied length instead of full `duration_ms` reintroduces the
  macOS HIGH-severity multi-second desync. Mitigation: §5.2, reuse `AudioSlots`.
- Device-gated reorder tests can false-green by `GTEST_SKIP` on GPU-less CI. Mitigation:
  the `CLINGFY_REQUIRE_PIXEL_TESTS` canary forces them on the known-good box.
- The camera's forward-only reader + split source/edited time base is the most fragile
  consumer of a backward jump. Mitigation: D6 re-prime + the §5.5 call-site audit.
- `ColorGradeGoldenTest` is a permanent 2-fail local baseline (fixture absent); CI
  excludes it via `-E ColorGradeGoldenTest`. Don't confuse it with new reorder failures.

## 8. References

- macOS reorder export engine: `macos/Runner/Capture/Export/LetterboxExporter.swift`
  (`runRenderedExportSession`, `makeWindowReader`, `fillCompositionTrackWithKeptRanges`).
- macOS slot math: `macos/Runner/Capture/Export/CompositionBuilder.swift:1122-1164`
  (`AudioSlot` / `audioSlots`); expected values `macos/RunnerTests/RunnerTests.swift:8675-8714`.
- Windows planner (already reorder-complete):
  `windows/runner/Capture/Export/clip_playback_planner.{h,cpp}` +
  `windows/runner_tests/clip_playback_planner_test.cpp`.
- Windows export writer / guard: `windows/runner/Capture/Export/export_pipeline.cpp`,
  `windows/runner/Capture/Export/export_passthrough.cpp:160-187, 365-395`.
- Contract & invariants: `docs/windows-port-editing-features.md` §5.1–§5.5, §6.

_Line numbers are as of `develop` on 2026-07-10 and drift; re-verify at implementation._
