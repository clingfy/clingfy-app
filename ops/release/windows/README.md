# Windows Release Lane

This directory contains the secret-free operational tooling used to build, package, sign, and publish Clingfy Windows releases. It is the PowerShell counterpart of the macOS bash lane one level up, sharing its release concepts — channel model, pubspec version source of truth, artifact naming, Azure publishing conventions — while staying fully independent of it: nothing here is sourced or invoked by the macOS scripts, and nothing here writes into the macOS lane's artifact locations (`release_archive/`, the `appcast.xml` feed, or `downloads/` outside the `windows/` prefix).

Like the parent lane, these scripts are public. Private credentials (Azure identities, signing certificates, Sentry tokens) are injected through the environment or local `.env.*` files that are never committed.

## Structure

- `_config.ps1` - shared context dot-sourced by every script: channel/version/name/path resolution, Azure defaults, dotenv fallback loading, tool discovery
- `00_version_guard.ps1` - verify a `release/*` branch name matches the semantic version in `pubspec.yaml`
- `01_build.ps1` - `flutter build windows --release` and stage a clean app folder into `dist/windows/app` (excludes PDBs/`runner_bridge.lib`/`native_assets.json`, bundles the VC++ CRT app-locally, verifies required runtime files)
- `02_package_inno.ps1` - compile the per-user Inno Setup installer into `dist/windows/installer`
- `03_sign.ps1` - Authenticode-sign the staged app binaries (`-Target app`, before packaging) or the installer (`-Target installer`, after); skips with a loud warning when no signing material is configured (decision D3 allows an unsigned private beta)
- `04_publish_azure.ps1` - upload installer + `.sha256` + `latest-windows.json` to Azure blob storage under `downloads/windows/`, then purge the Front Door cache for exactly those paths
- `05_smoke.ps1` - verify the published feed and installer through the public endpoint, including a download + SHA-256 comparison
- `upload_symbols.ps1` - Sentry symbol upload (PDBs + Dart AOT snapshot); written in Phase 10.4, invoked by the workflows as a non-blocking publish step
- `installer/Clingfy.iss` - Inno Setup source; channel identity arrives via `ISCC /D` defines from `02_package_inno.ps1`
- `workflows/ci_release.ps1` - full CI release pipeline (guard → build → sign → package → sign → publish → symbols → smoke)
- `workflows/local_release.ps1` - local workflow with optional test gate and opt-in publish

## Quick start

```powershell
# Dev installer on your machine (no publishing, no credentials needed):
pwsh ops/release/windows/workflows/local_release.ps1

# Full local gate, then publish the prod installer:
az login
pwsh ops/release/windows/workflows/local_release.ps1 -Channel prod -Clean -RunTests -Publish
```

Step numbering is nominal — signing straddles packaging, so the workflows run `03_sign.ps1 -Target app` before `02_package_inno.ps1` and `-Target installer` after it.

## Installer behavior (decision D1)

- Per-user install (`PrivilegesRequired=lowest`), no UAC at install or update; install dir `%LOCALAPPDATA%\Programs\<app name>`.
- Windows 10 1903+ (build 18362), x64 only.
- Registers the per-user `.clingfyproj` file association; the runner already handles both cold-start and running-instance opens.
- Bundles the VC++ CRT app-locally (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`).
- Uninstall removes only the install directory, shortcuts, and the registry association. It preserves `%LOCALAPPDATA%\Clingfy\` (recordings + native logs), `%APPDATA%\com.clingfy\clingfy\` (Dart logs, prefs, secure storage), `%TEMP%\clingfy_*`, and exported videos.
- Channels are distinct installer identities (AppId GUID, display name, install dir, ProgId), so dev and prod can install side by side — but they still share the single-instance mutex and data directories until the D9 per-config identity plumbing lands in the runner.

## Published artifact layout

Same storage account and `updates` container as the macOS lane (isolation between dev and prod comes from the per-`.env` storage account, exactly like macOS):

```
updates/
  downloads/
    <DMGs + Sparkle deltas — macOS lane, untouched>
    windows/
      Clingfy_Setup_<version>.exe              (prod)
      Clingfy_Dev_Setup_<version>+<build>.exe  (dev)
      <installer>.exe.sha256
      latest-windows.json
  appcast.xml                                  (macOS feed — never written from here)
```

`latest-windows.json` is a static feed stub (version, URL, SHA-256, size, minimum OS); the slice 10.6 in-app update check consumes it, making 10.6 a client-only change.

## Required tooling

- PowerShell 7+ (`pwsh`)
- Flutter (with the Windows desktop toolchain / Visual Studio Build Tools)
- Inno Setup 6.3+ (`winget install JRSoftware.InnoSetup`)
- Windows 10/11 SDK `signtool.exe` (only when signing material is configured)
- Azure CLI (`az`) logged in via `az login` (publish/smoke steps only)
- `sentry-cli` (symbol upload step only; non-blocking when absent)

## Environment and credential categories

Values are read from the process environment first; the channel's `.env` file is a fallback for the Azure publishing settings and (via `upload_symbols.ps1 -EnvFile`) the Sentry settings. Environment variables always win. Signing material is environment-only — never read from `.env` files.

### Azure publishing and CDN (from `.env.<channel>` or environment)

- `AZ_STORAGE_ACCOUNT`
- `AZ_RESOURCE_GROUP`
- `AZ_CDN_PROFILE`
- `AZ_CDN_ENDPOINT`
- `AZ_FRONTDOOR_ENDPOINT_NAME`

### Code signing (environment only — never in `.env` files, per decision D3)

- `WIN_SIGN_CERT_THUMBPRINT` (certificate store — preferred), or
- `WIN_SIGN_CERT_PFX` + `WIN_SIGN_CERT_PASSWORD` (PFX file)
- `WIN_SIGN_TIMESTAMP_URL` (optional; defaults to `http://timestamp.digicert.com`)

The PFX route hands the password to signtool as a process argument, where command-line auditing (Event 4688) and EDR telemetry can persist it. On shared machines or audited CI agents, import the PFX once (`Import-PfxCertificate -CertStoreLocation Cert:\CurrentUser\My`) and sign via the thumbprint instead — no secret crosses a command line. Setting only one half of the PFX pair is a hard failure (never a silent unsigned skip): that shape means a secret failed to inject.

### Sentry symbol upload (optional, non-blocking)

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_PROJECT`

### Version overrides (optional)

- `APP_VERSION_OVERRIDE`
- `BUILD_NUMBER_OVERRIDE` (must stay ≤ 65535 — the Windows `FILEVERSION` resource packs it into 16 bits, so the macOS lane's CI-build-id/epoch bump strategy does not transfer)

## CI job shape

Nothing in-repo invokes this workflow (the macOS release is likewise driven out-of-repo with secure variables). When wiring a pipeline, the Windows job needs a `windows-2022`-class agent and reduces to:

```yaml
steps:
  - pwsh: az login --service-principal ... # or federated identity
  - pwsh: winget install JRSoftware.InnoSetup --silent
  - pwsh: Import-PfxCertificate -FilePath $(winSignCert.secureFilePath) `
      -CertStoreLocation Cert:\CurrentUser\My `
      -Password (ConvertTo-SecureString $(winSignCertPassword) -AsPlainText -Force)
  - pwsh: ops/release/windows/workflows/ci_release.ps1 -Channel prod -RequireSignature
    env:
      WIN_SIGN_CERT_THUMBPRINT: $(winSignCertThumbprint)
      SENTRY_AUTH_TOKEN: $(sentryAuthToken)
```

Keep the Windows job separate from the macOS job — never run Windows packaging inside the macOS pipeline or vice versa.

## Local usage notes

- All generated artifacts land under `dist/windows/` (staged app, installer, checksum, feed JSON), which `.gitignore` already excludes; the lane never writes into `release_archive/` or other macOS lane locations.
- `ISCC.exe installer/Clingfy.iss` also works standalone after `01_build.ps1 -Channel dev` — the `#ifndef` defaults in the `.iss` match the dev channel and output to `dist/windows/installer`.
- The Windows lane never creates git tags; `v<version>` tags stay owned by the macOS prod release flow.
- The test gate (`-RunTests`) runs `flutter analyze lib` + the native GoogleTest suite. It intentionally skips `flutter test`: the develop baseline carries a known-flaky set of FluentLocalizations widget-test failures, so gating a release on its raw exit code would block every run. When validating Dart changes, compare the set of failing test names against the develop baseline instead of trusting the exit code.
