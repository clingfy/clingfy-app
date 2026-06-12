# Windows Signed Release Runbook

Everything needed to go from a git checkout to a **signed Windows installer published on Azure**, in one file. Commands are PowerShell 7 (`pwsh`), run from the repo root. No secret *values* live in this file or anywhere in the repo — only the names of the variables and where to obtain them.

The result of a full run:

```
https://<AZ_CDN_ENDPOINT>/downloads/windows/Clingfy_Setup_<version>.exe          signed installer
https://<AZ_CDN_ENDPOINT>/downloads/windows/Clingfy_Setup_<version>.exe.sha256   checksum
https://<AZ_CDN_ENDPOINT>/downloads/windows/latest-windows.json                  update feed stub (10.6 consumes it)
```

plus native PDBs + Dart AOT symbols uploaded to Sentry.

---

## 1. Machine requirements

| Tool | Why | Install / check |
|---|---|---|
| Windows 10/11 x64 | the lane refuses to run elsewhere (`_config.ps1` platform guard) | — |
| PowerShell 7+ | all lane scripts are `#Requires -Version 7` | `winget install Microsoft.PowerShell` |
| Flutter SDK + Visual Studio 2022 "Desktop development with C++" | `flutter build windows` | `flutter doctor` must show the Windows toolchain green |
| Inno Setup **6.3+** | installer compiler (`x64compatible` directives need ≥ 6.3) | `winget install JRSoftware.InnoSetup` — discovered via PATH or the default per-user/machine install dirs |
| Windows 10/11 SDK (`signtool.exe`) | Authenticode signing | ships with VS; the lane finds the newest SDK under `Program Files (x86)\Windows Kits\10\bin\<ver>\x64` |
| Azure CLI (`az`) | blob upload + Front Door purge | `winget install Microsoft.AzureCLI`, then `az login` |
| `sentry-cli` | symbol upload (optional — non-blocking step) | `scoop install sentry-cli` or `npm i -g @sentry/cli` |

> ⚠️ Inno Setup 6.5+ prints **"Non-commercial use only"** on unlicensed installs. Verify the Inno Setup license tier before shipping a commercial build.

## 2. Secrets & private files (all provided out-of-band, never committed)

### 2a. `.env.prod` (or `.env.dev`) in the repo root

Gitignored (`.gitignore` line 66); obtained per `docs/development.md`. The release lane reads two groups from it (environment variables always win over the file):

| Key | Used by | Purpose |
|---|---|---|
| `AZ_STORAGE_ACCOUNT` | `04_publish_azure.ps1`, `05_smoke.ps1` | target storage account — **dev and prod use different accounts**; that is the channel isolation model |
| `AZ_RESOURCE_GROUP` | `04_publish_azure.ps1` | Front Door purge identity |
| `AZ_CDN_PROFILE` | `04_publish_azure.ps1` | Front Door purge identity |
| `AZ_FRONTDOOR_ENDPOINT_NAME` | `04_publish_azure.ps1` | Front Door purge identity |
| `AZ_CDN_ENDPOINT` | `04_publish_azure.ps1`, `05_smoke.ps1` | public download hostname (builds the URLs above) |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` | `upload_symbols.ps1` | symbol upload (optional; missing → warn + continue) |

The same file also feeds the app itself via `--dart-define-from-file` (`API_BASE_URL`, `CLINGFY_SITE_URL`, `SENTRY_DSN`, …) — the build step passes it through verbatim.

### 2b. Code-signing certificate (decision D3: **environment-only — never in `.env` files, never in the repo**)

Two supported shapes; set in the shell right before releasing:

```powershell
# PREFERRED — cert already in the user store; no secret touches a command line:
$env:WIN_SIGN_CERT_THUMBPRINT = '<sha1 thumbprint>'

# One-time import if you only have a PFX file:
Import-PfxCertificate -FilePath C:\path\clingfy-codesign.pfx `
  -CertStoreLocation Cert:\CurrentUser\My `
  -Password (Read-Host -AsSecureString 'PFX password')
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert   # copy the thumbprint

# ALTERNATIVE — direct PFX (password lands on the signtool command line,
# visible to process auditing/EDR; avoid on shared machines):
$env:WIN_SIGN_CERT_PFX = 'C:\path\clingfy-codesign.pfx'
$env:WIN_SIGN_CERT_PASSWORD = '<password>'

# Optional (default http://timestamp.digicert.com):
$env:WIN_SIGN_TIMESTAMP_URL = '<rfc3161 url>'
```

Rules enforced by `03_sign.ps1`:
- **Nothing configured** → loud "UNSIGNED BUILD" warning, exit 0 (D3 allows the unsigned private beta). Pass `-RequireSignature` to make this fatal — always do so for prod.
- **Half a PFX pair configured** → hard failure (means a secret failed to inject).
- Signs `clingfy.exe` + `crashpad_handler.exe` *before* packaging and the installer *after*, SHA-256 digest + RFC 3161 timestamp, then `signtool verify /pa` on each.

### 2c. Azure identity

`az login` with an account that has, on the target storage account / Front Door profile:
- **Storage Blob Data Contributor** (uploads use `--auth-mode login`; no storage keys or SAS anywhere)
- Front Door purge rights (`az afd endpoint purge` on the profile)

## 3. Version preconditions

- `pubspec.yaml` `version: X.Y.Z+N` is the single source of truth. `X.Y.Z` becomes the artifact name; `N` must stay **≤ 65535** (16-bit Windows `FILEVERSION` field; the lane fails fast otherwise — never port the macOS epoch/CI-id build-number bump).
- Prod releases run from a `release/X.Y.Z` branch whose version matches pubspec (`00_version_guard.ps1` enforces; any other branch skips the guard — fine for dev rehearsals).

## 4. The whole thing in one command

```powershell
az login
$env:WIN_SIGN_CERT_THUMBPRINT = '<thumbprint>'

pwsh ops/release/windows/workflows/local_release.ps1 `
  -Channel prod -Clean -RunTests -Publish -RequireSignature
```

Rehearsal without touching prod infrastructure: `-Channel dev` (different storage account via `.env.dev`, artifact named `Clingfy_Dev_Setup_<ver>+<build>.exe`). Build-only, no upload: drop `-Publish`.

## 5. What runs, step by step (manual equivalents)

| # | Command | Produces / checks |
|---|---|---|
| 1 | `pwsh ops/release/windows/00_version_guard.ps1 -Channel prod` | `release/*` branch ↔ pubspec version match |
| 2 | `pwsh ops/release/windows/01_build.ps1 -Channel prod -Clean` | `flutter build windows --release --dart-define-from-file=.env.prod`; stages to `dist/windows/app` **excluding `*.pdb`, `runner_bridge.lib`, `native_assets.json`**; bundles the VC++ CRT app-locally; verifies required files (incl. `sentry.dll` + crashpad pair); writes the channel marker `dist/windows/app.channel.json` |
| 3 | `pwsh ops/release/windows/03_sign.ps1 -Channel prod -Target app -RequireSignature` | signs + verifies `clingfy.exe`, `crashpad_handler.exe` in the staging folder |
| 4 | `pwsh ops/release/windows/02_package_inno.ps1 -Channel prod` | compiles `installer/Clingfy.iss` → `dist/windows/installer/Clingfy_Setup_<ver>.exe`; refuses a channel/version-mismatched staging folder |
| 5 | `pwsh ops/release/windows/03_sign.ps1 -Channel prod -Target installer -RequireSignature` | signs + verifies the installer exe |
| 6 | `pwsh ops/release/windows/04_publish_azure.ps1 -Channel prod` | generates `.sha256` + `latest-windows.json`, uploads all three blobs, purges Front Door for exactly those paths, prints the download URL |
| 7 | `pwsh ops/release/windows/upload_symbols.ps1 -EnvFile .env.prod` | PDBs (`build/windows/x64/runner/Release`), Flutter engine PDB, `app.so` → Sentry (non-blocking) |
| 8 | `pwsh ops/release/windows/05_smoke.ps1 -Channel prod` | feed advertises this installer (9×5 s retries for CDN propagation), installer URL = HTTP 200, downloaded bytes hash-match the published sha256 |

## 6. Where everything lands

### Local (all gitignored under `/dist`)

```
dist/windows/app/                                  staged app (zero PDBs — verified)
dist/windows/app.channel.json                      channel/version marker
dist/windows/installer/Clingfy_Setup_<ver>.exe     the signed installer
dist/windows/installer/Clingfy_Setup_<ver>.exe.sha256
dist/windows/installer/latest-windows.json
```

### Azure (storage account = `AZ_STORAGE_ACCOUNT` from `.env.<channel>`)

```
container: updates
  downloads/windows/Clingfy_Setup_<ver>.exe            ← prod
  downloads/windows/Clingfy_Setup_<ver>.exe.sha256
  downloads/windows/latest-windows.json
  local/downloads/windows/...                          ← -Channel local only
```

Public URLs (via Front Door, domain = `AZ_CDN_ENDPOINT`):

```
https://<AZ_CDN_ENDPOINT>/downloads/windows/Clingfy_Setup_<ver>.exe
https://<AZ_CDN_ENDPOINT>/downloads/windows/latest-windows.json
```

Front Door purge targets exactly the three uploaded paths (resource group `AZ_RESOURCE_GROUP`, profile `AZ_CDN_PROFILE`, endpoint `AZ_FRONTDOOR_ENDPOINT_NAME`, domain `AZ_CDN_ENDPOINT`).

**Never touched by this lane:** `updates/appcast.xml` (macOS Sparkle feed), `downloads/*.dmg`, `downloads/*.delta`, the `symbols` container — the Windows lane writes only under its `windows/` prefix.

## 7. Verifying a published release by hand

```powershell
# Signature on the downloaded installer:
Get-AuthenticodeSignature .\Clingfy_Setup_<ver>.exe          # Status: Valid
& signtool verify /pa /v .\Clingfy_Setup_<ver>.exe

# Feed + checksum:
Invoke-RestMethod https://<AZ_CDN_ENDPOINT>/downloads/windows/latest-windows.json
Get-FileHash .\Clingfy_Setup_<ver>.exe -Algorithm SHA256     # == feed sha256

# Install smoke (per-user, no admin):
.\Clingfy_Setup_<ver>.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
# app at %LOCALAPPDATA%\Programs\Clingfy\clingfy.exe; .clingfyproj double-click opens it
```

## 8. Common failures

| Symptom | Cause / fix |
|---|---|
| `Environment file not found: .env.prod` | obtain it out-of-band (docs/development.md); never commit it |
| `Missing Azure publish settings: AZ_...` | the five AZ_* keys are absent from both the environment and the `.env` file |
| `az storage blob upload failed` / auth errors | not `az login`'d, or missing Storage Blob Data Contributor on the account |
| `UNSIGNED BUILD` warning when you expected signing | no `WIN_SIGN_*` set in *this* shell — they are environment-only by design |
| `Signing material is PARTIALLY configured` | one of `WIN_SIGN_CERT_PFX`/`WIN_SIGN_CERT_PASSWORD` missing — a secret failed to inject |
| `Staged app was built for channel 'dev' …` | staging/packaging channel mismatch — re-run `01_build.ps1 -Channel <x>` |
| `Build number … exceeds 65535` | pubspec `+N` too large for the 16-bit Windows version resource |
| `Version mismatch: branch=… pubspec=…` | on a `release/*` branch the versions must match exactly |
| Smoke feed check loops then fails | CDN purge still propagating (it retries 45 s) or the upload went to the other channel's storage account — check which `.env` was used |

## 9. Related

- `ops/release/windows/README.md` — script inventory, credential categories, CI job shape
- `docs/windows-port.md` § "Phase 10.5 — installer + release pipeline" — design rationale + smoke checklist
- `docs/decisions/windows-phase-10-beta-readiness-plan.md` — locked decisions D1 (installer), D3 (signing), D9 (channel identity)
