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
    final resolved = l10n ?? lookupAppLocalizations(const Locale('en'));

    switch (key) {
      case NativeUIStringKey.menuStartRecording:
        return resolved.menuStartRecording;
      case NativeUIStringKey.menuStopRecording:
        return resolved.menuStopRecording;
      case NativeUIStringKey.menuOpenApp:
        return resolved.menuOpenApp;
      case NativeUIStringKey.menuQuit:
        return resolved.menuQuit;
      case NativeUIStringKey.accessibilityStartRecording:
        return resolved.menuStartRecording;
      case NativeUIStringKey.accessibilityStopRecording:
        return resolved.menuStopRecording;
      case NativeUIStringKey.recordingSelectedMicFallbackWarning:
        return resolved.recordingSelectedMicFallbackWarning;
      case NativeUIStringKey.recordingSelectedMicFallbackFailure:
        return resolved.recordingSelectedMicFallbackFailure;
      case NativeUIStringKey.preRecordingBarDisplay:
        return resolved.display;
      case NativeUIStringKey.preRecordingBarWindow:
        return resolved.window;
      case NativeUIStringKey.preRecordingBarArea:
        return resolved.area;
      case NativeUIStringKey.preRecordingBarCamera:
        return resolved.camera;
      case NativeUIStringKey.preRecordingBarMic:
        return resolved.mic;
      case NativeUIStringKey.preRecordingBarSystem:
        return resolved.system;
      case NativeUIStringKey.preRecordingBarUpdate:
        return resolved.update;
      case NativeUIStringKey.preRecordingBarPause:
        return resolved.pause;
      case NativeUIStringKey.preRecordingBarResume:
        return resolved.resume;
      case NativeUIStringKey.preRecordingBarNone:
        return resolved.none;
      case NativeUIStringKey.preRecordingBarRefresh:
        return resolved.storageRefresh;
      case NativeUIStringKey.preRecordingBarSelectDisplay:
        return resolved.selectDisplay;
      case NativeUIStringKey.preRecordingBarSelectWindow:
        return resolved.selectWindow;
      case NativeUIStringKey.preRecordingBarSelectMicrophone:
        return resolved.selectMicrophone;
      case NativeUIStringKey.preRecordingBarSelectCamera:
        return resolved.selectCamera;
      case NativeUIStringKey.preRecordingBarUnknownDisplay:
        return resolved.unknownDisplay;
      case NativeUIStringKey.preRecordingBarUnknownWindow:
        return resolved.unknownWindow;
      case NativeUIStringKey.preRecordingBarUnknownMic:
        return resolved.unknownMic;
      case NativeUIStringKey.preRecordingBarUnknownCamera:
        return resolved.unknownCamera;
      case NativeUIStringKey.preRecordingBarNoCamera:
        return resolved.noCamera;
      case NativeUIStringKey.preRecordingBarDoNotRecordAudio:
        return resolved.doNotRecordAudio;
      case NativeUIStringKey.displayServiceScreen:
        return resolved.screen;
      case NativeUIStringKey.displayServiceApp:
        return resolved.app;
      case NativeUIStringKey.recordingIndicatorStopping:
        return resolved.stoppingEllipsis;
      case NativeUIStringKey.recordingIndicatorPauseRecording:
        return resolved.pauseRecording;
      case NativeUIStringKey.recordingIndicatorResumeRecording:
        return resolved.resumeRecording;
      case NativeUIStringKey.recordingIndicatorInProgressLabel:
        return resolved.recordingInProgressLabel;
      case NativeUIStringKey.recordingIndicatorPausedLabel:
        return resolved.recordingPausedLabel;
      case NativeUIStringKey.recordingIndicatorStoppingRecording:
        return resolved.stoppingRecording;
      case NativeUIStringKey.recordingIndicatorHelpPause:
        return resolved.recordingIndicatorHelpPause;
      case NativeUIStringKey.recordingIndicatorHelpResume:
        return resolved.recordingIndicatorHelpResume;
      case NativeUIStringKey.recordingIndicatorHelpStopping:
        return resolved.recordingIndicatorHelpStopping;
      default:
        return key;
    }
  }
}
