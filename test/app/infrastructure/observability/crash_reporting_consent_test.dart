import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Crash reporting is the one setting where a silent regression means data
/// leaves a user's machine after they asked it not to. These pin the rules
/// rather than leaving them to a `??`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CrashReportingConsent.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  group('the undecided default', () {
    // A brand-new install has no stored value. What that means IS the product
    // decision — opt-out today — and it must be stated in one place.
    test('an absent preference resolves to the declared default', () {
      expect(
        CrashReportingConsent.resolveEnabled(null),
        CrashReportingConsent.kCrashReportingDefaultEnabled,
      );
    });

    // Flipping the constant to opt-in must need no other change, so both
    // branches are pinned independently of which one is currently shipping.
    test('a stored value always wins over the default', () {
      expect(CrashReportingConsent.resolveEnabled(true), isTrue);
      expect(CrashReportingConsent.resolveEnabled(false), isFalse);
    });

    test('a fresh install has not seen the notice', () async {
      await CrashReportingConsent.load();
      expect(CrashReportingConsent.noticeSeen, isFalse);
      expect(
        CrashReportingConsent.enabled,
        CrashReportingConsent.kCrashReportingDefaultEnabled,
      );
      expect(CrashReportingConsent.isLoaded, isTrue);
    });
  });

  group('persistence', () {
    // THE one that matters: a user who turned reporting off must still have it
    // off after a restart. A key rename or a bad default silently re-enables
    // reporting for exactly the person who opted out.
    test('an opt-out survives a restart', () async {
      await CrashReportingConsent.load();
      await CrashReportingConsent.setEnabled(false);
      expect(CrashReportingConsent.enabled, isFalse);

      // Simulate a fresh process against the same stored preferences.
      CrashReportingConsent.resetForTesting();
      expect(
        CrashReportingConsent.enabled,
        CrashReportingConsent.kCrashReportingDefaultEnabled,
        reason: 'reset should return to the default before loading',
      );

      await CrashReportingConsent.load();
      expect(
        CrashReportingConsent.enabled,
        isFalse,
        reason: 'the stored opt-out was lost across a restart',
      );
    });

    test('an opt-in survives a restart', () async {
      await CrashReportingConsent.load();
      await CrashReportingConsent.setEnabled(true);

      CrashReportingConsent.resetForTesting();
      await CrashReportingConsent.load();
      expect(CrashReportingConsent.enabled, isTrue);
    });

    test('the notice is only shown once', () async {
      await CrashReportingConsent.load();
      expect(CrashReportingConsent.noticeSeen, isFalse);

      await CrashReportingConsent.markNoticeSeen();
      expect(CrashReportingConsent.noticeSeen, isTrue);

      CrashReportingConsent.resetForTesting();
      await CrashReportingConsent.load();
      expect(CrashReportingConsent.noticeSeen, isTrue);
    });

    // Seeing the disclosure is not the same as agreeing to it. Acknowledging
    // must not quietly re-enable reporting for someone who turned it off.
    test('marking the notice seen does not change the choice', () async {
      await CrashReportingConsent.load();
      await CrashReportingConsent.setEnabled(false);
      await CrashReportingConsent.markNoticeSeen();
      expect(CrashReportingConsent.enabled, isFalse);
    });

    // The stored keys are load-bearing: renaming one resets every existing
    // user to the default, which under an opt-OUT default means re-enabling
    // reporting for people who opted out.
    test('writes the documented preference keys', () async {
      await CrashReportingConsent.load();
      await CrashReportingConsent.setEnabled(false);
      await CrashReportingConsent.markNoticeSeen();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(CrashReportingConsent.enabledKey), isFalse);
      expect(prefs.getBool(CrashReportingConsent.noticeSeenKey), isTrue);
    });

    test('reads a pre-existing stored opt-out on first load', () async {
      SharedPreferences.setMockInitialValues({
        CrashReportingConsent.enabledKey: false,
        CrashReportingConsent.noticeSeenKey: true,
      });
      await CrashReportingConsent.load();
      expect(CrashReportingConsent.enabled, isFalse);
      expect(CrashReportingConsent.noticeSeen, isTrue);
    });
  });

  group('runtime behaviour', () {
    // The in-memory flag is what `beforeSend` consults on every event, so a
    // mid-session opt-out has to take effect without waiting for the write.
    test('setEnabled updates the in-memory flag before the write settles', () {
      CrashReportingConsent.debugSetState(enabled: true, noticeSeen: true);
      // Deliberately not awaited: this is the ordering `beforeSend` relies on.
      CrashReportingConsent.setEnabled(false);
      expect(CrashReportingConsent.enabled, isFalse);
    });
  });
}
