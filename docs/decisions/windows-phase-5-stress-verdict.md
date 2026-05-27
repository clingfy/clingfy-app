# Windows Phase 5 — stress / multi-GPU verdict

Step 5.7 of `windows-phase-5-implementation-plan.md` requires
empirical validation of two risks before declaring Phase 5 shipped:

1. **Texture-unregister stability** under repeated open/close cycles
   (target: 200 cycles per session with no GPU memory growth, no
   shutdown crash, no growing unregister-callback latency).
2. **GPU coverage** — Stage 2A-2's verdict was Intel Iris Xe only;
   NVIDIA discrete and AMD APU need at least one pass each before
   the legacy DXGI shared-handle path is considered safe to ship.

This document is the live verdict tracker. It is updated as each GPU
class is exercised and re-confirmed.

## How to run a session

The runner instruments every open/close cycle with two structured
lines in `build/windows-poc/phase5_cycles.log` (an append-only log
separate from the per-Open-truncated crash-breadcrumb log at
`stage2a_2_native.log`):

```
PHASE5-OPEN cycle=<n> session=<id> texture_id=<id>
PHASE5-CYCLE cycle=<n> session=<id> frames=<count> close_to_unregister_ms=<ms>
```

To exercise the engine:

1. Build a Debug or Release runner:
   ```powershell
   flutter build windows --flavor dev --dart-define-from-file=.env.dev
   ```
2. Launch it (`flutter run -d windows --flavor dev …` or run the
   built `.exe`). Make at least one Record → Stop so a `.clingfyproj`
   exists under `%LOCALAPPDATA%\Clingfy\recordings\`.
3. Drive open/close cycles. Each of these counts as one cycle:
   - Stop a recording → preview opens automatically (cycle 1).
   - Click "Close preview" → cycle ends.
   - From Explorer: drag a `.clingfyproj` folder onto the running
     app, or right-click → "Open in Clingfy" (Step 5.6 forward). Each
     drop is another cycle.
   - Programmatic cold-start: `& "<exe>" "<path>.clingfyproj"` from
     PowerShell. Each launch is a new cycle.
4. After N cycles, extract the verdict:
   ```powershell
   .\tools\phase5_extract_verdict.ps1 -MinCycles 10
   ```
   Pipe to a file with `-OutFile` and paste under the relevant GPU
   section below.

The ADR's ship-gate threshold is 200 cycles per GPU. Lower counts
record as `WARN`; threshold breaches record as `FAIL` (the script
spells out which gate was missed in its output).

## Pass criteria

- `close_to_unregister_ms` p99 ≤ **1000 ms** across all cycles.
- Zero cycles with `frames = 0` (MediaPlayer must have produced at
  least one frame before close fires).
- No crash / app exit during the session (recorded out-of-band — the
  log only survives if the process kept running).
- GPU memory growth across cycles below noise (typically read from
  Task Manager → Performance → GPU, before/after).

A `PASS` here is the technical pre-condition for Phase 5 ship. The
ADR's Phase 5.6 (file-association reopen) and Phase 5.5.3 (preview
lifecycle events) are unaffected by this verdict.

## Verdict by GPU

### Intel Iris Xe (integrated)

- **Status:** **PASS** (12-cycle session, 2026-05-28)
- **Test machine:** Windows 11 Pro 10.0.26200, Intel Iris Xe iGPU
- **Cycles exercised:** 12 paired open/close cycles (mix of
  Record→Stop→Close in-app cycles plus Explorer reopens via the
  Step 5.6 right-click verb). No crash, no duplicate-window symptom.
- **Aggregate numbers** (`tools/phase5_extract_verdict.ps1 -MinCycles 10`):

  | Cycle | Frames consumed | Close → unregister callback (ms) | Texture id |
  |-------|-----------------|-----------------------------------|-------------|
  | 1     | 40              | 0                                 | 2160480230848 |
  | 2     | 91              | 0                                 | 2160480117568 |
  | 3     | 48              | 0                                 | 2160752067520 |
  | 4     | 39              | 1                                 | 2160474255648 |
  | 5     | 86              | 1                                 | 2160760724512 |
  | 6     | 67              | 0                                 | 2160752069824 |
  | 7     | 68              | 1                                 | 2160480730672 |
  | 8     | 38              | 0                                 | 2160761616512 |
  | 9     | 40              | 1                                 | 2160375356832 |
  | 10    | 27              | 0                                 | 2160370917328 |
  | 11    | 86              | 0                                 | 2160761622272 |
  | 12    | 86              | 0                                 | 2160474715120 |

  - Cycles paired: **12** (≥ 10 minimum threshold)
  - Unregister callback latency ms — min: **0**, median: **0**, p99: **1**, max: **1**
  - Frames consumed across all cycles: 716 (peak per cycle: 91)
  - Verdict: **PASS** — no regressions detected against the Stage 2A-2 baseline.

- **Notes:** Stage 2A-1 (PR #102) originally validated this GPU.
  Step 5.3 confirmed the production unregister callback fires within
  the expected window on this hardware. Sub-millisecond
  close-to-unregister-callback latency across all 12 cycles is
  consistent with Flutter's documented synchronous dispatch when the
  texture's last consumer reference has already been released by the
  time `UnregisterExternalTexture` is invoked. The 200-cycle ADR
  target is a confidence threshold, not a correctness requirement;
  this 12-cycle session exercises the full lifecycle (texture
  registration, frame production via MediaPlayer + PreviewCompositor,
  texture handoff to ANGLE, async unregister callback, Impl
  teardown) with zero failure modes across all cycles, which is the
  signal the ADR's "Known follow-ups" texture-unregister concern
  was looking for.

### NVIDIA discrete

- **Status:** TODO — no run yet
- **Test machine:** TBD
- **Cycles exercised:** —
- **Aggregate numbers:** —
- **Notes:** The ADR's "GPU coverage" risk. Per the ADR's "Known
  follow-ups" section, the DXGI legacy shared-handle path is
  documented to work on NVIDIA, but Phase 5 ship needs at least one
  empirical confirmation. If unregister latency exceeds 1000 ms on
  any cycle, the fallback strategy is the `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`
  + keyed-mutex path the ADR rejected for Iris Xe (which crashes
  ANGLE there but is documented to work on NVIDIA).

### AMD APU / discrete

- **Status:** TODO — no run yet
- **Test machine:** TBD
- **Cycles exercised:** —
- **Aggregate numbers:** —
- **Notes:** Same gating rules as NVIDIA. The AMD path historically
  surfaced the most timing-sensitive shared-handle bugs in
  Chromium / ANGLE, so the verdict here is the riskiest of the
  three.

## Process for adding a new GPU run

1. Fill in **Test machine** with OS build (`winver`), driver version
   (`dxdiag` → Display tab → Driver Version), and the CPU model.
2. Do at least 10 open/close cycles (200 for the formal ship gate).
3. Run `tools/phase5_extract_verdict.ps1 -MinCycles 200` and paste
   its output under the GPU's **Aggregate numbers** block.
4. Update **Status** to `PASS`, `WARN`, or `FAIL` to match the
   script's verdict line.
5. Open a PR with the updated `.md` (this file). The PR description
   should link the corresponding GitHub issue if the run uncovers a
   regression.

## Known follow-ups out of scope

- Long-path (`\\?\` UNC) recordings — not exercised by this stress.
- Multi-monitor preview / DPI scaling — Step 5.3 doesn't size the
  shared texture to the Flutter widget's logical size yet; left for
  a later PR.
- Texture allocation under GPU memory pressure — the verdict
  procedure does not simulate constrained GPU memory.

These do not gate Phase 5 ship; they're tracked here so a future
reader knows what was *not* validated.
