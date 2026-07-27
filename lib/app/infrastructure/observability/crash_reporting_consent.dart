import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/core/logging/logger_service.dart';

/// Whether the user lets Clingfy send crash and diagnostic reports.
///
/// This is deliberately NOT part of [SettingsController]. Sentry initialises
/// before the app — and before any controller exists — because a crash during
/// startup is exactly the crash worth catching. So the answer has to be
/// readable straight from [SharedPreferences] at that point.
///
/// Two pieces of state, and they are not the same question:
///   * [enabled] — may we report?
///   * [noticeSeen] — has the user been TOLD we report? Reporting without ever
///     having said so is the thing the disclosure exists to fix, so a build
///     that has never shown the notice is not in a good state even when
///     reporting is technically permitted.
///
/// DEFAULT IS OPT-OUT: reporting starts enabled and the first run explains it.
/// That is the weaker of the two models the beta checklist allows ("ship a
/// disclosure or an opt-out") and it is a product/legal call, not an
/// engineering one — see [kCrashReportingDefaultEnabled] to flip it to opt-in,
/// which is one constant and no other change.
class CrashReportingConsent {
  CrashReportingConsent._();

  /// Preference keys. Stable strings — renaming one silently resets every
  /// existing user's choice back to the default, which for an opt-OUT default
  /// means silently re-enabling reporting for someone who turned it off.
  @visibleForTesting
  static const String enabledKey = 'crashReportingEnabled';
  @visibleForTesting
  static const String noticeSeenKey = 'crashReportingNoticeSeen';

  /// What an undecided user gets.
  ///
  /// `true` = opt-out (report until told otherwise, disclose on first run).
  /// `false` = opt-in (report nothing until the user agrees).
  ///
  /// Flip this ONE constant for a consent-first jurisdiction; everything else
  /// already reads through it, and [ResolveEnabled] is tested against both.
  static const bool kCrashReportingDefaultEnabled = true;

  /// In-memory mirror, so `beforeSend` can consult it on every event without
  /// touching disk on a crash path. Seeded by [load].
  static bool _enabled = kCrashReportingDefaultEnabled;
  static bool _noticeSeen = false;
  static bool _loaded = false;

  static bool get enabled => _enabled;
  static bool get noticeSeen => _noticeSeen;

  /// True once [load] has run. Before that, [enabled] is only the default and
  /// must not be treated as the user's answer.
  static bool get isLoaded => _loaded;

  /// Pure: what an [enabled] value of `stored` means.
  ///
  /// Exposed because "absent means the default" is the rule that decides
  /// whether a brand-new install reports, and it should be pinned by a test
  /// rather than inferred from a `??`.
  @visibleForTesting
  static bool resolveEnabled(bool? stored) =>
      stored ?? kCrashReportingDefaultEnabled;

  /// Reads the stored choice. Call BEFORE initialising Sentry.
  ///
  /// Never throws: a preferences failure must not stop the app from starting,
  /// and it falls back to the default rather than to "report anyway".
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = resolveEnabled(prefs.getBool(enabledKey));
      _noticeSeen = prefs.getBool(noticeSeenKey) ?? false;
    } catch (e, st) {
      Log.e('Telemetry', 'Failed to read crash-reporting consent', e, st);
      _enabled = kCrashReportingDefaultEnabled;
      _noticeSeen = false;
    }
    _loaded = true;
  }

  /// Records the user's choice.
  ///
  /// Turning it OFF stops Dart-side events immediately (`beforeSend` reads the
  /// in-memory flag). The native crash handler is installed at startup and
  /// cannot be uninstalled, so native crash capture stops at the next launch —
  /// the settings copy says exactly that rather than implying otherwise.
  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, value);
    } catch (e, st) {
      Log.e('Telemetry', 'Failed to persist crash-reporting consent', e, st);
    }
  }

  /// Marks the first-run disclosure as shown.
  static Future<void> markNoticeSeen() async {
    _noticeSeen = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(noticeSeenKey, true);
    } catch (e, st) {
      Log.e('Telemetry', 'Failed to persist the crash-reporting notice', e, st);
    }
  }

  /// Test seam: restore process state to a fresh install.
  @visibleForTesting
  static void resetForTesting() {
    _enabled = kCrashReportingDefaultEnabled;
    _noticeSeen = false;
    _loaded = false;
  }

  /// Test seam: force in-memory state without touching preferences.
  @visibleForTesting
  static void debugSetState({required bool enabled, required bool noticeSeen}) {
    _enabled = enabled;
    _noticeSeen = noticeSeen;
    _loaded = true;
  }
}
