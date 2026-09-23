#!/usr/bin/env pwsh
#Requires -Version 7
# 04_publish.ps1
#
# Phase 10.5 (Windows installer + release pipeline): publishes the Windows
# installer to the same release storage the macOS lane uses, under a
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
# Mechanics mirror commands/publish_release.sh: one cloud CLI, federated identity
# (GitHub OIDC in CI, `aws sso login` locally; no stored keys), object overwrite,
# then a CloudFront invalidation of exactly the touched paths. The settings come from
# the environment first with the channel's .env file as fallback (environment
# variables always win); on the aws provider AWS_RELEASES_BUCKET,
# AWS_CLOUDFRONT_DISTRIBUTION_ID and the public endpoint (AWS_PUBLIC_ENDPOINT, or
# RELEASE_PUBLIC_ENDPOINT to override it) are ALL required and validated before any
# bytes move. Nothing here is optional any more: the old Front Door purge settings
# went with the azure arm, and the invalidation is required rather than
# nice-to-have because latest-windows.json is republished on every run, so without
# it the edge keeps serving the previous release while S3 already holds the new
# bytes.

[CmdletBinding()]
param(
  # Release channel: selects the artifact identity and blob path layout
  # (prod/dev publish to downloads/windows/, local to local/downloads/windows/).
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel> in the repo root).
  [string]$EnvFile,

  # Allow replacing an ALREADY-PUBLISHED versioned artifact.
  #
  # Off by default because the blob is the release: overwriting it changes what
  # a URL means after people may already have downloaded it, and the .sha256
  # published beside it silently starts describing different bytes. Re-running
  # a release for a version that shipped is almost always a mistake -- the
  # intended fix is a new build number.
  #
  # `latest-windows.json` is exempt: it is a POINTER, not a release, and every
  # publish is meant to replace it.
  [switch]$AllowOverwrite
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Publishing ($Channel)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

if (-not (Test-Path -LiteralPath $Ctx.InstallerPath -PathType Leaf)) {
  Fail ("Installer not found: $($Ctx.InstallerPath). " +
    "Run 01_build.ps1 + 02_package_inno.ps1 -Channel $Channel first.")
}

Import-AzurePublishSettings $Ctx
$downloadBaseUrl = Get-WindowsDownloadBaseUrl $Ctx

# Require the CLI this PROVIDER needs, not the one the filename suggests.
#
# This check used to sit above Import-AzurePublishSettings and demand `az`
# unconditionally, so a publish to AWS failed with "Azure CLI (az) not found on
# PATH" while never checking for `aws` at all -- the wrong tool required, the right
# one unverified. It only stayed dormant because windows-latest ships az.
#
# It has to run HERE rather than earlier: Initialize-WindowsReleaseContext leaves
# StorageProvider as $null and Import-AzurePublishSettings is what sets it, so
# dispatching any earlier reads $null and always takes the fallback arm.
# Mirrors require_release_storage_cli() in ops/release/lib/env.sh.
switch ($Ctx.StorageProvider) {
  'aws' {
    $cli = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $cli) {
      Fail ("AWS CLI (aws) not found on PATH, and this channel publishes to S3. Install it first:`n" +
        "  winget install Amazon.AWSCLI`n" +
        "  # CI authenticates with OIDC; locally: aws sso login --profile clingfy-dev")
    }
    Write-Info "aws: $($cli.Source)"
  }
  'none' {
    # No storage target, so no CLI to require. The publish steps below refuse
    # before they move anything.
    Write-Info "provider none: this channel does not publish"
  }
  default {
    Fail "RELEASE_STORAGE_PROVIDER must be 'aws' or 'none', got '$($Ctx.StorageProvider)'."
  }
}

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
  # '+' is percent-encoded for the same reason the macOS appcast does it (see
  # ops/release/commands/publish_release.sh): CloudFront mangles a literal '+' in the path on the
  # way to the S3 origin, so .../Clingfy_Dev_Setup_1.0.7+127.exe 404s while the %2B form returns
  # 206 for the very same object. Every DEV installer is named <version>+<build>. `fileName` above
  # stays unencoded — it is the on-disk name, not a URL.
  url              = "$downloadBaseUrl$($Ctx.InstallerUrlName)"
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
# True when the blob already exists in the container.
function Test-BlobExists([string]$BlobName) {
  if ($Ctx.StorageProvider -eq 'aws') {
    # head-object, not `s3 ls`: ls matches a PREFIX, and this bucket really does hold
    # latest-windows.json.azure-bak-20260817-174816 next to latest-windows.json.
    & aws s3api head-object `
      --bucket $Ctx.AwsReleasesBucket `
      --key "$($Ctx.AzContainer)/$BlobName" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      # Missing OR unreadable. Same posture as the Azure branch: treat as absent and let the
      # upload surface the real auth/network error rather than blocking a release on a probe.
      return $false
    }
    return $true
  }

  Fail ("Test-BlobExists: StorageProvider '$($Ctx.StorageProvider)' has no storage to " +
    "probe. Only 'aws' publishes; the '$($Ctx.Channel)' channel does not.")
}

# Content-Type must be explicit on S3: `aws s3 cp` guesses from the extension and would upload the
# installer as binary/octet-stream where the objects already in the bucket are
# application/x-msdownload. Matches lib/aws.sh on the macOS side.
function Get-ContentTypeFor([string]$BlobName) {
  switch -Wildcard ($BlobName) {
    '*.exe'    { return 'application/x-msdownload' }
    '*.sha256' { return 'text/plain' }
    '*.json'   { return 'application/json' }
    default    { return 'application/octet-stream' }
  }
}

function Publish-Blob([string]$File, [string]$BlobName, [switch]$IsPointer) {
  # The overwrite guard. A versioned artifact that already exists means this
  # version was published before; replacing it rewrites history for anyone
  # holding the URL, and re-points the published .sha256 at different bytes.
  if (-not $IsPointer -and -not $AllowOverwrite) {
    if (Test-BlobExists $BlobName) {
      Fail (
        "$BlobName is ALREADY PUBLISHED. Refusing to overwrite a released " +
        "artifact.`n" +
        "  If this is a mistake, cut a new build number and publish that.`n" +
        "  If you genuinely mean to replace the published bytes, re-run with " +
        "-AllowOverwrite.")
    }
  }
  Write-Info "uploading $BlobName"
  if ($Ctx.StorageProvider -eq 'aws') {
    & aws s3 cp $File "s3://$($Ctx.AwsReleasesBucket)/$($Ctx.AzContainer)/$BlobName" `
      --content-type (Get-ContentTypeFor $BlobName) `
      --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Fail "aws s3 cp failed for $BlobName with exit code $LASTEXITCODE."
    }
    return
  }

  # No silent alternate path. Falling through here used to upload to Azure blob storage;
  # both release accounts were deleted 2026-09-15, so it was an upload into nothing.
  Fail ("Cannot upload ${BlobName}: StorageProvider '$($Ctx.StorageProvider)' has no " +
    "storage target. Only 'aws' publishes; the '$($Ctx.Channel)' channel does not.")
}

$uploadTarget = if ($Ctx.StorageProvider -eq 'aws') {
  "s3://$($Ctx.AwsReleasesBucket)/$($Ctx.AzContainer)"
} else {
  "$($Ctx.AzStorageAccount)/$($Ctx.AzContainer)"
}
Write-Step "Uploading to $uploadTarget"
$prefix = $Ctx.WindowsBlobPrefix
Publish-Blob $Ctx.InstallerPath "$prefix/$($Ctx.InstallerName)"
Publish-Blob $Ctx.Sha256Path "$prefix/$($Ctx.InstallerName).sha256"
# The feed is a pointer and is REPLACED on every publish by design.
Publish-Blob $Ctx.LatestJsonPath "$prefix/latest-windows.json" -IsPointer

# --- Front Door purge ------------------------------------------------------------------
# Purge exactly the touched paths, like purge_frontdoor_paths on macOS. The
# macOS feed (appcast.xml) is deliberately NOT purged from here — this lane
# never writes outside its windows/ prefix.
#
# Guarded on the endpoint name: dev and prod are blob-direct (no Front Door) as
# of 2026-07, so there is no cache to purge. Mirrors the macOS lane's
# publish_release.sh guard.
if ($Ctx.StorageProvider -eq 'aws') {
  # CloudFront serves /updates/* with the managed CachingOptimized policy, so latest-windows.json —
  # replaced on EVERY publish by design — would otherwise stay stale at the edge for its full TTL.
  # The installer and .sha256 are new paths each release and need no invalidation, but they are
  # included so a re-published build behaves the same as a first publish.
  #
  # No "unset" branch: Import-AzurePublishSettings now REQUIRES AwsCloudFrontDistributionId on the
  # aws provider, so reaching here without one is impossible. It used to Write-Info and carry on,
  # which shipped a release nobody could receive while printing success.
  Write-Step 'Invalidating CloudFront paths'
  $invalidatePaths = @(
    "/$($Ctx.AzContainer)/$prefix/$($Ctx.InstallerUrlName)",
    "/$($Ctx.AzContainer)/$prefix/$($Ctx.InstallerUrlName).sha256",
    "/$($Ctx.AzContainer)/$prefix/latest-windows.json"
  )
  & aws cloudfront create-invalidation `
    --distribution-id $Ctx.AwsCloudFrontDistributionId `
    --paths @($invalidatePaths) `
    --query 'Invalidation.Id' --output text | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail ("aws cloudfront create-invalidation failed with exit code $LASTEXITCODE. " +
      "latest-windows.json is republished on every publish, so without the invalidation the " +
      "edge keeps serving the previous release and no installed app sees this one. " +
      "The bytes are already in S3 - re-run the invalidation, then re-verify the feed.")
  }
} else {
  Write-Step "No CDN invalidation for provider '$($Ctx.StorageProvider)'"
}

# --- Smoke test --------------------------------------------------------------------
#
# Read the feed back through the PUBLIC endpoint, which is what the updater actually reads.
# This lane had no verification at all: it uploaded, optionally invalidated, and printed
# "Publish completed successfully" without ever checking that a client could see the release.
# The macOS lane has always done this (publish_release.sh fetches FEED_URL and greps for the new
# DMG), and it is the reason a bad publish there fails loudly.
#
# It must go through the CDN, not the bucket. Reading S3 directly would verify the bytes we just
# wrote and pass green while the edge still served the previous release — the same shape as the
# Azure-era smoke test that fetched the copy it had just uploaded.
#
# Retries because a CloudFront invalidation is not instant; the macOS lane uses the same 9 x 5s.
$feedUrl = "${downloadBaseUrl}latest-windows.json"
Write-Step 'Smoke testing published feed'

$feedOk = $false
$lastSeen = '<no response>'
foreach ($attempt in 1..9) {
  try {
    # -UseBasicParsing for Windows PowerShell 5.1 compatibility; no-cache headers so a local
    # proxy cannot answer on CloudFront's behalf and hide exactly the staleness being tested.
    $resp = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 20 `
      -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
    $feed = $resp.Content | ConvertFrom-Json
    $lastSeen = "fileName=$($feed.fileName) versionFull=$($feed.versionFull)"
    if ($feed.fileName -eq $Ctx.InstallerName -and $feed.sha256 -eq $hash) {
      $feedOk = $true
      break
    }
  } catch {
    $lastSeen = $_.Exception.Message
  }
  Start-Sleep -Seconds 5
}

if (-not $feedOk) {
  Fail ("Smoke test failed: $feedUrl does not yet describe this release. " +
    "Expected fileName=$($Ctx.InstallerName) sha256=$hash, last saw: $lastSeen. " +
    "The installer is in the bucket, so this is a serving problem, not a build one - " +
    "check the CloudFront invalidation and the /updates/* behaviour before announcing.")
}
Write-Info "feed verified through $($Ctx.PublicEndpoint): $($Ctx.InstallerName)"

# The installer itself must be reachable at the URL the feed advertises. The feed can be correct
# while the binary 404s if the key prefix and the CDN path behaviour ever disagree.
# The URL spelling: a literal '+' here 404s at CloudFront even though the object exists.
$installerUrl = "$downloadBaseUrl$($Ctx.InstallerUrlName)"
try {
  $head = Invoke-WebRequest -Uri $installerUrl -Method Head -UseBasicParsing -TimeoutSec 30
  $installerStatus = [int]$head.StatusCode
} catch {
  $installerStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
}
if ($installerStatus -ne 200) {
  Fail ("Smoke test failed: installer returned HTTP $installerStatus at $installerUrl. " +
    "The feed points every updater at this URL, so a non-200 here is a release nobody can install.")
}
Write-Info "installer reachable: HTTP 200"

Write-Step 'Publish summary'
Write-Info "Download URL: $downloadBaseUrl$($Ctx.InstallerUrlName)"
Write-Info "Feed URL:     $feedUrl"
Write-Host 'Publish completed successfully.' -ForegroundColor Green
exit 0
