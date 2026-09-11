# Branching Strategy

This document defines the branching and release workflow for Clingfy.

## Branch roles

### `develop`
The main integration branch for active development.

Use `develop` for:
- new features
- normal bug fixes
- refactors
- ongoing integration work

### `main`
The stable production branch.

Use `main` for:
- shipped release history
- production-ready code
- hotfix integration for already released versions

### `release/x.y.z`
A short-lived stabilization branch for a specific release.

Examples:
- `release/1.0.0`
- `release/1.0.1`

Use a release branch for:
- release-only bug fixes
- packaging or signing issues
- version validation
- final QA and release readiness work

### Short-lived work branches

Name a work branch `<type>/<short-description>`, where `<type>` is the same
conventional-commit type the branch's commits will use. Keeping the two aligned
means the branch name already says what the squashed commit will say.

| Prefix | For | Example |
|---|---|---|
| `feat/` | New feature work | `feat/timeline-zoom-editor` |
| `fix/` | Bug fixes in unreleased development work | `fix/timeline-scrub-jump` |
| `docs/` | Documentation only | `docs/windows-port-inventory` |
| `chore/` | Repo hygiene, tooling, dependencies | `chore/bump-flutter-3-44` |
| `refactor/` | Behaviour-preserving restructuring | `refactor/editor-state` |
| `test/` | Test-only work | `test/camera-export-parity` |
| `ci/` | Pipeline and workflow changes | `ci/windows-path-filters` |

Anything else conventional commits allows (`perf/`, `style/`, `revert/`) is fine
on the same rule.

`feature/` and `bugfix/` are the older long forms of `feat/` and `fix/`. Both
appear in history and neither is wrong; new branches should use the short form
so branch prefixes and commit types match. Do not rename existing branches to
suit this — an open PR's branch name is not worth a force-push.

### `hotfix/*`
Short-lived branches for production fixes after a release has already shipped.

Examples:
- `hotfix/1.0.1`
- `hotfix/startup-crash`

---

## Standard flow

### Feature work
Branch from `develop` and merge back into `develop`.

```text
feat/my-feature -> develop
````

### Release preparation

When `develop` is stable enough, create a release branch from `develop`.

```text
develop -> release/x.y.z
```

After the release branch is created:

* stop adding unrelated features
* accept only release-safe fixes
* validate and ship from the release branch

### Bug found before release

If a bug is found while preparing a release, fix it on the release branch.

```text
fix/release-issue -> release/x.y.z
```

### Completing a release

After the release ships, merge the release branch back into:

```text
release/x.y.z -> main
release/x.y.z -> develop
```

This ensures that both production and ongoing development receive the release fixes.

### Bug found after release

If a bug is discovered in a shipped version, create a hotfix branch from `main`.

```text
hotfix/x.y.z -> main
hotfix/x.y.z -> develop
```

Do not start production hotfixes from `develop`, because it may already contain unreleased work.

---

## Merge strategy

Protected branches are expected to keep a linear history.

Recommended merge methods:

* any work branch (`feat/`, `fix/`, `docs/`, `chore/`, …) `-> develop` → usually **Squash and merge**
* `release/x.y.z -> main` → usually **Rebase and merge**
* `release/x.y.z -> develop` → usually **Rebase and merge**
* `hotfix/* -> main` → usually **Rebase and merge**
* `hotfix/* -> develop` → usually **Rebase and merge**

If GitHub cannot rebase automatically because of conflicts, resolve the rebase locally, push the updated branch, and then complete the PR.

---

## Decision guide

### New feature?

Branch from `develop` as `feat/*`.

### Normal bug in unreleased development work?

Branch from `develop` as `fix/*`.

### Docs, tooling, or repo hygiene?

Branch from `develop` as `docs/*` or `chore/*`.

### Release blocker found before shipping?

Branch from `release/x.y.z` as `fix/*`.

### Production bug found after shipping?

Branch from `main` as `hotfix/*`. Never from `develop` — it may already carry
unreleased work.

---

## Summary

```text
feat/*   -> develop
fix/*    -> develop
docs/*   -> develop
chore/*  -> develop

develop -> release/x.y.z

release-only fixes:
fix/release-* -> release/x.y.z

release/x.y.z -> main
release/x.y.z -> develop

post-release production fixes:
hotfix/x.y.z -> main
hotfix/x.y.z -> develop