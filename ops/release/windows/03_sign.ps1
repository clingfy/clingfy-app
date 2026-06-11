#!/usr/bin/env pwsh
#Requires -Version 7
# 03_sign.ps1
#
# Phase 10.5 (Windows installer + release pipeline): Authenticode-signs the
# Windows release artifacts with signtool, then verifies the signatures.
#
# Two targets, because signing must straddle packaging:
#   -Target app        signs the staged binaries (clingfy.exe,
#                      crashpad_handler.exe) BEFORE 02_package_inno.ps1
#                      embeds them in the installer
#   -Target installer  signs dist/windows/installer/<name>.exe AFTER packaging
#
# Signing material (per decision D3) is provided out-of-band and read from
# the process environment ONLY — never from .env files, never from the repo:
#   WIN_SIGN_CERT_PFX        path to a PFX code-signing certificate, plus
#   WIN_SIGN_CERT_PASSWORD   its password
#     — or —
#   WIN_SIGN_CERT_THUMBPRINT SHA-1 thumbprint of a cert in the user's store
#   WIN_SIGN_TIMESTAMP_URL   RFC 3161 timestamp server
#                            (default http://timestamp.digicert.com)
#
# When no signing material is configured the script SKIPS with a loud
# warning and exits 0: decision D3 explicitly allows the private beta to
# ship unsigned (with SmartScreen instructions in the tester guide). Pass
# -RequireSignature to turn the skip into a failure once a certificate
# exists — CI should do so for prod releases. Half-configured material
# (one of the PFX pair set, the other missing) is always a hard failure,
# never a skip — that shape means a secret failed to inject.
#
# CAVEAT: the PFX path hands the password to signtool as a process argument
# (`/p`), which is visible to same-user process listing and persisted by
# command-line auditing (Event 4688) / EDR telemetry. On shared machines or
# audited CI agents, prefer importing the PFX once into the user store
# (Import-PfxCertificate -CertStoreLocation Cert:\CurrentUser\My) and
# signing via WIN_SIGN_CERT_THUMBPRINT — no secret crosses a command line.

[CmdletBinding()]
param(
  # Release channel: resolves which staged/packaged artifacts to sign.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev',

  # What to sign: the staged app binaries (before packaging) or the
  # compiled installer (after packaging).
  [Parameter(Mandatory)]
  [ValidateSet('app', 'installer')]
  [string]$Target,

  # Fail instead of skipping when no signing material is configured.
  [switch]$RequireSignature,

  # Override the dotenv file (context resolution only; signing material is
  # never read from .env files).
  [string]$EnvFile
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step "Code signing ($Channel, target: $Target)"
$initArgs = @{ Channel = $Channel }
if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
$Ctx = Initialize-WindowsReleaseContext @initArgs

# --- Resolve the files to sign -------------------------------------------------
$filesToSign = [System.Collections.Generic.List[string]]::new()
if ($Target -eq 'app') {
  # Only first-party executables: the Flutter engine, plugin DLLs, and CRT
  # are third-party binaries we must not re-sign.
  foreach ($name in @('clingfy.exe', 'crashpad_handler.exe')) {
    $path = Join-Path $Ctx.StagingDir $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $filesToSign.Add($path)
    } else {
      Write-Skip "Not staged, skipping: $name"
    }
  }
  if ($filesToSign.Count -eq 0) {
    Fail "Nothing to sign under $($Ctx.StagingDir). Run 01_build.ps1 -Channel $Channel first."
  }
} else {
  if (-not (Test-Path -LiteralPath $Ctx.InstallerPath -PathType Leaf)) {
    Fail ("Installer not found: $($Ctx.InstallerPath). " +
      "Run 02_package_inno.ps1 -Channel $Channel first.")
  }
  $filesToSign.Add($Ctx.InstallerPath)
}

# --- Signing material (environment only, per D3) --------------------------------
$pfxPath = $env:WIN_SIGN_CERT_PFX
$pfxPassword = $env:WIN_SIGN_CERT_PASSWORD
$thumbprint = $env:WIN_SIGN_CERT_THUMBPRINT
$timestampUrl = if ($env:WIN_SIGN_TIMESTAMP_URL) { $env:WIN_SIGN_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' }

# Half-configured PFX material is a hard failure even in soft-skip mode: an
# operator who set one half believes signing is ON, and the likeliest cause
# (CI secret failed to inject, typo'd variable name) must not silently ship
# an unsigned build behind a "no material configured" message.
if (-not $thumbprint -and ([bool]$pfxPath -ne [bool]$pfxPassword)) {
  $missingHalf = if ($pfxPath) { 'WIN_SIGN_CERT_PASSWORD' } else { 'WIN_SIGN_CERT_PFX' }
  Fail ("Signing material is PARTIALLY configured: $missingHalf is missing. " +
    'Set both halves of the PFX pair (or use WIN_SIGN_CERT_THUMBPRINT), or unset both to ship unsigned.')
}

$haveMaterial = ($pfxPath -and $pfxPassword) -or $thumbprint
if (-not $haveMaterial) {
  if ($RequireSignature) {
    Fail ('No signing material configured (WIN_SIGN_CERT_PFX + WIN_SIGN_CERT_PASSWORD, ' +
      'or WIN_SIGN_CERT_THUMBPRINT) and -RequireSignature was passed.')
  }
  Write-Skip ('UNSIGNED BUILD: no signing material configured ' +
    '(WIN_SIGN_CERT_PFX/WIN_SIGN_CERT_PASSWORD or WIN_SIGN_CERT_THUMBPRINT). ' +
    'Decision D3 allows the private beta to ship unsigned; testers will see ' +
    'SmartScreen warnings and need the bypass instructions from the tester guide.')
  exit 0
}

if ($pfxPath -and -not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) {
  Fail "WIN_SIGN_CERT_PFX points to a missing file: $pfxPath"
}

$signtool = Find-SignTool
if (-not $signtool) {
  Fail ('signtool.exe not found on PATH or in the Windows 10/11 SDK ' +
    '(Program Files (x86)\Windows Kits\10\bin\<version>\x64). Install the SDK first.')
}
Write-Info "signtool: $signtool"

# --- Sign + verify ----------------------------------------------------------------
foreach ($file in $filesToSign) {
  Write-Step "Signing $(Split-Path -Leaf $file)"
  if ($thumbprint) {
    & $signtool sign `
      /fd SHA256 `
      /tr $timestampUrl `
      /td SHA256 `
      /sha1 $thumbprint `
      $file
  } else {
    & $signtool sign `
      /fd SHA256 `
      /tr $timestampUrl `
      /td SHA256 `
      /f $pfxPath `
      /p $pfxPassword `
      $file
  }
  if ($LASTEXITCODE -ne 0) {
    Fail "signtool sign failed for $file with exit code $LASTEXITCODE."
  }

  & $signtool verify /pa /v $file
  if ($LASTEXITCODE -ne 0) {
    Fail "signtool verify failed for $file with exit code $LASTEXITCODE."
  }
  Write-Info "signed + verified: $file"
}

Write-Host 'Code signing completed successfully.' -ForegroundColor Green
exit 0
