import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/core/models/startup_recovery_report.dart';

/// Phase 10.4: decides what (if anything) to surface after the native
/// startup crash-recovery sweep.
///
/// Pure on purpose — testable without the HomeScope/widget harness
/// (resolve_toolbar_notice_test.dart precedent). Only interrupted
/// recordings warrant a toast; temp-file cleanup alone is log-only.
HomeUiNotice? buildStartupRecoveryNotice(
  StartupRecoveryReport? report, {
  required String Function(int count) interruptedMessage,
}) {
  if (report == null || !report.hasInterruptedProjects) {
    return null;
  }
  return HomeUiNotice(
    message: interruptedMessage(report.interruptedProjects.length),
    tone: HomeUiNoticeTone.warning,
  );
}
