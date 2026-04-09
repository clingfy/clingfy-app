import 'package:flutter/services.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:flutter/foundation.dart';

class NativeBridge {
  late final MethodChannel _nativeBridge;
  late final EventChannel _updaterEvents;
  late final EventChannel _workflowEvents;
  late final EventChannel _playerEvents;
  late final Stream<Map<String, dynamic>> _workflowEventStream;
  late final Stream<Map<String, dynamic>> _playerEventStream;

  /// Whether an app update has been found by Sparkle.
  final ValueNotifier<bool> isUpdateAvailable = ValueNotifier(false);

  VoidCallback? _onIndicatorPauseTapped;
  VoidCallback? _onIndicatorStopTapped;
  VoidCallback? _onIndicatorResumeTapped;
  ValueChanged<double>? _onExportProgress;
  VoidCallback? _onMenuBarToggleRequest;
  void Function(String projectPath)? _onProjectOpenRequested;
  Function(String type, Map<String, dynamic>? payload)?
  _onPreRecordingBarAction;
  Function(String type, dynamic id)? _onNativeSelectionChanged;
  void Function(double normalizedX, double normalizedY)? _onCameraOverlayMoved;
  VoidCallback? _onAreaSelectionCleared;
  void Function(String version, String build)? _onUpdateAvailable;
  final List<String> _pendingProjectOpenRequests = [];

  static final NativeBridge _instance = NativeBridge._internal();

  static NativeBridge get instance => _instance;

  NativeBridge._internal() {
    _nativeBridge = MethodChannel(NativeChannel.screenRecorder);
    _updaterEvents = EventChannel(
      NativeChannel.updaterEvents,
    ); // Initialize EventChannel
    _workflowEvents = EventChannel(NativeChannel.workflowEvents);
    _playerEvents = EventChannel(NativeChannel.playerEvents);
    _workflowEventStream = _workflowEvents
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => (event as Map).cast<String, dynamic>())
        .asBroadcastStream();
    _playerEventStream = _playerEvents
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => (event as Map).cast<String, dynamic>())
        .asBroadcastStream();
    _nativeBridge.setMethodCallHandler(_handleMethodCall);

    // Listen to updater events
    _updaterEvents.receiveBroadcastStream().listen(
      (event) {
        if (event is Map && event['type'] == 'updateAvailable') {
          Log.i("NativeBridge", "Sparkle: update available (event stream)");
          isUpdateAvailable.value = true;
        }
      },
      onError: (error) {
        Log.e("NativeBridge", "Error on updater event stream: $error");
      },
    );

    _workflowEventStream.listen(
      (event) {
        final type = event['type'] as String?;
        if (type != 'openProjectRequest') {
          return;
        }

        final projectPath = event['projectPath'] as String?;
        if (projectPath == null || projectPath.isEmpty) {
          return;
        }

        Log.i(
          "NativeBridge",
          "Received Finder project open request",
          null,
          null,
          {'projectPath': projectPath},
        );

        final cb = _onProjectOpenRequested;
        if (cb != null) {
          cb(projectPath);
          return;
        }

        if (!_pendingProjectOpenRequests.contains(projectPath)) {
          _pendingProjectOpenRequests.add(projectPath);
        }
      },
      onError: (error) {
        Log.e("NativeBridge", "Error on workflow event stream: $error");
      },
    );
  }

  Stream<Map<String, dynamic>> get workflowEvents => _workflowEventStream;
  Stream<Map<String, dynamic>> get playerEvents => _playerEventStream;

  void setOnIndicatorPauseTapped(VoidCallback? cb) {
    _onIndicatorPauseTapped = cb;
  }

  void setOnIndicatorStopTapped(VoidCallback? cb) {
    _onIndicatorStopTapped = cb;
  }

  void setOnIndicatorResumeTapped(VoidCallback? cb) {
    _onIndicatorResumeTapped = cb;
  }

  void setOnMenuBarToggleRequest(VoidCallback? cb) {
    _onMenuBarToggleRequest = cb;
  }

  void setOnProjectOpenRequested(void Function(String projectPath)? cb) {
    _onProjectOpenRequested = cb;
    if (cb == null) {
      return;
    }

    final pending = List<String>.from(_pendingProjectOpenRequests);
    _pendingProjectOpenRequests.clear();
    for (final projectPath in pending) {
      cb(projectPath);
    }
  }

  void setOnPreRecordingBarAction(
    Function(String type, Map<String, dynamic>? payload)? cb,
  ) {
    _onPreRecordingBarAction = cb;
  }

  void setOnNativeSelectionChanged(Function(String type, dynamic id)? cb) {
    _onNativeSelectionChanged = cb;
  }

  void setOnExportProgress(ValueChanged<double>? cb) {
    _onExportProgress = cb;
  }

  void setOnCameraOverlayMoved(
    void Function(double normalizedX, double normalizedY)? cb,
  ) {
    _onCameraOverlayMoved = cb;
  }

  void setOnAreaSelectionCleared(VoidCallback? cb) {
    _onAreaSelectionCleared = cb;
  }

  void setOnUpdateAvailable(void Function(String version, String build)? cb) {
    _onUpdateAvailable = cb;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case NativeToFlutterMethod.log:
        final args = call.arguments;
        if (args is Map) {
          Log.nativeEvent(args.cast<String, dynamic>());
        }
        return null;
      case NativeToFlutterMethod.indicatorPauseTapped:
        _onIndicatorPauseTapped?.call();
        return null;
      case NativeToFlutterMethod.indicatorStopTapped:
        _onIndicatorStopTapped?.call();
        return null;
      case NativeToFlutterMethod.indicatorResumeTapped:
        _onIndicatorResumeTapped?.call();
        return null;
      case NativeToFlutterMethod.menuBarToggleRequest:
        _onMenuBarToggleRequest?.call();
        return null;
      case NativeToFlutterMethod.updateExportProgress:
        final p = call.arguments as double?;
        if (p != null) {
          _onExportProgress?.call(p);
        }
        return null;
      case NativeToFlutterMethod.preRecordingBarAction:
        final args = call.arguments as Map?;
        final type = args?['type'] as String?;
        final payload = args?['payload'] as Map?;
        if (type != null) {
          _onPreRecordingBarAction?.call(
            type,
            payload?.cast<String, dynamic>(),
          );
        }
        return null;
      case NativeToFlutterMethod.nativeSelectionChanged:
        final args = call.arguments as Map?;
        final type = args?['type'] as String?;
        final id = args?['id'];
        if (type != null) {
          _onNativeSelectionChanged?.call(type, id);
        }
        return null;
      case NativeToFlutterMethod.cameraOverlayMoved:
        final args = call.arguments as Map?;
        final x = (args?['normalizedX'] as num?)?.toDouble();
        final y = (args?['normalizedY'] as num?)?.toDouble();
        if (x != null && y != null) {
          _onCameraOverlayMoved?.call(x, y);
        }
        return null;
      case NativeToFlutterMethod.areaSelectionCleared:
        _onAreaSelectionCleared?.call();
        return null;
      case 'updateAvailable': // This case is for the _onUpdateAvailable callback
        final args = call.arguments as Map?;
        final version = args?['version'] as String? ?? '';
        final build = args?['build'] as String? ?? '';
        _onUpdateAvailable?.call(version, build);
        return null;
      default:
        Log.w("NativeBridge", "Method not implemented: ${call.method}");
        return null;
    }
  }

  Future<void> setRecordingIndicatorPinned(bool pinned) async {
    await _nativeBridge.invokeMethod<void>('setRecordingIndicatorPinned', {
      'pinned': pinned,
    });
  }

  Future<void> setRecordingQuality(String wireValue) async {
    await _nativeBridge.invokeMethod<void>('setRecordingQuality', {
      'quality': wireValue,
    });
  }

  Future<bool> getExcludeRecorderApp() async {
    final result = await _nativeBridge.invokeMethod<bool>(
      'getExcludeRecorderApp',
    );
    return result ?? false;
  }

  Future<void> setExcludeRecorderApp(bool exclude) async {
    await _nativeBridge.invokeMethod<void>('setExcludeRecorderApp', {
      'exclude': exclude,
    });
  }

  Future<void> setFileNameTemplate(String template) async {
    await _nativeBridge.invokeMethod<void>('setFileNameTemplate', {
      'template': template,
    });
  }

  Future<void> setDisplayTargetMode(DisplayTargetMode m) async {
    await _nativeBridge.invokeMethod<void>('setDisplayTargetMode', {
      'mode': m.index,
    });
  }

  Future<void> revealAreaRecordingRegion() async {
    await _nativeBridge.invokeMethod<void>('revealAreaRecordingRegion');
  }

  Future<void> clearAreaRecordingSelection() async {
    await _nativeBridge.invokeMethod<void>('clearAreaRecordingSelection');
  }

  Future<void> setPreRecordingBarEnabled(bool enabled) async {
    await _nativeBridge.invokeMethod<void>('setPreRecordingBarEnabled', {
      'enabled': enabled,
    });
  }

  Future<void> showPreRecordingBar() async {
    await _nativeBridge.invokeMethod<void>('showPreRecordingBar');
  }

  Future<void> togglePreRecordingBar() async {
    await _nativeBridge.invokeMethod<void>('togglePreRecordingBar');
  }

  Future<void> setPreRecordingBarVisible(bool enabled) async {
    await setPreRecordingBarEnabled(enabled);
  }

  Future<void> setPreRecordingBarState(Map<String, dynamic> state) async {
    await _nativeBridge.invokeMethod<void>('setPreRecordingBarState', state);
  }

  Future<void> pauseRecording({String? sessionId}) async {
    await _nativeBridge.invokeMethod<void>('pauseRecording', {
      if (sessionId != null) 'sessionId': sessionId,
    });
  }

  Future<void> resumeRecording({String? sessionId}) async {
    await _nativeBridge.invokeMethod<void>('resumeRecording', {
      if (sessionId != null) 'sessionId': sessionId,
    });
  }

  Future<void> togglePauseRecording({String? sessionId}) async {
    await _nativeBridge.invokeMethod<void>('togglePauseRecording', {
      if (sessionId != null) 'sessionId': sessionId,
    });
  }

  Future<RecordingPauseResumeCapabilities> getRecordingCapabilities() async {
    final raw = await _nativeBridge.invokeMethod<Map<dynamic, dynamic>>(
      'getRecordingCapabilities',
    );
    return RecordingPauseResumeCapabilities.fromMap(raw);
  }

  Future<void> setCursorHighlightEnabled(bool enabled) async {
    await _nativeBridge.invokeMethod<void>('setCursorHighlightEnabled', {
      'enabled': enabled,
    });
  }

  Future<void> setOverlayLinkedToRecording(bool linked) async {
    await _nativeBridge.invokeMethod<void>('setOverlayLinkedToRecording', {
      'linked': linked,
    });
  }

  Future<void> setCursorHighlightLinkedToRecording(bool linked) async {
    await _nativeBridge.invokeMethod<void>(
      'setCursorHighlightLinkedToRecording',
      {'linked': linked},
    );
  }

  Future<void> setAudioGainDb(double gainDb) async {
    await setAudioMix(gainDb: gainDb, volumePercent: 100.0, sessionId: null);
  }

  Future<void> setAudioMix({
    required double gainDb,
    required double volumePercent,
    required String? sessionId,
  }) async {
    await _nativeBridge.invokeMethod<void>('updateAudioPreview', {
      if (sessionId != null) 'sessionId': sessionId,
      'gain': gainDb,
      'volume': volumePercent,
    });
  }

  Future<void> previewSetCameraPlacement({
    required String projectPath,
    required CameraPreviewChangeKind changeKind,
    required String? sessionId,
    required String? cameraPath,
    required CameraCompositionState? cameraState,
  }) async {
    await _nativeBridge.invokeMethod<void>('previewSetCameraPlacement', {
      'projectPath': projectPath,
      if (sessionId != null) 'sessionId': sessionId,
      if (cameraPath != null) 'cameraPath': cameraPath,
      'cameraPreviewChangeKind': changeKind.name,
      ...?cameraState?.toMap(),
    });
  }

  Future<List<ZoomSegment>> getZoomSegments(String videoPath) async {
    try {
      final List? results = await _nativeBridge.invokeMethod<List>(
        'getZoomSegments',
        {'projectPath': videoPath},
      );
      if (results == null) return [];
      return results.map((m) => ZoomSegment.fromMap(m as Map)).toList();
    } catch (e) {
      Log.e("NativeBridge", "getZoomSegments failed: $e");
      return [];
    }
  }

  Future<List<ZoomSegment>> getManualZoomSegments(String videoPath) async {
    try {
      final List? results = await _nativeBridge.invokeMethod<List>(
        'getManualZoomSegments',
        {'projectPath': videoPath},
      );
      if (results == null) return [];
      return results
          .map((m) => ZoomSegment.fromMap(m as Map).copyWith(source: 'manual'))
          .toList();
    } catch (e) {
      Log.e("NativeBridge", "getManualZoomSegments failed: $e");
      return [];
    }
  }

  Future<bool> saveManualZoomSegments(
    String videoPath,
    List<ZoomSegment> segments,
  ) async {
    try {
      final bool? success = await _nativeBridge
          .invokeMethod<bool>('saveManualZoomSegments', {
            'projectPath': videoPath,
            'segments': segments.map((s) => s.toMap()).toList(),
          });
      return success ?? false;
    } catch (e) {
      Log.e("NativeBridge", "saveManualZoomSegments failed: $e");
      return false;
    }
  }

  Future<void> previewSetZoomSegments(
    List<ZoomSegment> segments, {
    required String? sessionId,
  }) async {
    try {
      await _nativeBridge.invokeMethod('previewSetZoomSegments', {
        if (sessionId != null) 'sessionId': sessionId,
        'segments': segments
            .map((s) => {'startMs': s.startMs, 'endMs': s.endMs})
            .toList(),
      });
    } catch (e) {
      Log.e("NativeBridge", "previewSetZoomSegments failed: $e");
    }
  }

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    return _nativeBridge.invokeMethod<T>(method, arguments);
  }

  Future<StorageSnapshot> getStorageSnapshot() async {
    final raw = await _nativeBridge.invokeMethod<Map<dynamic, dynamic>>(
      'getStorageSnapshot',
    );
    if (raw == null) {
      throw StateError('Native storage snapshot returned null.');
    }
    return StorageSnapshot.fromMap(raw);
  }

  Future<void> revealRecordingsFolder() async {
    await _nativeBridge.invokeMethod<void>('revealRecordingsFolder');
  }

  Future<void> revealTempFolder() async {
    await _nativeBridge.invokeMethod<void>('revealTempFolder');
  }

  Future<int> clearCachedRecordings() async {
    final raw = await _nativeBridge.invokeMethod<Map<dynamic, dynamic>>(
      'clearCachedRecordings',
    );
    if (raw == null) {
      throw StateError('Native clearCachedRecordings returned null.');
    }
    final deletedCount = raw['deletedCount'];
    if (deletedCount is int) return deletedCount;
    if (deletedCount is num) return deletedCount.toInt();
    return int.tryParse(deletedCount?.toString() ?? '') ?? 0;
  }

  Future<void> previewOpen({
    required String sessionId,
    required String projectPath,
    String? cameraPath,
  }) async {
    await _nativeBridge.invokeMethod<void>('previewOpen', {
      'sessionId': sessionId,
      'projectPath': projectPath,
      if (cameraPath != null) 'cameraPath': cameraPath,
    });
  }

  Future<RecordingSceneInfo> getRecordingSceneInfo(String projectPath) async {
    final raw = await _nativeBridge.invokeMethod<Map<dynamic, dynamic>>(
      'getRecordingSceneInfo',
      {'projectPath': projectPath},
    );
    if (raw == null) {
      return RecordingSceneInfo(
        projectPath: projectPath,
        screenPath: projectPath,
      );
    }
    return RecordingSceneInfo.fromMap(raw);
  }

  Future<void> previewClose({required String sessionId}) async {
    await _nativeBridge.invokeMethod<void>('previewClose', {
      'sessionId': sessionId,
    });
  }

  Future<Map<String, bool>> getPermissionStatus() async {
    final Map? result = await _nativeBridge.invokeMethod<Map>(
      'getPermissionStatus',
    );
    Log.d('NativeBridge', 'Permission status fetched', null, null, {
      'result': result,
    });

    if (result == null) return {};

    bool parseBool(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.toLowerCase().trim();
        return s == 'true' ||
            s == '1' ||
            s == 'yes' ||
            s == 'granted' ||
            s == 'authorized';
      }
      return false;
    }

    final out = <String, bool>{};
    result.forEach((k, v) {
      final key = k.toString();

      // Ignore debug marker keys returned by native code.
      if (key == 'getPermissionStatus') return;

      out[key] = parseBool(v);
    });

    return out;
  }

  Future<bool> requestScreenRecordingPermission() async {
    final result = await _nativeBridge.invokeMethod<bool>(
      'requestScreenRecordingPermission',
    );
    return result ?? false;
  }

  Future<bool> requestMicrophonePermission() async {
    final result = await _nativeBridge.invokeMethod<bool>(
      'requestMicrophonePermission',
    );
    return result ?? false;
  }

  Future<bool> requestCameraPermission() async {
    final result = await _nativeBridge.invokeMethod<bool>(
      'requestCameraPermission',
    );
    return result ?? false;
  }

  Future<void> openAccessibilitySettings() async {
    await _nativeBridge.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<void> openSystemSettings(String pane) async {
    await _nativeBridge.invokeMethod<void>('openSystemSettings', {
      'pane': pane,
    });
  }

  Future<void> openScreenRecordingSettings() async {
    await _nativeBridge.invokeMethod<void>('openScreenRecordingSettings');
  }

  Future<void> relaunchApp() async {
    await _nativeBridge.invokeMethod<void>('relaunchApp');
  }

  Future<bool> checkForUpdates() async {
    try {
      final result = await _nativeBridge.invokeMethod<bool>('checkForUpdates');
      return result ?? false;
    } catch (e, st) {
      Log.e("NativeBridge", "Failed to invoke checkForUpdates", e, st);
      return false;
    }
  }
}
