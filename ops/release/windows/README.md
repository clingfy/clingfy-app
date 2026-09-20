# Windows Release Lane

> **⚠️ PUBLISH TARGET CHANGED 2026-09-12 — prod publishes to AWS S3, not Azure.**
> Azure decommissioning finished 2026-09-15 — zero Clingfy resources remain, both release storage
> accounts (`clingfyreleases`, `clingfyreleasesdev`) are deleted and their hostnames no longer resolve
> in DNS. `clingfy.com/updates/*` has served from the AWS
> releases bucket since the 2026-08-17 cutover. Publishing prod to Azure would have written to a
> location nothing reads — the upload succeeds, the smoke test passes (it checks the copy it just
> wrote), and no installed app ever sees the release.
>
> `RELEASE_STORAGE_PROVIDER` selects the backend and defaults per channel: **prod and dev -> `aws`**,
> only the `local` channel -> `azure`. Dev publishes to `clingfy-labs-dev-releases-422661068605` and is
> served from `dev.clingfy.com/updates`. The S3 key is `<container>/<blob name>`, identical to the old Azure layout,
> because the CloudFront `/updates/*` behaviour has no path rewrite.
>
> Script names still say `azure` (`05_publish_azure.sh`, `04_publish_azure.ps1`) — renaming them
> would break the workflows and `local_run_all.sh` that call them. Mentions of Azure below describe
> the `azure` branch, which is now reachable only from the `local` channel and has no storage account left behind it.
>
> **Three vars are required for `aws`**: `AWS_RELEASES_BUCKET` (where bytes go),
> `AWS_PUBLIC_ENDPOINT` (where they are SERVED from, e.g. `clingfy.com/updates`), and
> `AWS_CLOUDFRONT_DISTRIBUTION_ID` (how a republished feed reaches viewers).
>
> Bucket and endpoint are separate on purpose — the appcast bakes the public URL into every
> enclosure, so an endpoint left pointing at Azure would publish a feed from clingfy.com whose
> downloads resolve to the retired storage account.
>
> The distribution id became required rather than optional because every feed this pipeline
> publishes is a REPUBLISHED path — `appcast.xml` on macOS, `latest-windows.json` on Windows
> (replaced on every publish by design). `/updates/*` is cached with the managed
> CachingOptimized policy, so without an invalidation the edge keeps serving the previous
> release for the full TTL while the bucket already holds the new bytes: the upload succeeds,
> nothing errors, and no installed app sees the release. Publishing to AWS without the means
> to invalidate is not a degraded release, it is a release nobody receives.
>
> All three are validated at startup and abort before any bytes move.



This directory contains the secret-free operational tooling used to build, package, sign, and publish Clingfy Windows releases. It is the PowerShell counterpart of the macOS bash lane one level up, sharing its release concepts — channel model, pubspec version source of truth, artifact naming, publishing conventions (AWS S3 + CloudFront since the 2026-08-17 cutover) — while staying fully independent of it: nothing here is sourced or invoked by the macOS scripts, and nothing here writes into the macOS lane's artifact locations (`release_archive/`, the `appcast.xml` feed, or `downloads/` outside the `windows/` prefix).

Like the parent lane, these scripts are public. Private credentials (Azure identities, signing certificates, Sentry tokens) are injected through the environment or local `.env.*` files that are never committed.

For the complete operator walkthrough — machine requirements, every secret and where to obtain it, step-by-step commands, and the exact Azure blob/URL layout — see `RUNBOOK.md`.

## Structure

- `RUNBOOK.md` - end-to-end signed-release runbook (requirements, secrets, steps, Azure locations)
- `_config.ps1` - shared context dot-sourced by every script: channel/version/name/path resolution, storage-provider selection (`aws` for prod/dev, `azure` only for `local`) and its defaults, dotenv fallback loading, tool discovery
- `00_version_guard.ps1` - verify a `release/*` branch name matches the semantic version in `pubspec.yaml`
- `01_build.ps1` - `flutter build windows --release` and stage a clean app folder into `dist/windows/app` (excludes PDBs/`runner_bridge.lib`/`native_assets.json`, bundles the VC++ CRT app-locally, verifies required runtime files)
- `02_package_inno.ps1` - compile the per-user Inno Setup installer into `dist/windows/installer`
- `03_sign.ps1` - Authenticode-sign the staged app binaries (`-Target app`, before packaging) or the installer (`-Target installer`, after); skips with a loud warning when no signing material is configured (decision D3 allows an unsigned private beta)
- `04_publish_azure.ps1` - upload installer + `.sha256` + `latest-windows.json` under `updates/downloads/windows/`, then invalidate exactly those CloudFront paths (the filename still says `azure`; it dispatches on `$Ctx.StorageProvider`, and the Azure blob + Front Door purge branch now runs only for the `local` channel — do not rename the file, the workflows invoke it by path)
- `05_smoke.ps1` - verify the published feed and installer through the public endpoint, including a download + SHA-256 comparison
- `upload_symbols.ps1` - Sentry symbol upload (PDBs + Dart AOT snapshot); written in Phase 10.4, invoked by the workflows as a non-blocking publish step
- `installer/Clingfy.iss` - Inno Setup source; channel identity arrives via `ISCC /D` defines from `02_package_inno.ps1`
- `workflows/ci_release.ps1` - full CI release pipeline (guard → build → sign → package → sign → publish → symbols → smoke)
- `workflows/local_release.ps1` - local workflow with optional test gate and opt-in publish

## Quick start

```powershell
# Dev installer on your machine (no publishing, no credentials needed):
pwsh ops/release/windows/workflows/local_release.ps1

# Full local gate, then publish the prod installer (prod publishes to AWS S3):
aws sso login --profile clingfy-dev   # AWS creds for account 422661068605; CI uses GitHub OIDC instead
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

Same bucket and `updates/` key prefix as the macOS lane — isolation between dev and prod comes from the per-`.env` bucket (`clingfy-labs-dev-releases-422661068605` / `clingfy-labs-prod-releases-422661068605`), exactly like macOS:

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
- AWS CLI v2 with credentials for the releases bucket (publish/smoke steps only; CI assumes the release role via GitHub OIDC, no stored keys)
- Azure CLI (`az`) on PATH — `04_publish_azure.ps1` still hard-fails when the binary is missing, before it dispatches on the provider; no `az login` is needed on the aws path
- `sentry-cli` (symbol upload step only; non-blocking when absent)

## Environment and credential categories

Values are read from the process environment first; the channel's `.env` file is a fallback for the publishing settings (`AWS_*` on the aws provider, `AZ_*` only on the legacy azure one) and (via `upload_symbols.ps1 -EnvFile`) the Sentry settings. Environment variables always win. Signing material is environment-only — never read from `.env` files.

### Publishing and CDN (from `.env.<channel>` or environment)

`RELEASE_STORAGE_PROVIDER` picks the backend (defaults: `aws` for prod and dev, `azure` for `local`). On `aws` all three of these are required and validated at startup, before any bytes move:

- `AWS_RELEASES_BUCKET` — where the bytes go
- `AWS_PUBLIC_ENDPOINT` — where they are served from (e.g. `clingfy.com/updates`), baked into every `latest-windows.json` URL
- `AWS_CLOUDFRONT_DISTRIBUTION_ID` — the invalidation target, without which the republished feed stays stale at the edge

Legacy `azure` provider (`local` channel only — the storage accounts behind these keys were deleted 2026-09-15, so the values still sitting in `.env.dev` / `.env.prod` are dead):

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

Two GitHub Actions workflows drive this lane: `.github/workflows/release-windows-dev.yml` (push to `develop` on Windows-relevant paths, gated on the repo variable `GH_RELEASE_LANES_ENABLED == 'true'`) and `.github/workflows/release-windows-prod.yml` (manual dispatch, `release/*` branches only, and never run as of 2026-09-20). Both run on `windows-latest`, install Inno Setup with `choco install innosetup`, and authenticate to AWS with GitHub OIDC (`aws-actions/configure-aws-credentials@v4` + `vars.AWS_RELEASE_ROLE_ARN`, which is scoped per environment) — no stored cloud keys. The shape is:

```yaml
steps:
  - uses: aws-actions/configure-aws-credentials@v4   # GitHub OIDC, no stored keys
    with:
      role-to-assume: ${{ vars.AWS_RELEASE_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION || 'eu-west-1' }}
  - pwsh: choco install innosetup -y --no-progress   # not preinstalled on windows-latest
  - pwsh: Import-PfxCertificate -FilePath $env:WIN_SIGN_CERT_PFX `   # signing is NOT wired in CI yet (D3: prod ships unsigned)
      -CertStoreLocation Cert:\CurrentUser\My `
      -Password (ConvertTo-SecureString $env:WIN_SIGN_CERT_PASSWORD -AsPlainText -Force)   # injected from a GitHub secret, not an ADO $(...) macro
  - pwsh: ops/release/windows/workflows/ci_release.ps1 -Channel prod -RequireSignature
    env:
      WIN_SIGN_CERT_THUMBPRINT: ${{ secrets.WIN_SIGN_CERT_THUMBPRINT }}
      SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}   # the real lanes read Sentry settings from the staged .env.<channel>
```

Keep the Windows job separate from the macOS job — never run Windows packaging inside the macOS pipeline or vice versa.

## Local usage notes

- All generated artifacts land under `dist/windows/` (staged app, installer, checksum, feed JSON), which `.gitignore` already excludes; the lane never writes into `release_archive/` or other macOS lane locations.
- `ISCC.exe installer/Clingfy.iss` also works standalone after `01_build.ps1 -Channel dev` — the `#ifndef` defaults in the `.iss` match the dev channel and output to `dist/windows/installer`.
- The Windows lane never creates git tags; `v<version>` tags stay owned by the macOS prod release flow.
- The test gate (`-RunTests`) runs `flutter analyze lib` + the native GoogleTest suite. It intentionally skips `flutter test`: the develop baseline carries a known-flaky set of FluentLocalizations widget-test failures, so gating a release on its raw exit code would block every run. When validating Dart changes, compare the set of failing test names against the develop baseline instead of trusting the exit code.
