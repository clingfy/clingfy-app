#!/usr/bin/env pwsh
#Requires -Version 7
# 02_package_inno.ps1
#
# Phase 10.5 (Windows installer + release pipeline): compiles the Inno Setup
# installer from the staged app folder:
#
#   dist/windows/app  --(installer/Clingfy.iss)-->  dist/windows/installer/<name>.exe
#
# All channel identity (AppId GUID, display name, ProgId, artifact name) is
# passed to ISCC as preprocessor defines, so Clingfy.iss stays a single
# channel-agnostic source. Requires Inno Setup 6.3+ (x64compatible
# architecture directives).
#
# Run after 01_build.ps1. If the app binaries should be Authenticode-signed,
# run 03_sign.ps1 -Target app BEFORE this script — the installer embeds the
# staged files as-is — and 03_sign.ps1 -Target installer after it.

[CmdletBinding()]
param(
  # Release channel: must match the channel the staging folder was built for.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # Override the dotenv file (defaults to .env.<channel>; only used for
  # context resolution here, not read by ISCC).
  [string]$EnvFile
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Packaging installer ($Channel)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

if (-not (Test-Path -LiteralPath (Join-Path $Ctx.StagingDir 'clingfy.exe') -PathType Leaf)) {
  Fail ("Staged app not found at $($Ctx.StagingDir). Run 01_build.ps1 -Channel $Channel first.")
}

# The staging folder carries no identity of its own — refuse to wrap a build
# staged for a different channel (a prod-AppId installer around dev-dart-define
# binaries would upgrade real prod installs in place) or a stale version.
if (-not (Test-Path -LiteralPath $Ctx.StagingMarkerPath -PathType Leaf)) {
  Fail ("Staging marker not found: $($Ctx.StagingMarkerPath). " +
    "Re-run 01_build.ps1 -Channel $Channel (pre-marker staging folders cannot be trusted).")
}
$marker = Get-Content -LiteralPath $Ctx.StagingMarkerPath -Raw | ConvertFrom-Json
if ($marker.channel -ne $Ctx.Channel -or $marker.versionFull -ne $Ctx.AppVersionFull) {
  Fail ("Staged app was built for channel '$($marker.channel)' v$($marker.versionFull), " +
    "but packaging was requested for '$($Ctx.Channel)' v$($Ctx.AppVersionFull). " +
    "Re-run 01_build.ps1 -Channel $($Ctx.Channel) first.")
}

$iscc = Find-Iscc
if (-not $iscc) {
  Fail ("Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6.3+ first:`n" +
    "  winget install JRSoftware.InnoSetup`n" +
    "  # or: https://jrsoftware.org/isdl.php")
}
Write-Info "ISCC: $iscc"

# ProgId is per-channel so a dev install never silently rebinds the prod
# file association (last-writer still wins on the extension itself; see the
# D9 note in Clingfy.iss).
$progId = switch ($Channel) {
  'prod' { 'Clingfy.Project' }
  'dev' { 'ClingfyDev.Project' }
  'local' { 'ClingfyLocal.Project' }
}

New-Item -ItemType Directory -Force -Path $Ctx.InstallerOutDir | Out-Null

$issPath = Join-Path $PSScriptRoot 'installer' 'Clingfy.iss'
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($Ctx.InstallerName)

Write-Step "ISCC $($Ctx.InstallerName)"
& $iscc `
  "/DMyAppId=$($Ctx.AppId)" `
  "/DMyAppName=$($Ctx.AppDisplayName)" `
  "/DMyAppVersion=$($Ctx.AppVersion)" `
  "/DMyBuildNumber=$($Ctx.BuildNumber)" `
  "/DMyAppVersionFull=$($Ctx.AppVersionFull)" `
  "/DMyProgId=$progId" `
  "/DStagingDir=$($Ctx.StagingDir)" `
  "/DMyOutputBaseFilename=$baseName" `
  "/O$($Ctx.InstallerOutDir)" `
  $issPath
if ($LASTEXITCODE -ne 0) {
  Fail "ISCC failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $Ctx.InstallerPath -PathType Leaf)) {
  Fail "ISCC reported success but the installer is missing: $($Ctx.InstallerPath)"
}

$installer = Get-Item -LiteralPath $Ctx.InstallerPath
Write-Info ("Installer: {0} ({1:N1} MB)" -f $installer.FullName, ($installer.Length / 1MB))
Write-Host 'Packaging completed successfully.' -ForegroundColor Green
exit 0
