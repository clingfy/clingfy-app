import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/startup_recovery_notice.dart';
import 'package:clingfy/core/models/startup_recovery_report.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.4: the pure salvage-notice decision (resolve_toolbar_notice
/// precedent — the full HomePage harness is part of the pre-existing
/// FluentLocalizations breakage, so the logic is extracted and tested
/// without a widget tree).
void main() {
  String message(int count) => '$count recording(s) interrupted';

  test('no report (macOS / native failure) produces no notice', () {
    expect(
      buildStartupRecoveryNotice(null, interruptedMessage: message),
      isNull,
    );
  });

  test('cleanup-only report produces no notice (log-only)', () {
    const report = StartupRecoveryReport(
      interruptedProjects: [],
      cleanedTempFileCount: 12,
      cleanedTempBytes: 1024 * 1024,
    );

    expect(
      buildStartupRecoveryNotice(report, interruptedMessage: message),
      isNull,
    );
  });

  test('interrupted recordings produce a warning-tone notice with the '
      'plural-aware message', () {
    const report = StartupRecoveryReport(
      interruptedProjects: [
        InterruptedRecordingProject(
          projectPath: r'C:\rec\a.clingfyproj',
          sessionId: 'rec_a',
        ),
        InterruptedRecordingProject(
          projectPath: r'C:\rec\b.clingfyproj',
          sessionId: 'rec_b',
        ),
      ],
      cleanedTempFileCount: 0,
      cleanedTempBytes: 0,
    );

    final notice = buildStartupRecoveryNotice(
      report,
      interruptedMessage: message,
    );

    expect(notice, isNotNull);
    expect(notice!.message, '2 recording(s) interrupted');
    expect(notice.tone, HomeUiNoticeTone.warning);
    // Warning notices stay until dismissed — same as 10.2 recording
    // warnings (HomeUiState gives warnings no auto-dismiss).
    expect(notice.autoDismissAfter, isNull);
  });
}
