#!/usr/bin/env pwsh
#Requires -Version 7
# upload_symbols.ps1
#
# Phase 10.4 (crash pipeline): minimal standalone Sentry symbol upload for
# Windows. Uploads every debug file a symbolicated native crash needs:
#
#   * the runner + in-tree native PDBs   build/windows/x64/runner/Release/**/*.pdb
#     (RelWithDebInfo too, if present)   build/windows/x64/runner/RelWithDebInfo/**/*.pdb
#   * the Flutter engine PDB             windows/flutter/ephemeral/flutter_windows.dll.pdb
#   * the Dart AOT snapshot              build/windows/app.so
#   * plugin PDBs                        build/windows/x64/plugins/**/*.pdb
#
# Run it after `flutter build windows --release` (the Release PDBs only exist
# since the Phase 10.4 /Z7 + /DEBUG:FULL change in windows/CMakeLists.txt).
#
# Credentials: SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT are read from
# the process environment first; pass -EnvFile .env.dev (or .env.prod) to
# fall back to the values in that file. Environment variables always win.
#
# NOTE: this is the Phase 10.4 minimal script — the Phase 10.5 Windows
# release pipeline absorbs it. Keep it dependency-free (sentry-cli only).

[CmdletBinding()]
param(
  # Flutter build output root, relative to the repo root (or absolute).
  [string]$BuildRoot = "build",

  # Optional dotenv-style file (e.g. ".env.dev") used as a FALLBACK for
  # SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT when the corresponding
  # environment variables are not already set.
  [string]$EnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Skip([string]$Message) { Write-Warning $Message }
function Fail([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

# --- Resolve paths against the repo root (ops/release/windows -> ../../..) ---
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return Join-Path $RepoRoot $Path
}

$BuildRootPath = Resolve-RepoPath $BuildRoot

Write-Step "Sentry symbol upload (Windows, Phase 10.4)"
Write-Info "Repo root:  $RepoRoot"
Write-Info "Build root: $BuildRootPath"

# --- Credentials: environment first, -EnvFile fallback ----------------------
$SentryKeys = @('SENTRY_AUTH_TOKEN', 'SENTRY_ORG', 'SENTRY_PROJECT')

if ($EnvFile) {
  $EnvFilePath = Resolve-RepoPath $EnvFile
  if (-not (Test-Path -LiteralPath $EnvFilePath -PathType Leaf)) {
    Fail "Env file not found: $EnvFilePath"
  }
  foreach ($line in Get-Content -LiteralPath $EnvFilePath) {
    # Match KEY="value" or KEY=value lines; ignore comments/blank lines.
    if ($line -match '^\s*(SENTRY_AUTH_TOKEN|SENTRY_ORG|SENTRY_PROJECT)\s*=\s*"?([^"]*)"?\s*$') {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      # Environment variables win over the file.
      if (-not [Environment]::GetEnvironmentVariable($key) -and $value) {
        Set-Item -Path "env:$key" -Value $value
        Write-Info "Loaded $key from $(Split-Path -Leaf $EnvFilePath)"
      }
    }
  }
}

$missingKeys = $SentryKeys | Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
if ($missingKeys) {
  Fail ("Missing Sentry settings: $($missingKeys -join ', '). " +
    "Set them in the environment or pass -EnvFile .env.dev / .env.prod.")
}

# --- Tooling ----------------------------------------------------------------
$sentryCli = Get-Command sentry-cli -ErrorAction SilentlyContinue
if (-not $sentryCli) {
  Fail ("sentry-cli not found on PATH. Install it first, e.g.:`n" +
    "  scoop install sentry-cli`n" +
    "  # or: npm install -g @sentry/cli`n" +
    "  # or: https://docs.sentry.io/cli/installation/")
}
Write-Info "sentry-cli: $($sentryCli.Source)"

# --- Collect debug files ------------------------------------------------------
# Each entry: a label for the summary plus the concrete files found.
$uploadFiles = [System.Collections.Generic.List[string]]::new()
$summary = [System.Collections.Generic.List[string]]::new()

function Add-PdbTree([string]$Label, [string]$Directory) {
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    Write-Skip "$Label not found, skipping: $Directory"
    return
  }
  $pdbs = @(Get-ChildItem -LiteralPath $Directory -Recurse -Filter '*.pdb' -File)
  if ($pdbs.Count -eq 0) {
    Write-Skip "$Label contains no .pdb files, skipping: $Directory"
    return
  }
  foreach ($pdb in $pdbs) { $uploadFiles.Add($pdb.FullName) }
  $summary.Add("$Label — $($pdbs.Count) PDB(s) under $Directory")
}

function Add-SingleFile([string]$Label, [string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
    Write-Skip "$Label not found, skipping: $File"
    return
  }
  $uploadFiles.Add((Get-Item -LiteralPath $File).FullName)
  $summary.Add("$Label — $File")
}

Write-Step "Collecting debug files"

# Runner + runner_bridge + anything else linked under the runner tree.
Add-PdbTree 'Runner Release PDBs' (Join-Path $BuildRootPath 'windows' 'x64' 'runner' 'Release')
Add-PdbTree 'Runner RelWithDebInfo PDBs' (Join-Path $BuildRootPath 'windows' 'x64' 'runner' 'RelWithDebInfo')

# Flutter engine PDB (ships in the ephemeral dir next to flutter_windows.dll).
Add-SingleFile 'Flutter engine PDB' (Join-Path $RepoRoot 'windows' 'flutter' 'ephemeral' 'flutter_windows.dll.pdb')

# Dart AOT snapshot (ELF with symbols; Sentry symbolizes Dart frames from it).
Add-SingleFile 'Dart AOT snapshot' (Join-Path $BuildRootPath 'windows' 'app.so')

# Plugin PDBs next to the built plugin DLLs.
Add-PdbTree 'Plugin PDBs' (Join-Path $BuildRootPath 'windows' 'x64' 'plugins')

if ($uploadFiles.Count -eq 0) {
  Fail ("No uploadable debug files found under '$BuildRootPath'. " +
    "Run 'flutter build windows --release' first (Release PDBs require the " +
    "Phase 10.4 windows/CMakeLists.txt change).")
}

Write-Info "Found $($uploadFiles.Count) file(s) to upload."

# --- Upload -------------------------------------------------------------------
Write-Step "Uploading to Sentry ($env:SENTRY_ORG / $env:SENTRY_PROJECT)"

# An array variable in native-command argument position expands to one
# argument per element — every collected file becomes its own path argument.
$fileArgs = $uploadFiles.ToArray()
& $sentryCli.Source debug-files upload `
  --org $env:SENTRY_ORG `
  --project $env:SENTRY_PROJECT `
  $fileArgs
if ($LASTEXITCODE -ne 0) {
  Fail "sentry-cli debug-files upload failed with exit code $LASTEXITCODE."
}

# --- Summary --------------------------------------------------------------------
Write-Step "Upload summary"
foreach ($line in $summary) { Write-Info $line }
Write-Host "Symbol upload completed successfully." -ForegroundColor Green
exit 0
