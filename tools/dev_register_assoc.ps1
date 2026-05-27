<#
.SYNOPSIS
  Register or unregister the `.clingfyproj` file-type association for a
  local dev build of Clingfy (Windows).

.DESCRIPTION
  Step 5.6 of the Phase 5 Windows port adds Explorer reopen support for
  `.clingfyproj` bundles via WM_COPYDATA single-instance forwarding.
  Triggering that handoff requires Windows to know which executable
  handles `.clingfyproj` — that's the file-type association this script
  installs.

  This script writes to HKCU (per-user), NOT HKLM, so no elevation is
  needed and uninstall is clean. Production installer packaging will
  use a different (HKLM, ProgID-shared, IconHandler-enabled) flow.

.PARAMETER ExePath
  Absolute path to clingfy.exe. Defaults to the debug build under
  build/windows/x64/runner/Debug/clingfy.exe, which is what
  `flutter run -d windows --flavor dev` produces.

.PARAMETER Unregister
  Remove the association instead of installing it.

.EXAMPLE
  # Install the association pointing at your debug build.
  .\tools\dev_register_assoc.ps1

.EXAMPLE
  # Install pointing at a release build.
  .\tools\dev_register_assoc.ps1 -ExePath C:\work\clingfy-app\build\windows\x64\runner\Release\clingfy.exe

.EXAMPLE
  # Uninstall.
  .\tools\dev_register_assoc.ps1 -Unregister
#>

[CmdletBinding()]
param(
    [string]$ExePath,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

# HKCU per-user file-association — Shell merges these over HKLM at
# read-time per Microsoft's "Programmatic Identifiers" docs:
# https://learn.microsoft.com/en-us/windows/win32/shell/fa-progids
$ProgId = 'Clingfy.Project.1'
$Ext = '.clingfyproj'

$ProgIdRoot = "HKCU:\Software\Classes\$ProgId"
$ExtRoot = "HKCU:\Software\Classes\$Ext"

function Resolve-ExePath {
    param([string]$Override)
    if ($Override) { return (Resolve-Path -LiteralPath $Override).Path }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidate = Join-Path $repoRoot 'build\windows\x64\runner\Debug\clingfy.exe'
    if (-not (Test-Path -LiteralPath $candidate)) {
        $candidate = Join-Path $repoRoot 'build\windows\x64\runner\Release\clingfy.exe'
    }
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Could not find clingfy.exe under build\windows\x64\runner. Run 'flutter build windows' first, or pass -ExePath."
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Register-Association {
    param([string]$Exe)
    Write-Host "Registering $Ext -> $ProgId -> $Exe"

    if (-not (Test-Path -LiteralPath $ProgIdRoot)) {
        New-Item -Path $ProgIdRoot -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ProgIdRoot -Name '(default)' -Value 'Clingfy Recording'

    $shellOpen = Join-Path $ProgIdRoot 'shell\open\command'
    if (-not (Test-Path -LiteralPath $shellOpen)) {
        New-Item -Path $shellOpen -Force | Out-Null
    }
    # `"%1"` is the standard Shell substitution for the dropped path. Quoting
    # is critical for paths with spaces — `CommandLineToArgvW` on the receiver
    # side honours the quoting.
    $command = '"' + $Exe + '" "%1"'
    Set-ItemProperty -LiteralPath $shellOpen -Name '(default)' -Value $command

    if (-not (Test-Path -LiteralPath $ExtRoot)) {
        New-Item -Path $ExtRoot -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ExtRoot -Name '(default)' -Value $ProgId

    Write-Host 'Done. Double-click a .clingfyproj in Explorer to verify.'
    Write-Host 'Use -Unregister to remove.'
}

function Unregister-Association {
    Write-Host "Unregistering $ProgId from HKCU"
    if (Test-Path -LiteralPath $ProgIdRoot) {
        Remove-Item -LiteralPath $ProgIdRoot -Recurse -Force
    }
    # Only clear the extension key if it still points at our ProgID — be
    # polite to anything the user has since associated.
    if (Test-Path -LiteralPath $ExtRoot) {
        $current = (Get-ItemProperty -LiteralPath $ExtRoot -ErrorAction SilentlyContinue).'(default)'
        if ($current -eq $ProgId) {
            Remove-Item -LiteralPath $ExtRoot -Recurse -Force
        } else {
            Write-Host "Note: $Ext is currently associated with '$current'; leaving it alone."
        }
    }
    Write-Host 'Done.'
}

if ($Unregister) {
    Unregister-Association
} else {
    $resolvedExe = Resolve-ExePath -Override $ExePath
    Register-Association -Exe $resolvedExe
}
