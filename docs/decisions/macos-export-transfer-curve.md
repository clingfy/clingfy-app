# macOS export transfer curve: gamma 1.961, not the BT.709 OETF

Status: **accepted**, shipped in 1.0.7 (#391). Recorded 2026-10-26; the reasoning
first lived only in code comments.

## Decision

The export tags its video BT.709 and encodes it with a pure gamma of **1.961**
(`ColorTransferFunctions.exportTransferGamma`), the curve Apple's decoders apply
to a 709 tag, rather than the published BT.709 OETF.

## Why

Both curves are wrong by the same amount, at most 18 code values. They are
wrong on different players, though, and they fail in different directions:

| encode          | worst on Apple | worst on strict spec |
|-----------------|---------------:|---------------------:|
| published OETF  |           18.0 |                  0.0 |
| gamma 1.961     |            0.0 |                 18.0 |
| gamma 2.000     |            1.9 |                 19.0 |

There is no compromise curve, because the error lives in the shape of the toe,
not in the exponent.

The tie-break is which failure does more damage:

- **Spec encode crushes on Apple.** On a real dark-mode recording, stored luma
  20 rendered at 1.3 in QuickTime, where the standard intends 13.1. About 70%
  of the frame sat in that band, so the shadow detail was gone.
- **1.961 lifts on strict-spec players.** Authored 32 shows near 45, washed out
  but with every level still distinguishable.

Lifting is the gentler error. QuickTime, Preview, Safari and Messages are where
macOS users check a recording.

## Related choices

- **Limited range stays.** The file declares limited range and contains limited
  range. The earlier "full range" theory was a red herring (#372, closed).
  Moving to full-range or planar buffers would also mean reworking
  `clearPixelBuffer`, which memsets a 32BGRA buffer (`LetterboxExporter.swift`).
- **The pixel buffers are tagged sRGB on purpose.** sRGB is the working space,
  and `encodeForExport` writes the data into the 709 transfer the file declares.

## Revisit when

Revisit if Windows or browser playback becomes the primary target. The sweep
that produced the table takes a second to re-run (`ColorTransferFunctions.swift`).
A by-eye check of a dark clip in QuickTime is still open in `TODOS.md`.
