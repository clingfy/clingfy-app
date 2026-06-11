#!/usr/bin/env pwsh
#Requires -Version 7
# 04_publish_azure.ps1
#
# Phase 10.5 (Windows installer + release pipeline): publishes the Windows
# installer to the same Azure release storage the macOS lane uses, under a
# windows/ prefix so the artifacts can never collide with the DMGs and
# Sparkle deltas:
#
#   updates/downloads/windows/<installer>.exe
#   updates/downloads/windows/<installer>.exe.sha256
#   updates/downloads/windows/latest-windows.json
#
# latest-windows.json is a static feed stub for the private beta: slice 10.6
# wires the in-app update check against it. Publishing it now means 10.6 is
# a client-only change.
#
# Mechanics mirror commands/publish_release.sh: Azure CLI only, AAD identity
# (`--auth-mode login` — run `az login` first; no account keys or SAS), blob
# overwrite, then an Azure Front Door purge of exactly the touched paths.
# The five AZ_* settings come from the environment first with the channel's
# .env file as fallback (environment variables always win).

[CmdletBinding()]
param(
  # Release channel: selects the artifact identity and blob path layout
  # (prod/dev publish to downloads/windows/, local to local/downloads/windows/).
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Publishing to Azure ($Channel)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

if (-not (Test-Path -LiteralPath $Ctx.InstallerPath -PathType Leaf)) {
  Fail ("Installer not found: $($Ctx.InstallerPath). " +
    "Run 01_build.ps1 + 02_package_inno.ps1 -Channel $Channel first.")
}

$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
  Fail ("Azure CLI (az) not found on PATH. Install it first:`n" +
    "  winget install Microsoft.AzureCLI`n" +
    "  # then: az login")
}
Write-Info "az: $($az.Source)"

Import-AzurePublishSettings $Ctx
$downloadBaseUrl = Get-WindowsDownloadBaseUrl $Ctx

# --- Generate checksum + latest-windows.json --------------------------------------
Write-Step 'Generating checksum and feed metadata'

$installer = Get-Item -LiteralPath $Ctx.InstallerPath
$hash = (Get-FileHash -LiteralPath $Ctx.InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
# Same "<hash>  <filename>" layout `sha256sum -c` accepts.
"$hash  $($Ctx.InstallerName)" | Set-Content -LiteralPath $Ctx.Sha256Path -Encoding ascii -NoNewline
Write-Info "sha256: $hash"

$latest = [ordered]@{
  version          = $Ctx.AppVersion
  build            = [long]$Ctx.BuildNumber
  versionFull      = $Ctx.AppVersionFull
  channel          = $Ctx.Channel
  platform         = 'windows-x64'
  fileName         = $Ctx.InstallerName
  url              = "$downloadBaseUrl$($Ctx.InstallerName)"
  sha256           = $hash
  sizeBytes        = $installer.Length
  minimumOsVersion = '10.0.18362'
  # Invariant culture is load-bearing: an unquoted ':' is the culture's
  # time-separator placeholder (fi-FI emits '.'), and non-Gregorian default
  # calendars (ar-SA) rewrite the whole date — the 10.6 updater parses this
  # field as ISO 8601.
  publishedAt      = [DateTime]::UtcNow.ToString(
    "yyyy-MM-dd'T'HH':'mm':'ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}
$latest | ConvertTo-Json | Set-Content -LiteralPath $Ctx.LatestJsonPath -Encoding utf8
Write-Info "feed:   $($Ctx.LatestJsonPath)"

# --- Upload -------------------------------------------------------------------------
function Publish-Blob([string]$File, [string]$BlobName) {
  Write-Info "uploading $BlobName"
  & az storage blob upload `
    --account-name $Ctx.AzStorageAccount `
    --container-name $Ctx.AzContainer `
    --file $File `
    --name $BlobName `
    --auth-mode login `
    --overwrite `
    --only-show-errors | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail "az storage blob upload failed for $BlobName with exit code $LASTEXITCODE."
  }
}

Write-Step "Uploading to $($Ctx.AzStorageAccount)/$($Ctx.AzContainer)"
$prefix = $Ctx.WindowsBlobPrefix
Publish-Blob $Ctx.InstallerPath "$prefix/$($Ctx.InstallerName)"
Publish-Blob $Ctx.Sha256Path "$prefix/$($Ctx.InstallerName).sha256"
Publish-Blob $Ctx.LatestJsonPath "$prefix/latest-windows.json"

# --- Front Door purge ------------------------------------------------------------------
# Purge exactly the touched paths, like purge_frontdoor_paths on macOS. The
# macOS feed (appcast.xml) is deliberately NOT purged from here — this lane
# never writes outside its windows/ prefix.
Write-Step 'Purging Azure Front Door cache'
$purgePaths = @(
  "/$prefix/$($Ctx.InstallerName)",
  "/$prefix/$($Ctx.InstallerName).sha256",
  "/$prefix/latest-windows.json"
)
& az afd endpoint purge `
  --resource-group $Ctx.AzResourceGroup `
  --profile-name $Ctx.AzCdnProfile `
  --endpoint-name $Ctx.AzFrontDoorEndpointName `
  --domains $Ctx.AzCdnEndpoint `
  --content-paths @($purgePaths) `
  --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  Fail "az afd endpoint purge failed with exit code $LASTEXITCODE."
}
Write-Info "purged: $($purgePaths -join ', ')"

Write-Step 'Publish summary'
Write-Info "Download URL: $downloadBaseUrl$($Ctx.InstallerName)"
Write-Info "Feed URL:     ${downloadBaseUrl}latest-windows.json"
Write-Host 'Publish completed successfully.' -ForegroundColor Green
exit 0
