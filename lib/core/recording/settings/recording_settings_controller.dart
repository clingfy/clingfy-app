import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';

class RecordingSettingsController extends ChangeNotifier {
  RecordingSettingsController({required NativeBridge nativeBridge})
    : _nativeBridge = nativeBridge;

  final NativeBridge _nativeBridge;
  static const String _prefExcludeRecorderAppFromCapture =
      'excludeRecorderAppFromCapture';
  static const String _prefExcludeMicFromSystemAudio =
      'excludeMicFromSystemAudio';
  static const String _prefMicEchoCancellationEnabled =
      'micEchoCancellationEnabled';

  bool _excludeRecorderAppFromCapture = false;
  // Defaults ON: "record my screen" implies recording what the screen plays.
  // Shipping this off meant a recording could silently omit system audio, and
  // the omission was only discoverable by inspecting the project bundle after
  // the fact — by which point the take is gone. Speaker users are warned
  // instead (see [RecordingController.systemAudioBleedRisk]), because the
  // speaker -> mic bleed path is the real hazard, not system audio itself.
  bool _systemAudioEnabled = true;
  bool _excludeMicFromSystemAudio = true;
  bool _micEchoCancellationEnabled = false;
  bool _autoStopEnabled = false;
  Duration _autoStopAfter = const Duration(minutes: 10);
  bool _countdownEnabled = false;
  int _countdownDuration = 3;
  int _captureFrameRate = 30;

  bool get excludeRecorderAppFromCapture => _excludeRecorderAppFromCapture;
  bool get systemAudioEnabled => _systemAudioEnabled;
  bool get excludeMicFromSystemAudio => _excludeMicFromSystemAudio;
  bool get micEchoCancellationEnabled => _micEchoCancellationEnabled;
  bool get autoStopEnabled => _autoStopEnabled;
  Duration get autoStopAfter => _autoStopAfter;
  bool get countdownEnabled => _countdownEnabled;
  int get countdownDuration => _countdownDuration;
  int get captureFrameRate => _captureFrameRate;

  Future<void> loadPreferences(SharedPreferences prefs) async {
    _autoStopEnabled = prefs.getBool('autoStopEnabled') ?? false;
    _autoStopAfter = Duration(minutes: prefs.getInt('autoStopMinutes') ?? 10);
    _countdownEnabled = prefs.getBool('countdownEnabled') ?? false;
    _countdownDuration = prefs.getInt('countdownDuration') ?? 3;
    _captureFrameRate = prefs.getInt('captureFrameRate') ?? 30;

    _excludeRecorderAppFromCapture =
        prefs.getBool(_prefExcludeRecorderAppFromCapture) ?? false;
    if (!prefs.containsKey(_prefExcludeRecorderAppFromCapture)) {
      try {
        _excludeRecorderAppFromCapture = await _nativeBridge
            .getExcludeRecorderApp();
        await prefs.setBool(
          _prefExcludeRecorderAppFromCapture,
          _excludeRecorderAppFromCapture,
        );
      } catch (e, st) {
        Log.e(
          'Settings',
          'Failed to migrate excludeRecorderApp from native',
          e,
          st,
        );
      }
    }
    try {
      await _nativeBridge.setExcludeRecorderApp(_excludeRecorderAppFromCapture);
    } catch (e, st) {
      Log.e('Settings', 'Failed to sync excludeRecorderApp to native', e, st);
    }

    _systemAudioEnabled = prefs.getBool('systemAudioEnabled') ?? true;

    _excludeMicFromSystemAudio =
        prefs.getBool(_prefExcludeMicFromSystemAudio) ?? true;
    if (!prefs.containsKey(_prefExcludeMicFromSystemAudio)) {
      try {
        _excludeMicFromSystemAudio =
            await _nativeBridge.invokeMethod<bool>(
              'getExcludeMicFromSystemAudio',
            ) ??
            true;
        await prefs.setBool(
          _prefExcludeMicFromSystemAudio,
          _excludeMicFromSystemAudio,
        );
      } catch (e, st) {
        Log.e(
          'Settings',
          'Failed to migrate excludeMicFromSystemAudio from native',
          e,
          st,
        );
      }
    }
    try {
      await _nativeBridge.invokeMethod<void>('setExcludeMicFromSystemAudio', {
        'exclude': _excludeMicFromSystemAudio,
      });
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to sync excludeMicFromSystemAudio to native',
        e,
        st,
      );
    }

    _micEchoCancellationEnabled =
        prefs.getBool(_prefMicEchoCancellationEnabled) ?? false;
    try {
      await _nativeBridge.invokeMethod<void>('setMicEchoCancellationEnabled', {
        'enabled': _micEchoCancellationEnabled,
      });
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to sync micEchoCancellationEnabled to native',
        e,
        st,
      );
    }

    notifyListeners();
  }

  Future<void> updateAutoStopEnabled(bool value) async {
    if (value == _autoStopEnabled) return;
    _autoStopEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool('autoStopEnabled', value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist auto-stop enabled setting', e, st);
    }
  }

  Future<void> updateAutoStopAfter(Duration value) async {
    if (value == _autoStopAfter) return;
    _autoStopAfter = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setInt('autoStopMinutes', value.inMinutes);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist auto-stop duration', e, st);
    }
  }

  Future<void> updateCountdownEnabled(bool value) async {
    if (value == _countdownEnabled) return;
    _countdownEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool('countdownEnabled', value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist countdown enabled setting', e, st);
    }
  }

  Future<void> updateCountdownDuration(int value) async {
    if (value == _countdownDuration) return;
    _countdownDuration = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setInt('countdownDuration', value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist countdown duration', e, st);
    }
  }

  Future<void> updateCaptureFrameRate(int value) async {
    if (value == _captureFrameRate) return;
    _captureFrameRate = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setInt('captureFrameRate', value);
      await _nativeBridge.invokeMethod<void>('setCaptureFrameRate', {
        'fps': value,
      });
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist/set capture frame rate', e, st);
    }
  }

  Future<void> updateExcludeRecorderAppFromCapture(bool value) async {
    if (value == _excludeRecorderAppFromCapture) return;
    _excludeRecorderAppFromCapture = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefExcludeRecorderAppFromCapture, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist excludeRecorderApp setting', e, st);
    }
    try {
      await _nativeBridge.setExcludeRecorderApp(value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to set excludeRecorderApp on native', e, st);
    }
  }

  Future<void> updateSystemAudioEnabled(bool value) async {
    if (value == _systemAudioEnabled) return;
    _systemAudioEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool('systemAudioEnabled', value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist systemAudioEnabled', e, st);
    }
  }

  Future<void> updateExcludeMicFromSystemAudio(bool value) async {
    if (value == _excludeMicFromSystemAudio) return;
    _excludeMicFromSystemAudio = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefExcludeMicFromSystemAudio, value);
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to persist excludeMicFromSystemAudio setting',
        e,
        st,
      );
    }
    try {
      await _nativeBridge.invokeMethod<void>('setExcludeMicFromSystemAudio', {
        'exclude': value,
      });
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to set excludeMicFromSystemAudio on native',
        e,
        st,
      );
    }
  }

  Future<void> updateMicEchoCancellationEnabled(bool value) async {
    if (value == _micEchoCancellationEnabled) return;
    _micEchoCancellationEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefMicEchoCancellationEnabled, value);
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to persist micEchoCancellationEnabled setting',
        e,
        st,
      );
    }
    try {
      await _nativeBridge.invokeMethod<void>('setMicEchoCancellationEnabled', {
        'enabled': value,
      });
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to set micEchoCancellationEnabled on native',
        e,
        st,
      );
    }
  }
}
