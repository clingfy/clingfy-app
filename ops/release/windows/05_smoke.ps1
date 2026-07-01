#!/usr/bin/env pwsh
#Requires -Version 7
# 05_smoke.ps1
#
# Phase 10.5 (Windows installer + release pipeline): post-publish smoke test.
# Verifies, through the public download endpoint (AZ_CDN_ENDPOINT — a Front
# Door host when configured, or the blob endpoint directly; the same path
# testers download through):
#
#   1. latest-windows.json is reachable, parses, and advertises this
#      version + installer (retried, like the macOS appcast smoke — a CDN
#      purge, when there is one, takes a moment to propagate)
#   2. the installer URL answers HTTP 200
#   3. the downloaded installer's SHA-256 matches the published .sha256
#      (skippable with -SkipDownload on slow links)
#
# The hash check goes one step beyond the macOS smoke (which relies on
# Sparkle's ed25519 signature for integrity) because the Windows feed has no
# signature yet — the checksum is the only end-to-end integrity proof until
# the 10.6 updater lands.

[CmdletBinding()]
param(
  # Release channel: must match what 04_publish_azure.ps1 published.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile,

  # Skip the full installer download + hash comparison (URL checks only).
  [switch]$SkipDownload
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Post-publish smoke test ($Channel)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

Import-AzurePublishSettings $Ctx
$downloadBaseUrl = Get-WindowsDownloadBaseUrl $Ctx
$installerUrl = "$downloadBaseUrl$($Ctx.InstallerName)"
$feedUrl = "${downloadBaseUrl}latest-windows.json"

# --- 1. Feed advertises this release (retried, mirrors the appcast smoke) ----
Write-Step "Checking feed: $feedUrl"
$maxAttempts = 9
$feed = $null
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  try {
    $response = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 30
    $candidate = $response.Content | ConvertFrom-Json
    if ($candidate.fileName -eq $Ctx.InstallerName) {
      $feed = $candidate
      break
    }
    Write-Info ("attempt {0}/{1}: feed still advertises {2}" -f $attempt, $maxAttempts, $candidate.fileName)
  } catch {
    Write-Info ("attempt {0}/{1}: {2}" -f $attempt, $maxAttempts, $_.Exception.Message)
  }
  if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 5 }
}
if (-not $feed) {
  Fail "Smoke test failed: latest-windows.json does not advertise $($Ctx.InstallerName)."
}
if ($feed.version -ne $Ctx.AppVersion) {
  Fail "Smoke test failed: feed version $($feed.version) != pubspec $($Ctx.AppVersion)."
}
Write-Info "feed OK: $($feed.fileName) v$($feed.versionFull)"

# --- 2. Installer URL answers 200 -----------------------------------------------
Write-Step "Checking installer URL: $installerUrl"
try {
  $head = Invoke-WebRequest -Uri $installerUrl -Method Head -UseBasicParsing -TimeoutSec 60
} catch {
  Fail "Smoke test failed: installer URL error: $($_.Exception.Message)"
}
if ($head.StatusCode -ne 200) {
  Fail "Smoke test failed: installer returned HTTP $($head.StatusCode)."
}
Write-Info "installer URL OK (HTTP 200)"

# --- 3. Downloaded bytes match the published checksum -----------------------------
if ($SkipDownload) {
  Write-Skip 'Skipping download + hash verification (-SkipDownload).'
} else {
  Write-Step 'Downloading installer for hash verification'
  $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "clingfy_smoke_$($Ctx.InstallerName)"
  try {
    Invoke-WebRequest -Uri $installerUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 600
    $downloadedHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadedHash -ne $feed.sha256) {
      Fail ("Smoke test failed: downloaded hash $downloadedHash != published " +
        "sha256 $($feed.sha256).")
    }
    Write-Info "hash OK: $downloadedHash"
  } finally {
    if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
  }
}

Write-Host 'Smoke test passed.' -ForegroundColor Green
exit 0
