import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/app/home/recording/recorded_duration_tracker.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/settings/settings_controller.dart';

enum _PreviewOpenSource { recordingFinalized, externalProject }

class RecordingController extends ChangeNotifier {
  static const List<String> _recordingStartFailureContextKeys = [
    'failingCall',
    'errorOriginFile',
    'errorOriginLine',
    'backend',
    'targetMode',
    'displayID',
    'windowID',
    'targetCropRect',
    'sourceRect',
    'filterContentRect',
    'streamConfig',
    'recordingOutputConfig',
    'underlyingErrorDomain',
    'underlyingErrorCode',
    'underlyingErrorDescription',
  ];

  RecordingController({
    required NativeBridge nativeBridge,
    required SettingsController settings,
  }) : _nativeBridge = nativeBridge,
       _settings = settings {
    _settings.addListener(_onSettingsChanged);
    _workflowSub = _nativeBridge.workflowEvents.listen(_handleWorkflowEvent);
    unawaited(refreshPauseResumeCapabilities());
  }

  final NativeBridge _nativeBridge;
  final SettingsController _settings;
  final Random _random = Random.secure();

  late final StreamSubscription<Map<String, dynamic>> _workflowSub;

  RecordingWorkflowState _state = const RecordingWorkflowState.idle();
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTicker;
  Timer? _autoStopTimer;
  int _sessionCounter = 0;
  bool _startCommandIssued = false;
  String? _mountedPreviewSessionId;
  bool _previewOpenRequested = false;
  bool _pauseResumeInFlight = false;
  _PreviewOpenSource? _previewOpenSource;
  String? _pendingExternalProjectReplacementPath;
  String? _openingExternalProjectPath;
  String? _failedExternalProjectOpenPath;
  String? _pendingWarningMessage;
  RecordingPauseResumeCapabilities _pauseResumeCapabilities =
      const RecordingPauseResumeCapabilities.unsupported();
  final RecordedDurationTracker _durationTracker = RecordedDurationTracker();

  RecordingWorkflowState get state => _state;
  WorkflowPhase get phase => _state.phase;
  String? get sessionId => _state.sessionId;
  String? get projectPath => _state.projectPath;
  String? get previewPath => _state.previewPath ?? _state.projectPath;
  String? get previewToken => _state.previewToken;
  String? get lastRecordingPath => previewPath;
  String? get originalRecordingPath => _state.projectPath;
  String? get errorCode => _state.errorCode;
  String? get errorMessage => _state.errorMessage ?? _state.errorCode;
  String? get pendingWarningMessage => _pendingWarningMessage;

  bool get isRecording =>
      phase == WorkflowPhase.recording ||
      phase == WorkflowPhase.pausedRecording;
  bool get isActivelyRecording => phase == WorkflowPhase.recording;
  bool get isPaused => phase == WorkflowPhase.pausedRecording;
  bool get canPauseResume => _pauseResumeCapabilities.canPauseResume;
  bool get canPause =>
      canPauseResume &&
      phase == WorkflowPhase.recording &&
      !_pauseResumeInFlight;
  bool get canResume =>
      canPauseResume &&
      phase == WorkflowPhase.pausedRecording &&
      !_pauseResumeInFlight;
  bool get pauseResumeInFlight => _pauseResumeInFlight;
  RecordingPauseResumeCapabilities get pauseResumeCapabilities =>
      _pauseResumeCapabilities;
  bool get isExporting => phase == WorkflowPhase.exporting;
  bool get showHeroPanel => switch (phase) {
    WorkflowPhase.idle ||
    WorkflowPhase.startingRecording ||
    WorkflowPhase.recording ||
    WorkflowPhase.pausedRecording ||
    WorkflowPhase.stoppingRecording ||
    WorkflowPhase.finalizingRecording => true,
    WorkflowPhase.openingPreview ||
    WorkflowPhase.previewLoading ||
    WorkflowPhase.previewReady ||
    WorkflowPhase.closingPreview ||
    WorkflowPhase.exporting => false,
  };
  bool get showPreviewShell => switch (phase) {
    WorkflowPhase.openingPreview ||
    WorkflowPhase.previewLoading ||
    WorkflowPhase.previewReady ||
    WorkflowPhase.closingPreview ||
    WorkflowPhase.exporting => true,
    WorkflowPhase.idle ||
    WorkflowPhase.startingRecording ||
    WorkflowPhase.recording ||
    WorkflowPhase.pausedRecording ||
    WorkflowPhase.stoppingRecording ||
    WorkflowPhase.finalizingRecording => false,
  };
  bool get showPreviewLoadingOverlay =>
      phase == WorkflowPhase.openingPreview ||
      phase == WorkflowPhase.previewLoading;
  bool get showPreviewSurface =>
      phase == WorkflowPhase.previewReady || phase == WorkflowPhase.exporting;
  bool get showPreviewControls => phase == WorkflowPhase.previewReady;
  bool get canInteractWithPreview => phase == WorkflowPhase.previewReady;
  bool get isBusyTransitioning => switch (phase) {
    WorkflowPhase.startingRecording ||
    WorkflowPhase.stoppingRecording ||
    WorkflowPhase.finalizingRecording ||
    WorkflowPhase.openingPreview ||
    WorkflowPhase.previewLoading ||
    WorkflowPhase.closingPreview => true,
    WorkflowPhase.idle ||
    WorkflowPhase.recording ||
    WorkflowPhase.pausedRecording ||
    WorkflowPhase.previewReady ||
    WorkflowPhase.exporting => false,
  };
  bool get isBusy => isBusyTransitioning;
  bool get showTimelineBar => phase == WorkflowPhase.previewReady;
  bool get showPreRecordingBar => phase == WorkflowPhase.idle;
  bool get shouldNotifyRecordingFinalizedOnPreviewOpen =>
      _previewOpenSource == _PreviewOpenSource.recordingFinalized;

  Duration get elapsed => _elapsed;
  bool get autoStopEnabled => _settings.recording.autoStopEnabled;
  Duration get autoStopAfter => _settings.recording.autoStopAfter;
  String get formattedElapsed => _fmt(_elapsed);

  String? get countdownText {
    if (!_settings.recording.autoStopEnabled ||
        !(phase == WorkflowPhase.recording ||
            phase == WorkflowPhase.pausedRecording) ||
        !_durationTracker.hasStarted) {
      return null;
    }
    final left = _settings.recording.autoStopAfter - _elapsed;
    if (left.isNegative) return '00:00:00';
    return _fmt(left);
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final hh = h.toString().padLeft(2, '0');
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  Map<String, dynamic> _previewLifecycleLogContext([
    Map<String, dynamic>? event,
  ]) {
    return {
      'phase': phase.name,
      'sessionId': event?['sessionId']?.toString() ?? _state.sessionId,
      'projectPath': _state.projectPath,
      'previewPath': _state.previewPath,
      'token': event?['token']?.toString() ?? _state.previewToken,
      'path': event?['path']?.toString(),
    };
  }

  void _onSettingsChanged() {
    notifyListeners();
    if (phase == WorkflowPhase.recording) {
      _disarmAutoStopTimer();
      _armAutoStopTimer();
    } else if (phase == WorkflowPhase.pausedRecording) {
      _disarmAutoStopTimer();
    }
  }

  void clearError() {
    if (!_state.hasError) return;
    _state = _state.copyWith(clearErrorCode: true, clearErrorMessage: true);
    notifyListeners();
  }

  @visibleForTesting
  static Map<String, dynamic> recordingStartFailureContextFromPlatformException(
    PlatformException error,
  ) {
    final details = _stringKeyedMap(error.details);
    if (details == null) {
      return <String, dynamic>{};
    }

    final startFailureInfo = _stringKeyedMap(details['startFailureInfo']);
    final context = <String, dynamic>{};
    if (startFailureInfo != null) {
      context['startFailureInfo'] = startFailureInfo;
    }

    for (final key in _recordingStartFailureContextKeys) {
      final value = details[key] ?? startFailureInfo?[key];
      if (value != null) {
        context[key] = value;
      }
    }
    return context;
  }

  static Map<String, dynamic>? _stringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(key.toString(), nestedValue),
      );
    }
    return null;
  }

  String? _normalizedPlatformErrorMessage(PlatformException error) {
    final message = error.message;
    if (message == null || message.trim().isEmpty) {
      return null;
    }
    return message;
  }

  Future<void> refreshPauseResumeCapabilities() async {
    try {
      final capabilities = await _nativeBridge.getRecordingCapabilities();
      final changed =
          capabilities.canPauseResume !=
              _pauseResumeCapabilities.canPauseResume ||
          capabilities.backend != _pauseResumeCapabilities.backend ||
          capabilities.strategy != _pauseResumeCapabilities.strategy;
      _pauseResumeCapabilities = capabilities;
      if (changed) {
        notifyListeners();
      }
    } catch (e) {
      Log.w('Recording', 'Failed to refresh pause/resume capabilities: $e');
      if (_pauseResumeCapabilities.canPauseResume) {
        _pauseResumeCapabilities =
            const RecordingPauseResumeCapabilities.unsupported();
        notifyListeners();
      }
    }
  }

  void beginRecordingStartIntent() {
    if (phase != WorkflowPhase.idle) return;
    final nextSessionId = _generateSessionId();
    _startCommandIssued = false;
    _pauseResumeInFlight = false;
    _mountedPreviewSessionId = null;
    _previewOpenRequested = false;
    _state = RecordingWorkflowState(
      phase: WorkflowPhase.startingRecording,
      sessionId: nextSessionId,
    );
    _pendingWarningMessage = null;
    notifyListeners();
  }

  String? consumePendingWarningMessage() {
    final warning = _pendingWarningMessage;
    _pendingWarningMessage = null;
    return warning;
  }

  void cancelPendingStartIntent() {
    if (phase != WorkflowPhase.startingRecording || _startCommandIssued) return;
    _transitionToIdle(clearError: false);
  }

  void openExistingProject(String projectPath) {
    if (projectPath.isEmpty) return;
    _pendingExternalProjectReplacementPath = null;
    _enterPreviewForProject(
      projectPath: projectPath,
      source: _PreviewOpenSource.externalProject,
    );
  }

  Future<void> replacePreviewWithProject(String projectPath) async {
    if (projectPath.isEmpty || !showPreviewShell) return;
    _pendingExternalProjectReplacementPath = projectPath;
    await _beginPreviewClose(requestNativeClose: true);
  }

  String? consumeFailedExternalProjectOpenPath() {
    final failedPath = _failedExternalProjectOpenPath;
    _failedExternalProjectOpenPath = null;
    return failedPath;
  }

  Future<void> startRecording({
    RecordingStartOverrides overrides = const RecordingStartOverrides(),
  }) async {
    if (phase == WorkflowPhase.idle) {
      beginRecordingStartIntent();
    }
    if (phase != WorkflowPhase.startingRecording ||
        _state.sessionId == null ||
        _startCommandIssued) {
      return;
    }

    final activeSessionId = _state.sessionId!;
    _startCommandIssued = true;
    Log.recordingId = activeSessionId;
    clearError();

    try {
      await ClingfyTelemetry.startSession(
        bridge: _nativeBridge,
        recordingId: activeSessionId,
        settings: _settings,
        phase: WorkflowPhase.startingRecording,
      );

      await _nativeBridge.invokeMethod<void>('startRecording', {
        'sessionId': activeSessionId,
        'frameRate': _settings.recording.captureFrameRate,
        'systemAudioEnabled': _settings.recording.systemAudioEnabled,
        'disableMicrophone': overrides.disableMicrophone,
        'disableCameraOverlay': overrides.disableCameraOverlay,
        'disableCursorHighlight': overrides.disableCursorHighlight,
        'allowLowStorageBypass': overrides.allowLowStorageBypass,
      });
    } on PlatformException catch (e, st) {
      final startFailureContext =
          RecordingController.recordingStartFailureContextFromPlatformException(
            e,
          );
      Log.e('Recording', 'Failed to start recording: $e', null, null, {
        'sessionId': activeSessionId,
        'details': e.details,
        ...startFailureContext,
      });
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'startRecording',
        context: {
          'sessionId': activeSessionId,
          'frameRate': _settings.recording.captureFrameRate,
          'systemAudioEnabled': _settings.recording.systemAudioEnabled,
          'disableMicrophone': overrides.disableMicrophone,
          'disableCameraOverlay': overrides.disableCameraOverlay,
          'disableCursorHighlight': overrides.disableCursorHighlight,
          'allowLowStorageBypass': overrides.allowLowStorageBypass,
          'details': e.details,
          ...startFailureContext,
        },
      );
      await ClingfyTelemetry.stopSession();
      _startCommandIssued = false;
      _transitionToIdle(
        errorCode: e.code,
        errorMessage: _normalizedPlatformErrorMessage(e),
      );
    } catch (e, st) {
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'startRecording',
        context: {
          'sessionId': activeSessionId,
          'frameRate': _settings.recording.captureFrameRate,
          'systemAudioEnabled': _settings.recording.systemAudioEnabled,
          'disableMicrophone': overrides.disableMicrophone,
          'disableCameraOverlay': overrides.disableCameraOverlay,
          'disableCursorHighlight': overrides.disableCursorHighlight,
          'allowLowStorageBypass': overrides.allowLowStorageBypass,
        },
      );
      await ClingfyTelemetry.stopSession();
      _startCommandIssued = false;
      _transitionToIdle(
        errorCode: 'RECORDING_ERROR',
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> stopRecording({bool triggeredByAutoStop = false}) async {
    if ((phase != WorkflowPhase.recording &&
            phase != WorkflowPhase.pausedRecording) &&
        !triggeredByAutoStop) {
      return;
    }
    if (_state.sessionId == null) return;

    final previousState = _state;
    _setState(_state.copyWith(phase: WorkflowPhase.stoppingRecording));

    try {
      await ClingfyTelemetry.syncRecordingScope(
        phase: WorkflowPhase.stoppingRecording,
        settings: _settings,
        recordingId: _state.sessionId,
      );

      final stopFuture = _nativeBridge.invokeMethod<void>('stopRecording', {
        'sessionId': _state.sessionId,
      });
      if (previousState.phase == WorkflowPhase.recording) {
        _elapsed = _durationTracker.current();
      }
      _stopElapsedTicker();
      _disarmAutoStopTimer();
      Log.d('Recording', 'stopRecording', null, null, {
        'phase': phase.name,
        'sessionId': _state.sessionId,
      });
      if (phase == WorkflowPhase.stoppingRecording) {
        _setState(_state.copyWith(phase: WorkflowPhase.finalizingRecording));
      }
      await stopFuture;
    } on PlatformException catch (e, st) {
      Log.e("Recording", "Failed to stop recording: $e");
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'stopRecording',
        context: {
          'sessionId': _state.sessionId,
          'triggeredByAutoStop': triggeredByAutoStop,
          'previousPhase': previousState.phase.name,
        },
      );
      _restoreAfterStopFailure(
        previousState,
        e.code,
        _normalizedPlatformErrorMessage(e),
      );
    } catch (e, st) {
      Log.e("Recording", "Failed to stop recording: $e");
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'stopRecording',
        context: {
          'sessionId': _state.sessionId,
          'triggeredByAutoStop': triggeredByAutoStop,
          'previousPhase': previousState.phase.name,
        },
      );
      _restoreAfterStopFailure(previousState, 'RECORDING_ERROR', e.toString());
    }
  }

  Future<void> pauseRecording() async {
    if (!canPause || _state.sessionId == null) return;

    _pauseResumeInFlight = true;
    notifyListeners();
    try {
      await _nativeBridge.pauseRecording(sessionId: _state.sessionId);
    } on PlatformException catch (e, st) {
      _pauseResumeInFlight = false;
      notifyListeners();
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'pauseRecording',
        context: {'sessionId': _state.sessionId, 'phase': phase.name},
      );
      _setState(
        _state.copyWith(
          errorCode: e.code,
          errorMessage: _normalizedPlatformErrorMessage(e),
        ),
      );
    } catch (e, st) {
      _pauseResumeInFlight = false;
      notifyListeners();
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'pauseRecording',
        context: {'sessionId': _state.sessionId, 'phase': phase.name},
      );
      _setState(
        _state.copyWith(
          errorCode: 'RECORDING_ERROR',
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> resumeRecording() async {
    if (!canResume || _state.sessionId == null) return;

    _pauseResumeInFlight = true;
    notifyListeners();
    try {
      await _nativeBridge.resumeRecording(sessionId: _state.sessionId);
    } on PlatformException catch (e, st) {
      _pauseResumeInFlight = false;
      notifyListeners();
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'resumeRecording',
        context: {'sessionId': _state.sessionId, 'phase': phase.name},
      );
      _setState(
        _state.copyWith(
          errorCode: e.code,
          errorMessage: _normalizedPlatformErrorMessage(e),
        ),
      );
    } catch (e, st) {
      _pauseResumeInFlight = false;
      notifyListeners();
      await ClingfyTelemetry.captureError(
        e,
        stackTrace: st,
        method: 'resumeRecording',
        context: {'sessionId': _state.sessionId, 'phase': phase.name},
      );
      _setState(
        _state.copyWith(
          errorCode: 'RECORDING_ERROR',
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> handlePreviewHostMounted() async {
    final activeSessionId = _state.sessionId;
    final path = _state.previewPath ?? _state.projectPath;
    Log.d('Recording', 'Preview host mounted', null, null, {
      'phase': phase.name,
      'sessionId': activeSessionId,
      'projectPath': _state.projectPath,
      'previewPath': _state.previewPath,
      'token': _state.previewToken,
      'path': path,
    });
    if (phase != WorkflowPhase.openingPreview ||
        activeSessionId == null ||
        path == null) {
      return;
    }
    if (_mountedPreviewSessionId == activeSessionId && _previewOpenRequested) {
      return;
    }

    _mountedPreviewSessionId = activeSessionId;
    _previewOpenRequested = true;
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.previewLoading,
        previewPath: path,
        clearPreviewToken: true,
      ),
    );

    try {
      Log.i(
        'Recording',
        'Invoking native previewOpen for session $activeSessionId',
      );
      await _nativeBridge.previewOpen(
        sessionId: activeSessionId,
        projectPath: path,
      );
    } catch (e, st) {
      Log.e("Recording", "Failed to open preview: $e", e, st);
      _recordExternalProjectOpenFailureIfNeeded();
      _state = _state.copyWith(
        errorCode: 'PREVIEW_OPEN_ERROR',
        errorMessage: e.toString(),
      );
      notifyListeners();
      await _beginPreviewClose(requestNativeClose: false);
      _transitionToIdle(
        errorCode: 'PREVIEW_OPEN_ERROR',
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> closePreview() async {
    if (!showPreviewShell || phase == WorkflowPhase.exporting) return;
    await _beginPreviewClose(requestNativeClose: true);
  }

  void enterExporting() {
    if (phase == WorkflowPhase.previewReady) {
      _setState(_state.copyWith(phase: WorkflowPhase.exporting));
    }
  }

  void finishExporting() {
    if (phase == WorkflowPhase.exporting) {
      _setState(_state.copyWith(phase: WorkflowPhase.previewReady));
    }
  }

  void _restoreAfterStopFailure(
    RecordingWorkflowState previousState,
    String errorCode,
    String? errorMessage,
  ) {
    _setState(
      previousState.copyWith(errorCode: errorCode, errorMessage: errorMessage),
    );
    if (phase == WorkflowPhase.recording) {
      _startElapsedTicker();
      _armAutoStopTimer();
      unawaited(
        ClingfyTelemetry.syncRecordingScope(
          phase: WorkflowPhase.recording,
          settings: _settings,
          recordingId: _state.sessionId,
        ),
      );
    } else if (phase == WorkflowPhase.pausedRecording) {
      _elapsed = _durationTracker.current();
      _stopElapsedTicker();
      _disarmAutoStopTimer();
    }
  }

  void _handleWorkflowEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == null || type.isEmpty) return;

    if (type == 'previewPreparing' ||
        type == 'previewReady' ||
        type == 'previewFailed' ||
        type == 'previewClosed' ||
        type == 'recordingFinalized' ||
        type == 'recordingFinished') {
      Log.d('Recording', 'Received $type workflow event', null, null, {
        ..._previewLifecycleLogContext(event),
      });
    }

    switch (type) {
      case 'recordingStarted':
        _handleRecordingStartedEvent(event);
        return;
      case 'recordingPaused':
        _handleRecordingPausedEvent(event);
        return;
      case 'recordingResumed':
        _handleRecordingResumedEvent(event);
        return;
      case 'recordingFinalized':
      case 'recordingFinished':
        _handleRecordingFinalizedEvent(event);
        return;
      case 'recordingFailed':
        _handleRecordingFailedEvent(event);
        return;
      case 'recordingWarning':
        _handleRecordingWarningEvent(event);
        return;
      case 'previewPreparing':
        _handlePreviewPreparingEvent(event);
        return;
      case 'previewReady':
        _handlePreviewReadyEvent(event);
        return;
      case 'previewFailed':
        _handlePreviewFailedEvent(event);
        return;
      case 'previewClosed':
        _handlePreviewClosedEvent(event);
        return;
      case 'openProjectRequest':
        return;
      default:
        Log.d('Recording', 'Ignoring unknown workflow event: $type');
    }
  }

  void _handleRecordingStartedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    if (phase != WorkflowPhase.startingRecording) return;

    _durationTracker.start();
    _elapsed = Duration.zero;
    _pauseResumeInFlight = false;
    _startElapsedTicker();
    _disarmAutoStopTimer();
    _armAutoStopTimer();
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.recording,
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
    unawaited(
      ClingfyTelemetry.syncRecordingScope(
        phase: WorkflowPhase.recording,
        settings: _settings,
        recordingId: eventSessionId,
      ),
    );
  }

  void _handleRecordingPausedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    if (phase != WorkflowPhase.recording &&
        phase != WorkflowPhase.pausedRecording) {
      return;
    }

    _pauseResumeInFlight = false;
    _durationTracker.pause();
    _elapsed = _durationTracker.current();
    _stopElapsedTicker();
    _disarmAutoStopTimer();
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.pausedRecording,
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
    unawaited(
      ClingfyTelemetry.syncRecordingScope(
        phase: WorkflowPhase.pausedRecording,
        settings: _settings,
        recordingId: eventSessionId,
      ),
    );
  }

  void _handleRecordingResumedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    if (phase != WorkflowPhase.pausedRecording &&
        phase != WorkflowPhase.recording) {
      return;
    }

    _pauseResumeInFlight = false;
    _durationTracker.resume();
    _elapsed = _durationTracker.current();
    _startElapsedTicker();
    _disarmAutoStopTimer();
    _armAutoStopTimer();
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.recording,
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
    unawaited(
      ClingfyTelemetry.syncRecordingScope(
        phase: WorkflowPhase.recording,
        settings: _settings,
        recordingId: eventSessionId,
      ),
    );
  }

  void _handleRecordingFinalizedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    if (phase == WorkflowPhase.closingPreview ||
        phase == WorkflowPhase.previewLoading ||
        phase == WorkflowPhase.previewReady ||
        phase == WorkflowPhase.exporting) {
      return;
    }

    final projectPath = event['projectPath']?.toString();
    if (projectPath == null || projectPath.isEmpty) {
      _handleRecordingFailedEvent({
        'type': 'recordingFailed',
        'sessionId': eventSessionId,
        'stage': 'finalize',
        'code': 'RECORDING_FINALIZE_ERROR',
        'error': 'Missing finalized project path',
      });
      return;
    }

    Log.i(
      'Recording',
      'Recording finalized, opening preview shell',
      null,
      null,
      {..._previewLifecycleLogContext(event), 'projectPath': projectPath},
    );
    _enterPreviewForProject(
      projectPath: projectPath,
      source: _PreviewOpenSource.recordingFinalized,
      sessionId: eventSessionId,
    );
    unawaited(ClingfyTelemetry.stopSession());
  }

  void _handleRecordingFailedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;

    final code =
        event['code']?.toString() ??
        event['stage']?.toString() ??
        'RECORDING_ERROR';
    final error = event['error']?.toString();

    _pauseResumeInFlight = false;
    _stopElapsedTicker();
    _disarmAutoStopTimer();
    Log.recordingId = null;
    _startCommandIssued = false;

    unawaited(ClingfyTelemetry.stopSession());
    _transitionToIdle(errorCode: code, errorMessage: error);
  }

  void _handleRecordingWarningEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;

    final message = event['message']?.toString();
    if (message == null || message.trim().isEmpty) {
      return;
    }

    _pendingWarningMessage = message;
    notifyListeners();
  }

  void _handlePreviewPreparingEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    if (phase != WorkflowPhase.openingPreview &&
        phase != WorkflowPhase.previewLoading) {
      return;
    }

    _setState(
      _state.copyWith(
        phase: WorkflowPhase.previewLoading,
        previewPath:
            event['path']?.toString() ??
            _state.previewPath ??
            _state.projectPath,
        previewToken: event['token']?.toString(),
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
    Log.d(
      'Recording',
      'Preview transitioned to loading',
      null,
      null,
      _previewLifecycleLogContext(event),
    );
  }

  void _handlePreviewReadyEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId) ||
        phase == WorkflowPhase.closingPreview) {
      return;
    }
    if (phase != WorkflowPhase.previewLoading &&
        phase != WorkflowPhase.openingPreview) {
      return;
    }

    _openingExternalProjectPath = null;
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.previewReady,
        previewPath:
            event['path']?.toString() ??
            _state.previewPath ??
            _state.projectPath,
        previewToken: event['token']?.toString(),
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
    Log.d(
      'Recording',
      'Preview transitioned to ready',
      null,
      null,
      _previewLifecycleLogContext(event),
    );
  }

  void _handlePreviewFailedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;

    final errorCode = event['reason']?.toString() ?? 'PREVIEW_ERROR';
    final errorMessage =
        event['error']?.toString() ?? event['reason']?.toString();
    Log.w('Recording', 'Preview failed', null, null, {
      ..._previewLifecycleLogContext(event),
      'errorCode': errorCode,
      'errorMessage': errorMessage,
    });
    _recordExternalProjectOpenFailureIfNeeded();
    _state = _state.copyWith(errorCode: errorCode, errorMessage: errorMessage);
    notifyListeners();
    unawaited(_beginPreviewClose(requestNativeClose: true));
  }

  void _handlePreviewClosedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;
    final reason = event['reason']?.toString() ?? 'unknown';
    Log.d('Recording', 'Received previewClosed event', null, null, {
      ..._previewLifecycleLogContext(event),
      'reason': reason,
    });
    if (phase != WorkflowPhase.closingPreview) {
      Log.d(
        'Recording',
        'Ignoring non-authoritative previewClosed',
        null,
        null,
        {'phase': phase.name, 'sessionId': eventSessionId, 'reason': reason},
      );
      return;
    }

    final pendingReplacementPath = _pendingExternalProjectReplacementPath;
    if (pendingReplacementPath != null && pendingReplacementPath.isNotEmpty) {
      _pendingExternalProjectReplacementPath = null;
      _enterPreviewForProject(
        projectPath: pendingReplacementPath,
        source: _PreviewOpenSource.externalProject,
      );
      return;
    }
    _transitionToIdle(clearError: false);
  }

  bool _isStaleSession(String? eventSessionId) {
    final activeSessionId = _state.sessionId;
    if (eventSessionId == null || activeSessionId == null) {
      return true;
    }
    if (eventSessionId != activeSessionId) {
      Log.d(
        'Recording',
        'Ignoring stale workflow event for session $eventSessionId while active session is $activeSessionId',
      );
      return true;
    }
    return false;
  }

  Future<void> _beginPreviewClose({required bool requestNativeClose}) async {
    final activeSessionId = _state.sessionId;
    if (activeSessionId == null) {
      _transitionToIdle(clearError: false);
      return;
    }

    _mountedPreviewSessionId = null;
    _previewOpenRequested = false;
    if (phase != WorkflowPhase.closingPreview) {
      _setState(_state.copyWith(phase: WorkflowPhase.closingPreview));
    }

    if (!requestNativeClose) return;

    try {
      await _nativeBridge.previewClose(sessionId: activeSessionId);
    } catch (e) {
      Log.e("Recording", "Failed to close preview: $e");
      _transitionToIdle(clearError: false);
    }
  }

  void _transitionToIdle({
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
  }) {
    _pauseResumeInFlight = false;
    _stopElapsedTicker();
    _resetElapsedTracking();
    _disarmAutoStopTimer();
    _startCommandIssued = false;
    _mountedPreviewSessionId = null;
    _previewOpenRequested = false;
    _previewOpenSource = null;
    _pendingExternalProjectReplacementPath = null;
    _openingExternalProjectPath = null;
    _pendingWarningMessage = null;
    Log.recordingId = null;
    _state = RecordingWorkflowState(
      phase: WorkflowPhase.idle,
      errorCode: clearError ? null : (errorCode ?? _state.errorCode),
      errorMessage: clearError ? null : (errorMessage ?? _state.errorMessage),
    );
    notifyListeners();
  }

  void _setState(RecordingWorkflowState nextState) {
    final changed = nextState != _state;
    _state = nextState;
    if (changed) {
      notifyListeners();
    }
  }

  void _enterPreviewForProject({
    required String projectPath,
    required _PreviewOpenSource source,
    String? sessionId,
  }) {
    final nextSessionId = sessionId ?? _generateSessionId();
    _pauseResumeInFlight = false;
    _stopElapsedTicker();
    _disarmAutoStopTimer();
    Log.recordingId = null;
    _startCommandIssued = false;
    _mountedPreviewSessionId = null;
    _previewOpenRequested = false;
    _previewOpenSource = source;
    _failedExternalProjectOpenPath = null;
    _pendingExternalProjectReplacementPath = null;
    _openingExternalProjectPath = source == _PreviewOpenSource.externalProject
        ? projectPath
        : null;
    _setState(
      _state.copyWith(
        phase: WorkflowPhase.openingPreview,
        sessionId: nextSessionId,
        projectPath: projectPath,
        previewPath: projectPath,
        clearPreviewToken: true,
        clearErrorCode: true,
        clearErrorMessage: true,
      ),
    );
  }

  void _recordExternalProjectOpenFailureIfNeeded() {
    final externalProjectPath = _openingExternalProjectPath;
    if (externalProjectPath == null || externalProjectPath.isEmpty) {
      return;
    }
    _failedExternalProjectOpenPath = externalProjectPath;
    _openingExternalProjectPath = null;
  }

  String _generateSessionId() {
    _sessionCounter += 1;
    final randomHex = _random
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    return 'rec_${DateTime.now().microsecondsSinceEpoch}_${_sessionCounter}_$randomHex';
  }

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (phase != WorkflowPhase.recording) return;
      _elapsed = _durationTracker.current();
      notifyListeners();
    });
    if (phase == WorkflowPhase.recording) {
      _elapsed = _durationTracker.current();
      notifyListeners();
    }
  }

  void _stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  void _resetElapsedTracking() {
    _durationTracker.reset();
    _elapsed = Duration.zero;
  }

  void _armAutoStopTimer() {
    _autoStopTimer?.cancel();
    if (_settings.recording.autoStopEnabled) {
      final remaining = _settings.recording.autoStopAfter - _elapsed;
      if (remaining <= Duration.zero) {
        unawaited(stopRecording(triggeredByAutoStop: true));
        return;
      }
      _autoStopTimer = Timer(remaining, () async {
        if (phase != WorkflowPhase.recording) return;
        await stopRecording(triggeredByAutoStop: true);
      });
    }
  }

  void _disarmAutoStopTimer() {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }

  @override
  void dispose() {
    _workflowSub.cancel();
    _settings.removeListener(_onSettingsChanged);
    _elapsedTicker?.cancel();
    _autoStopTimer?.cancel();
    _durationTracker.reset();
    super.dispose();
  }
}
