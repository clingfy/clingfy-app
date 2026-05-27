<#
.SYNOPSIS
  Register or unregister the `.clingfyproj` "open" associations for a
  local dev build of Clingfy (Windows).

.DESCRIPTION
  Step 5.6 of the Phase 5 Windows port adds Explorer reopen support for
  `.clingfyproj` bundles via WM_COPYDATA single-instance forwarding.
  Triggering that handoff requires Windows to know which executable
  handles `.clingfyproj` — that's what this script installs.

  Two complementary registrations are written under HKCU:

  1. **File-type ProgID** (`Clingfy.Project.1` → `.clingfyproj`).
     This is the classic Win32 file association. It works when a
     `.clingfyproj` is a literal file (which is how a future installer
     would ship them).

  2. **Directory shell verb** (`Folder\shell\OpenInClingfy`). Step
     5.6's actual on-disk layout is a directory bundle, not a file —
     `%LOCALAPPDATA%\Clingfy\recordings\<id>.clingfyproj\` is a folder
     containing `manifest.json`, `capture\screen.mov`, etc. Windows
     does not let a ProgID claim "open" for a folder without a COM
     IShellFolder hook (installer territory), so the dev workflow uses
     a right-click "Open in Clingfy" verb on the Folder class
     instead. Verified working from the running app's argv +
     WM_COPYDATA pipeline.

  Both writes use HKCU (no elevation, clean uninstall). Production
  installer packaging will register the same shape under HKLM plus an
  IconHandler / IShellExtInit COM hook to make the bundle appear as a
  file in Explorer.

.PARAMETER ExePath
  Absolute path to clingfy.exe. Defaults to the debug build under
  build/windows/x64/runner/Debug/clingfy.exe, which is what
  `flutter run -d windows --flavor dev` produces.

.PARAMETER Unregister
  Remove both registrations instead of installing them.

.EXAMPLE
  # Install pointing at your debug build.
  .\tools\dev_register_assoc.ps1

.EXAMPLE
  # Install pointing at a release build.
  .\tools\dev_register_assoc.ps1 -ExePath C:\work\clingfy-app\build\windows\x64\runner\Release\clingfy.exe

.EXAMPLE
  # Uninstall both registrations.
  .\tools\dev_register_assoc.ps1 -Unregister
#>

[CmdletBinding()]
param(
    [string]$ExePath,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$ProgId = 'Clingfy.Project.1'
$Ext = '.clingfyproj'
$DirectoryVerb = 'OpenInClingfy'

$ProgIdRoot = "HKCU:\Software\Classes\$ProgId"
$ExtRoot = "HKCU:\Software\Classes\$Ext"
# Folder verb root. Putting it under `Folder` rather than `Directory`
# scopes the right-click entry to "real" filesystem folders only (and
# is what most third-party tools target). Microsoft's per-folder
# shell verb docs are at:
# https://learn.microsoft.com/en-us/windows/win32/shell/context-menu-handlers
$DirectoryVerbRoot = "HKCU:\Software\Classes\Folder\shell\$DirectoryVerb"

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

function Register-FileProgId {
    param([string]$Exe)
    Write-Host "Registering file association: $Ext -> $ProgId -> $Exe"

    if (-not (Test-Path -LiteralPath $ProgIdRoot)) {
        New-Item -Path $ProgIdRoot -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ProgIdRoot -Name '(default)' -Value 'Clingfy Recording'

    $shellOpen = Join-Path $ProgIdRoot 'shell\open\command'
    if (-not (Test-Path -LiteralPath $shellOpen)) {
        New-Item -Path $shellOpen -Force | Out-Null
    }
    # `"%1"` is the standard Shell substitution for the dropped path.
    # Quoting is critical for paths with spaces — `CommandLineToArgvW`
    # on the receiver side honours the quoting.
    $command = '"' + $Exe + '" "%1"'
    Set-ItemProperty -LiteralPath $shellOpen -Name '(default)' -Value $command

    if (-not (Test-Path -LiteralPath $ExtRoot)) {
        New-Item -Path $ExtRoot -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ExtRoot -Name '(default)' -Value $ProgId
}

function Register-FolderVerb {
    param([string]$Exe)
    Write-Host "Registering folder right-click verb: $DirectoryVerb -> $Exe"

    if (-not (Test-Path -LiteralPath $DirectoryVerbRoot)) {
        New-Item -Path $DirectoryVerbRoot -Force | Out-Null
    }
    # The (default) value is the menu label the user sees.
    Set-ItemProperty -LiteralPath $DirectoryVerbRoot -Name '(default)' -Value 'Open in Clingfy'
    # Make the verb's icon match the exe so it's visually obvious.
    Set-ItemProperty -LiteralPath $DirectoryVerbRoot -Name 'Icon' -Value $Exe

    $folderCommand = Join-Path $DirectoryVerbRoot 'command'
    if (-not (Test-Path -LiteralPath $folderCommand)) {
        New-Item -Path $folderCommand -Force | Out-Null
    }
    # `%V` (not `%1`) is the Shell substitution for the folder path
    # under Folder\shell\… — `%1` is empty for folder verbs because
    # there is no "file" argument. See:
    # https://learn.microsoft.com/en-us/windows/win32/shell/context
    $command = '"' + $Exe + '" "%V"'
    Set-ItemProperty -LiteralPath $folderCommand -Name '(default)' -Value $command
}

function Unregister-FileProgId {
    if (Test-Path -LiteralPath $ProgIdRoot) {
        Remove-Item -LiteralPath $ProgIdRoot -Recurse -Force
        Write-Host "Removed $ProgIdRoot"
    }
    # Only clear the extension key if it still points at our ProgID —
    # be polite to anything the user has since associated.
    if (Test-Path -LiteralPath $ExtRoot) {
        $current = (Get-ItemProperty -LiteralPath $ExtRoot -ErrorAction SilentlyContinue).'(default)'
        if ($current -eq $ProgId) {
            Remove-Item -LiteralPath $ExtRoot -Recurse -Force
            Write-Host "Removed $ExtRoot"
        } else {
            Write-Host "Note: $Ext is currently associated with '$current'; leaving it alone."
        }
    }
}

function Unregister-FolderVerb {
    if (Test-Path -LiteralPath $DirectoryVerbRoot) {
        Remove-Item -LiteralPath $DirectoryVerbRoot -Recurse -Force
        Write-Host "Removed $DirectoryVerbRoot"
    }
}

if ($Unregister) {
    Write-Host "Unregistering Clingfy dev associations from HKCU"
    Unregister-FileProgId
    Unregister-FolderVerb
    Write-Host 'Done.'
} else {
    $resolvedExe = Resolve-ExePath -Override $ExePath
    Register-FileProgId -Exe $resolvedExe
    Register-FolderVerb -Exe $resolvedExe
    Write-Host ''
    Write-Host 'Done. Two ways to verify Step 5.6 from Explorer:'
    Write-Host "  1. Right-click any .clingfyproj folder under $env:LOCALAPPDATA\Clingfy\recordings\"
    Write-Host '     and pick "Open in Clingfy".'
    Write-Host '  2. Or drag-and-drop the folder onto clingfy.exe.'
    Write-Host '  Use -Unregister to remove both registrations.'
}
