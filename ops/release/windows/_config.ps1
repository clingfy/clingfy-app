#!/usr/bin/env pwsh
#Requires -Version 7
# _config.ps1
#
# Phase 10.5 (Windows installer + release pipeline): shared context for the
# Windows release lane. Every script in this directory dot-sources this file
# and then calls Initialize-WindowsReleaseContext to obtain one immutable
# context object holding the resolved channel, version, names, paths, and
# Azure settings.
#
# This is the PowerShell counterpart of the macOS lane's `ops/release/lib/`
# (env.sh + common.sh). It deliberately mirrors that lane's concepts —
# channel switch, pubspec version model, artifact naming, Azure defaults —
# without sharing any code with it: the bash `_config.sh` sources a fixed
# list of lib/*.sh files and never looks inside windows/, so nothing here
# can affect a macOS release.
#
# Channel model (mirrors configure_app_flavor / configure_paths in env.sh):
#   prod  -> "Clingfy"        Clingfy_Setup_<version>.exe            downloads/windows/
#   dev   -> "Clingfy Dev"    Clingfy_Dev_Setup_<version>+<build>.exe downloads/windows/
#   local -> "Clingfy Local"  Clingfy_Local_Setup_<ver>+<build>.exe  local/downloads/windows/
# Like macOS, dev and prod share the same blob layout; isolation comes from
# the storage account / Front Door endpoint differing per .env file.
#
# Credentials convention (same as upload_symbols.ps1): values are read from
# the process environment FIRST; the channel's .env file is a fallback for
# the Azure publishing settings only. Environment variables always win.
# Signing material (WIN_SIGN_*) is environment-only by design — per decision
# D3, signing keys never live in .env files or the repository.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Output helpers (match ops/release/windows/upload_symbols.ps1) -----------
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Skip([string]$Message) { Write-Warning $Message }
function Fail([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

# --- Platform guard -------------------------------------------------------------
# Structurally prevents any lane step from running on a macOS/Linux checkout:
# `flutter clean` is cross-platform and would happily delete build/macos/
# (including Runner.xcarchive mid-release) before `flutter build windows`
# ever got the chance to fail on the wrong host.
if (-not $IsWindows) {
  Fail 'The Windows release lane must run on Windows (use ops/release/*.sh for macOS).'
}

# --- Repo-root path resolution ------------------------------------------------
# This file lives at ops/release/windows, so the repo root is three levels up.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return Join-Path $script:RepoRoot $Path
}

# --- Dotenv fallback loader ----------------------------------------------------
# Loads only the named keys, and only when the corresponding environment
# variable is not already set. Environment variables win over the file.
function Import-DotenvFallback([string]$EnvFilePath, [string[]]$Keys) {
  if (-not (Test-Path -LiteralPath $EnvFilePath -PathType Leaf)) { return }
  $pattern = '^\s*(' + ($Keys -join '|') + ')\s*=\s*"?([^"]*)"?\s*$'
  foreach ($line in Get-Content -LiteralPath $EnvFilePath) {
    if ($line -match $pattern) {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      if (-not [Environment]::GetEnvironmentVariable($key) -and $value) {
        Set-Item -Path "env:$key" -Value $value
        Write-Info "Loaded $key from $(Split-Path -Leaf $EnvFilePath)"
      }
    }
  }
}

# --- Version model (mirrors read_pubspec_version_info in lib/env.sh) ----------
# Source of truth is the `version: X.Y.Z+N` line in pubspec.yaml. The same
# APP_VERSION_OVERRIDE / BUILD_NUMBER_OVERRIDE escape hatches apply.
function Get-PubspecVersion {
  $pubspec = Join-Path $script:RepoRoot 'pubspec.yaml'
  if (-not (Test-Path -LiteralPath $pubspec -PathType Leaf)) {
    Fail "pubspec.yaml not found at $pubspec"
  }
  $line = (Get-Content -LiteralPath $pubspec) -match '^version:' | Select-Object -First 1
  if (-not $line -or $line -notmatch '^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$') {
    Fail "Could not parse a 'version: X.Y.Z+N' line from pubspec.yaml"
  }
  $version = $Matches[1]
  $build = if ($Matches.Count -ge 3 -and $Matches[2]) { $Matches[2] } else { '1' }
  if ($env:APP_VERSION_OVERRIDE) { $version = $env:APP_VERSION_OVERRIDE }
  if ($env:BUILD_NUMBER_OVERRIDE) { $build = $env:BUILD_NUMBER_OVERRIDE }
  return [pscustomobject]@{
    AppVersion     = $version
    BuildNumber    = $build
    AppVersionFull = "$version+$build"
  }
}

function Get-CurrentBranchName {
  $branch = & git -C $script:RepoRoot branch --show-current 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $branch) { return 'local' }
  return $branch.Trim()
}

# --- Tool discovery -------------------------------------------------------------
# Inno Setup's command-line compiler. PATH first, then the default per-user
# and machine-wide install locations of Inno Setup 6.
function Find-Iscc {
  $cmd = Get-Command iscc -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs' 'Inno Setup 6' 'ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6' 'ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6' 'ISCC.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
  }
  return $null
}

# signtool.exe from the newest installed Windows 10/11 SDK (x64), PATH first.
function Find-SignTool {
  $cmd = Get-Command signtool -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits' '10' 'bin'
  if (-not (Test-Path -LiteralPath $kitsRoot -PathType Container)) { return $null }
  $versions = Get-ChildItem -LiteralPath $kitsRoot -Directory |
    Where-Object Name -match '^10\.' |
    Sort-Object Name -Descending
  foreach ($version in $versions) {
    $tool = Join-Path $version.FullName 'x64' 'signtool.exe'
    if (Test-Path -LiteralPath $tool -PathType Leaf) { return $tool }
  }
  return $null
}

# --- Context ----------------------------------------------------------------------
# The five Azure settings that exist in the real .env files. Container/folder
# names are defaults below (same values as lib/env.sh), not env-file keys.
$script:AzureEnvKeys = @(
  'AZ_STORAGE_ACCOUNT',
  'AZ_RESOURCE_GROUP',
  'AZ_CDN_PROFILE',
  'AZ_CDN_ENDPOINT',
  'AZ_FRONTDOOR_ENDPOINT_NAME'
)

function Initialize-WindowsReleaseContext {
  [CmdletBinding()]
  param(
    # Release channel: prod | dev | local. Selects display name, installer
    # identity (Inno AppId), artifact naming, and blob path layout.
    [ValidateSet('prod', 'dev', 'local')]
    [string]$Channel = 'dev',

    # Dotenv file for --dart-define-from-file and as the Azure-settings
    # fallback. Defaults to .env.<channel> in the repo root.
    [string]$EnvFile
  )

  if (-not $EnvFile) { $EnvFile = ".env.$Channel" }
  $envFilePath = Resolve-RepoPath $EnvFile

  $versionInfo = Get-PubspecVersion

  # The build number feeds two 16-bit consumers: Runner.rc silently truncates
  # it in FILEVERSION at build time, and ISCC hard-rejects VersionInfoVersion
  # components > 65535 at package time. The lane cannot produce a correct
  # artifact from such a build, so fail here — which also means the macOS
  # lane's CI-build-id/epoch bump strategy must never be ported to Windows.
  if ([long]$versionInfo.BuildNumber -gt 65535) {
    Fail ("Build number $($versionInfo.BuildNumber) exceeds 65535: Runner.rc would truncate " +
      'it in FILEVERSION and ISCC rejects it in VersionInfoVersion. Keep pubspec build ' +
      'numbers (and BUILD_NUMBER_OVERRIDE) within 16 bits.')
  }

  switch ($Channel) {
    'prod' {
      $displayName = 'Clingfy'
      # Stable per-channel installer identity: Inno uses AppId to recognize
      # an existing install and upgrade it in place. Never change these.
      $appId = '{BD658D62-9E6E-458E-A758-52595E839A97}'
      # Prod artifacts are semantic-version-only, like Clingfy_1.0.0.dmg.
      $installerBaseName = "Clingfy_Setup_$($versionInfo.AppVersion)"
      $binariesFolder = 'downloads'
    }
    'dev' {
      $displayName = 'Clingfy Dev'
      $appId = '{B6B2A6F2-42C3-4CB7-A01A-E3D904AE54AA}'
      # Dev artifacts carry the build number so every run is unique, like
      # Clingfy_Dev_1.0.0+1523.dmg.
      $installerBaseName = "Clingfy_Dev_Setup_$($versionInfo.AppVersionFull)"
      $binariesFolder = 'downloads'
    }
    'local' {
      $displayName = 'Clingfy Local'
      $appId = '{71F250C8-B918-482E-9086-93B1AF13BCCA}'
      $installerBaseName = "Clingfy_Local_Setup_$($versionInfo.AppVersionFull)"
      $binariesFolder = 'local/downloads'
    }
  }

  $installerName = "$installerBaseName.exe"
  $distDir = Join-Path $script:RepoRoot 'dist' 'windows'

  $context = [pscustomobject]@{
    Channel         = $Channel
    RepoRoot        = $script:RepoRoot
    EnvFile         = $envFilePath

    AppVersion      = $versionInfo.AppVersion
    BuildNumber     = $versionInfo.BuildNumber
    AppVersionFull  = $versionInfo.AppVersionFull

    AppDisplayName  = $displayName
    AppId           = $appId

    # Build output (flutter build windows) and staging/packaging locations.
    # Everything lands under the repo-root dist/ which .gitignore excludes.
    BundleDir       = Join-Path $script:RepoRoot 'build' 'windows' 'x64' 'runner' 'Release'
    DistDir         = $distDir
    StagingDir      = Join-Path $distDir 'app'
    # Channel/version marker written by 01_build next to (not inside) the
    # staged folder, so the installer's {#StagingDir}\* can never ship it;
    # 02_package refuses to wrap a staging folder built for another channel.
    StagingMarkerPath = Join-Path $distDir 'app.channel.json'
    InstallerOutDir = Join-Path $distDir 'installer'
    InstallerName   = $installerName
    InstallerPath   = Join-Path $distDir 'installer' $installerName
    Sha256Path      = Join-Path $distDir 'installer' "$installerName.sha256"
    LatestJsonPath  = Join-Path $distDir 'installer' 'latest-windows.json'

    # Azure blob layout. Windows artifacts live under a windows/ prefix so
    # they can never collide with the macOS DMGs and deltas in downloads/.
    AzContainer     = 'updates'
    WindowsBlobPrefix = "$binariesFolder/windows"

    # Filled by Import-AzurePublishSettings when a publish step runs.
    AzStorageAccount = $null
    AzResourceGroup  = $null
    AzCdnProfile     = $null
    AzCdnEndpoint    = $null
    AzFrontDoorEndpointName = $null
  }

  Write-Info "Channel:   $($context.Channel) ($($context.AppDisplayName))"
  Write-Info "Version:   $($context.AppVersionFull)"
  Write-Info "Installer: $($context.InstallerName)"
  return $context
}

# Resolves the Azure publish settings (environment first, .env fallback) and
# fails with the full list of missing keys. Only publish/smoke steps call
# this, so build/package work offline without any Azure configuration.
function Import-AzurePublishSettings([pscustomobject]$Context) {
  Import-DotenvFallback $Context.EnvFile $script:AzureEnvKeys
  $missing = $script:AzureEnvKeys | Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
  if ($missing) {
    Fail ("Missing Azure publish settings: $($missing -join ', '). " +
      "Set them in the environment or provide them in $($Context.EnvFile).")
  }
  $Context.AzStorageAccount = $env:AZ_STORAGE_ACCOUNT
  $Context.AzResourceGroup = $env:AZ_RESOURCE_GROUP
  $Context.AzCdnProfile = $env:AZ_CDN_PROFILE
  $Context.AzCdnEndpoint = $env:AZ_CDN_ENDPOINT
  $Context.AzFrontDoorEndpointName = $env:AZ_FRONTDOOR_ENDPOINT_NAME
  Write-Info "Storage account: $($Context.AzStorageAccount)"
  Write-Info "Blob path:       $($Context.AzContainer)/$($Context.WindowsBlobPrefix)/"
}

# Public download base for published Windows artifacts, e.g.
# https://<front-door-host>/downloads/windows/
function Get-WindowsDownloadBaseUrl([pscustomobject]$Context) {
  if (-not $Context.AzCdnEndpoint) {
    Fail 'Get-WindowsDownloadBaseUrl requires Import-AzurePublishSettings first.'
  }
  return "https://$($Context.AzCdnEndpoint)/$($Context.WindowsBlobPrefix)/"
}
