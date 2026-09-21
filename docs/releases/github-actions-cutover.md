# Release lanes on GitHub Actions — cutover runbook

The four release lanes in `azure-pipelines/` now have GitHub Actions
counterparts in `.github/workflows/`. Both sets exist side by side. **Nothing
has been cut over**: the new dev lanes are switched off, the new prod lanes are
manual-only, and the Azure lanes are untouched and still authoritative.

| lane | Azure Pipelines (retired) | GitHub Actions | trigger |
|---|---|---|---|
| macOS dev | `dev-channel.yml` | `release-macos-dev.yml` | push to `develop`, gated by a variable |
| Windows dev | `windows-dev-channel.yml` | `release-windows-dev.yml` | push to `develop` (path-scoped), gated by a variable |
| macOS prod | `release-prod.yml` | `release-macos-prod.yml` | manual, `release/*` only |
| Windows prod | `windows-release-prod.yml` | `release-windows-prod.yml` | manual, `release/*` only |
| — | — | `release-plumbing.yml` | manual; OIDC + S3 access check — keep it, run it before a prod release |

The release scripts under `ops/release/` were unchanged by the harness swap —
they already ran off a maintainer's laptop, so that step was a harness swap, not
a rewrite. They did change later, when the storage moved off Azure: publishing
now dispatches on `RELEASE_STORAGE_PROVIDER` (which defaults to `aws` for both
`dev` and `prod`) through `ops/release/lib/aws.sh`. Note that
`ops/release/05_publish.sh` and `ops/release/windows/04_publish.ps1`
kept their original filenames and are still the live publishers — the workflows
invoke them by path, so do not "fix" the names.

## One-time setup

### 1. Repository variables (Settings → Secrets and variables → Actions → Variables)

| variable | scope | value |
|---|---|---|
| `AWS_RELEASE_ROLE_ARN` | environment `development` / `production` | that channel's publish role, e.g. `arn:aws:iam::422661068605:role/clingfy-labs-prod-desktop-release` |
| `AWS_REGION` | environment `development` / `production` | `eu-west-1` |
| `GH_RELEASE_LANES_ENABLED` | repository | `true` since the dev cutover; unsetting it switches both dev lanes off |

These are identifiers, not credentials. There is no stored cloud key: the lanes
authenticate with GitHub OIDC, so what matters is the AWS role's trust policy,
which matches on the **environment** subject —
`repo:clingfy/clingfy-app:environment:development` and
`…:environment:production`, not a ref. That is why every lane declares an
`environment:`; without it the token carries the ref instead and the assume-role
fails with a message that never mentions environments.

Because the role ARNs are environment-scoped, a repository-scope lookup
(`gh variable list`) shows neither of them — that is expected, not a missing
variable. The three original Azure identifiers (`AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) do still exist at repository scope,
but no workflow reads them any more; they are dead config and can be deleted.

### 2. Environment secrets

These are **not** repository secrets: they live on the `development` and
`production` environments (a repository-scope `gh secret list` returns nothing).
Each environment carries its own `ENV_*_B64` and Apple profile, plus the shared
Apple and Sparkle secrets.

Each is the base64 of a file that used to live in the Azure DevOps Library as a
secure file. Encode with `base64 -i <file> | pbcopy` on macOS, or
`[Convert]::ToBase64String([IO.File]::ReadAllBytes('<file>')) | Set-Clipboard` in
PowerShell.

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
notary IDs, and the AWS side: releases bucket, CloudFront distribution ID and the
public `/updates` endpoint), so the list stops here.

> This repository is public. GitHub does not expose secrets to workflows
> triggered by a `pull_request` from a fork, and the release lanes deliberately
> trigger only on `push` to `develop` and on manual dispatch. **Never add a
> `pull_request_target` trigger to a workflow that can read these secrets.**

### 3. The `production` environment

Both environments were created on 2026-09-15, and `ENV_PROD_B64`, the Apple prod
profile and `AWS_RELEASE_ROLE_ARN` are scoped to `production`. The **required
reviewer was never added**: verified 2026-09-20,
`gh api repos/clingfy/clingfy-app/environments` returns `protection_rules: []`
for both. A workflow that names an environment creates it automatically with *no*
protection rules, so the approval gate does not exist until it is added by hand,
and required reviewers are free on a public repo. Until then
`environment: production` still buys the OIDC subject and the scoped secrets —
but no approval gate, so the real restrictions on the prod lanes are manual
dispatch, the `release/*` ref check, and the AWS trust policy.

## Cutover order

Each phase was independently revertible *at the time*, while the Azure lanes were
still on disk and functional. That safety net is gone: Azure was decommissioned
on 2026-09-15 and there is nothing left to fall back to. Steps 1–3 are done,
step 4 has never run, step 5 is partly done — see each step.

1. **Plumbing.** ✅ Done — both channels green on 2026-09-16. Run
   `Release plumbing check (OIDC + bucket access)`
   (`.github/workflows/release-plumbing.yml`) for `dev` with `write_probe`
   enabled, then for `prod`, and re-run it before any prod release. Green means
   OIDC, the environment subject in the role's trust policy, and read+write on
   that channel's S3 `updates/` prefix are all correct. A failure here is cheap;
   the same failure inside a real lane surfaces forty minutes into a macOS build.
2. **Windows dev.** Disable the Azure `windows-dev-channel` trigger, set
   `GH_RELEASE_LANES_ENABLED=true`, push to `develop`. Confirm on a real test box
   that auto-update still resolves — that is the check that matters, not a green
   tick.
3. **macOS dev.** ✅ Done — first AWS-published dev build on 2026-09-16, live on
   `dev.clingfy.com/updates` with deltas working.
   `azure-pipelines/dev-channel.yml` is `trigger: none`. The "Signing evidence"
   step still prints `codesign -dvvv`, `spctl -a -vvv` and `stapler validate`;
   the comparison baseline is now the last known-good GitHub-built app, because
   no Azure-built app can be produced any more.
4. **Both prod lanes.** ⏳ Not run yet — 0 dispatches of `release-macos-prod.yml`
   and `release-windows-prod.yml` as of 2026-09-20; 1.1.0 will be the first real
   run for both. Steps 2 and 3 have now run green repeatedly, so the precondition
   is met. Dry-run against a throwaway version number first.
5. **Decommission.** ◑ Partly done. The money part is finished: purchased
   parallel jobs were set to zero on 2026-08-08 (see the header of
   `azure-pipelines/dev-channel.yml`), and Azure itself was decommissioned on
   2026-09-15. What remains is cosmetic — delete `azure-pipelines/` and repoint
   `test/tooling/flutter_pin_consistency_test.dart`, which still treats
   `azure-pipelines/flutter-version.yml` as the canonical Flutter pin and is the
   only reason that directory cannot simply be removed.

During the cutover the rule was: never run an Azure lane and its GitHub
counterpart against the same channel at once. They would not have silently
collided (the version-exists guard fails the second one) but it wasted a
debugging session on a red build with a boring cause. Moot now — the Azure lanes
cannot publish anywhere.

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

**There is no rollback to Azure.** That escape hatch existed only while both
systems were live. The release storage accounts were deleted on 2026-09-15, so
re-enabling an Azure trigger now just produces a lane that builds for forty
minutes and then fails at publish against a storage account whose hostname no
longer resolves.

The only rollback left is to unset `GH_RELEASE_LANES_ENABLED`, which stops both
dev lanes — and stops dev builds reaching testers entirely until it is set back
to `true`. For prod, simply do not dispatch the workflow. Forward, not back: fix
the GitHub lane.
