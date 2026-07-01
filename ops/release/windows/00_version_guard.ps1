#!/usr/bin/env pwsh
#Requires -Version 7
# 00_version_guard.ps1
#
# Phase 10.5 (Windows installer + release pipeline): verifies that a
# `release/*` branch name matches the semantic version in pubspec.yaml —
# the same contract as the macOS lane's commands/version_guard.sh. On any
# other branch the guard logs and skips, so local dev-channel runs are
# never blocked.
#
# Like the macOS guard, only the semantic version is checked; the build
# number after `+` is not part of the branch contract.

[CmdletBinding()]
param(
  # Release channel; only used for context logging — the guard's behavior
  # does not vary by channel.
  [ValidateSet('prod', 'dev', 'local')]
  [string]$Channel = 'dev'
)

. (Join-Path $PSScriptRoot '_config.ps1')

Write-Step 'Version guard (Windows)'
$Ctx = Initialize-WindowsReleaseContext -Channel $Channel

$branch = Get-CurrentBranchName
if ($branch -notlike 'release/*') {
  Write-Info "Skipping version guard on non-release branch: $branch"
  exit 0
}

$versionFromBranch = $branch.Substring('release/'.Length)
if ($versionFromBranch -ne $Ctx.AppVersion) {
  Fail "Version mismatch: branch=$versionFromBranch pubspec=$($Ctx.AppVersion)"
}

Write-Host "Version guard passed: $($Ctx.AppVersion)" -ForegroundColor Green
exit 0
