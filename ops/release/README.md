# Release Tooling

> **⚠️ PUBLISH TARGET CHANGED 2026-09-12 — prod publishes to AWS S3, not Azure.**
> Azure was decommissioned on 2026-09-10, and `clingfy.com/updates/*` has served from the AWS
> releases bucket since the 2026-08-17 cutover. Publishing prod to Azure would have written to a
> location nothing reads — the upload succeeds, the smoke test passes (it checks the copy it just
> wrote), and no installed app ever sees the release.
>
> `RELEASE_STORAGE_PROVIDER` selects the backend and defaults per channel: **prod and dev -> `aws`**,
> `local` -> `azure`. Dev moved off Azure on 2026-09-15 when it got its own bucket
> (`clingfy-labs-dev-releases-<account>`), seeded from the old `clingfyreleasesdev` updates container
> with enclosure hosts rewritten to dev.clingfy.com. `local` is the only arm still selecting `azure`,
> and it has no credentials for either cloud, so it dies at `require_release_storage_cli` long before
> it matters — see `configure_storage_provider()` in `lib/env.sh`. The S3 key is
> `<container>/<blob name>`, identical to the old Azure layout,
> because the CloudFront `/updates/*` behaviour has no path rewrite.
>
> The publish scripts were named `05_publish_azure.sh` / `04_publish_azure.ps1` until
> 2026-09-21. They never became Azure-specific — they dispatch on `RELEASE_STORAGE_PROVIDER`
> and have published to S3 since the cutover — so the names were renamed to `05_publish.sh`
> and `04_publish.ps1` once every caller was found. Mentions of Azure below describe the
> `azure` branch, which no release lane reaches any more: only the `local` channel selects it,
> and the accounts it would write to no longer exist.
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



This directory contains the secret-free operational tooling used to build, sign, notarize, package, and publish Clingfy macOS releases. The Windows release lane lives in `windows/` (PowerShell, fully independent of the macOS scripts) — see `windows/README.md`.

The scripts in this directory are public. Private credentials, signing assets, and hosted service configuration are intentionally kept outside the repository and injected through local environment files or CI secure files.

## Structure

- `00_restore_history.sh` - restore prior release artifacts such as `appcast.xml` and the previously published DMG from the release store (S3 on `dev` and `prod`; Azure blob only on the `local` channel)
- `00_version_bump.sh` - bump the build number in `pubspec.yaml`
- `00_version_guard.sh` - verify a `release/*` branch name matches the semantic version in `pubspec.yaml`
- `01_build.sh` - build and archive the macOS app, install CocoaPods, and generate export options
- `02_create_dmg.sh` - package the exported app into a signed DMG
- `03_notarize.sh` - submit the DMG to Apple notarization and save logs under `dist/`
- `04_finish.sh` - staple the notarization ticket and verify the DMG
- `05_publish.sh` - generate Sparkle metadata, upload the DMG and deltas, upload symbols, and invalidate the CloudFront `/updates/*` paths. Dispatches on `RELEASE_STORAGE_PROVIDER` and publishes to S3 on `dev` and `prod`. The workflows invoke it by path, so any future rename has to move with them.
- `06_git_tag.sh` - create and push the release git tag
- `notify_telegram.sh` - send release/failure notifications when Telegram credentials are configured. Renders the CHANGELOG section as Telegram HTML and caps it at Telegram's 4096-character limit. Preview without sending:
  ```bash
  APP_ENV=prod RELEASE_CHANNEL=prod ./ops/release/notify_telegram.sh success --dry-run
  ```
  Never fatal: a notification failure must not stop the run, because it sits between publishing the release and tagging it.
- `commands/` - implementation scripts used by the wrapper entrypoints above
- `workflows/ci_release.sh` - full CI release pipeline
- `workflows/local_release.sh` - local release workflow with optional restore/publish steps
- `lib/` - shared helpers for Apple signing/notary, AWS S3 + CloudFront (`aws.sh`), release context (`context.sh`), environment loading, Sparkle, and common shell helpers
- `docs/sparkle.md` - notes specific to the Sparkle updater integration
- `windows/` - Windows release lane (PowerShell): build/stage, Inno Setup packaging, signing, publish (`04_publish.ps1` — same historical name, same S3/CloudFront target), smoke - see `windows/README.md`

## What is safe to keep public

Safe and intentionally public:

- release flow orchestration
- build, notarization, packaging, and publish logic
- script documentation and templates
- generated-file locations and validation behavior

Never stored here:

- Apple signing certificates
- provisioning profiles
- Sparkle private keys
- notary API keys
- Azure secrets or service credentials
- Telegram bot credentials
- local `.env.*` files with private values

## Required tooling

Depending on the script, the release flow expects:

- Flutter
- Xcode / `xcodebuild`
- CocoaPods / `pod`
- `create-dmg`
- Sparkle's `generate_appcast`
- AWS CLI (`aws`) - the publisher for the `dev` and `prod` channels; the `local` channel publishes nowhere and needs no cloud CLI at all
- Apple notarization tooling via `xcrun`
- `codesign`, `spctl`, `zip`, `curl`, and standard Unix shell tools

The scripts already fail fast when required tools or critical environment variables are missing.

## Environment and credential categories

The release scripts load private configuration from a local `.env.<flavor>` file or CI secure files. Those inputs are not part of the public repository.

### Build metadata and app configuration

- `APP_ENV`
- `API_BASE_URL`
- `CLINGFY_SITE_URL`
- `CLINGFY_UPDATE_FEED_HOST` - the Windows in-app updater's feed host + path prefix (`clingfy.com/updates` on prod, `dev.clingfy.com/updates` on dev). Compiled into the installer by `--dart-define-from-file` and the ONLY source for that URL (`lib/core/updater/windows_update_feed.dart`), so a build missing it ships an updater that can never succeed while the lane still reports success. No release script reads it — `AWS_PUBLIC_ENDPOINT` is the publishing side of the same host, and the two must move together. Renamed from `AZ_CDN_ENDPOINT` on 2026-09-21; the fallback to the old name is gone.
- `SENTRY_DSN`
- `SENTRY_ENVIRONMENT`
- `SENTRY_TRACES_SAMPLE_RATE`

### Apple signing and export

- `APPLE_PROV_PROFILE_SPECIFIER`
- `APPLE_PROV_PROFILE_UUID`
- `APPLE_TEAM_ID`
- `CERT_HASH` or `APPLE_CERTIFICATE_SIGNING_IDENTITY`

### Apple notarization

- `NOTARY_KEY_ID`
- `NOTARY_ISSUER`
- `NOTARY_KEY_PATH`

### Sparkle publishing

- `SPARKLE_KEY_PATH`

### Release publishing and CDN

- `RELEASE_STORAGE_PROVIDER` - `aws` or `none`; defaults to `aws` on the `prod` and `dev` channels and `none` on `local`, which does not publish at all. Any other value is a hard failure before any bytes move.

Azure-era names that outlived Azure — `configure_azure_defaults()` still exports them and they are live on the only remaining backend. On AWS they are S3 key prefixes, not containers (`S3 key = <container>/<blob name>`):

- `AZ_CONTAINER` (default `updates`)
- `AZ_BINARIES_FOLDER` (default `downloads`)
- `AZ_CONTAINER_SYMBOLS` (default `symbols`)

AWS — all three required whenever the provider is `aws`, validated at startup before any bytes move:

- `AWS_RELEASES_BUCKET` - where the bytes go
- `AWS_PUBLIC_ENDPOINT` - where they are SERVED from, e.g. `clingfy.com/updates` (baked into every appcast enclosure)
- `AWS_CLOUDFRONT_DISTRIBUTION_ID` - how a republished feed reaches viewers

CI authenticates to AWS with GitHub OIDC, not stored access keys, so no AWS key material belongs in `.env.*`.

Azure — gone, not merely unused. The provider switch accepts only `aws` and `none` (`prod` and `dev` default to `aws`, every other channel including `local` to `none`, and `configure_storage_provider()` in `lib/env.sh` dies on anything else), so no release script reads any of these on any channel:

- `AZ_STORAGE_ACCOUNT`
- `AZ_RESOURCE_GROUP`
- `AZ_CDN_PROFILE`
- `AZ_FRONTDOOR_ENDPOINT_NAME`

The Windows lane still *loads* those four (`$script:AzureLegacyKeys` in `windows/_config.ps1`), purely so an operator reading a stale `.env` sees them accounted for; nothing validates or uses the values. `AZ_CDN_ENDPOINT` is not on that list, and it is not dead in the same way: it was renamed `CLINGFY_UPDATE_FEED_HOST` on 2026-09-21 — the Windows updater's feed host (`clingfy.com/updates`, `dev.clingfy.com/updates`), compiled into the installer via `--dart-define-from-file` — and nothing reads the old name any more, though the `ENV_DEV_B64` / `ENV_PROD_B64` CI secrets still carry it. Both Azure release storage accounts were deleted on 2026-09-15, and the `azure` provider arm itself (`lib/azure.sh` and the `azure` case in both provider switches) on 2026-09-21.

### Optional release integrations

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_PROJECT`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

## Local usage notes

- Local release flows are intended for maintainers who already have private signing/notary/publishing credentials configured.
- Generated scratch files such as `ops/release/output.log` and `ops/release/ExportOptions.plist` are ignored and should not be committed.
- Release artifacts are generated under `dist/` and `release_archive/`; keep those directories out of the public repo surface.
