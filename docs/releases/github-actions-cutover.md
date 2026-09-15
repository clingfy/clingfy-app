# Release lanes on GitHub Actions — cutover runbook

The four release lanes in `azure-pipelines/` now have GitHub Actions
counterparts in `.github/workflows/`. Both sets exist side by side. **Nothing
has been cut over**: the new dev lanes are switched off, the new prod lanes are
manual-only, and the Azure lanes are untouched and still authoritative.

| lane | Azure Pipelines | GitHub Actions | trigger |
|---|---|---|---|
| macOS dev | `dev-channel.yml` | `release-macos-dev.yml` | push to `develop`, gated by a variable |
| Windows dev | `windows-dev-channel.yml` | `release-windows-dev.yml` | push to `develop` (path-scoped), gated by a variable |
| macOS prod | `release-prod.yml` | `release-macos-prod.yml` | manual, `release/*` only |
| Windows prod | `windows-release-prod.yml` | `release-windows-prod.yml` | manual, `release/*` only |
| — | — | `release-azure-plumbing.yml` | manual; credentials check, delete when done |

The release scripts under `ops/release/` are unchanged. They already ran off a
maintainer's laptop, so this is a harness swap, not a rewrite.

## One-time setup

### 1. Repository variables (Settings → Secrets and variables → Actions → Variables)

| variable | value |
|---|---|
| `AZURE_CLIENT_ID` | app registration (client) ID of the federated identity |
| `AZURE_TENANT_ID` | directory (tenant) ID |
| `AZURE_SUBSCRIPTION_ID` | subscription holding both storage accounts |
| `GH_RELEASE_LANES_ENABLED` | leave unset until cutover; `true` switches the dev lanes on |

These are identifiers, not credentials. There is no Azure secret: the lanes
authenticate with OIDC federation, which is why the app registration needs
federated credentials for `repo:clingfy/clingfy-app:ref:refs/heads/develop` and
for the `production` environment.

### 2. Repository secrets

Each is the base64 of a file that used to live in the Azure Library as a secure
file. Encode with `base64 -i <file> | pbcopy` on macOS.

| secret | was |
|---|---|
| `ENV_DEV_B64` | `.env.dev` |
| `ENV_PROD_B64` | `.env.prod` |
| `APPLE_CERT_P12_B64` | `Certificates.p12` |
| `APPLE_CERT_PASSWORD` | `CERT_PASSWORD` (was read out of `.env` and re-exported inline) |
| `APPLE_PROFILE_DEV_B64` | `Clingfy_Dev_Distribution.mobileprovision` |
| `APPLE_PROFILE_PROD_B64` | `Clingfy_Distribution.mobileprovision` |
| `APPLE_NOTARY_KEY_B64` | `AuthKey_*.p8` |
| `SPARKLE_KEY_B64` | `SparkleKey` |

The `.env` files still carry the rest of the surface (Sentry, Telegram, PostHog,
notary IDs, storage account names), so the list stops here.

> This repository is public. GitHub does not expose secrets to workflows
> triggered by a `pull_request` from a fork, and the release lanes deliberately
> trigger only on `push` to `develop` and on manual dispatch. **Never add a
> `pull_request_target` trigger to a workflow that can read these secrets.**

### 3. The `production` environment

Scope `ENV_PROD_B64` and the Apple prod profile to it, and **add a required
reviewer**. A workflow that names an environment creates it automatically with
*no* protection rules, so the approval gate does not exist until it is added by
hand. Without it, `environment: production` buys nothing.

## Cutover order

Each phase is independently revertible, and the Azure lanes stay on disk and
functional throughout.

1. **Plumbing.** Run `Release plumbing check` for `dev` with `write_probe`
   enabled, then for `prod`. Green means OIDC, the federated subject and the
   Storage Blob Data Contributor role assignments are all correct. A failure
   here is cheap; the same failure inside a real lane surfaces forty minutes
   into a macOS build.
2. **Windows dev.** Disable the Azure `windows-dev-channel` trigger, set
   `GH_RELEASE_LANES_ENABLED=true`, push to `develop`. Confirm on a real test box
   that auto-update still resolves — that is the check that matters, not a green
   tick.
3. **macOS dev.** Disable the Azure `dev-channel` trigger. Compare the
   `codesign -dvvv`, `spctl -a -vvv` and `stapler validate` output printed by
   the "Signing evidence" step against an Azure-built app. They must match.
4. **Both prod lanes.** Only after 2 and 3 have run green repeatedly. Dry-run
   against a throwaway version number first.
5. **Decommission.** Delete `azure-pipelines/`, repoint
   `test/tooling/flutter_pin_consistency_test.dart` at a new source of truth for
   the Flutter pin, then set the Azure DevOps organization's purchased parallel
   jobs to zero. **The billing stops at that last step and only there** —
   deleting the YAML on its own saves nothing.

Do not run an Azure lane and its GitHub counterpart against the same channel at
once. They would not silently collide (the version-exists guard fails the second
one) but it wastes a debugging session on a red build with a boring cause.

## Two things that behave differently

**Build numbers.** Azure used `counter()` for the Windows dev channel and the
org-wide `$(Build.BuildId)` everywhere else. GitHub has neither.
`github.run_number` is per-workflow and starts at 1, so each lane offsets it by a
seed and then checks the result against what the live feed actually advertises,
failing before the build if it is not strictly greater. This matters more than
it looks: publish a number lower than what a tester already has and their client
silently stops updating — no error, on their machine, invisible here. The seeds
live at the top of each "Resolve … build number" step. Raise them, never lower
them, and raise them if a workflow file is ever renamed, because that resets
`run_number` to 1.

**`ALLOW_OVERWRITE`.** The Azure prod lane kept it in a variable group and
reached back into the ADO API to reset it to `false` after each run, so the
escape hatch could not be left switched on. The GitHub lane takes it as a
`workflow_dispatch` boolean, which is single-use by construction. The reset
logic is deliberately not ported.

## Rolling back

Unset `GH_RELEASE_LANES_ENABLED` and re-enable the Azure trigger. That is the
whole rollback for the dev lanes; for prod, simply do not dispatch the GitHub
workflow. Nothing in this change deletes or edits an Azure lane.
