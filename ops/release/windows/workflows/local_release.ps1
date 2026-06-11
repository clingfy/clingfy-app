#!/usr/bin/env pwsh
#Requires -Version 7
# local_release.ps1
#
# Phase 10.5 (Windows installer + release pipeline): maintainer-local release
# workflow — the PowerShell counterpart of ops/release/workflows/local_release.sh.
# Defaults mirror the macOS lane: build + package only; publishing is opt-in;
# never tags (git tags stay owned by the macOS prod release).
#
#   ./local_release.ps1                          # dev build -> dist/windows/installer
#   ./local_release.ps1 -Clean -RunTests         # full gate before packaging
#   ./local_release.ps1 -Channel prod -Publish   # publish to Azure + smoke test
#
# Steps: version guard -> [tests] -> build+stage -> sign app -> package ->
# sign installer -> [publish -> Sentry symbols (non-blocking) -> smoke].
#
# The optional test gate runs `flutter analyze lib` plus the native Windows
# GoogleTest suite (ctest). It deliberately does NOT run `flutter test`: the
# develop baseline carries a known-flaky set of FluentLocalizations widget-
# test failures, so a raw exit-code gate on it would block every release —
# compare the set of failing test names against the develop baseline instead.

[CmdletBinding()]
param(
  # Release channel: prod | dev | local.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile,

  # Run `flutter clean` before building.
  [switch]$Clean,

  # Run the test gate (flutter analyze lib + native ctest) before building.
  [switch]$RunTests,

  # Publish to Azure and smoke-test the published URLs.
  [switch]$Publish,

  # Fail (instead of warn) when no signing material is configured.
  [switch]$RequireSignature
)

. (Join-Path $PSScriptRoot '..' '_config.ps1')

$LaneRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Each step runs as a child pwsh process (like the macOS workflow execs its
# command scripts) so a step's `exit` can never tear down the workflow, and
# $LASTEXITCODE is unambiguous.
function Invoke-Step([string]$Script, [string[]]$StepArgs) {
  $path = Join-Path $LaneRoot $Script
  Write-Host ''
  Write-Host "========== $Script $($StepArgs -join ' ') ==========" -ForegroundColor Yellow
  & pwsh -NoProfile -File $path @StepArgs
  if ($LASTEXITCODE -ne 0) {
    Fail "Step failed: $Script (exit code $LASTEXITCODE)"
  }
}

$channelArgs = @('-Channel', $Channel)
if ($EnvFile) { $channelArgs += @('-EnvFile', $EnvFile) }

Invoke-Step '00_version_guard.ps1' $channelArgs

# --- Optional test gate ---------------------------------------------------------
if ($RunTests) {
  Write-Step 'Test gate: flutter analyze lib'
  & flutter analyze lib
  if ($LASTEXITCODE -ne 0) { Fail "flutter analyze lib failed (exit $LASTEXITCODE)." }

  $testsDir = Resolve-RepoPath (Join-Path 'build' 'windows-tests')
  if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
    Fail ("Native test build dir not found: $testsDir. One-time configure:`n" +
      '  cmake -S windows -B build/windows-tests -DBUILD_RUNNER_TESTS=ON ...' + "`n" +
      "  (see the Windows section of CLAUDE.md for the full command)")
  }
  # Build BEFORE ctest, and gate on the build result — ctest happily reruns a
  # stale binary and reports green if the rebuild silently failed.
  Write-Step 'Test gate: native runner_tests'
  & cmake --build $testsDir --config Debug --target runner_tests
  if ($LASTEXITCODE -ne 0) { Fail "runner_tests build failed (exit $LASTEXITCODE)." }
  & ctest --test-dir $testsDir --output-on-failure -C Debug
  if ($LASTEXITCODE -ne 0) { Fail "ctest failed (exit $LASTEXITCODE)." }
}

# --- Build -> sign -> package -> sign --------------------------------------------
$buildArgs = @() + $channelArgs
if ($Clean) { $buildArgs += '-Clean' }
Invoke-Step '01_build.ps1' $buildArgs

$signAppArgs = @() + $channelArgs + @('-Target', 'app')
if ($RequireSignature) { $signAppArgs += '-RequireSignature' }
Invoke-Step '03_sign.ps1' $signAppArgs

Invoke-Step '02_package_inno.ps1' $channelArgs

$signInstallerArgs = @() + $channelArgs + @('-Target', 'installer')
if ($RequireSignature) { $signInstallerArgs += '-RequireSignature' }
Invoke-Step '03_sign.ps1' $signInstallerArgs

# --- Optional publish + symbols + smoke -------------------------------------------
if ($Publish) {
  Invoke-Step '04_publish_azure.ps1' $channelArgs

  # Sentry symbol upload is non-blocking, like the macOS publish step: a
  # missing sentry-cli or missing SENTRY_* settings must not abort a release.
  $symbolsScript = Join-Path $LaneRoot 'upload_symbols.ps1'
  Write-Host ''
  Write-Host '========== upload_symbols.ps1 (non-blocking) ==========' -ForegroundColor Yellow
  $envFileForSymbols = if ($EnvFile) { $EnvFile } else { ".env.$Channel" }
  & pwsh -NoProfile -File $symbolsScript -EnvFile $envFileForSymbols
  if ($LASTEXITCODE -ne 0) {
    Write-Skip 'Sentry symbol upload failed. Continuing release.'
  }

  Invoke-Step '05_smoke.ps1' $channelArgs
} else {
  Write-Info 'Publish skipped (pass -Publish to upload to Azure).'
}

Write-Host ''
Write-Host 'Local Windows release workflow completed.' -ForegroundColor Green
exit 0
