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
  # A CI agent that cannot name its own branch must NOT be read as "nothing to
  # check". This guard skipped EVERY prod run until now: agents check out a
  # detached HEAD, Get-CurrentBranchName fell through to 'local', and 'local'
  # is not a release branch -- so the one check whose entire job is to catch a
  # release/X.Y.Z branch shipping a different pubspec version passed silently
  # on the only lane that matters. It read as green.
  #
  # Get-CurrentBranchName now resolves the branch from BUILD_SOURCEBRANCH /
  # GITHUB_REF, so reaching 'local' under CI means that resolution itself
  # failed. Fail loudly rather than skip: a release built from an unknown ref
  # is exactly the case the guard exists for.
  $underCi = ([bool]$env:TF_BUILD) -or ([bool]$env:GITHUB_ACTIONS)
  if ($underCi -and $branch -eq 'local') {
    Fail ("Could not determine the branch under CI (detached HEAD and no " +
          "usable BUILD_SOURCEBRANCH/GITHUB_REF). Refusing to skip the " +
          "version guard on a release lane.")
  }
  Write-Info "Skipping version guard on non-release branch: $branch"
  exit 0
}

$versionFromBranch = $branch.Substring('release/'.Length)
if ($versionFromBranch -ne $Ctx.AppVersion) {
  Fail "Version mismatch: branch=$versionFromBranch pubspec=$($Ctx.AppVersion)"
}

Write-Host "Version guard passed: $($Ctx.AppVersion)" -ForegroundColor Green
exit 0
