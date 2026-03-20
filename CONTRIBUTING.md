# Contributing

Thanks for your interest in contributing to Clingfy.

## Before you start

- For larger changes, open an issue or discussion before investing in implementation work.
- Never commit secrets, local environment files, signing assets, or generated release artifacts.
- Keep pull requests focused and easy to review.

## Local setup

```bash
flutter pub get
flutter analyze
flutter test
````

For macOS-specific work, use the flavor-aware build commands:

```bash
flutter build macos --flavor dev
flutter build macos --flavor prod
```

Additional development notes are available in [docs/development.md](docs/development.md).

## Branching and release flow

Clingfy uses a structured branching model for development, release stabilization, and production hotfixes.

See [docs/branching-strategy.md](docs/branching-strategy.md) for:

* branch roles and naming
* where to branch from for features, release fixes, and hotfixes
* pull request targets
* merge strategy expectations

## Pull request expectations

* Keep refactors separate from feature work when possible.
* Add or update tests when behavior changes.
* Run `flutter analyze` and `flutter test` before opening a PR.
* If your change touches native macOS code or release tooling, also run the relevant macOS build or explain why you could not.

## Coding and review expectations

* Follow the existing project structure and boundary intent:

  * `lib/core` for reusable recorder and domain logic
  * `lib/app` for the product shell and workflow
  * `lib/commercial` for client-side licensing and monetization
  * `lib/ui` for shared UI primitives
* Avoid introducing secrets or environment-specific values into tracked files.
* Prefer focused, low-risk changes over broad rewrites.

## Contribution licensing

By submitting a contribution to this repository, you agree that your contribution will be licensed under the repository’s GPL-3.0-or-later terms.