import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/core/models/startup_recovery_report.dart';

/// Phase 10.4: decides what (if anything) to surface after the native
/// startup crash-recovery sweep.
///
/// Pure on purpose — testable without the HomeScope/widget harness
/// (resolve_toolbar_notice_test.dart precedent). Interrupted recordings
/// warrant a warning; paused recordings whose parts were joined at launch
/// get an info notice that can open the most recent one. Temp-file cleanup
/// alone is log-only.
HomeUiNotice? buildStartupRecoveryNotice(
  StartupRecoveryReport? report, {
  required String Function(int count) interruptedMessage,
  String Function(int count)? repairedMessage,
  HomeUiNoticeAction? Function(String projectPath)? openRepaired,
}) {
  if (report == null) return null;
  if (report.hasInterruptedProjects) {
    return HomeUiNotice(
      message: interruptedMessage(report.interruptedProjects.length),
      tone: HomeUiNoticeTone.warning,
    );
  }
  if (report.hasRepairedProjects && repairedMessage != null) {
    return HomeUiNotice(
      message: repairedMessage(report.repairedProjects.length),
      tone: HomeUiNoticeTone.info,
      // Project folders are named by date, so the last is the newest.
      action: openRepaired?.call(([...report.repairedProjects]..sort()).last),
    );
  }
  return null;
}
