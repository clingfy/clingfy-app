/// Product-analytics event names (PostHog). Naming: `category:object_action`, lowercase snake —
/// names are effectively immutable once events exist, so add new names rather than renaming.
/// The desktop records only what the backend cannot observe (recordings, exports, paywall views);
/// backend outcomes (purchases, license fulfilment) are captured server-side. Taxonomy of record:
/// clingfy-labs `docs/runbooks/analytics-posthog.md`.
abstract final class AnalyticsEvents {
  static const String appLaunch = 'desktop:app_launch';

  static const String recordingSessionStart = 'recording:session_start';
  static const String recordingSessionComplete = 'recording:session_complete';
  static const String recordingSessionFail = 'recording:session_fail';

  static const String exportJobStart = 'export:job_start';
  static const String exportJobComplete = 'export:job_complete';
  static const String exportJobFail = 'export:job_fail';

  static const String billingPaywallView = 'billing:paywall_view';
}
