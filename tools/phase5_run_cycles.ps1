<#
.SYNOPSIS
  One-command driver for the Phase 5 preview-lifecycle stress verdict
  (Windows beta gate #2 — the NVIDIA / AMD 200-cycle run).

.DESCRIPTION
  The stress verdict needs >= 200 preview open/close cycles against an
  INSTALLED build, then tools/phase5_extract_verdict.ps1 to score them.
  The repo previously documented driving those cycles BY HAND and never
  rotated the append-only cycle log between runs, so stale cycles from a
  prior run inflated the count and could carry a bad MAX into a fresh
  verdict. This script makes the run repeatable and honest:

    1. Reminds you to force the discrete GPU (the engine picks the default
       D3D adapter, so on a hybrid laptop the run can silently execute on
       the iGPU and prove nothing).
    2. Rotates (archives) the existing PHASE5 cycle log so only THIS run's
       cycles are counted.
    3. Drives N programmatic cold-start cycles — the documented
       `& "<exe>" "<project>.clingfyproj"` method (each launch forwards to
       the running instance and opens a fresh preview = one cycle).
    4. Waits for the log to reach the target pair count.
    5. Runs phase5_extract_verdict.ps1 to print the PASS/WARN/FAIL verdict.

  It drives the SAME log + pairing the verdict tool reads
  (%LOCALAPPDATA%\Clingfy\Logs\phase5_cycles.log). Capture the machine
  metadata (winver, dxdiag driver version, CPU, GPU) separately for the
  verdict doc; this script only produces the cycles + numbers.

.PARAMETER Cycles
  Number of cold-start cycles to drive. Default 200 (the ship-gate target).

.PARAMETER Channel
  Which installed build to drive (selects the default exe path). dev ->
  "Clingfy Dev", prod -> "Clingfy". Ignored if -ExePath is given.

.PARAMETER ExePath
  Path to the installed clingfy.exe. Defaults to the per-channel install
  location under %LOCALAPPDATA%\Programs\.

.PARAMETER ProjectPath
  Path to a .clingfyproj bundle to open each cycle. Defaults to the newest
  bundle under %LOCALAPPDATA%\Clingfy\recordings\. Record -> Stop once in
  the app first if none exists.

.PARAMETER DelayMs
  Delay between cold-starts, letting the preview open and the previous one
  close + unregister. Default 1500 ms.

.PARAMETER SettleSec
  After the last launch, how long to keep polling the log for the final
  pairs to land before scoring. Default 60 s.

.PARAMETER LogPath
  PHASE5 cycle log. Defaults to %LOCALAPPDATA%\Clingfy\Logs\phase5_cycles.log
  (CLINGFY_NATIVE_LOG_DIR overrides), matching the native writer and the
  verdict tool.

.PARAMETER MinCycles
  Passed to phase5_extract_verdict.ps1 as the confidence floor. Defaults to
  the value of -Cycles.

.PARAMETER KeepLog
  Do NOT rotate the existing log first (append to it). Off by default — a
  fresh verdict should start from an empty log.

.PARAMETER NoExtract
  Skip auto-running phase5_extract_verdict.ps1 at the end.

.PARAMETER DryRun
  Resolve + report the exe / project / log paths and print the plan without
  rotating the log or launching anything.

.EXAMPLE
  # Full 200-cycle dev run, rotate the log, score at the end:
  .\tools\phase5_run_cycles.ps1 -Channel dev

.EXAMPLE
  # 50-cycle smoke against a specific project, keep the verdict in a file:
  .\tools\phase5_run_cycles.ps1 -Cycles 50 -ProjectPath 'C:\...\rec.clingfyproj' `
    | Out-File -Encoding utf8 build\windows-phase-5\nvidia_result.md

.EXAMPLE
  # See what it would do without touching anything:
  .\tools\phase5_run_cycles.ps1 -DryRun
#>

[CmdletBinding()]
param(
  [int]$Cycles = 200,
  [ValidateSet('dev', 'prod')]
  [string]$Channel = 'dev',
  [string]$ExePath,
  [string]$ProjectPath,
  [int]$DelayMs = 1500,
  [int]$SettleSec = 60,
  [string]$LogPath,
  [int]$MinCycles = -1,
  [switch]$KeepLog,
  [switch]$NoExtract,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Info($m) { Write-Host "    $m" }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if ($MinCycles -lt 0) { $MinCycles = $Cycles }

# --- Resolve the cycle log (same default as phase5_extract_verdict.ps1) ------
if (-not $LogPath) {
  $nativeLogDir = if ($env:CLINGFY_NATIVE_LOG_DIR) { $env:CLINGFY_NATIVE_LOG_DIR }
                  else { Join-Path $env:LOCALAPPDATA 'Clingfy\Logs' }
  $LogPath = Join-Path $nativeLogDir 'phase5_cycles.log'
}

# --- Resolve the installed exe -----------------------------------------------
if (-not $ExePath) {
  $appDir = if ($Channel -eq 'prod') { 'Programs\Clingfy' } else { 'Programs\Clingfy Dev' }
  $ExePath = Join-Path $env:LOCALAPPDATA (Join-Path $appDir 'clingfy.exe')
}

# --- Resolve the project bundle (newest under recordings\) --------------------
if (-not $ProjectPath) {
  $recordingsDir = Join-Path $env:LOCALAPPDATA 'Clingfy\recordings'
  if (Test-Path -LiteralPath $recordingsDir) {
    $newest = Get-ChildItem -LiteralPath $recordingsDir -Filter '*.clingfyproj' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { $ProjectPath = $newest.FullName }
  }
}

Write-Step 'Plan'
Write-Info "Channel:  $Channel"
Write-Info "Exe:      $ExePath$(if (Test-Path -LiteralPath $ExePath) { '' } else { '   [NOT FOUND]' })"
Write-Info "Project:  $(if ($ProjectPath) { $ProjectPath } else { '[none found under recordings\ — Record -> Stop once first]' })"
Write-Info "Log:      $LogPath"
Write-Info "Cycles:   $Cycles  (delay ${DelayMs}ms, settle ${SettleSec}s, verdict floor $MinCycles)"
Write-Info "Rotate:   $([bool](-not $KeepLog))"

Write-Host ''
Write-Host 'REMINDER: force the discrete GPU for a meaningful NVIDIA/AMD verdict.' -ForegroundColor Yellow
Write-Host '  Settings > System > Display > Graphics > add clingfy.exe > High performance.' -ForegroundColor Yellow
Write-Host '  The engine uses the default D3D adapter, so a hybrid laptop can otherwise' -ForegroundColor Yellow
Write-Host '  run the whole stress on the iGPU and prove nothing about NVIDIA/AMD.' -ForegroundColor Yellow
Write-Host 'Capture for the verdict doc: winver, dxdiag > Display > Driver Version, CPU, GPU,' -ForegroundColor Yellow
Write-Host 'and Task Manager > Performance > GPU memory BEFORE and AFTER the run.' -ForegroundColor Yellow
Write-Host ''

# --- Validate (fatal outside dry-run) ----------------------------------------
if (-not (Test-Path -LiteralPath $ExePath)) {
  if ($DryRun) { Write-Info 'DRY RUN: exe missing — install the build, then run for real.' }
  else { Fail "Installed exe not found: $ExePath. Install the $Channel build first (run the Clingfy setup .exe)." }
}
if (-not $ProjectPath) {
  if ($DryRun) { Write-Info 'DRY RUN: no project bundle — Record -> Stop once, or pass -ProjectPath.' }
  else { Fail "No .clingfyproj found under %LOCALAPPDATA%\Clingfy\recordings\. Record -> Stop once in the app, or pass -ProjectPath." }
}

if ($DryRun) {
  Write-Host ''
  Write-Step 'DRY RUN — no log rotated, nothing launched.'
  exit 0
}

# --- Rotate the log so only this run's cycles are counted --------------------
if (Test-Path -LiteralPath $LogPath) {
  if ($KeepLog) {
    Write-Info 'Keeping existing log (-KeepLog); its prior cycles will be counted too.'
  } else {
    if (Get-Process -Name 'clingfy' -ErrorAction SilentlyContinue) {
      Fail 'Clingfy is running; close it first so the append-only log can be rotated cleanly, then re-run.'
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archive = "$LogPath.$stamp.bak"
    Move-Item -LiteralPath $LogPath -Destination $archive
    Write-Step "Rotated old log -> $archive"
  }
} else {
  $logDir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
  Write-Info 'No existing log; starting fresh.'
}

# --- Count paired PHASE5 cycles in the log (same pairing as the verdict tool) -
function Get-PairedCount([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  $opens = @{}; $closes = @{}
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match 'PHASE5-OPEN\s+cycle=\d+\s+session=(\S+)') { $opens[$Matches[1]] = $true }
    elseif ($line -match 'PHASE5-CYCLE\s+cycle=\d+\s+session=(\S+)') { $closes[$Matches[1]] = $true }
  }
  return ($opens.Keys | Where-Object { $closes.ContainsKey($_) }).Count
}

# --- Drive the cold-start cycles ---------------------------------------------
Write-Step "Driving $Cycles cold-start cycles"
for ($i = 1; $i -le $Cycles; $i++) {
  # Fire-and-forget: a single-instance forward opens a fresh preview (one
  # cycle) and the launched process exits. The first launch becomes the
  # persistent instance.
  Start-Process -FilePath $ExePath -ArgumentList "`"$ProjectPath`"" | Out-Null
  Start-Sleep -Milliseconds $DelayMs
  if ($i % 10 -eq 0 -or $i -eq $Cycles) {
    Write-Info ("launched {0}/{1}  (paired so far: {2})" -f $i, $Cycles, (Get-PairedCount $LogPath))
  }
}

# --- Settle: wait for the last cycles' unregister callbacks to land ----------
Write-Step "Settling up to ${SettleSec}s for final pairs"
$deadline = (Get-Date).AddSeconds($SettleSec)
while ((Get-Date) -lt $deadline) {
  if ((Get-PairedCount $LogPath) -ge $Cycles) { break }
  Start-Sleep -Seconds 2
}
$paired = Get-PairedCount $LogPath
Write-Info "paired cycles in log: $paired / $Cycles target"
if ($paired -lt $Cycles) {
  Write-Host ''
  Write-Host "NOTE: only $paired paired cycles landed. If the count did not advance," -ForegroundColor Yellow
  Write-Host 'the single-instance cold-start forward may be a no-op on this build; drive' -ForegroundColor Yellow
  Write-Host 'the remaining cycles by hand (Record -> Stop -> Close preview) and re-score.' -ForegroundColor Yellow
}

# --- Score -------------------------------------------------------------------
if ($NoExtract) {
  Write-Host ''
  Write-Info "Skipping verdict (-NoExtract). Score with:"
  Write-Info "  ./tools/phase5_extract_verdict.ps1 -LogPath `"$LogPath`" -MinCycles $MinCycles"
  exit 0
}
Write-Host ''
Write-Step 'Extracting verdict'
& (Join-Path $PSScriptRoot 'phase5_extract_verdict.ps1') -LogPath $LogPath -MinCycles $MinCycles
