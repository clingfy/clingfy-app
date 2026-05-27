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
  Path to the native log. Defaults to
  build\windows-poc\stage2a_2_native.log under the repo root.

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
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $LogPath = Join-Path $repoRoot 'build\windows-poc\stage2a_2_native.log'
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Native log not found at $LogPath. Run the app, do at least a few Record -> Stop -> Close cycles, then re-run this script."
}

$lines = Get-Content -LiteralPath $LogPath

# Pair PHASE5-OPEN and PHASE5-CYCLE on the `cycle=` token.
$opens = @{}
$closes = @{}
foreach ($line in $lines) {
    if ($line -match 'PHASE5-OPEN\s+cycle=(\d+)\s+session=(\S+)\s+texture_id=(-?\d+)') {
        $cycle = [int]$Matches[1]
        $opens[$cycle] = @{
            session = $Matches[2]
            texture_id = [int64]$Matches[3]
        }
    }
    elseif ($line -match 'PHASE5-CYCLE\s+cycle=(\d+)\s+session=(\S+)\s+frames=(\d+)\s+close_to_unregister_ms=(\d+)') {
        $cycle = [int]$Matches[1]
        $closes[$cycle] = @{
            session = $Matches[2]
            frames = [int64]$Matches[3]
            close_to_unregister_ms = [int]$Matches[4]
        }
    }
}

$pairedCycles = $closes.Keys | Where-Object { $opens.ContainsKey($_) } | Sort-Object

if ($pairedCycles.Count -eq 0) {
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
foreach ($c in $pairedCycles) {
    $o = $opens[$c]
    $cl = $closes[$c]
    Write-Host ("| {0,5} | {1,15} | {2,34} | {3,10} |" -f $c, $cl.frames, $cl.close_to_unregister_ms, $o.texture_id)
}

# Aggregate.
$latencies = $pairedCycles | ForEach-Object { $closes[$_].close_to_unregister_ms }
$sorted = $latencies | Sort-Object
$min = $sorted[0]
$max = $sorted[-1]
$median = $sorted[[int][math]::Floor($sorted.Count / 2)]
$p99Index = [int][math]::Floor($sorted.Count * 0.99)
if ($p99Index -ge $sorted.Count) { $p99Index = $sorted.Count - 1 }
$p99 = $sorted[$p99Index]
$maxFrames = ($pairedCycles | ForEach-Object { $closes[$_].frames } | Measure-Object -Maximum).Maximum
$totalFrames = ($pairedCycles | ForEach-Object { $closes[$_].frames } | Measure-Object -Sum).Sum

Write-Host ''
Write-Host '## Aggregate'
Write-Host ''
Write-Host "- Cycles paired: $($pairedCycles.Count)"
Write-Host ('- Unregister callback latency ms — min: {0}  median: {1}  p99: {2}  max: {3}' -f $min, $median, $p99, $max)
Write-Host ('- Frames consumed across all cycles: {0} (peak per cycle: {1})' -f $totalFrames, $maxFrames)
Write-Host "- Log path: $LogPath"

# Verdict.
$verdict = 'PASS'
$reasons = @()
if ($pairedCycles.Count -lt $MinCycles) {
    $verdict = 'WARN'
    $reasons += ('Only {0} cycles paired (threshold for confidence: {1}).' -f $pairedCycles.Count, $MinCycles)
}
if ($max -gt $MaxUnregisterMs) {
    $verdict = 'FAIL'
    $reasons += "Max unregister-callback latency $max ms exceeds threshold $MaxUnregisterMs ms."
}
# A zero-frame cycle means MediaPlayer never produced output before close
# — that's a load failure dressed up as a successful cycle.
$zeroFrameCycles = $pairedCycles | Where-Object { $closes[$_].frames -eq 0 }
if ($zeroFrameCycles.Count -gt 0) {
    $verdict = 'FAIL'
    $reasons += "$($zeroFrameCycles.Count) cycle(s) consumed zero frames (cycles: $($zeroFrameCycles -join ', '))."
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
