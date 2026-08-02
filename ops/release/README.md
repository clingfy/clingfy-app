# Release Tooling

This directory contains the secret-free operational tooling used to build, sign, notarize, package, and publish Clingfy macOS releases. The Windows release lane lives in `windows/` (PowerShell, fully independent of the macOS scripts) — see `windows/README.md`.

The scripts in this directory are public. Private credentials, signing assets, and hosted service configuration are intentionally kept outside the repository and injected through local environment files or CI secure files.

## Structure

- `00_restore_history.sh` - restore prior release artifacts such as `appcast.xml` and the previously published DMG from Azure storage
- `00_version_bump.sh` - bump the build number in `pubspec.yaml`
- `00_version_guard.sh` - verify a `release/*` branch name matches the semantic version in `pubspec.yaml`
- `01_build.sh` - build and archive the macOS app, install CocoaPods, and generate export options
- `02_create_dmg.sh` - package the exported app into a signed DMG
- `03_notarize.sh` - submit the DMG to Apple notarization and save logs under `dist/`
- `04_finish.sh` - staple the notarization ticket and verify the DMG
- `05_publish_azure.sh` - generate Sparkle metadata, upload the DMG and deltas, upload symbols, and purge CDN paths
- `06_git_tag.sh` - create and push the release git tag
- `notify_telegram.sh` - send release/failure notifications when Telegram credentials are configured. Renders the CHANGELOG section as Telegram HTML and caps it at Telegram's 4096-character limit. Preview without sending:
  ```bash
  APP_ENV=prod RELEASE_CHANNEL=prod ./ops/release/notify_telegram.sh success --dry-run
  ```
  Never fatal: a notification failure must not stop the run, because it sits between publishing the release and tagging it.
- `commands/` - implementation scripts used by the wrapper entrypoints above
- `workflows/ci_release.sh` - full CI release pipeline
- `workflows/local_release.sh` - local release workflow with optional restore/publish steps
- `lib/` - shared helpers for Apple signing/notary, Azure, environment loading, Sparkle, and common shell helpers
- `docs/sparkle.md` - notes specific to the Sparkle updater integration
- `windows/` - Windows release lane (PowerShell): build/stage, Inno Setup packaging, signing, Azure publish, smoke - see `windows/README.md`

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
- Azure CLI (`az`)
- Apple notarization tooling via `xcrun`
- `codesign`, `spctl`, `zip`, `curl`, and standard Unix shell tools

The scripts already fail fast when required tools or critical environment variables are missing.

## Environment and credential categories

The release scripts load private configuration from a local `.env.<flavor>` file or CI secure files. Those inputs are not part of the public repository.

### Build metadata and app configuration

- `APP_ENV`
- `API_BASE_URL`
- `CLINGFY_SITE_URL`
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

### Azure publishing and CDN

- `AZ_STORAGE_ACCOUNT`
- `AZ_CONTAINER`
- `AZ_BINARIES_FOLDER`
- `AZ_CONTAINER_SYMBOLS`
- `AZ_CDN_ENDPOINT`
- `AZ_RESOURCE_GROUP`
- `AZ_CDN_PROFILE`
- `AZ_FRONTDOOR_ENDPOINT_NAME`

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
