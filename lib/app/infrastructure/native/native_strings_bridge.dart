import 'package:flutter/widgets.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/bridges/native_ui_string_keys.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';

/// Bridge for providing localized strings to native code.
///
/// Native code (macOS menu bar, etc.) can request localized strings
/// via the MethodChannel. This class handles those requests and
/// proactively pushes updated strings when the locale changes.
class NativeStringsBridge {
  final NativeBridge _nativeBridge;
  BuildContext? _context;
  Locale? _lastLocale;

  static final NativeStringsBridge _instance = NativeStringsBridge._internal();
  factory NativeStringsBridge() => _instance;

  NativeStringsBridge._internal() : _nativeBridge = NativeBridge.instance;

  /// Call this from the main app widget when context is available.
  /// Should be called after MaterialApp is built so AppLocalizations works.
  void attachContext(BuildContext context) {
    _context = context;
    _checkAndPushStrings();
  }

  /// Call this when the locale changes to push updated strings to native.
  void onLocaleChanged(BuildContext context) {
    _context = context;
    _checkAndPushStrings();
  }

  void _checkAndPushStrings() {
    final context = _context;
    if (context == null) return;

    final currentLocale = Localizations.localeOf(context);
    if (_lastLocale != currentLocale) {
      _lastLocale = currentLocale;
      pushStringsToNative();
    }
  }

  /// Pushes all native UI strings to the native side for caching.
  Future<void> pushStringsToNative() async {
    final context = _context;
    if (context == null) {
      Log.w('NativeStringsBridge', 'No context available, skipping push');
      return;
    }

    final strings = getLocalizedStrings(NativeUIStringKey.allKeys);
    try {
      await _nativeBridge.invokeMethod<void>('cacheLocalizedStrings', strings);
      Log.i(
        'NativeStringsBridge',
        'Pushed ${strings.length} strings to native',
      );
    } catch (e) {
      Log.e('NativeStringsBridge', 'Failed to push strings: $e');
    }
  }

  /// Returns a map of localized strings for the given keys.
  /// Falls back to English if localization is not available.
  Map<String, String> getLocalizedStrings(List<String> keys) {
    final context = _context;
    final l10n = context != null ? AppLocalizations.of(context) : null;

    final Map<String, String> result = {};
    for (final key in keys) {
      result[key] = _getLocalizedString(key, l10n);
    }
    return result;
  }

  String _getLocalizedString(String key, AppLocalizations? l10n) {
    // If l10n is null, return English fallback
    if (l10n == null) {
      return _getFallbackString(key);
    }

    switch (key) {
      case NativeUIStringKey.menuStartRecording:
        return l10n.menuStartRecording;
      case NativeUIStringKey.menuStopRecording:
        return l10n.menuStopRecording;
      case NativeUIStringKey.menuOpenApp:
        return l10n.menuOpenApp;
      case NativeUIStringKey.menuQuit:
        return l10n.menuQuit;
      case NativeUIStringKey.accessibilityStartRecording:
        return l10n.menuStartRecording;
      case NativeUIStringKey.accessibilityStopRecording:
        return l10n.menuStopRecording;
      case NativeUIStringKey.recordingSelectedMicFallbackWarning:
        return l10n.recordingSelectedMicFallbackWarning;
      case NativeUIStringKey.recordingSelectedMicFallbackFailure:
        return l10n.recordingSelectedMicFallbackFailure;
      default:
        return _getFallbackString(key);
    }
  }

  String _getFallbackString(String key) {
    switch (key) {
      case NativeUIStringKey.menuStartRecording:
        return 'Start Recording';
      case NativeUIStringKey.menuStopRecording:
        return 'Stop Recording';
      case NativeUIStringKey.menuOpenApp:
        return 'Open Clingfy';
      case NativeUIStringKey.menuQuit:
        return 'Quit Clingfy';
      case NativeUIStringKey.accessibilityStartRecording:
        return 'Start recording';
      case NativeUIStringKey.accessibilityStopRecording:
        return 'Stop recording';
      case NativeUIStringKey.recordingSelectedMicFallbackWarning:
        return 'Selected microphone couldn’t be used. Recording started with the system default microphone.';
      case NativeUIStringKey.recordingSelectedMicFallbackFailure:
        return 'Selected microphone couldn’t be used for recording. Choose another microphone or turn microphone recording off.';
      default:
        return key;
    }
  }
}
