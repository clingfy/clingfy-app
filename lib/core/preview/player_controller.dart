import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';

class PlayerController extends ChangeNotifier {
  PlayerController({required NativeBridge nativeBridge})
    : _nativeBridge = nativeBridge {
    _listenPlayer();
  }

  final NativeBridge _nativeBridge;

  StreamSubscription<Map<String, dynamic>>? _playerSub;
  RecordingController? _workflow;

  int _posMs = 0;
  int _durMs = 0;
  bool _scrubbing = false;
  bool _playerReady = false;
  bool _playerPlaying = false;
  bool _isPeeking = false;

  String? _blockingError;
  String? _blockingErrorCode;
  String? _activeSessionId;
  String? _activePreviewPath;

  final _warningController = StreamController<String>.broadcast();
  final _warningCodeController = StreamController<String>.broadcast();
  final _cameraManualPositionController = StreamController<Offset>.broadcast();

  ZoomEditorController? _zoomEditor;
  VoidCallback? _zoomEditorListener;

  int get positionMs => _posMs;
  int get durationMs => _durMs;
  bool get isScrubbing => _scrubbing;
  bool get isReady => _playerReady;
  bool get isPlaying => _playerPlaying;
  String? get blockingError => _blockingError;
  String? get blockingErrorCode => _blockingErrorCode;
  Stream<String> get warningStream => _warningController.stream;
  Stream<String> get warningCodeStream => _warningCodeController.stream;
  Stream<Offset> get cameraManualPositionStream =>
      _cameraManualPositionController.stream;
  ZoomEditorController? get zoomEditor => _zoomEditor;
  List<ZoomSegment> get zoomSegments => _zoomSegments;
  List<ZoomSegment>? get previewCompositionZoomSegments => _zoomEditor == null
      ? null
      : List<ZoomSegment>.unmodifiable(_zoomSegments);

  List<ZoomSegment> _zoomSegments = [];

  void bindWorkflow(RecordingController workflow) {
    if (identical(_workflow, workflow)) return;
    _workflow?.removeListener(_syncWithWorkflow);
    _workflow = workflow;
    _workflow?.addListener(_syncWithWorkflow);
    _syncWithWorkflow();
  }

  void _listenPlayer() {
    _playerSub?.cancel();
    _playerSub = _nativeBridge.playerEvents.listen((event) {
      final type = event['type']?.toString();
      if (type == null || _isStaleEvent(event)) return;

      switch (type) {
        case 'playerTick':
          if (!_scrubbing && !_isPeeking) {
            _posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
            _durMs = (event['durationMs'] as num?)?.toInt() ?? 0;
            _playerReady = _durMs > 0;
            if (_playerReady &&
                _zoomEditor == null &&
                _activeSessionId != null &&
                _activePreviewPath != null &&
                (_workflow?.phase == WorkflowPhase.previewReady ||
                    _workflow?.phase == WorkflowPhase.exporting)) {
              unawaited(
                _attachZoomEditor(_activeSessionId!, _activePreviewPath!),
              );
            }
            notifyListeners();
          }
          return;
        case 'playerState':
          final state = event['state'] as String?;
          if (state == 'playing') {
            _playerPlaying = true;
          } else if (state == 'paused') {
            _playerPlaying = false;
          } else if (state == 'completed') {
            _playerPlaying = false;
            _posMs = 0;
          }
          notifyListeners();
          return;
        case 'playerError':
          Log.e('Player', 'Native player error', null, null, {
            'message': event['message']?.toString(),
            'code': event['code']?.toString(),
            'sessionId': event['sessionId']?.toString(),
          });
          _blockingError = event['message'] as String? ?? 'Unknown error';
          _blockingErrorCode = event['code'] as String?;
          notifyListeners();
          return;
        case 'playerWarning':
          final message = event['message'] as String? ?? 'Warning';
          final code = event['code'] as String?;
          _warningController.add(message);
          if (code != null) {
            _warningCodeController.add(code);
          }
          return;
        case 'debug':
          Log.d("Player", "Native: ${event['message']}");
          return;
        case 'cameraManualPositionChanged':
          final x = (event['normalizedX'] as num?)?.toDouble();
          final y = (event['normalizedY'] as num?)?.toDouble();
          if (x != null && y != null) {
            _cameraManualPositionController.add(Offset(x, y));
          }
          return;
        default:
          return;
      }
    });
  }

  bool _isStaleEvent(Map<String, dynamic> event) {
    final eventSessionId = event['sessionId']?.toString();
    if (_activeSessionId == null) {
      return eventSessionId != null;
    }
    if (eventSessionId == null) {
      Log.d(
        'Player',
        'Ignoring player event without sessionId while active session is $_activeSessionId',
      );
      return true;
    }
    if (eventSessionId != _activeSessionId) {
      Log.d(
        'Player',
        'Ignoring stale player event for session $eventSessionId while active session is $_activeSessionId',
      );
      return true;
    }
    return false;
  }

  void _syncWithWorkflow() {
    final workflow = _workflow;
    if (workflow == null) return;

    final nextSessionId = workflow.sessionId;
    final nextPreviewPath = workflow.previewPath;
    final nextProjectPath = workflow.projectPath;
    final workflowAllowsPreview =
        workflow.phase == WorkflowPhase.previewReady ||
        workflow.phase == WorkflowPhase.exporting;

    if (workflowAllowsPreview &&
        nextSessionId != null &&
        nextPreviewPath != null &&
        (_activeSessionId != nextSessionId ||
            _activePreviewPath != nextPreviewPath)) {
      _activeSessionId = nextSessionId;
      _activePreviewPath = nextPreviewPath;
      _blockingError = null;
      _blockingErrorCode = null;
      _playerReady = false;
      if (_durMs > 0 && nextProjectPath != null) {
        unawaited(_attachZoomEditor(nextSessionId, nextProjectPath));
      } else {
        _detachZoomEditor();
      }
      notifyListeners();
      return;
    }

    if (workflow.phase == WorkflowPhase.openingPreview ||
        workflow.phase == WorkflowPhase.previewLoading) {
      if (_activeSessionId != nextSessionId) {
        _clearPlaybackState(detachZoomEditor: true);
        _activeSessionId = nextSessionId;
        _activePreviewPath = nextPreviewPath;
      }
      return;
    }

    if (!workflow.showPreviewShell ||
        workflow.phase == WorkflowPhase.closingPreview) {
      if (_activeSessionId != null || _zoomEditor != null || _playerReady) {
        _activeSessionId = null;
        _activePreviewPath = null;
        _clearPlaybackState(detachZoomEditor: true);
      }
    }
  }

  Future<void> _attachZoomEditor(String sessionId, String path) async {
    _detachZoomEditor();

    final editor = ZoomEditorController(
      nativeBridge: _nativeBridge,
      videoPath: path,
      durationMs: _durMs,
      sessionId: sessionId,
    );
    _zoomEditor = editor;
    await editor.init();
    _zoomSegments = editor.effectiveZoomSegments;
    notifyListeners();

    void listener() {
      if (_zoomEditor != editor) return;
      _zoomSegments = editor.effectiveZoomSegments;
      notifyListeners();
    }

    _zoomEditorListener = listener;
    editor.addListener(listener);
  }

  void _detachZoomEditor() {
    final editor = _zoomEditor;
    final listener = _zoomEditorListener;

    if (editor != null && listener != null) {
      editor.removeListener(listener);
    }

    editor?.dispose();
    _zoomEditor = null;
    _zoomEditorListener = null;
    _zoomSegments = [];
  }

  void _clearPlaybackState({required bool detachZoomEditor}) {
    _blockingError = null;
    _blockingErrorCode = null;
    _posMs = 0;
    _durMs = 0;
    _scrubbing = false;
    _playerReady = false;
    _playerPlaying = false;
    _isPeeking = false;
    if (detachZoomEditor) {
      _detachZoomEditor();
    }
    notifyListeners();
  }

  Future<void> play() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    await _nativeBridge.invokeMethod('previewPlay', {'sessionId': sessionId});
    _playerPlaying = true;
    notifyListeners();
  }

  Future<void> pause() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    await _nativeBridge.invokeMethod('previewPause', {'sessionId': sessionId});
    _playerPlaying = false;
    notifyListeners();
  }

  Future<void> seekTo(int ms) async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    _posMs = ms;
    Log.d("Player", "seekTo: $ms ms");
    notifyListeners();
    await _nativeBridge.invokeMethod('previewSeekTo', {
      'sessionId': sessionId,
      'ms': ms,
    });
  }

  Future<void> previewPeekTo(int ms) async {
    final sessionId = _activeSessionId;
    if (sessionId == null || _playerPlaying) return;

    _isPeeking = true;
    await _nativeBridge.invokeMethod('previewPeekTo', {
      'sessionId': sessionId,
      'ms': ms,
    });
  }

  Future<void> previewPeekEnd() async {
    if (!_isPeeking) return;
    _isPeeking = false;
    if (_playerPlaying) return;
    await seekTo(_posMs);
  }

  void setScrubbing(bool value) {
    _scrubbing = value;
    notifyListeners();
  }

  void clearError() {
    if (_blockingError == null && _blockingErrorCode == null) return;
    _blockingError = null;
    _blockingErrorCode = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _workflow?.removeListener(_syncWithWorkflow);
    _playerSub?.cancel();
    _warningController.close();
    _warningCodeController.close();
    _cameraManualPositionController.close();
    _detachZoomEditor();
    super.dispose();
  }
}
