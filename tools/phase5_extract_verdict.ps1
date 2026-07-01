<#
.SYNOPSIS
  Parse PreviewEngine's native log and emit a Phase 5 verdict table.

.DESCRIPTION
  PreviewEngine instruments each open/close cycle with two structured
  log lines (Step 5.7 of the Phase 5 implementation plan):

    PHASE5-OPEN cycle=<n> session=<...> texture_id=<...>
    PHASE5-CYCLE cycle=<n> session=<...> frames=<...> close_to_unregister_ms=<...>

  This tool reads `build/windows-poc/stage2a_2_native.log`, pairs the
  two lines by `cycle=`, and prints:

    * a per-cycle table (cycle, frames consumed, unregister latency ms)
    * an aggregate summary (cycle count, min/median/p99/max unregister ms)
    * a verdict line ("PASS" / "WARN" / "FAIL" with reason)

  Pipe the output into `docs/decisions/windows-phase-5-stress-verdict.md`
  under the GPU's section. The pass criteria are documented in the
  same file; this script just produces the numbers.

.PARAMETER LogPath
  Path to the append-only PHASE5 cycle log. Defaults to
  build\windows-poc\phase5_cycles.log under the repo root. The legacy
  build\windows-poc\stage2a_2_native.log path is *not* used — that
  file is truncated on every Open() (crash breadcrumb semantics) and
  cannot retain cross-cycle history.

.PARAMETER MaxUnregisterMs
  Threshold for the "all unregister callbacks under N ms" gate.
  Defaults to 1000ms — anything above is the texture-unregister
  pathology the POC was working around.

.PARAMETER MinCycles
  Minimum cycle count before the verdict considers itself meaningful.
  Defaults to 10 (a sane sanity-test floor); the ADR target is 200
  for the formal ship gate.

.EXAMPLE
  .\tools\phase5_extract_verdict.ps1
  # Reads the default log path, prints the table + verdict to stdout.

.EXAMPLE
  .\tools\phase5_extract_verdict.ps1 -MinCycles 200 |
    Out-File -Encoding utf8 build\windows-phase-5\stage5_lifecycle_result.md
#>

[CmdletBinding()]
param(
    [string]$LogPath,
    [int]$MaxUnregisterMs = 1000,
    [int]$MinCycles = 10
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    # Phase 10.1 moved native logs to %LOCALAPPDATA%\Clingfy\Logs
    # (CLINGFY_NATIVE_LOG_DIR overrides). Fall back to the legacy
    # repo-relative location for logs produced by older builds.
    $nativeLogDir = if ($env:CLINGFY_NATIVE_LOG_DIR) { $env:CLINGFY_NATIVE_LOG_DIR }
                    else { Join-Path $env:LOCALAPPDATA 'Clingfy\Logs' }
    $LogPath = Join-Path $nativeLogDir 'phase5_cycles.log'
    if (-not (Test-Path -LiteralPath $LogPath)) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $legacy = Join-Path $repoRoot 'build\windows-poc\phase5_cycles.log'
        if (Test-Path -LiteralPath $legacy) { $LogPath = $legacy }
    }
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "PHASE5 cycle log not found at $LogPath. Run the app, do at least a few Record -> Stop -> Close cycles, then re-run this script."
}

$lines = Get-Content -LiteralPath $LogPath

# Pair PHASE5-OPEN and PHASE5-CYCLE by `session=` (unique per cycle).
# Earlier shipping code paired by the `cycle=` token, but a bug in
# PreviewEngine's Close() path always reports CYCLE cycle=0 (the
# index is cleared before the TearDownContext snapshots it). Matching
# by session sidesteps that bug for logs produced before the native
# fix lands.
$opens = @{}
$closes = @{}
$openOrder = @()
foreach ($line in $lines) {
    if ($line -match 'PHASE5-OPEN\s+cycle=(\d+)\s+session=(\S+)\s+texture_id=(-?\d+)') {
        $cycle = [int]$Matches[1]
        $session = $Matches[2]
        $opens[$session] = @{
            cycle = $cycle
            texture_id = [int64]$Matches[3]
        }
        $openOrder += $session
    }
    elseif ($line -match 'PHASE5-CYCLE\s+cycle=(\d+)\s+session=(\S+)\s+frames=(\d+)\s+close_to_unregister_ms=(\d+)') {
        $session = $Matches[2]
        $closes[$session] = @{
            frames = [int64]$Matches[3]
            close_to_unregister_ms = [int]$Matches[4]
        }
    }
}

$pairedSessions = $openOrder | Where-Object { $closes.ContainsKey($_) }

if ($pairedSessions.Count -eq 0) {
    Write-Host '# Phase 5 verdict' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'No PHASE5-OPEN/PHASE5-CYCLE pairs found in the log.' -ForegroundColor Yellow
    Write-Host "Log path: $LogPath"
    Write-Host 'Do at least one Record -> Stop -> Close cycle in the app and re-run this script.'
    exit 1
}

# Per-cycle table.
Write-Host ''
Write-Host '## Per-cycle measurements'
Write-Host ''
Write-Host '| Cycle | Frames consumed | Close -> unregister callback (ms) | Texture id |'
Write-Host '|-------|-----------------|------------------------------------|------------|'
foreach ($s in $pairedSessions) {
    $o = $opens[$s]
    $cl = $closes[$s]
    Write-Host ("| {0,5} | {1,15} | {2,34} | {3,10} |" -f $o.cycle, $cl.frames, $cl.close_to_unregister_ms, $o.texture_id)
}

# Aggregate.
$latencies = $pairedSessions | ForEach-Object { $closes[$_].close_to_unregister_ms }
$sorted = $latencies | Sort-Object
$min = $sorted[0]
$max = $sorted[-1]
$median = $sorted[[int][math]::Floor($sorted.Count / 2)]
$p99Index = [int][math]::Floor($sorted.Count * 0.99)
if ($p99Index -ge $sorted.Count) { $p99Index = $sorted.Count - 1 }
$p99 = $sorted[$p99Index]
$maxFrames = ($pairedSessions | ForEach-Object { $closes[$_].frames } | Measure-Object -Maximum).Maximum
$totalFrames = ($pairedSessions | ForEach-Object { $closes[$_].frames } | Measure-Object -Sum).Sum

Write-Host ''
Write-Host '## Aggregate'
Write-Host ''
Write-Host "- Cycles paired: $($pairedSessions.Count)"
Write-Host ('- Unregister callback latency ms — min: {0}  median: {1}  p99: {2}  max: {3}' -f $min, $median, $p99, $max)
Write-Host ('- Frames consumed across all cycles: {0} (peak per cycle: {1})' -f $totalFrames, $maxFrames)
Write-Host "- Log path: $LogPath"

# Verdict.
$verdict = 'PASS'
$reasons = @()
if ($pairedSessions.Count -lt $MinCycles) {
    $verdict = 'WARN'
    $reasons += ('Only {0} cycles paired (threshold for confidence: {1}).' -f $pairedSessions.Count, $MinCycles)
}
if ($max -gt $MaxUnregisterMs) {
    $verdict = 'FAIL'
    $reasons += "Max unregister-callback latency $max ms exceeds threshold $MaxUnregisterMs ms."
}
# A zero-frame cycle means MediaPlayer never produced output before close
# — that's a load failure dressed up as a successful cycle.
$zeroFrameSessions = $pairedSessions | Where-Object { $closes[$_].frames -eq 0 }
if ($zeroFrameSessions.Count -gt 0) {
    $zeroFrameOpenCycles = $zeroFrameSessions | ForEach-Object { $opens[$_].cycle }
    $verdict = 'FAIL'
    $reasons += "$($zeroFrameSessions.Count) cycle(s) consumed zero frames (cycles: $($zeroFrameOpenCycles -join ', '))."
}

Write-Host ''
Write-Host '## Verdict'
Write-Host ''
if ($verdict -eq 'PASS') {
    Write-Host '**PASS** — no regressions detected against the Stage 2A-2 baseline.'
} elseif ($verdict -eq 'WARN') {
    Write-Host '**WARN** — verdict is preliminary:'
    foreach ($r in $reasons) { Write-Host "  - $r" }
} else {
    Write-Host '**FAIL** — Phase 5 ship gate not met:'
    foreach ($r in $reasons) { Write-Host "  - $r" }
}
