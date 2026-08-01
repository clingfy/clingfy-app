import 'package:flutter/widgets.dart';

import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';

/// One-time disclosure that Clingfy sends crash reports, with an opt-out.
///
/// Sentry shipped without ever telling the user it was running, and a setting
/// nobody goes looking for is not a disclosure. This is the telling.
///
/// WHEN IT FIRES: after the user's FIRST SUCCESSFUL EXPORT — not at launch.
/// A modal about diagnostics is the wrong first thing to meet on opening an
/// app you have not used yet: the user has produced nothing, has no reason to
/// care, and the fastest way past it is to dismiss it unread, which makes the
/// disclosure worthless. After an export they have finished something, the
/// moment is calm, and the dialog is the only thing competing for attention.
///
/// The trade this accepts: a crash BEFORE the first export is reported without
/// the user having seen the notice. That window is real. It is bounded by the
/// privacy policy covering the same ground, by `sendDefaultPii = false`, and by
/// the notice arriving the first time the app produces anything at all — which
/// for a recorder is the first session that did any work.
Future<void> maybeShowCrashReportingNotice(BuildContext context) async {
  if (CrashReportingConsent.noticeSeen) return;
  if (!context.mounted) return;

  final l10n = AppLocalizations.of(context);
  if (l10n == null) return;

  final keepEnabled = await AppDialog.confirm(
    context,
    title: l10n.crashReportingNoticeTitle,
    message: l10n.crashReportingNoticeBody,
    confirmLabel: l10n.crashReportingNoticeAccept,
    cancelLabel: l10n.crashReportingNoticeOptOut,
  );

  // Recorded as SHOWN either way. Dismissing without choosing must not
  // re-prompt after every export — being asked repeatedly is its own dark
  // pattern, and the user has now seen it regardless of which button they hit.
  await CrashReportingConsent.markNoticeSeen();
  if (!keepEnabled) {
    await CrashReportingConsent.setEnabled(false);
  }
}
