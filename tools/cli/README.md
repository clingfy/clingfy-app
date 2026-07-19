# `clingfy` terminal launcher

Open the app — optionally with a `.clingfyproj` — from any terminal:

```
clingfy            # launch the app
clingfy .          # open the project in (or under) the current directory
clingfy <path>     # open a specific .clingfyproj
```

Relative paths are absolutized before launch (the single-instance forward
hands argv to the already-running app, whose working directory is not yours).
Pointing at a directory that *contains* a `.clingfyproj` — or being inside
one — also works.

## One-time install

### Windows

Add this repo's `tools\cli` directory to your user PATH (run from the repo
root; the launcher then updates itself with `git pull`):

```powershell
$bin = (Resolve-Path tools\cli).Path
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path -notlike "*$bin*") {
  [Environment]::SetEnvironmentVariable('Path', "$path;$bin", 'User')
}
```

Open a new terminal afterwards (PATH changes don't reach existing shells).
The launcher resolves the exe as: `CLINGFY_EXE` env override → this repo's
`build\windows\x64\runner\{Debug,Release}` → installed
`%LOCALAPPDATA%\Programs\Clingfy Dev` → installed `Clingfy`. (A copy placed
outside the repo also works — it just skips the repo-build candidates.)

### macOS

Symlink the script somewhere on PATH (run from the repo root):

```sh
mkdir -p /usr/local/bin
ln -sf "$(pwd)/tools/cli/clingfy" /usr/local/bin/clingfy
```

Resolution: `CLINGFY_APP` env override → the "Clingfy Dev" app → "Clingfy"
(via `open -a`, so the normal macOS open-project flow handles the path).
