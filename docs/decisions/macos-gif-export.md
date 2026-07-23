# macOS GIF export — architecture decision

Status: **accepted** (design). Implementation tracked as PR-1…PR-4 below.
Author: engineering. Date: 2026-07-24.

## Context — the gap

macOS **recognizes** `"gif"` as an export format but routes it to a
"separate GIF export pipeline" that was never built:

- `macos/Runner/Capture/Export/ExportPrep.swift:109` →
  `case "gif": return .init(ext: "gif", avFileType: nil)  // handled by GIF pipeline, not AVAssetExportSession`
- `macos/Runner/Capture/Export/LetterboxExporter.swift:3700` →
  `case "gif": return nil  // handled by a separate GIF export pipeline`
- `ExportFormatInfo.avFileType` is `nil` for gif — `AVAssetExportSession` /
  `AVFileType` has no `.gif` muxer, by design.

So selecting **GIF on macOS today dead-ends** — nothing encodes it. The Flutter
UI already offers GIF and the method-channel payload already carries
`format: "gif"`, and **Windows already ships a real GIF encoder**
(`windows/runner/Encoding/gif_encoder.{h,cpp}` +
`windows/runner/Capture/Export/gif_export_policy.{h,cpp}`, wired into
`export_pipeline.cpp`). This is a **native-macOS hole behind an existing UI +
wire contract** — the fix is purely additive Swift, no Flutter change.

This decision was produced by a mapping + design pass that was adversarially
verified along three axes (frame-source reality, 4K memory/scale, output
quality/parity). The two amendments in §"Corrections" below are the direct
result of that review.

## Decision

### Encoder — native ImageIO `CGImageDestination`

Use `ImageIO.CGImageDestination` with the raw UTI **`"com.compuserve.gif"`**
(10.15-safe; `UTType.gif` where the deployment target allows). **No third-party
encoder.**

Rationale: Windows' GIF encoder is **WIC's built-in**
`IWICPalette::InitializeFromBitmap(256, FALSE)` + `WICBitmapDitherTypeErrorDiffusion`
— a platform adaptive-256 quantizer + error-diffusion dither, **no NeuQuant /
libimagequant**. ImageIO is the *same tier*. So native ImageIO gives free
quality parity, zero dependency, zero notarization/hardened-runtime/signing
surface.

A bundled encoder is **counterproductive for a parity goal**:

- **gifski** sits a tier *above* both platform encoders → macOS would look
  visibly better than Windows (a parity *regression*: same project → different
  GIF per OS). Also **AGPL-3.0** — a hard blocker for a closed-source paid app.
- **ffmpeg** — LGPL/GPL audit + multi-MB binary + per-dylib
  signing/hardened-runtime/notarization for a GIF-only feature, no quality edge.
- **AVFoundation** — confirmed dead end (`AVFileType` has no `.gif`).

The **only** condition to switch: GIF fidelity becomes a deliberate product
differentiator, and **both** platforms upgrade together (most plausibly
libimagequant, not gifski). A macOS-local swap is the wrong move — it's a
cross-platform product decision, not an implementation choice.

### Frame source — transcode the rendered video (as implemented)

**Load-bearing constraint (verified against the code):** color grade and the
inline camera are applied in the export's per-frame **compose tail**
(`LetterboxExporter.swift` ~2398–2490), **not** in `comp.videoComposition`. So
*no* readily-tappable source of fully-composited frames exists — neither
`AVAssetExportSession` nor a standalone `AVAssetReaderVideoCompositionOutput`
over `comp.videoComposition` would include grade + camera. The only source of
truth for correct frames is the **finished video** the (tested) pipeline bakes.

**Implemented approach — transcode the rendered video at the `ExportEngine`
layer, not surgery inside `LetterboxExporter`:** when `format == "gif"`,
`ExportEngine.export` renders the composited video to a **temp `.mov`** (the
whole existing render path, with grade/camera/cuts baked in, at the user's
codec/bitrate), then `GifExportSession` transcodes that MOV → GIF (decimate to
15 fps, downscale to the long-edge cap, opaque flatten, encode), deletes the
temp, and reports the `.gif` path. `LetterboxExporter` is **untouched**.

Why this over the originally-designed single-pass (extract `composeRenderedFrame`
+ a parallel reader loop): the compose tail is deeply entangled (a stateful
inline-camera sample pump plus many render-loop locals), so extracting a shared
tail is a genuine, hard-to-verify refactor. Transcoding the finished video is
**guaranteed-correct** (it reuses the entire tested render) and isolates all GIF
code to two new files + one `ExportEngine` branch. The cost is one extra
intermediate encode generation — negligible for a 256-color, ≤1080, 15 fps GIF,
where ImageIO quantization dominates quality, not an H.264 intermediate.
Single-pass remains a valid **future optimization** (it halves the render work
on GIF exports) but is not worth its risk for v1.

## The parity contract

| Setting | Value |
|---|---|
| fps | **15** (`kGifTargetFps`) — smoothness/size sweet spot; divides 30/60 cleanly |
| decimation | grid-anchored emit target (keep once per ideal interval), **not** last-kept-timestamp gate — stays near target under decoder jitter |
| delay | per-frame from **real edited-timeline gaps** → centiseconds, round-nearest, **floor 2 cs**, **ceil `0xFFFF`**, final frame default **7 cs**, **+ residual-carrying accumulator to kill drift** |
| delay keys | set **both** `kCGImagePropertyGIFDelayTime` **and** `kCGImagePropertyGIFUnclampedDelayTime` per frame |
| loop | `kCGImagePropertyGIFLoopCount = 0` (infinite) |
| **max-size** | **long-edge cap ≤ 1080** (see amendment below; Windows to match via follow-up) |
| palette/dither | ImageIO internal adaptive-256 + internal dither — **same tier as WIC, not byte-identical**; verify by read-back |
| alpha | **opaque-flatten** each frame into `kCGImageAlphaNoneSkipFirst`; never emit a transparent index |

Windows reference values (ported value-for-value in `GifExportPolicy.swift`):
`kGifTargetFps = 15`, `kGifMinDelayCentiseconds = 2`,
`kGifDefaultDelayCentiseconds = 7`, emit-target sentinel `Int64.min`,
`GifFrameIntervalHns = 10_000_000 / 15`, delay = `round(gap / 100_000)` clamped
to `[2, 0xFFFF]`.

## Corrections folded in from adversarial review

1. **≤1080 long-edge cap is mandatory (v1).** 4K is a real, selectable export
   path (`ExportPrep.swift` `p2160`); un-capped it is a *guaranteed* failure —
   ~9,000 kept frames × 3840×2160 → a **7–25 GB** file (opens in no browser)
   after **45 min–2.5 hr** of single-threaded encode. Decimation cuts frame
   *count*, not frame *size*. Windows has the same latent no-cap bug → open a
   Windows follow-up to add the identical cap. "Parity" = both produce a usable
   capped GIF.
2. **Opaque flattening is mandatory.** The composite can carry sub-1.0 alpha
   (rounded-corner AA; `CompositionBuilder.buildExport` uses
   `backgroundMode: .transparent` + a `clearPixelBuffer` when inline camera is
   present). If ImageIO sees alpha it may allocate a transparent palette index →
   **edge halos Windows structurally can't produce** (Windows forces
   `addTransparentColor = FALSE`). This is the single path to macOS looking
   *worse*. Fix: blit each frame into a no-alpha `CGBitmapContext`
   (`kCGImageAlphaNoneSkipFirst`) so ImageIO never sees alpha.
3. **Drift-free delay accumulator (should-fix).** Rounding each 15 fps gap
   (~0.0667 s) to 7 cs (0.070 s) stamps every frame +5% slow → 630 s for a
   600 s clip, monotonic. Carry the fractional-centisecond residual so delays
   alternate 7,6,7,7,6… averaging 6.667. **Intentionally diverges from the
   Windows line-for-line port** (Windows carries the same bug) — flag it for the
   Windows parity follow-up.
4. Set **both** GIF delay keys (legacy-decoder cadence). Relabel palette/dither
   parity as "verify by read-back," not "identical." Add a soft
   duration/frame-count estimate/warning (GIF is the wrong container past
   ~30–60 s); a hard duration cap stays a measured decision.

## Memory strategy

`CGImageDestinationCreateWithURL` (never `…WithData`); `autoreleasepool` per
iteration; one-frame lookahead (previous `CGImage` held as an ARC property,
committed on next append so the last frame gets its default delay); **decimate
before `CGImage` conversion**; **downscale kept frames to the capped size before
encode**. RSS stays flat (~200–400 MB even from a 4K source), independent of
clip length. Cancel/failure deletes the partial `.gif`; `finalize()` on zero
frames returns false and writes nothing.

## Sliced plan

- **PR-1 — `GifExportPolicy.swift` + `GifExportPolicyTests.swift`.** Pure,
  inert, CI-safe. Ports `gif_export_policy.cpp` value-for-value **plus**
  `gifRenderSize(canvasSize:maxLongEdge:)` (the cap math) and the residual
  delay accumulator. Test vectors mirror `gif_export_policy_test.cpp` + new
  cases for the cap and the accumulator's alternating-delay sequence.
- **PR-2 — `GifEncoder.swift` + `GifEncoderTests.swift`.** ImageIO wrapper
  (open/append/finalize/cancel + lookahead) on
  `CGImageDestinationCreateWithURL`. Includes the opaque `noneSkipFirst` flatten
  and both delay keys. Adds two read-back tests: palette-locality (measure &
  document what ImageIO emits) and **no-transparent-index** on an AA/rounded
  frame.
- **PR-3/PR-4 (implemented together) — `GifExportSession.swift` + the
  `ExportEngine.export` GIF branch** (+ `GifExportSessionTests.swift`).
  `GifExportSession` transcodes a rendered video → GIF: `AVAssetReader` /
  `AVAssetReaderTrackOutput` over the finished MOV, decimate on the ideal grid,
  CIImage downscale to the capped size, `GifEncoder`. `ExportEngine` renders the
  temp MOV first (progress `0…0.85`), then transcodes (`0.85…1.0`), deletes the
  temp, and threads the `.gif` path back through the existing manifest/cleanup.
  `cancel()` stops both phases. `LetterboxExporter` is untouched — this replaces
  the original design's compose-tail extraction (dropped as too risky; see the
  frame-source section). Integration tests write a synthetic video and assert
  decimation (30→~15 fps), infinite loop, and the long-edge downscale.
- **PR-5 (optional, data-driven)** — single-pass: composite natively at the
  capped size and encode the GIF in the same render (eliminates the intermediate
  MOV). Only worth it if the extra encode generation shows up in real perf
  numbers, plus any hard duration cap.

## Effort & verification

| Slice | Size | Needs a real macOS box? |
|---|---|---|
| PR-1 policy + tests | S (~0.5d) | No — pure, CI-verifiable |
| PR-2 encoder + tests | M (~1d) | No — ImageIO is CPU-only, headless-safe |
| PR-3 compose-tail refactor | M (~1–1.5d) | Yes — native export tests + manual grade+camera `.mov` smoke |
| PR-4 session + branch + tests | L (~1.5–2d) | Yes — **visual GIF smoke is a human check** |
| PR-5 perf/cap | S–M | Yes — 4K/long perf only meaningful on hardware |

**Total v1 (PR-1→4): ~4–5 days.** Human-only per `CLAUDE.md`: **visual/pixel GIF
correctness** (color, dither texture, chroma/AA edges) and **4K/long perf
numbers**. Everything timing, lifecycle, dimension, loop, and memory-contract is
pinned by automated tests on both platforms.

## Follow-ups

- **Windows parity follow-up:** add the ≤1080 long-edge cap and the drift-free
  delay accumulator to the Windows encoder (both currently un-capped / drift by
  the same ~5%). Update the stale comment in `gif_export_policy.h` that says
  "macOS has NO real GIF encoder" once PR-4 lands.
