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

### `feature/*`
Short-lived branches for new feature work.

Examples:
- `feature/timeline-zoom-editor`
- `feature/camera-overlay-squircle`

### `bugfix/*`
Short-lived branches for normal development bug fixes.

Examples:
- `bugfix/mic-monitor-collapse-state`
- `bugfix/timeline-scrub-jump`

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
feature/my-feature -> develop
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
bugfix/release-issue -> release/x.y.z
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

* `feature/* -> develop` → usually **Squash and merge**
* `bugfix/* -> develop` → usually **Squash and merge**
* `release/x.y.z -> main` → usually **Rebase and merge**
* `release/x.y.z -> develop` → usually **Rebase and merge**
* `hotfix/* -> main` → usually **Rebase and merge**
* `hotfix/* -> develop` → usually **Rebase and merge**

If GitHub cannot rebase automatically because of conflicts, resolve the rebase locally, push the updated branch, and then complete the PR.

---

## Decision guide

### New feature?

Branch from `develop`.

### Normal bug in unreleased development work?

Branch from `develop`.

### Release blocker found before shipping?

Branch from `release/x.y.z`.

### Production bug found after shipping?

Branch from `main`.

---

## Summary

```text
feature/*  -> develop
bugfix/*   -> develop

develop -> release/x.y.z

release-only fixes:
bugfix/release-* -> release/x.y.z

release/x.y.z -> main
release/x.y.z -> develop

post-release production fixes:
hotfix/x.y.z -> main
hotfix/x.y.z -> develop