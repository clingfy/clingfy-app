import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_events.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_service.dart';
import 'package:clingfy/app/home/recording/recorded_duration_tracker.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

enum _PreviewOpenSource { recordingFinalized, externalProject }

/// A recordingWarning waiting to be shown, with the optional Windows
/// machine-readable code (see RecordingWarningCode).
class PendingRecordingWarning {
  const PendingRecordingWarning({required this.message, this.code});

  final String message;
  final String? code;
}

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
    // Phase 10.4: an onError-less subscription would silently detach the
    // controller from every future workflow event on the first stream
    // error. Log + breadcrumb and stay subscribed (cancelOnError is false).
    _workflowSub = _nativeBridge.workflowEvents.listen(
      _handleWorkflowEvent,
      onError: (Object error, StackTrace stack) {
        Log.e('Recording', 'Workflow event stream error', error, stack);
        unawaited(
          ClingfyTelemetry.addBreadcrumb(
            category: 'recording.workflow_stream',
            message: 'workflow event stream error: $error',
          ),
        );
      },
    );
    unawaited(refreshPauseResumeCapabilities());
  }

  /// Phase 10.4 (Windows): how long each transitional phase may wait for
  /// the native workflow event that advances it before the watchdog
  /// recovers the UI. Without these, a dropped native event leaves the app
  /// stuck in a busy phase forever (verified gap — nothing else recovers
  /// these phases). macOS keeps trusting native: no watchdogs are armed
  /// there so its behavior is unchanged.
  static const Map<WorkflowPhase, Duration> _defaultWatchdogDurations = {
    WorkflowPhase.startingRecording: Duration(seconds: 30),
    WorkflowPhase.finalizingRecording: Duration(seconds: 120),
    WorkflowPhase.openingPreview: Duration(seconds: 30),
    WorkflowPhase.previewLoading: Duration(seconds: 30),
    WorkflowPhase.closingPreview: Duration(seconds: 15),
  };

  /// Test seam: per-phase overrides for the watchdog durations. Phases not
  /// present fall back to [_defaultWatchdogDurations]. Reset to null in
  /// test tearDown.
  @visibleForTesting
  static Map<WorkflowPhase, Duration>? debugWatchdogDurations;

  final NativeBridge _nativeBridge;
  final SettingsController _settings;
  final Random _random = Random.secure();

  late final StreamSubscription<Map<String, dynamic>> _workflowSub;

  RecordingWorkflowState _state = const RecordingWorkflowState.idle();
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTicker;
  Timer? _autoStopTimer;
  Timer? _phaseWatchdog;
  WorkflowPhase? _watchdogPhase;
  String? _watchdogSessionId;
  int _sessionCounter = 0;
  bool _startCommandIssued = false;
  String? _mountedPreviewSessionId;
  bool _previewOpenRequested = false;
  // Step 5.5.2: Flutter texture id returned by Windows previewOpen so
  // the InlinePreview widget can mount `Texture(textureId: ...)`. null
  // on macOS (AppKitView path) and until the native call completes.
  int? _inlinePreviewTextureId;
  // The native canvas aspect (previewOpen width/height — the fixed texture
  // the engine letterboxes video into). The InlinePreview widget must show
  // the texture at exactly this aspect: a bare `Texture` stretches to its
  // layout box, distorting the video whenever the panel isn't canvas-shaped
  // (side panel closed, timeline hidden). null until previewOpen replies.
  double? _inlinePreviewTextureAspect;
  bool _pauseResumeInFlight = false;
  _PreviewOpenSource? _previewOpenSource;
  String? _pendingExternalProjectReplacementPath;
  String? _openingExternalProjectPath;
  String? _failedExternalProjectOpenPath;
  String? _pendingWarningMessage;
  String? _pendingWarningCode;
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

  /// Phase 10.3: what the toolbar should feed the error mapper. On Windows
  /// the CODE wins (native messages are hardcoded English; the mapper
  /// localizes codes), with the prose kept as [displayErrorFallback] for
  /// unmapped codes. On macOS native messages are already localized, so
  /// prose keeps winning.
  String? get displayError => isWindows()
      ? (_state.errorCode ?? _state.errorMessage)
      : (_state.errorMessage ?? _state.errorCode);

  /// The native prose to show when [displayError] is a code the mapper
  /// doesn't recognize (better than rendering the raw token).
  String? get displayErrorFallback => _state.errorMessage;
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
  // The timeline stays visible during export so the user can keep scrubbing
  // the preview; editing is disabled for the duration (VideoTimeline's
  // editingEnabled, driven by isExporting).
  bool get showTimelineBar =>
      phase == WorkflowPhase.previewReady || phase == WorkflowPhase.exporting;
  bool get showPreRecordingBar => phase == WorkflowPhase.idle;
  bool get shouldNotifyRecordingFinalizedOnPreviewOpen =>
      _previewOpenSource == _PreviewOpenSource.recordingFinalized;

  /// Step 5.5.2: Windows-only Flutter texture id from the latest
  /// `previewOpen` reply. macOS uses an AppKit platform view and never
  /// produces a texture id. Cleared by `_beginPreviewClose` and on
  /// `_transitionToIdle`.
  int? get inlinePreviewTextureId => _inlinePreviewTextureId;

  /// Aspect ratio (width / height) of the native preview canvas the texture
  /// id points at, from the same `previewOpen` reply; null until the reply
  /// arrives (the widget falls back to 16:9, the engine's canvas shape).
  double? get inlinePreviewTextureAspect => _inlinePreviewTextureAspect;

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
    _pendingWarningCode = null;
    _syncPhaseWatchdog();
    notifyListeners();
  }

  String? consumePendingWarningMessage() {
    final warning = _pendingWarningMessage;
    _pendingWarningMessage = null;
    _pendingWarningCode = null;
    return warning;
  }

  /// Phase 10.2: read-and-clear the pending warning together with its
  /// optional machine-readable code (Windows-only; null on macOS).
  PendingRecordingWarning? consumePendingWarning() {
    final message = _pendingWarningMessage;
    final code = _pendingWarningCode;
    _pendingWarningMessage = null;
    _pendingWarningCode = null;
    if (message == null || message.isEmpty) return null;
    return PendingRecordingWarning(message: message, code: code);
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
        errorCode: NativeErrorCode.recordingError,
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
      _restoreAfterStopFailure(
        previousState,
        NativeErrorCode.recordingError,
        e.toString(),
      );
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
          errorCode: NativeErrorCode.recordingError,
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
          errorCode: NativeErrorCode.recordingError,
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
      final openResult = await _nativeBridge.previewOpen(
        sessionId: activeSessionId,
        projectPath: path,
      );
      // Stale-session guard: if the user already pressed close while
      // native was warming the texture, drop the id on the floor.
      if (_mountedPreviewSessionId == activeSessionId &&
          _previewOpenRequested) {
        _inlinePreviewTextureId = openResult.hasTexture
            ? openResult.textureId
            : null;
        _inlinePreviewTextureAspect =
            (openResult.hasTexture &&
                openResult.width > 0 &&
                openResult.height > 0)
            ? openResult.width / openResult.height
            : null;
        Log.d('Recording', 'previewOpen returned', null, null, {
          'sessionId': activeSessionId,
          'textureId': _inlinePreviewTextureId,
          'width': openResult.width,
          'height': openResult.height,
          'videoWidth': openResult.videoWidth,
          'videoHeight': openResult.videoHeight,
          'sharedHandleOk': openResult.sharedHandleOk,
        });
        notifyListeners();
      }
    } catch (e, st) {
      Log.e("Recording", "Failed to open preview: $e", e, st);
      _recordExternalProjectOpenFailureIfNeeded();
      // Keep the structured PlatformException code (PREVIEW_INPUT_MISSING
      // etc.) so the mapper can localize it; the full toString was an
      // unlocalizable wall of text.
      _state = _state.copyWith(
        errorCode: e is PlatformException
            ? e.code
            : NativeErrorCode.previewOpenError,
        errorMessage: e is PlatformException
            ? _normalizedPlatformErrorMessage(e)
            : e.toString(),
      );
      notifyListeners();
      await _beginPreviewClose(requestNativeClose: false);
      // Thread the SAME structured values — passing the generic
      // PREVIEW_OPEN_ERROR/toString here would clobber the code set above
      // and make the PREVIEW_INPUT_MISSING mapper case unreachable.
      _transitionToIdle(
        errorCode: e is PlatformException
            ? e.code
            : NativeErrorCode.previewOpenError,
        errorMessage: e is PlatformException
            ? _normalizedPlatformErrorMessage(e)
            : e.toString(),
      );
    }
  }

  Future<void> closePreview() async {
    if (!showPreviewShell || phase == WorkflowPhase.exporting) return;
    await _beginPreviewClose(requestNativeClose: true);
  }

  /// Silently close and reopen the native preview session in place, keeping
  /// the same session id and workflow phase. Windows-only recovery driven by
  /// the `previewInvalidated` player event (the D3D device backing the
  /// session died — a Modern Standby / suspend resume). Unlike
  /// [_beginPreviewClose] + [_enterPreviewForProject] this never transitions
  /// the phase, never shows the loading overlay, and never remounts the
  /// preview subtree — only the texture id/aspect change, which the inline
  /// preview widget re-renders in place. Returns true when the reopen
  /// produced a usable texture.
  Future<bool> reopenInlinePreviewInPlace() async {
    final activeSessionId = _state.sessionId;
    final path = _state.previewPath ?? _state.projectPath;
    if (activeSessionId == null ||
        path == null ||
        (phase != WorkflowPhase.previewReady &&
            phase != WorkflowPhase.exporting)) {
      return false;
    }
    Log.w(
      'Recording',
      'Rebuilding the invalidated preview session in place',
      null,
      null,
      {'sessionId': activeSessionId, 'path': path},
    );
    bool sessionStillActive() =>
        _state.sessionId == activeSessionId &&
        (phase == WorkflowPhase.previewReady ||
            phase == WorkflowPhase.exporting);

    try {
      await _nativeBridge.previewClose(sessionId: activeSessionId);
      // Re-check BEFORE reopening: the close await is the widest window in
      // the rebuild (native joins the render/heartbeat threads), and a user
      // action landing in it (close button, replace-with-project) must win —
      // issuing previewOpen for the abandoned session would resurrect it
      // natively with no Dart owner.
      if (!sessionStillActive()) {
        return false;
      }
      final openResult = await _nativeBridge.previewOpen(
        sessionId: activeSessionId,
        projectPath: path,
      );
      // The session may also have been closed or replaced while the reopen
      // itself was in flight — don't resurrect texture state for a session
      // that is no longer active, and tear the freshly opened native session
      // back down instead of orphaning it until the next open's reconcile.
      if (!sessionStillActive()) {
        unawaited(
          _nativeBridge
              .previewClose(sessionId: activeSessionId)
              .catchError((Object _) {}),
        );
        return false;
      }
      _inlinePreviewTextureId = openResult.hasTexture
          ? openResult.textureId
          : null;
      _inlinePreviewTextureAspect =
          (openResult.hasTexture &&
              openResult.width > 0 &&
              openResult.height > 0)
          ? openResult.width / openResult.height
          : null;
      notifyListeners();
      return openResult.hasTexture;
    } catch (e, st) {
      Log.e('Recording', 'Failed to rebuild the invalidated preview', e, st, {
        'sessionId': activeSessionId,
      });
      return false;
    }
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

    if (type == WorkflowEventType.previewPreparing ||
        type == WorkflowEventType.previewReady ||
        type == WorkflowEventType.previewFailed ||
        type == WorkflowEventType.previewClosed ||
        type == WorkflowEventType.recordingFinalized ||
        type == WorkflowEventType.recordingFinished) {
      Log.d('Recording', 'Received $type workflow event', null, null, {
        ..._previewLifecycleLogContext(event),
      });
    }

    switch (type) {
      case WorkflowEventType.recordingStarted:
        _handleRecordingStartedEvent(event);
        return;
      case WorkflowEventType.recordingPaused:
        _handleRecordingPausedEvent(event);
        return;
      case WorkflowEventType.recordingResumed:
        _handleRecordingResumedEvent(event);
        return;
      case WorkflowEventType.recordingFinalized:
      case WorkflowEventType.recordingFinished:
        _handleRecordingFinalizedEvent(event);
        return;
      case WorkflowEventType.recordingFailed:
        _handleRecordingFailedEvent(event);
        return;
      case WorkflowEventType.recordingWarning:
        _handleRecordingWarningEvent(event);
        return;
      case WorkflowEventType.previewPreparing:
        _handlePreviewPreparingEvent(event);
        return;
      case WorkflowEventType.previewReady:
        _handlePreviewReadyEvent(event);
        return;
      case WorkflowEventType.previewFailed:
        _handlePreviewFailedEvent(event);
        return;
      case WorkflowEventType.previewClosed:
        _handlePreviewClosedEvent(event);
        return;
      case WorkflowEventType.openProjectRequest:
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
    ClingfyAnalytics.capture(
      AnalyticsEvents.recordingSessionStart,
      properties: {
        'fps': _settings.recording.captureFrameRate,
        'system_audio': _settings.recording.systemAudioEnabled,
      },
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
    // Phase 10.4: openingPreview joins the ignore-list so a duplicate
    // finalized event cannot re-enter _enterPreviewForProject and restart
    // the preview open that the first event already kicked off.
    if (phase == WorkflowPhase.closingPreview ||
        phase == WorkflowPhase.openingPreview ||
        phase == WorkflowPhase.previewLoading ||
        phase == WorkflowPhase.previewReady ||
        phase == WorkflowPhase.exporting) {
      return;
    }

    final projectPath = event['projectPath']?.toString();
    if (projectPath == null || projectPath.isEmpty) {
      _handleRecordingFailedEvent({
        'type': WorkflowEventType.recordingFailed,
        'sessionId': eventSessionId,
        'stage': 'finalize',
        'code': DartSynthesizedErrorCode.recordingFinalizeError,
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
    ClingfyAnalytics.capture(
      AnalyticsEvents.recordingSessionComplete,
      properties: {'duration_seconds': _elapsed.inSeconds},
    );
  }

  void _handleRecordingFailedEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_isStaleSession(eventSessionId)) return;

    final code =
        event['code']?.toString() ??
        event['stage']?.toString() ??
        NativeErrorCode.recordingError;
    final error = event['error']?.toString();

    // Phase 10.4: once the workflow reached a preview (or export) phase the
    // recording already finalized successfully — native cannot legitimately
    // fail it afterwards. Tearing the workflow down over a late/duplicate
    // failure event would discard a recording the user can already see
    // (review fix: `exporting` added so a mid-export event can't yank the
    // shell to idle under a live export, matching the finalized handler's
    // ignore list).
    if (phase == WorkflowPhase.openingPreview ||
        phase == WorkflowPhase.previewLoading ||
        phase == WorkflowPhase.previewReady ||
        phase == WorkflowPhase.closingPreview ||
        phase == WorkflowPhase.exporting) {
      Log.w(
        'Recording',
        'Ignoring recordingFailed during preview phase ${phase.name}',
        null,
        null,
        {
          'phase': phase.name,
          'sessionId': eventSessionId,
          'code': code,
          'error': error,
        },
      );
      unawaited(
        ClingfyTelemetry.addBreadcrumb(
          category: 'recording.workflow',
          message: 'recordingFailed ignored during ${phase.name}',
          data: {'code': code, 'sessionId': eventSessionId},
        ),
      );
      return;
    }

    // Phase 10.4: this event path previously logged nothing — mid-recording
    // native failures never reached the JSONL log or Sentry unless the
    // start call itself threw.
    Log.e('Recording', 'Native recordingFailed event: $code', null, null, {
      'phase': phase.name,
      'sessionId': eventSessionId,
      'code': code,
      'error': error,
      'stage': event['stage']?.toString(),
    });
    // Review fix: a refused START is reported on BOTH surfaces by native
    // (the recordingFailed event AND an error reply to the startRecording
    // call, on macOS and Windows alike). The startRecording catch already
    // captures that to Sentry — capturing here too double-reported every
    // failed start. Mid-recording/finalize failures arrive only as events,
    // so those still capture here.
    // One failure = one analytics event, whichever surface reports it first (the method catch
    // does NOT capture analytics, so no double-count here — unlike the Sentry split below).
    ClingfyAnalytics.capture(
      AnalyticsEvents.recordingSessionFail,
      properties: {
        'stage': phase == WorkflowPhase.startingRecording ? 'start' : 'recording',
        'error_code': code,
      },
    );
    final isStartFailureOwnedByMethodCatch =
        phase == WorkflowPhase.startingRecording && _startCommandIssued;
    if (!isStartFailureOwnedByMethodCatch) {
      unawaited(
        ClingfyTelemetry.captureError(
          PlatformException(code: code, message: error),
          method: 'workflow.recordingFailed',
          context: {
            'phase': phase.name,
            'sessionId': eventSessionId,
            'stage': event['stage']?.toString(),
          },
        ),
      );
    }

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

    // Phase 10.2: Windows attaches a machine-readable code (see
    // RecordingWarningCode) so the UI can localize the toast and offer the
    // right settings action. Absent on macOS — message renders verbatim.
    final code = event['code']?.toString();
    _pendingWarningMessage = message;
    _pendingWarningCode = (code == null || code.trim().isEmpty) ? null : code;
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

    // Windows sends `code` (workflow_event_publisher.cpp); macOS sends
    // `reason`. Reading only `reason` dropped the Windows code entirely.
    final errorCode =
        event['code']?.toString() ??
        event['reason']?.toString() ??
        DartSynthesizedErrorCode.previewError;
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
    _inlinePreviewTextureId = null;
    _inlinePreviewTextureAspect = null;
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
    _inlinePreviewTextureId = null;
    _inlinePreviewTextureAspect = null;
    _previewOpenSource = null;
    _pendingExternalProjectReplacementPath = null;
    _openingExternalProjectPath = null;
    _pendingWarningMessage = null;
    _pendingWarningCode = null;
    Log.recordingId = null;
    _state = RecordingWorkflowState(
      phase: WorkflowPhase.idle,
      errorCode: clearError ? null : (errorCode ?? _state.errorCode),
      errorMessage: clearError ? null : (errorMessage ?? _state.errorMessage),
    );
    _syncPhaseWatchdog();
    notifyListeners();
  }

  void _setState(RecordingWorkflowState nextState) {
    final changed = nextState != _state;
    _state = nextState;
    _syncPhaseWatchdog();
    if (changed) {
      notifyListeners();
    }
  }

  /// Phase 10.4: (re)arm or cancel the phase watchdog after any phase (or
  /// in-phase session) change. Must be called by every state-mutation site
  /// that can change [WorkflowPhase]. No-op on macOS.
  void _syncPhaseWatchdog() {
    final currentPhase = _state.phase;
    if (_watchdogPhase == currentPhase &&
        _watchdogSessionId == _state.sessionId) {
      return;
    }
    _phaseWatchdog?.cancel();
    _phaseWatchdog = null;
    _watchdogPhase = currentPhase;
    _watchdogSessionId = _state.sessionId;
    if (!isWindows()) return;

    final duration =
        debugWatchdogDurations?[currentPhase] ??
        _defaultWatchdogDurations[currentPhase];
    if (duration == null) return;

    final armedSessionId = _state.sessionId;
    _phaseWatchdog = Timer(duration, () {
      _onPhaseWatchdogFired(currentPhase, armedSessionId, duration);
    });
  }

  void _onPhaseWatchdogFired(
    WorkflowPhase armedPhase,
    String? armedSessionId,
    Duration duration,
  ) {
    // Stale fire: the phase (or session) already moved on. The timer is
    // canceled on every transition, so this is belt-and-braces only.
    if (_state.phase != armedPhase || _state.sessionId != armedSessionId) {
      return;
    }
    _phaseWatchdog = null;

    Log.e(
      'Recording',
      'Watchdog: no native workflow event after ${duration.inSeconds}s in '
          '${armedPhase.name}; recovering UI',
      null,
      null,
      {
        'phase': armedPhase.name,
        'sessionId': armedSessionId,
        'projectPath': _state.projectPath,
        'watchdogSeconds': duration.inSeconds,
      },
    );
    unawaited(
      ClingfyTelemetry.captureError(
        TimeoutException(
          'Workflow watchdog expired in ${armedPhase.name}',
          duration,
        ),
        method: 'workflow.watchdog',
        context: {
          'phase': armedPhase.name,
          'sessionId': armedSessionId,
          'projectPath': _state.projectPath,
          'watchdogMs': duration.inMilliseconds,
        },
      ),
    );

    switch (armedPhase) {
      case WorkflowPhase.startingRecording:
        // Review fix: UI-only recovery orphaned a live native capture —
        // native may have started (the event was lost/late) and would keep
        // recording with the UI idle, refusing every future start. Issue a
        // best-effort native stop for the armed session first; the engine's
        // Stop is idempotent and safely no-ops if the start never landed.
        unawaited(_invokeNativeStopQuietly(armedSessionId));
        unawaited(ClingfyTelemetry.stopSession());
        _transitionToIdle(
          errorCode: DartSynthesizedErrorCode.recordingStartTimeout,
        );
      case WorkflowPhase.finalizingRecording:
        // Same rationale: a still-finalizing native session would emit a
        // late recordingFinalized into a stale-dropped void; the stop is a
        // no-op if the session already settled.
        unawaited(_invokeNativeStopQuietly(armedSessionId));
        unawaited(ClingfyTelemetry.stopSession());
        _transitionToIdle(
          errorCode: DartSynthesizedErrorCode.recordingFinalizeTimeout,
        );
      case WorkflowPhase.openingPreview:
      case WorkflowPhase.previewLoading:
        // Same shape as a native previewFailed with PREVIEW_TIMEOUT; the
        // closingPreview watchdog backstops the close request below.
        _recordExternalProjectOpenFailureIfNeeded();
        _state = _state.copyWith(
          errorCode: DartSynthesizedErrorCode.previewTimeout,
        );
        notifyListeners();
        unawaited(_beginPreviewClose(requestNativeClose: true));
      case WorkflowPhase.closingPreview:
        // Mirror the previewClosed handler: back to idle, KEEPING any
        // existing error (e.g. the PREVIEW_TIMEOUT set above).
        _transitionToIdle(clearError: false);
      default:
        break;
    }
  }

  /// Review fix (Phase 10.4): best-effort native stop used by the
  /// start/finalize watchdogs. Without it the watchdog recovered the UI
  /// only — a live native capture kept recording invisibly, refused every
  /// future start, and could only be ended by closing the app. The engine's
  /// stop is idempotent, so this is safe when the session never actually
  /// started or already settled. All errors are swallowed: the watchdog has
  /// already reported the underlying timeout.
  Future<void> _invokeNativeStopQuietly(String? sessionId) async {
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }
    try {
      await _nativeBridge.invokeMethod<void>('stopRecording', {
        'sessionId': sessionId,
      });
    } catch (e) {
      Log.w('Recording', 'watchdog best-effort native stop failed: $e');
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
    _inlinePreviewTextureId = null;
    _inlinePreviewTextureAspect = null;
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
    _phaseWatchdog?.cancel();
    _phaseWatchdog = null;
    _durationTracker.reset();
    super.dispose();
  }
}
