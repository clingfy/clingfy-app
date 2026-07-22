#!/usr/bin/env pwsh
#Requires -Version 7
# 01_build.ps1
#
# Phase 10.5 (Windows installer + release pipeline): builds the Windows
# release bundle and stages a clean, installable app folder:
#
#   flutter build windows --release --dart-define-from-file=.env.<channel>
#   build/windows/x64/runner/Release  ->  dist/windows/app
#
# Staging rules (per the Phase 10 beta-readiness plan, D1/10.5):
#   * EXCLUDE *.pdb            — symbols are upload artifacts for Sentry
#                                (upload_symbols.ps1), never shipped to users
#   * EXCLUDE runner_bridge.lib — static-lib build artifact, not a runtime file
#   * EXCLUDE native_assets.json — build input; the runtime manifest lives in
#                                data/flutter_assets/NativeAssetsManifest.json
#   * INCLUDE the VC++ CRT app-locally (msvcp140/vcruntime140/vcruntime140_1)
#                              — vc_redist.exe needs admin, which a per-user
#                                install (PrivilegesRequired=lowest) cannot ask
#                                for; missing-CRT failures are pre-telemetry
#
# The staged folder is verified afterwards: required runtime files (incl. the
# crashpad trio) must be present, and zero PDBs may remain.

[CmdletBinding()]
param(
  # Release channel: selects the .env file for --dart-define-from-file and
  # the staged artifact identity.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile,

  # Run `flutter clean` first for a fully reproducible release build.
  [switch]$Clean,

  # Skip `flutter build windows` and only re-stage an existing bundle.
  # Useful when iterating on packaging without paying for a rebuild.
  [switch]$SkipBuild
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Windows release build ($Channel)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

if (-not (Test-Path -LiteralPath $Ctx.EnvFile -PathType Leaf)) {
  Fail ("Environment file not found: $($Ctx.EnvFile). The .env files are " +
    'provided out-of-band (see docs/development.md); they are never committed.')
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
  Fail 'flutter not found on PATH. Install the Flutter SDK first.'
}

# --- Build -------------------------------------------------------------------
if ($SkipBuild) {
  Write-Skip 'Skipping flutter build windows (-SkipBuild); staging the existing bundle.'
} else {
  # flutter operates on the project in the CURRENT directory, so pin it to
  # the repo root (the macOS lane's build_archive.sh does the same cd) —
  # otherwise running from elsewhere cleans/builds whatever Flutter project
  # the caller happens to be in and then stages a stale Clingfy bundle.
  Push-Location $Ctx.RepoRoot
  try {
    if ($Clean) {
      Write-Step 'flutter clean'
      & $flutter.Source clean
      if ($LASTEXITCODE -ne 0) { Fail "flutter clean failed with exit code $LASTEXITCODE." }
    }

    Write-Step 'flutter pub get'
    & $flutter.Source pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get failed with exit code $LASTEXITCODE." }

    # Build-provenance dart-defines (mirrors the macOS build_archive.sh set):
    # without these BuildConfig falls back to unknown/local and the About
    # screen shows no real commit/branch/build. .env files can't carry them —
    # they are per-build. Branch resolves from the CI env FIRST because Azure
    # checks out a detached HEAD, where `git branch --show-current` is empty.
    $commitHash = (& git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitHash)) {
      $commitHash = 'unknown'
    }
    $commitHash = "$commitHash".Trim()

    $branchName = ''
    if ($env:BUILD_SOURCEBRANCH) {
      $branchName = $env:BUILD_SOURCEBRANCH -replace '^refs/heads/', ''
    }
    elseif ($env:BUILD_SOURCEBRANCHNAME) {
      $branchName = $env:BUILD_SOURCEBRANCHNAME
    }
    else {
      $gitBranch = (& git branch --show-current 2>$null)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitBranch)) {
        $branchName = "$gitBranch".Trim()
      }
    }
    if ([string]::IsNullOrWhiteSpace($branchName)) { $branchName = 'local' }

    $buildId = if ($env:BUILD_BUILDID) {
      $env:BUILD_BUILDID
    }
    else {
      [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    }
    $timestampUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    Write-Step "flutter build windows --release (+ build-provenance defines: $commitHash / $branchName)"
    & $flutter.Source build windows --release `
      "--dart-define-from-file=$($Ctx.EnvFile)" `
      "--dart-define=COMMIT_HASH=$commitHash" `
      "--dart-define=BUILD_BRANCH=$branchName" `
      "--dart-define=BUILD_ID=$buildId" `
      "--dart-define=BUILD_TIMESTAMP=$timestampUtc"
    if ($LASTEXITCODE -ne 0) { Fail "flutter build windows failed with exit code $LASTEXITCODE." }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath $Ctx.BundleDir -PathType Container)) {
  Fail ("Release bundle not found: $($Ctx.BundleDir). " +
    "Run without -SkipBuild, or run 'flutter build windows --release' first.")
}

# --- Stage ---------------------------------------------------------------------
Write-Step "Staging bundle -> $($Ctx.StagingDir)"

if (Test-Path -LiteralPath $Ctx.StagingDir) {
  Remove-Item -LiteralPath $Ctx.StagingDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Ctx.StagingDir | Out-Null

# Names excluded from the bundle root (case-insensitive). PDBs are excluded
# everywhere via extension.
$excludedNames = @('runner_bridge.lib', 'native_assets.json')

$staged = 0
$excluded = 0
foreach ($item in Get-ChildItem -LiteralPath $Ctx.BundleDir -Recurse -File) {
  $relative = [System.IO.Path]::GetRelativePath($Ctx.BundleDir, $item.FullName)
  if ($item.Extension -ieq '.pdb' -or ($excludedNames -icontains $item.Name)) {
    Write-Info "excluded: $relative"
    $excluded++
    continue
  }
  $destination = Join-Path $Ctx.StagingDir $relative
  $destinationDir = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $destinationDir)) {
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
  }
  Copy-Item -LiteralPath $item.FullName -Destination $destination
  $staged++
}
Write-Info "Staged $staged file(s), excluded $excluded."

# --- VC++ CRT (app-local) -------------------------------------------------------
# Preferred source is a Visual Studio redist directory (the supported way to
# app-local the CRT); System32 is a last resort that still beats shipping
# nothing, since a clean VM without the CRT fails before any telemetry runs.
$crtNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')

function Find-CrtSourceDir {
  if ($env:VCToolsRedistDir) {
    $candidate = Get-ChildItem -Path (Join-Path $env:VCToolsRedistDir 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
  }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio' 'Installer' 'vswhere.exe'
  if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest -property installationPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $vsRoot) {
      $redistRoot = Join-Path $vsRoot.Trim() 'VC' 'Redist' 'MSVC'
      $candidate = Get-ChildItem -Path $redistRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
      if ($candidate) { return $candidate.FullName }
    }
  }
  $system32 = Join-Path $env:SystemRoot 'System32'
  $missingCrtDlls = $crtNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $system32 $_) -PathType Leaf) }
  if (-not $missingCrtDlls) { return $system32 }
  return $null
}

Write-Step 'Bundling VC++ CRT app-locally'
$crtSource = Find-CrtSourceDir
if (-not $crtSource) {
  Write-Skip ('No VC++ CRT source found (no VS redist dir, no complete System32 set). ' +
    'The staged app may fail to launch on a clean machine without the VC++ runtime.')
} else {
  Write-Info "CRT source: $crtSource"
  foreach ($name in $crtNames) {
    $source = Join-Path $crtSource $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $Ctx.StagingDir $name)
      Write-Info "bundled:  $name"
    } else {
      Write-Skip "CRT DLL not found, skipping: $name"
    }
  }
}

# --- Verify ----------------------------------------------------------------------
Write-Step 'Verifying staged app'

# Everything the installed app needs at runtime, including the crash pipeline
# (sentry.dll + crashpad pair) — a beta build without crash reporting is blind.
$requiredFiles = @(
  'clingfy.exe',
  'flutter_windows.dll',
  'sentry.dll',
  'crashpad_handler.exe',
  'crashpad_wer.dll',
  (Join-Path 'data' 'app.so'),
  (Join-Path 'data' 'icudtl.dat'),
  (Join-Path 'data' 'flutter_assets' 'AssetManifest.bin')
)
$missing = $requiredFiles | Where-Object {
  -not (Test-Path -LiteralPath (Join-Path $Ctx.StagingDir $_) -PathType Leaf)
}
if ($missing) {
  Fail "Staged app is missing required file(s): $($missing -join ', ')"
}

$strayPdbs = @(Get-ChildItem -LiteralPath $Ctx.StagingDir -Recurse -Filter '*.pdb' -File)
if ($strayPdbs.Count -gt 0) {
  Fail "Staged app contains $($strayPdbs.Count) PDB file(s); symbols must never ship."
}

$exe = Get-Item -LiteralPath (Join-Path $Ctx.StagingDir 'clingfy.exe')
$fileVersion = $exe.VersionInfo.FileVersion
Write-Info "clingfy.exe file version: $fileVersion (pubspec: $($Ctx.AppVersionFull))"

# Channel marker (next to, not inside, the staged folder): 02_package_inno.ps1
# refuses to wrap a staging folder built for a different channel or version.
[ordered]@{
  channel     = $Ctx.Channel
  versionFull = $Ctx.AppVersionFull
} | ConvertTo-Json | Set-Content -LiteralPath $Ctx.StagingMarkerPath -Encoding utf8
Write-Info "channel marker: $($Ctx.StagingMarkerPath)"

Write-Host "Build + staging completed: $($Ctx.StagingDir)" -ForegroundColor Green
exit 0
