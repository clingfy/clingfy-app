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

  test('no report (native failure) produces no notice', () {
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

  group('paused recordings joined at launch', () {
    String repaired(int count) => '$count joined';

    test('produce an info notice that opens the newest one', () {
      const report = StartupRecoveryReport(
        interruptedProjects: [],
        cleanedTempFileCount: 0,
        cleanedTempBytes: 0,
        repairedProjects: [
          '/r/rec_2026-10-20_10-00-00_a.clingfyproj',
          '/r/rec_2026-10-24_09-00-00_b.clingfyproj',
          '/r/rec_2026-10-22_10-00-00_c.clingfyproj',
        ],
      );
      String? opened;

      final notice = buildStartupRecoveryNotice(
        report,
        interruptedMessage: message,
        repairedMessage: repaired,
        openRepaired: (path) =>
            HomeUiNoticeAction(label: 'Open', onPressed: () => opened = path),
      );

      expect(notice, isNotNull);
      expect(notice!.message, '3 joined');
      expect(notice.tone, HomeUiNoticeTone.info);
      notice.action!.onPressed();
      expect(opened, '/r/rec_2026-10-24_09-00-00_b.clingfyproj');
    });

    test('give way to interrupted recordings, which are worse news', () {
      const report = StartupRecoveryReport(
        interruptedProjects: [
          InterruptedRecordingProject(projectPath: '/r/x', sessionId: 'x'),
        ],
        cleanedTempFileCount: 0,
        cleanedTempBytes: 0,
        repairedProjects: ['/r/y'],
      );

      final notice = buildStartupRecoveryNotice(
        report,
        interruptedMessage: message,
        repairedMessage: repaired,
      );

      expect(notice!.tone, HomeUiNoticeTone.warning);
    });

    test('without a message for them, produce no notice', () {
      const report = StartupRecoveryReport(
        interruptedProjects: [],
        cleanedTempFileCount: 0,
        cleanedTempBytes: 0,
        repairedProjects: ['/r/y'],
      );

      expect(
        buildStartupRecoveryNotice(report, interruptedMessage: message),
        isNull,
      );
    });
  });
}
