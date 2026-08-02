import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The crash-reporting disclosure must be shown ONCE and must record that it
/// was shown regardless of which button the user pressed.
///
/// It moved off app-launch and onto the first successful export: a modal about
/// diagnostics in front of someone who has not used the app yet gets dismissed
/// unread, which makes the disclosure worthless. That change makes the
/// once-only guarantee matter more, not less — the trigger now repeats (every
/// export) where launch happened once per session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CrashReportingConsent.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  // THE REGRESSION THIS GUARDS. The old trigger fired once per launch; the new
  // one sits on a path the user hits repeatedly. If `noticeSeen` were not
  // persisted, the dialog would reappear after EVERY export.
  test('a seen notice stays seen across restarts', () async {
    await CrashReportingConsent.load();
    expect(CrashReportingConsent.noticeSeen, isFalse);

    await CrashReportingConsent.markNoticeSeen();

    CrashReportingConsent.resetForTesting();
    await CrashReportingConsent.load();
    expect(
      CrashReportingConsent.noticeSeen,
      isTrue,
      reason: 'the notice would re-prompt after every export',
    );
  });

  // Dismissing without choosing still counts as shown. Being asked again and
  // again until you pick "yes" is its own dark pattern, and the user has read
  // it either way.
  test('acknowledging leaves reporting enabled', () async {
    await CrashReportingConsent.load();
    await CrashReportingConsent.markNoticeSeen();
    expect(CrashReportingConsent.enabled, isTrue);
    expect(CrashReportingConsent.noticeSeen, isTrue);
  });

  // The opt-out path from the dialog: seen AND disabled, and the choice
  // survives, because the whole point is that acting on the disclosure costs
  // nothing.
  test('opting out from the notice persists both facts', () async {
    await CrashReportingConsent.load();
    await CrashReportingConsent.markNoticeSeen();
    await CrashReportingConsent.setEnabled(false);

    CrashReportingConsent.resetForTesting();
    await CrashReportingConsent.load();
    expect(CrashReportingConsent.noticeSeen, isTrue);
    expect(CrashReportingConsent.enabled, isFalse);
  });

  // A fresh install has not been told anything yet — so the notice is still
  // owed, which is what the export path checks before showing it.
  test('a fresh install still owes the notice', () async {
    await CrashReportingConsent.load();
    expect(CrashReportingConsent.noticeSeen, isFalse);
  });
}
