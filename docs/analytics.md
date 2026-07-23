# Analytics

Clingfy sends a small set of **anonymous product-usage events** to PostHog (EU cloud) so we can
see whether features work and get used — the desktop counterpart of the website analytics. It is
deliberately minimal, and separate from crash reporting (Sentry).

## Privacy posture

- **Anonymous.** No account, email, or name. The identifier is a random per-install UUID stored
  locally; PostHog person profiles are suppressed (`$process_person_profile: false`).
- **No content, ever.** Recordings, filenames, paths, window titles, transcripts, and license
  keys are never sent — a hard-coded key blocklist strips them before an event leaves the machine.
- **Structure only.** Events carry counts, ids, durations, platform, and app version — never what
  you recorded.
- **Silent in debug.** Debug builds (`flutter run`) emit nothing.
- **Opt-out.** Settings → Diagnostics → **"Share anonymous usage analytics"** turns it off
  completely.
- **No token, no analytics.** Capture uses a public-class PostHog ingestion token supplied at
  build time via the `POSTHOG_TOKEN` define. Without it the service is a silent no-op.

## Events

Names follow `category:object_action` (lowercase snake). Today:

- `desktop:app_launch`
- `recording:session_start` / `recording:session_complete` / `recording:session_fail`
- `export:job_start` / `export:job_complete` / `export:job_fail`
- `billing:paywall_view`

Full catalog: `lib/app/infrastructure/analytics/analytics_events.dart`.
Implementation: `lib/app/infrastructure/analytics/analytics_service.dart`.

## Environment

Every event carries `environment` = `production` or `development`, derived from the `APP_ENV`
build define (`BuildConfig.isProd()`). Dev and local builds land under `development` so they never
mix into production numbers.

## Excluding your own devices + verifying the pipeline (owner / dev)

Two owner/dev-only modes keep your own testing out of the real numbers and let you fire events on
purpose. They are **runtime**, set on **your** machine — never baked into a build or shipped, and
they mirror the websites' `?clingfy_internal=1` / `?clingfy_test=1` device flags.

- **Mark this device internal** → events carry `is_internal`, which the dashboards exclude. Your
  own installs then stop inflating the stats.
- **Test analytics** → events additionally carry `is_test` (which implies internal, so they never
  reach real numbers) and capture runs **even in debug**, so you can verify the pipeline from
  `flutter run`.

Two ways to turn them on:

1. **In-app** — Settings → Diagnostics → "Mark this device internal" / "Test analytics". These
   controls are hidden from normal users: they appear in debug builds, when an env var (below) is
   set, once a toggle has been turned on, or after **tapping the "Diagnostics" title seven times**
   (the reveal for a shipped release build that has no env var — e.g. a macOS app launched from
   Finder, which does not inherit shell environment variables).
2. **Environment variable** (your machine only; then fully quit and relaunch the app):
   - Windows (PowerShell): `setx CLINGFY_INTERNAL 1` (and/or `setx CLINGFY_ANALYTICS_TEST 1`).
   - macOS: `launchctl setenv CLINGFY_INTERNAL 1` (and/or `CLINGFY_ANALYTICS_TEST`).

> Do **not** put `CLINGFY_INTERNAL` / `CLINGFY_ANALYTICS_TEST` into a build/env file: those feed
> every build, so they would mark all users internal — and they are read from the OS process
> environment at runtime, not from a build define, so they would have no effect there anyway.
