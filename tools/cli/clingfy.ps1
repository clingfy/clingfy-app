# clingfy — open Clingfy (optionally with a .clingfyproj) from any terminal.
#
# Usage:
#   clingfy                # launch the app
#   clingfy .              # open the .clingfyproj in the current directory
#   clingfy <path>         # open a specific .clingfyproj (relative or absolute)
#
# Executable resolution order (first hit wins):
#   1. $env:CLINGFY_EXE                  — explicit override
#   2. repo dev builds                   — Debug, then Release (what you are
#                                          actively iterating on)
#   3. installed "Clingfy Dev" / "Clingfy" under %LOCALAPPDATA%\Programs
#
# The project path is absolutized BEFORE launch: the single-instance forward
# hands argv to the already-running app, whose working directory is not ours,
# so a relative path would resolve wrong there.
#
# Install (one-time): see tools/cli/README.md.

param(
    [Parameter(Position = 0)]
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'

$candidates = @()
if ($env:CLINGFY_EXE) { $candidates += $env:CLINGFY_EXE }

# When this script ships inside an install ({app}\bin\clingfy.ps1, placed by
# the installer's "add clingfy to PATH" task), its own app's exe is one level
# up. Prefer it: a dev-channel shim stays on the dev exe and a prod shim on
# prod, regardless of what else is installed. In the repo this path does not
# exist and is skipped.
$candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) 'clingfy.exe')

# Repo dev builds — only when this script actually lives inside the repo
# (tools/cli/ -> repo root, verified by pubspec.yaml). A copy placed outside
# the repo silently skips these and falls through to the installed apps.
$repoRoot = Join-Path $PSScriptRoot '..\..'
if (Test-Path (Join-Path $repoRoot 'pubspec.yaml')) {
    $repoRoot = (Resolve-Path $repoRoot).Path
    $candidates += @(
        (Join-Path $repoRoot 'build\windows\x64\runner\Debug\clingfy.exe'),
        (Join-Path $repoRoot 'build\windows\x64\runner\Release\clingfy.exe')
    )
}
$candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Clingfy Dev\clingfy.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Clingfy\clingfy.exe')
)

$exe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $exe) {
    Write-Error ("No Clingfy executable found. Build one (flutter build windows) " +
        "or install the app, or set CLINGFY_EXE. Looked at:`n  " +
        ($candidates -join "`n  "))
    exit 1
}

if ($ProjectPath) {
    $resolved = (Resolve-Path $ProjectPath).Path
    if ($resolved -notlike '*.clingfyproj') {
        # Tolerate being INSIDE the bundle or pointing at its parent dir.
        $inner = Get-ChildItem -Path $resolved -Directory -Filter '*.clingfyproj' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($inner) { $resolved = $inner.FullName }
    }
    Start-Process -FilePath $exe -ArgumentList "`"$resolved`""
} else {
    Start-Process -FilePath $exe
}
