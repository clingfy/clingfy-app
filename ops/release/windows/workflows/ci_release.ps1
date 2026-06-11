#!/usr/bin/env pwsh
#Requires -Version 7
# ci_release.ps1
#
# Phase 10.5 (Windows installer + release pipeline): full CI release pipeline
# for Windows — the PowerShell counterpart of ops/release/workflows/ci_release.sh.
# Fixed sequence, no toggles:
#
#   version guard -> build+stage -> sign app -> package -> sign installer ->
#   publish Azure -> Sentry symbols (non-blocking) -> smoke test
#
# Differences from the macOS CI workflow, on purpose:
#   * no restore-history step — there is no Sparkle delta/feed history to
#     seed yet (the 10.6 updater slice owns the Windows feed lifecycle)
#   * no git tag — release tags (v<version>) stay owned by the macOS prod
#     release; a same-version Windows run must not race it
#
# Like the macOS lane, nothing in-repo invokes this: the release pipeline
# runs out-of-repo with credentials injected as secure variables (see
# ops/release/windows/README.md for the expected CI job shape). It works
# identically on a maintainer machine after `az login`.
#
# Signing follows decision D3: unsigned is allowed for the private beta, so
# the default only warns. Pass -RequireSignature once a certificate exists.

[CmdletBinding()]
param(
  # Release channel; CI releases default to prod (the dev/local channels are
  # for pipeline rehearsal).
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'prod',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile,

  # Fail (instead of warn) when no signing material is configured.
  [switch]$RequireSignature
)

. (Join-Path $PSScriptRoot '..' '_config.ps1')

$LaneRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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

$signArgs = @()
if ($RequireSignature) { $signArgs += '-RequireSignature' }

Invoke-Step '00_version_guard.ps1' $channelArgs
Invoke-Step '01_build.ps1' ($channelArgs + '-Clean')
Invoke-Step '03_sign.ps1' ($channelArgs + @('-Target', 'app') + $signArgs)
Invoke-Step '02_package_inno.ps1' $channelArgs
Invoke-Step '03_sign.ps1' ($channelArgs + @('-Target', 'installer') + $signArgs)
Invoke-Step '04_publish_azure.ps1' $channelArgs

# Sentry symbol upload is non-blocking, mirroring the macOS publish step.
$symbolsScript = Join-Path $LaneRoot 'upload_symbols.ps1'
Write-Host ''
Write-Host '========== upload_symbols.ps1 (non-blocking) ==========' -ForegroundColor Yellow
$envFileForSymbols = if ($EnvFile) { $EnvFile } else { ".env.$Channel" }
& pwsh -NoProfile -File $symbolsScript -EnvFile $envFileForSymbols
if ($LASTEXITCODE -ne 0) {
  Write-Skip 'Sentry symbol upload failed. Continuing release.'
}

Invoke-Step '05_smoke.ps1' $channelArgs

Write-Host ''
Write-Host 'CI Windows release workflow completed.' -ForegroundColor Green
exit 0
