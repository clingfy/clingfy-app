import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';

class DeviceController extends ChangeNotifier {
  final NativeBridge _nativeBridge;
  final EventChannel _events;

  static const String _prefAudioDeviceId = 'audioDeviceId';
  static const String _prefVideoDeviceId = 'videoDeviceId';
  static const String _prefSelectedDisplayId = 'selectedDisplayId';
  static const String _prefSelectedAppWindowId = 'selectedAppWindowId';

  DeviceController({required NativeBridge nativeBridge, EventChannel? events})
    : _nativeBridge = nativeBridge,
      _events =
          events ?? const EventChannel(NativeChannel.screenRecorderEvents) {
    _init();
  }

  // --- State Fields ---
  static const String noAudioId = '__none__';

  bool _loadingAudio = true;
  List<AudioSource> _audioSources = const [];
  String _selectedAudioSourceId = noAudioId;

  bool _loadingCams = true;
  List<CamSource> _cams = const [];
  String? _selectedCamId;

  List<DisplayInfo> _displays = [];
  int? _selectedDisplayId;

  List<AppWindowInfo> _appWindows = [];
  int? _selectedAppWindowId;
  bool _loadingAppWindows = false;

  String? _errorMessage;
  StreamSubscription? _deviceEventsSub;
  bool _isHydrated = false;
  double _micInputLevelLinear = 0.0;
  double _micInputLevelDbfs = -160.0;
  bool _micInputTooLow = false;
  DateTime? _micInputUpdatedAt;

  // --- Getters ---
  bool get loadingAudio => _loadingAudio;
  List<AudioSource> get audioSources => _audioSources;
  String get selectedAudioSourceId => _selectedAudioSourceId;

  bool get loadingCams => _loadingCams;
  List<CamSource> get cams => _cams;
  String? get selectedCamId => _selectedCamId;

  List<DisplayInfo> get displays => _displays;
  int? get selectedDisplayId => _selectedDisplayId;

  List<AppWindowInfo> get appWindows => _appWindows;
  int? get selectedAppWindowId => _selectedAppWindowId;
  bool get loadingAppWindows => _loadingAppWindows;

  String? get errorMessage => _errorMessage;
  bool get isHydrated => _isHydrated;
  double get micInputLevelLinear => _micInputLevelLinear;
  double get micInputLevelDbfs => _micInputLevelDbfs;
  bool get micInputTooLow => _micInputTooLow;
  DateTime? get micInputUpdatedAt => _micInputUpdatedAt;

  // --- Actions ---

  void clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  Future<void> _init() async {
    try {
      // Load prefs for previously selected targets/devices
      final sp = await SharedPreferences.getInstance();
      final storedWindowId = sp.getInt(_prefSelectedAppWindowId) ?? 0;
      _selectedAppWindowId = storedWindowId > 0 ? storedWindowId : null;
      final storedDisplayId = sp.getInt(_prefSelectedDisplayId) ?? 0;
      _selectedDisplayId = storedDisplayId > 0 ? storedDisplayId : null;
      _selectedCamId = sp.getString(_prefVideoDeviceId);

      // Set initial window target
      await _nativeBridge.invokeMethod<void>('setAppWindowTarget', {
        'windowId': _selectedAppWindowId,
      });

      _deviceEventsSub = _events.receiveBroadcastStream().listen(
        (dynamic event) async {
          if (event is Map) {
            if (event['type'] == DeviceEventType.audioSourcesChanged) {
              await reloadAudioSources();
            }
            if (event['type'] == DeviceEventType.videoSourcesChanged) {
              await reloadCameras();
            }
            if (event['type'] == DeviceEventType.microphoneLevel) {
              _applyMicrophoneLevelEvent(Map<dynamic, dynamic>.from(event));
            }
          }
        },
        onError: (Object err) {
          _errorMessage = '$err';
          notifyListeners();
        },
      );

      await Future.wait([
        reloadAudioSources(),
        reloadCameras(),
        reloadDisplays(),
        reloadAppWindows(),
      ]);
    } catch (e, st) {
      _errorMessage = e.toString();
      Log.e("Device", "Failed during initial device hydration", e, st);
    } finally {
      _isHydrated = true;
      notifyListeners();
    }
  }

  Future<void> reloadAudioSources() async {
    _loadingAudio = true;
    notifyListeners();
    try {
      Log.i("Device", "Loading audio resources...");
      final raw =
          await _nativeBridge.invokeMethod<List<dynamic>>('getAudioSources') ??
          [];
      final sources = raw
          .map((e) => AudioSource.fromMap(Map<dynamic, dynamic>.from(e as Map)))
          .toList();

      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString(_prefAudioDeviceId);

      // Default to noAudioId when no saved preference exists — audio is optional.
      // Only auto-restore a previously saved device; never silently pick the first one.
      final String selectedId = sources.isEmpty
          ? noAudioId
          : (saved != null && sources.any((s) => s.id == saved)
                ? saved
                : noAudioId);

      _audioSources = sources;
      _selectedAudioSourceId = sources.isEmpty ? noAudioId : selectedId;
      if (_selectedAudioSourceId == noAudioId) {
        _resetMicrophoneLevel(notify: false);
      }

      final nativeAudioId =
          (_selectedAudioSourceId == noAudioId ||
              _selectedAudioSourceId.isEmpty)
          ? null
          : _selectedAudioSourceId;
      await _nativeBridge.invokeMethod<void>('setAudioSource', {
        'id': nativeAudioId,
      });
      Log.i("Device", "Finished loading audio resources.");
    } on PlatformException catch (e) {
      Log.e("Device", "Error loading audio sources: $e");
      _errorMessage = e.code;
    } finally {
      _loadingAudio = false;
      notifyListeners();
    }
  }

  Future<void> setAudioSource(String? sourceId) async {
    final next = sourceId ?? noAudioId;
    if (_selectedAudioSourceId != next) {
      _selectedAudioSourceId = next;
      _resetMicrophoneLevel(notify: false);
      notifyListeners();
    }

    final nativeAudioId =
        (sourceId == null || sourceId.isEmpty || sourceId == noAudioId)
        ? null
        : sourceId;

    try {
      await _nativeBridge.invokeMethod<void>('setAudioSource', {
        'id': nativeAudioId,
      });
      final sp = await SharedPreferences.getInstance();
      if (nativeAudioId == null) {
        await sp.remove(_prefAudioDeviceId);
      } else {
        await sp.setString(_prefAudioDeviceId, nativeAudioId);
      }
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
      notifyListeners();
    }
  }

  Future<void> reloadCameras() async {
    _loadingCams = true;
    notifyListeners();
    try {
      final raw =
          await _nativeBridge.invokeMethod<List<dynamic>>('getVideoSources') ??
          [];
      final cams = raw
          .map((e) => CamSource.fromMap(Map<dynamic, dynamic>.from(e as Map)))
          .toList();

      final sp = await SharedPreferences.getInstance();
      final savedCamId = sp.getString(_prefVideoDeviceId);
      _cams = cams;
      _selectedCamId =
          (savedCamId != null && cams.any((c) => c.id == savedCamId))
          ? savedCamId
          : ((_selectedCamId != null && cams.any((c) => c.id == _selectedCamId))
                ? _selectedCamId
                : (cams.isNotEmpty ? cams.first.id : null));

      await _nativeBridge.invokeMethod<void>('setVideoSource', {
        'id': _selectedCamId,
      });

      if (_selectedCamId == null || _selectedCamId!.isEmpty) {
        await sp.remove(_prefVideoDeviceId);
      } else {
        await sp.setString(_prefVideoDeviceId, _selectedCamId!);
      }
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
    } finally {
      _loadingCams = false;
      notifyListeners();
    }
  }

  Future<void> setCamSource(String? id) async {
    if (_selectedCamId != id) {
      _selectedCamId = id;
      notifyListeners();
    }
    try {
      await _nativeBridge.invokeMethod<void>('setVideoSource', {'id': id});
      final sp = await SharedPreferences.getInstance();
      if (id == null || id.isEmpty) {
        await sp.remove(_prefVideoDeviceId);
      } else {
        await sp.setString(_prefVideoDeviceId, id);
      }
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
      notifyListeners();
    }
  }

  Future<void> reloadDisplays() async {
    try {
      final raw =
          await _nativeBridge.invokeMethod<List<dynamic>>('getDisplays') ?? [];
      Log.i("Device", "Displays: $raw");
      final displays = raw
          .map((e) => DisplayInfo.fromMap(Map<dynamic, dynamic>.from(e)))
          .toList();

      final sp = await SharedPreferences.getInstance();
      final savedDisplayId = sp.getInt(_prefSelectedDisplayId);

      _displays = displays;
      _selectedDisplayId =
          (_selectedDisplayId != null &&
              displays.any((d) => d.id == _selectedDisplayId))
          ? _selectedDisplayId
          : ((savedDisplayId != null &&
                    displays.any((d) => d.id == savedDisplayId))
                ? savedDisplayId
                : (displays.isNotEmpty ? displays.first.id : null));

      if (_selectedDisplayId == null) {
        await sp.remove(_prefSelectedDisplayId);
      } else {
        await sp.setInt(_prefSelectedDisplayId, _selectedDisplayId!);
      }
      notifyListeners();
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
      notifyListeners();
    }
  }

  Future<void> setDisplay(int? id) async {
    if (_selectedDisplayId != id) {
      _selectedDisplayId = id;
      notifyListeners();
    }
    try {
      await _nativeBridge.invokeMethod<void>('setDisplay', {'id': id});
      final sp = await SharedPreferences.getInstance();
      if (id == null) {
        await sp.remove(_prefSelectedDisplayId);
      } else {
        await sp.setInt(_prefSelectedDisplayId, id);
      }
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
      notifyListeners();
    }
  }

  Future<void> reloadAppWindows() async {
    _loadingAppWindows = true;
    notifyListeners();
    try {
      final raw =
          await _nativeBridge.invokeMethod<List<dynamic>>('getAppWindows') ??
          [];
      final windows = raw
          .map((e) => AppWindowInfo.fromMap(Map<dynamic, dynamic>.from(e)))
          .toList();

      _appWindows = windows;
      if (_selectedAppWindowId != null &&
          windows.every((w) => w.id != _selectedAppWindowId)) {
        _selectedAppWindowId = null;
      }
    } catch (e) {
      Log.e("Device", "Error reloading app windows: $e");
      // ignore
    } finally {
      _loadingAppWindows = false;
      notifyListeners();
    }
  }

  Future<void> setAppWindow(int? id) async {
    if (_selectedAppWindowId != id) {
      _selectedAppWindowId = id;
      notifyListeners();
    }

    try {
      final sp = await SharedPreferences.getInstance();
      if (id == null) {
        await sp.remove(_prefSelectedAppWindowId);
      } else {
        await sp.setInt(_prefSelectedAppWindowId, id);
      }
      await _nativeBridge.invokeMethod<void>('setAppWindowTarget', {
        'windowId': id,
      });
    } on PlatformException catch (e) {
      Log.e("Device", "Error is $e");
      _errorMessage = e.code;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _deviceEventsSub?.cancel();
    super.dispose();
  }

  void _applyMicrophoneLevelEvent(Map<dynamic, dynamic> event) {
    if (_selectedAudioSourceId == noAudioId) {
      return;
    }

    final linear = (event['linear'] as num?)?.toDouble() ?? 0.0;
    final dbfs = (event['dbfs'] as num?)?.toDouble() ?? -160.0;
    final isLow = event['isLow'] as bool? ?? (dbfs < -32.0 && dbfs > -120.0);

    final clampedLinear = linear.clamp(0.0, 1.0);
    final changed =
        (clampedLinear - _micInputLevelLinear).abs() >= 0.003 ||
        (dbfs - _micInputLevelDbfs).abs() >= 0.25 ||
        isLow != _micInputTooLow;

    _micInputLevelLinear = clampedLinear;
    _micInputLevelDbfs = dbfs;
    _micInputTooLow = isLow;
    _micInputUpdatedAt = DateTime.now();

    if (changed) {
      notifyListeners();
    }
  }

  void _resetMicrophoneLevel({required bool notify}) {
    _micInputLevelLinear = 0.0;
    _micInputLevelDbfs = -160.0;
    _micInputTooLow = false;
    _micInputUpdatedAt = null;
    if (notify) {
      notifyListeners();
    }
  }
}
