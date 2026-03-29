import 'dart:async';
import 'package:clingfy/app/config/build_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/home/post_processing/support/audio_debouncer.dart';
import 'package:clingfy/app/home/export/widgets/export_file_dialog.dart';
import 'package:clingfy/core/preview/player_controller.dart';

class PostProcessingController extends ChangeNotifier {
  final NativeBridge _nativeBridge;
  final SettingsController _settings;
  final PlayerController _player;

  PostProcessingController({
    required SettingsController settings,
    required PlayerController player,
    required NativeBridge channel,
  }) : _settings = settings,
       _player = player,
       _nativeBridge = channel {
    _player.addListener(
      notifyListeners,
    ); // Propagate player state changes (like error)
    _warningSub = _player.warningCodeStream.listen(_onPlayerWarning);
    _cameraManualPositionSub = _player.cameraManualPositionStream.listen(
      _onCameraManualPositionChanged,
    );
    _resetForNewRecording();
  }

  @override
  void dispose() {
    _player.removeListener(notifyListeners);
    _warningSub?.cancel();
    _cameraManualPositionSub?.cancel();
    _audioPreviewDebouncer.dispose();
    super.dispose();
  }

  StreamSubscription? _warningSub;
  StreamSubscription<Offset>? _cameraManualPositionSub;
  ISentrySpan? _activeExportTransaction;
  ISentrySpan? _activeExportInvokeSpan;
  bool _isExportCancelRequested = false;

  void _onPlayerWarning(String code) {
    if (code == 'CURSOR_FILE_MISSING') {
      _cursorAvailable = false;
      if (_showCursor) {
        _showCursor = false; // Force disable
        // We do NOT call applyProcessing explicitly here to avoid loops,
        // but user will see switch off.
        notifyListeners();
      }
    }
  }

  void _onCameraManualPositionChanged(Offset center) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(
        center.dx.clamp(0.0, 1.0),
        center.dy.clamp(0.0, 1.0),
      ),
    );
    notifyListeners();
  }

  // --- State Fields ---
  bool _isProcessingPreview = false;

  // Export State
  bool _isExporting = false;
  bool _isExportInBackground = false;
  bool _lastExportWasCancelled = false;
  bool _hasExportedCurrentRecording = false;
  double? _exportProgress; // null = indeterminate, 0.0-1.0 = determinate

  double _videoPadding = 0; // 0 to 100
  double _videoRadius = 0; // 0 to 50
  int? _backgroundColor; // null = black default
  String? _backgroundImagePath;
  double _cursorSize = 1.0;
  double _zoomFactor = 1.5;
  bool _showCursor = true;
  String? _previewPath;
  String? _sourcePath;
  String? _activeSessionId;
  bool _cursorAvailable = true;
  double _audioGainDb = 0.0;
  double _audioVolumePercent = 100.0;
  String? _cameraPath;
  CameraCompositionState? _cameraState;
  CameraExportCapabilities _cameraExportCapabilities =
      const CameraExportCapabilities.allSupported();
  final AudioDebouncer _audioPreviewDebouncer = AudioDebouncer(
    delay: Duration(milliseconds: 150),
  );

  // --- Getters ---
  bool get processing => _isProcessingPreview;
  bool get isEditingLocked => _isProcessingPreview || _isExporting;
  bool get isExporting => _isExporting;
  bool get isExportCancelRequested => _isExportCancelRequested;
  bool get isExportInBackground => _isExportInBackground;
  bool get isExportDockCollapsed => _isExportInBackground;
  bool get lastExportWasCancelled => _lastExportWasCancelled;
  bool get hasExportedCurrentRecording => _hasExportedCurrentRecording;
  double? get exportProgress => _exportProgress;

  double get padding => _videoPadding;
  double get radius => _videoRadius;
  int? get backgroundColor => _backgroundColor;
  String? get backgroundImagePath => _backgroundImagePath;
  double get cursorSize => _cursorSize;
  double get zoomFactor => _zoomFactor;
  bool get showCursor => _showCursor;
  String? get previewPath => _previewPath;
  bool get cursorAvailable => _cursorAvailable;
  double get audioGainDb => _audioGainDb;
  double get audioVolumePercent => _audioVolumePercent;
  String? get cameraPath => _cameraPath;
  bool get hasCameraAsset => _cameraPath != null && _cameraPath!.isNotEmpty;
  CameraCompositionState? get cameraState => _cameraState;
  CameraExportCapabilities get cameraExportCapabilities =>
      _cameraExportCapabilities;

  // Computed error state
  bool get hasError => _player.blockingError != null;

  // --- Setters ---

  void setLayoutPreset(LayoutPreset v) {
    _settings.post.updateLayoutPreset(v);
    applyProcessing();
  }

  void setResolutionPreset(ResolutionPreset v) {
    _settings.post.updateResolutionPreset(v);
    applyProcessing();
  }

  void setFitMode(FitMode v) {
    _settings.post.updateFitMode(v);
    applyProcessing();
  }

  void setPadding(double v) {
    _videoPadding = v;
    notifyListeners();
  }

  void setRadius(double v) {
    _videoRadius = v;
    notifyListeners();
  }

  void setBackgroundColor(int? v) {
    _backgroundColor = v;
    _backgroundImagePath = null;
    notifyListeners();
    applyProcessing();
  }

  void setBackgroundImagePath(String? path) {
    _backgroundImagePath = path;
    _backgroundColor = null;
    notifyListeners();
    applyProcessing();
  }

  void setCursorSize(double v) {
    _cursorSize = v;
    notifyListeners();
  }

  void setZoomFactor(double v) {
    _zoomFactor = v;
    notifyListeners();
  }

  void setShowCursor(bool v) {
    _showCursor = v;
    notifyListeners();
    applyProcessing();
  }

  void setCameraVisible(bool visible) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(visible: visible);
    notifyListeners();
    applyProcessing();
  }

  void setCameraLayoutPreset(CameraLayoutPreset preset) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      layoutPreset: preset,
      clearNormalizedCanvasCenter: true,
    );
    notifyListeners();
    applyProcessing();
  }

  void setCameraSizeFactor(double sizeFactor) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(sizeFactor: sizeFactor.clamp(0.08, 0.45));
    notifyListeners();
  }

  void setCameraSizeFactorEnd(double sizeFactor) {
    setCameraSizeFactor(sizeFactor);
    applyProcessing();
  }

  void setCameraShape(CameraShape shape) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(shape: shape);
    notifyListeners();
    applyProcessing();
  }

  void setCameraCornerRadius(double cornerRadius) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(cornerRadius: cornerRadius.clamp(0.0, 0.5));
    notifyListeners();
  }

  void setCameraCornerRadiusEnd(double cornerRadius) {
    setCameraCornerRadius(cornerRadius);
    applyProcessing();
  }

  void setCameraMirror(bool mirror) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(mirror: mirror);
    notifyListeners();
    applyProcessing();
  }

  void setCameraContentMode(CameraContentMode contentMode) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(contentMode: contentMode);
    notifyListeners();
    applyProcessing();
  }

  void setCameraZoomBehavior(CameraZoomBehavior behavior) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(zoomBehavior: behavior);
    notifyListeners();
    applyProcessing();
  }

  void setCameraZoomScaleMultiplier(double value) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(zoomScaleMultiplier: value.clamp(0.0, 1.0));
    notifyListeners();
  }

  void setCameraZoomScaleMultiplierEnd(double value) {
    setCameraZoomScaleMultiplier(value);
    applyProcessing();
  }

  void setCameraIntroPreset(CameraIntroPreset preset) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(introPreset: preset);
    notifyListeners();
    applyProcessing();
  }

  void setCameraOutroPreset(CameraOutroPreset preset) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(outroPreset: preset);
    notifyListeners();
    applyProcessing();
  }

  void setCameraZoomEmphasisPreset(CameraZoomEmphasisPreset preset) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(zoomEmphasisPreset: preset);
    notifyListeners();
    applyProcessing();
  }

  void setCameraIntroDurationMs(double value) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      introDurationMs: value.round().clamp(80, 600) as int,
    );
    notifyListeners();
  }

  void setCameraIntroDurationMsEnd(double value) {
    setCameraIntroDurationMs(value);
    applyProcessing();
  }

  void setCameraOutroDurationMs(double value) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      outroDurationMs: value.round().clamp(80, 600) as int,
    );
    notifyListeners();
  }

  void setCameraOutroDurationMsEnd(double value) {
    setCameraOutroDurationMs(value);
    applyProcessing();
  }

  void setCameraZoomEmphasisStrength(double value) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      zoomEmphasisStrength: value.clamp(0.0, 0.20),
    );
    notifyListeners();
  }

  void setCameraZoomEmphasisStrengthEnd(double value) {
    setCameraZoomEmphasisStrength(value);
    applyProcessing();
  }

  void resetCameraManualPosition() {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(clearNormalizedCanvasCenter: true);
    notifyListeners();
    applyProcessing();
  }

  void setCameraManualCenter(Offset? center) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: center,
      clearNormalizedCanvasCenter: center == null,
    );
    notifyListeners();
    applyProcessing();
  }

  void setCameraManualCenterX(double x) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    final existing = current.normalizedCanvasCenter ?? const Offset(0.5, 0.5);
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(x.clamp(0.0, 1.0), existing.dy),
    );
    notifyListeners();
  }

  void setCameraManualCenterXEnd(double x) {
    setCameraManualCenterX(x);
    applyProcessing();
  }

  void setCameraManualCenterY(double y) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    final existing = current.normalizedCanvasCenter ?? const Offset(0.5, 0.5);
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(existing.dx, y.clamp(0.0, 1.0)),
    );
    notifyListeners();
  }

  void setCameraManualCenterYEnd(double y) {
    setCameraManualCenterY(y);
    applyProcessing();
  }

  void setAudioGainDb(double v) {
    _audioGainDb = v.clamp(0.0, 24.0);
    notifyListeners();
    _schedulePreviewAudioMix();
  }

  void setAudioGainDbEnd(double v) {
    _audioGainDb = v.clamp(0.0, 24.0);
    notifyListeners();
    unawaited(_settings.post.updatePostAudioGainDb(_audioGainDb));
    _audioPreviewDebouncer.cancel();
    _pushPreviewAudioMix();
  }

  void setAudioVolumePercent(double v) {
    _audioVolumePercent = v.clamp(0.0, 100.0);
    notifyListeners();
    _schedulePreviewAudioMix();
  }

  void setAudioVolumePercentEnd(double v) {
    _audioVolumePercent = v.clamp(0.0, 100.0);
    notifyListeners();
    unawaited(_settings.post.updatePostAudioVolumePercent(_audioVolumePercent));
    _audioPreviewDebouncer.cancel();
    _pushPreviewAudioMix();
  }

  void _schedulePreviewAudioMix() {
    _audioPreviewDebouncer.run(_pushPreviewAudioMix);
  }

  void _pushPreviewAudioMix() {
    if (_previewPath == null) return;
    unawaited(
      _nativeBridge
          .setAudioMix(
            gainDb: _audioGainDb,
            volumePercent: _audioVolumePercent,
            sessionId: _activeSessionId,
          )
          .catchError((Object e, StackTrace st) {
            Log.e("PostProcessing", "Failed to update audio preview", e, st);
          }),
    );
  }

  // --- Actions ---

  void attachToRecording({
    required String sessionId,
    required String sourcePath,
  }) {
    _resetForNewRecording();
    _activeSessionId = sessionId;
    _sourcePath = sourcePath;
    _previewPath = sourcePath;
    notifyListeners();
    unawaited(_loadRecordingSceneInfo(sourcePath));
  }

  void detachRecording() {
    _resetForNewRecording();
    notifyListeners();
  }

  Future<void> prepareInitialPreview({required String sessionId}) async {
    if (_activeSessionId != sessionId || _sourcePath == null) return;
    await applyProcessing();
  }

  Future<void> reapplyPreviewComposition({required String sessionId}) async {
    if (_activeSessionId != sessionId || _sourcePath == null) return;
    await applyProcessing();
  }

  void _resetForNewRecording() {
    _videoPadding = 0;
    _videoRadius = 0;
    _backgroundColor = null;
    _backgroundImagePath = null;
    _cursorSize = 1.0;
    _zoomFactor = 1.5;
    _showCursor = true;
    _previewPath = null;
    _sourcePath = null;
    _activeSessionId = null;
    _cursorAvailable = true;
    _audioGainDb = _settings.post.postAudioGainDb;
    _audioVolumePercent = _settings.post.postAudioVolumePercent;
    _cameraPath = null;
    _cameraState = null;
    _cameraExportCapabilities = const CameraExportCapabilities.allSupported();
    _hasExportedCurrentRecording = false;
  }

  Future<void> _loadRecordingSceneInfo(String sourcePath) async {
    try {
      final sceneInfo = await _nativeBridge.getRecordingSceneInfo(sourcePath);
      if (_sourcePath != sourcePath) {
        return;
      }
      _cameraPath = sceneInfo.cameraPath;
      _cameraState = sceneInfo.camera;
      _cameraExportCapabilities = sceneInfo.cameraExportCapabilities;
      notifyListeners();
      await applyProcessing();
    } catch (e, st) {
      Log.e("PostProcessing", "Failed to load recording scene info: $e", e, st);
    }
  }

  void togglePlayback() {
    if (_player.isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  Future<void> applyProcessing() async {
    final originalPath = _sourcePath;
    if (originalPath == null) return;

    _isProcessingPreview = true;
    notifyListeners();

    try {
      Map<String, dynamic> args = {
        'layoutPreset': _settings.post.layoutPreset.name,
        'resolutionPreset': _settings.post.resolutionPreset.name,
        'fitMode': _settings.post.fitMode.name,
        'path': originalPath,
        'padding': _videoPadding,
        'cornerRadius': _videoRadius,
        'backgroundColor': _backgroundColor,
        'backgroundImagePath': _backgroundImagePath,
        'cursorSize': _cursorSize,
        'zoomFactor': _zoomFactor,
        'showCursor': _showCursor,
        'audioGainDb': _audioGainDb,
        'audioVolumePercent': _audioVolumePercent,
        'sessionId': _activeSessionId,
        // For preview, we still use mov/hevc for maximum quality/performance
        'format': 'mov',
        'codec': 'hevc',
        'bitrate': 'auto',
        if (_cameraPath != null) 'cameraPath': _cameraPath,
        ...?_cameraState?.toMap(),
      };

      final zoomSegments = _player.previewCompositionZoomSegments;
      if (zoomSegments != null) {
        args['zoomSegments'] = zoomSegments
            .map((s) => {'startMs': s.startMs, 'endMs': s.endMs})
            .toList();
      }

      final newPath = await _nativeBridge.invokeMethod<String>(
        'processVideo',
        args,
      );

      if (newPath != null) {
        _previewPath = newPath;
        Log.d(
          "PostProcessing",
          "Preview composition updated for session $_activeSessionId: $newPath",
        );
      }
    } on PlatformException catch (e, st) {
      Log.e("PostProcessing", 'Error processing video: $e');
      await ClingfyTelemetry.captureNativeMethodChannelError(
        method: 'processVideo',
        error: e,
        stackTrace: st,
        context: {
          'layoutPreset': _settings.post.layoutPreset.name,
          'resolutionPreset': _settings.post.resolutionPreset.name,
          'fitMode': _settings.post.fitMode.name,
          'showCursor': _showCursor,
          'audioGainDb': _audioGainDb,
          'audioVolumePercent': _audioVolumePercent,
        },
      );
    } catch (e, st) {
      Log.e("PostProcessing", 'Error processing video: $e');
      await ClingfyTelemetry.captureNativeMethodChannelError(
        method: 'processVideo',
        error: e,
        stackTrace: st,
        context: {
          'layoutPreset': _settings.post.layoutPreset.name,
          'resolutionPreset': _settings.post.resolutionPreset.name,
          'fitMode': _settings.post.fitMode.name,
          'showCursor': _showCursor,
          'audioGainDb': _audioGainDb,
          'audioVolumePercent': _audioVolumePercent,
        },
      );
    } finally {
      _isProcessingPreview = false;
      notifyListeners();
    }
  }

  Future<String?> exportCurrentRecording(BuildContext context) async {
    _lastExportWasCancelled = false;

    if (_isExporting) {
      await ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.export',
        message: 'export_duplicate_start_blocked',
      );
      return null;
    }

    final originalPath = _sourcePath;
    if (originalPath == null) return null;

    final l10n = AppLocalizations.of(context)!;
    final dialogResult = await ExportFileDialog.show(
      context,
      initialFileName: _defaultExportFileName(
        format: _settings.export.exportFormat.trim().toLowerCase(),
      ),
      initialDirectory:
          _settings.workspace.saveFolderPath ?? l10n.defaultSaveFolder,
      initialResolutionPreset: _settings.post.resolutionPreset,
      initialExportFormat: _settings.export.exportFormatType,
      initialExportCodec: _settings.export.exportCodecType,
      initialExportBitrate: _settings.export.exportBitrateType,
      onPickFolder: _settings.workspace.chooseSaveFolderPath,
    );

    if (dialogResult == null || dialogResult.fileName.trim().isEmpty) {
      return null;
    }

    // Apply the resolution chosen in the export dialog
    if (dialogResult.resolutionPreset != _settings.post.resolutionPreset) {
      setResolutionPreset(dialogResult.resolutionPreset);
    }

    // Apply and persist the format chosen in the export dialog
    final chosenFormat = dialogResult.exportFormat.wireValue;
    if (chosenFormat != _settings.export.exportFormat) {
      await _settings.export.updateExportFormat(chosenFormat);
    }

    // Apply and persist codec/bitrate
    final chosenCodec = dialogResult.exportCodec.wireValue;
    if (chosenCodec != _settings.export.exportCodec) {
      await _settings.export.updateExportCodec(chosenCodec);
    }
    final chosenBitrate = dialogResult.exportBitrate.wireValue;
    if (chosenBitrate != _settings.export.exportBitrate) {
      await _settings.export.updateExportBitrate(chosenBitrate);
    }

    // Determine target size
    _isExporting = true;
    _lastExportWasCancelled = false;
    _isExportCancelRequested = false;
    _isExportInBackground = false;
    _exportProgress = null;
    notifyListeners();

    SpanStatus exportStatus = const SpanStatus.ok();
    CaptureDiagnostics diagnostics = const CaptureDiagnostics();
    final autoNormalizeOnExport = _settings.post.postAutoNormalizeEnabled;
    final targetLoudnessDbfs = _settings.post.postTargetLoudnessDbfs;

    try {
      diagnostics = await ClingfyTelemetry.loadCaptureDiagnostics(
        _nativeBridge,
      );
      _activeExportTransaction = Sentry.startTransaction(
        'recording.export',
        'video.export',
        bindToScope: true,
      );
      _activeExportTransaction!.setTag(
        'export.layout',
        _settings.post.layoutPreset.name,
      );
      _activeExportTransaction!.setTag(
        'export.resolution',
        _settings.post.resolutionPreset.name,
      );
      _activeExportTransaction!.setTag(
        'export.format',
        _settings.export.exportFormat,
      );
      _activeExportTransaction!.setTag(
        'export.codec',
        _settings.export.exportCodec,
      );
      _activeExportTransaction!.setTag(
        'export.bitrate',
        _settings.export.exportBitrate,
      );
      _activeExportTransaction!.setTag(
        'audio.gain_db',
        _audioGainDb.toStringAsFixed(1),
      );
      _activeExportTransaction!.setTag(
        'audio.volume_percent',
        _audioVolumePercent.toStringAsFixed(0),
      );
      _activeExportTransaction!.setTag(
        'audio.auto_normalize',
        autoNormalizeOnExport ? 'true' : 'false',
      );
      _activeExportTransaction!.setTag(
        'audio.target_loudness_dbfs',
        targetLoudnessDbfs.toStringAsFixed(1),
      );
      if (diagnostics.backend != null && diagnostics.backend!.isNotEmpty) {
        _activeExportTransaction!.setTag(
          'recording.backend',
          diagnostics.backend!,
        );
      }
      if (diagnostics.bestFreeBytes != null) {
        _activeExportTransaction!.setData(
          'diskFreeBytes',
          diagnostics.bestFreeBytes,
        );
      }

      Map<String, dynamic> args = {
        'layoutPreset': _settings.post.layoutPreset.name,
        'resolutionPreset': _settings.post.resolutionPreset.name,
        'fitMode': _settings.post.fitMode.name,
        'path': originalPath,
        'padding': _videoPadding,
        'cornerRadius': _videoRadius,
        'backgroundColor': _backgroundColor,
        'backgroundImagePath': _backgroundImagePath,
        'cursorSize': _cursorSize,
        'zoomFactor': _zoomFactor,
        'showCursor': _showCursor,
        'audioGainDb': _audioGainDb,
        'audioVolumePercent': _audioVolumePercent,
        'autoNormalizeOnExport': autoNormalizeOnExport,
        'targetLoudnessDbfs': targetLoudnessDbfs,
        'filename': dialogResult.fileName.trim(),
        'directoryOverride': dialogResult.directoryOverride,
        'sessionId': _activeSessionId,
        'format': _settings.export.exportFormat,
        'codec': _settings.export.exportCodec,
        'bitrate': _settings.export.exportBitrate,
        if (_cameraPath != null) 'cameraPath': _cameraPath,
        ...?_cameraState?.toMap(),
      };

      _activeExportInvokeSpan = _activeExportTransaction!.startChild(
        'method_channel.export_video',
        description: 'Invoke native exportVideo',
      );

      final newPath = await _nativeBridge.invokeMethod<String>(
        'exportVideo',
        args,
      );

      if (_isExportCancelRequested) {
        _lastExportWasCancelled = true;
        exportStatus = const SpanStatus.cancelled();
      }

      if (newPath != null) {
        Log.i("PostProcessing", "Export completed successfully");
        _hasExportedCurrentRecording = true;
      } else if (!_isExportCancelRequested) {
        exportStatus = const SpanStatus.aborted();
      }
      return newPath;
    } on PlatformException catch (e, st) {
      if (_isExportCancellationException(e)) {
        _lastExportWasCancelled = true;
        exportStatus = const SpanStatus.cancelled();
        return null;
      }
      exportStatus = _statusForExportPlatformException(e);
      Log.e("PostProcessing", "Export failed: $e");
      await ClingfyTelemetry.captureNativeMethodChannelError(
        method: 'exportVideo',
        error: e,
        stackTrace: st,
        context: {
          'layoutPreset': _settings.post.layoutPreset.name,
          'resolutionPreset': _settings.post.resolutionPreset.name,
          'fitMode': _settings.post.fitMode.name,
          'format': _settings.export.exportFormat,
          'codec': _settings.export.exportCodec,
          'bitrate': _settings.export.exportBitrate,
          'audioGainDb': _audioGainDb,
          'audioVolumePercent': _audioVolumePercent,
          'autoNormalizeOnExport': autoNormalizeOnExport,
          'targetLoudnessDbfs': targetLoudnessDbfs,
          'directoryOverride': dialogResult.directoryOverride,
          if (diagnostics.backend != null) 'backend': diagnostics.backend,
          if (diagnostics.bestFreeBytes != null)
            'diskFreeBytes': diagnostics.bestFreeBytes,
        },
      );
      rethrow;
    } catch (e, st) {
      if (_isExportCancelRequested ||
          _isLikelyCancellationMessage(e.toString())) {
        _lastExportWasCancelled = true;
        exportStatus = const SpanStatus.cancelled();
        return null;
      }
      exportStatus = const SpanStatus.internalError();
      Log.e("PostProcessing", "Export failed: $e");
      await ClingfyTelemetry.captureNativeMethodChannelError(
        method: 'exportVideo',
        error: e,
        stackTrace: st,
        context: {
          'layoutPreset': _settings.post.layoutPreset.name,
          'resolutionPreset': _settings.post.resolutionPreset.name,
          'fitMode': _settings.post.fitMode.name,
          'format': _settings.export.exportFormat,
          'codec': _settings.export.exportCodec,
          'bitrate': _settings.export.exportBitrate,
          'audioGainDb': _audioGainDb,
          'audioVolumePercent': _audioVolumePercent,
          'autoNormalizeOnExport': autoNormalizeOnExport,
          'targetLoudnessDbfs': targetLoudnessDbfs,
          'directoryOverride': dialogResult.directoryOverride,
          if (diagnostics.backend != null) 'backend': diagnostics.backend,
          if (diagnostics.bestFreeBytes != null)
            'diskFreeBytes': diagnostics.bestFreeBytes,
        },
      );
      rethrow;
    } finally {
      if (_isExportCancelRequested && exportStatus == const SpanStatus.ok()) {
        exportStatus = const SpanStatus.cancelled();
      }
      await _finishSpan(_activeExportInvokeSpan, exportStatus);
      await _finishSpan(_activeExportTransaction, exportStatus);
      _activeExportInvokeSpan = null;
      _activeExportTransaction = null;

      _isExporting = false;
      _isExportCancelRequested = false;
      _isExportInBackground = false;
      _exportProgress = null;
      notifyListeners();
    }
  }

  Future<void> cancelExport() async {
    if (!_isExporting) return;
    try {
      _isExportCancelRequested = true;
      notifyListeners();
      await ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.export',
        message: 'export_cancel_requested',
      );
      await _nativeBridge.invokeMethod('cancelExport');
    } catch (e) {
      Log.e("PostProcessing", 'Error cancelling export: $e');
    }
  }

  void sendExportToBackground() {
    if (!_isExporting || _isExportInBackground) return;
    _isExportInBackground = true;
    notifyListeners();
  }

  void showExportProgressModal() {
    if (!_isExporting || !_isExportInBackground) return;
    _isExportInBackground = false;
    notifyListeners();
  }

  void collapseExportDock() => sendExportToBackground();

  void expandExportDock() => showExportProgressModal();

  Future<String?> pickImage() async {
    try {
      return await _nativeBridge.invokeMethod<String>('pickImage');
    } catch (e) {
      Log.e("PostProcessing", 'Error picking image: $e');
      return null;
    }
  }

  void updateProgress(double p) {
    if (!p.isFinite || p.isNaN || p < 0) return;
    final normalized = p > 1.0 ? p / 100.0 : p;
    _exportProgress = normalized.clamp(0.0, 1.0).toDouble();
    notifyListeners();
  }

  SpanStatus _statusForExportPlatformException(PlatformException e) {
    if (_isExportCancellationException(e)) {
      return const SpanStatus.cancelled();
    }
    if (e.code == NativeErrorCode.exportInputMissing ||
        e.code == NativeErrorCode.fileNotFound) {
      return const SpanStatus.notFound();
    }
    if (e.code == NativeErrorCode.exportError &&
        (e.message?.toLowerCase().contains('space') == true ||
            e.message?.toLowerCase().contains('storage') == true ||
            e.message?.toLowerCase().contains('no such file') == true)) {
      return const SpanStatus.resourceExhausted();
    }
    return const SpanStatus.internalError();
  }

  Future<void> _finishSpan(ISentrySpan? span, SpanStatus status) async {
    if (span == null || span.finished) return;
    await span.finish(status: status);
  }

  bool _isExportCancellationException(PlatformException e) {
    if (_isExportCancelRequested) return true;
    if (_isLikelyCancellationMessage(e.message) ||
        _isLikelyCancellationMessage(e.details?.toString())) {
      return true;
    }
    final code = e.code.toLowerCase();
    return code.contains('cancel');
  }

  bool _isLikelyCancellationMessage(String? message) {
    if (message == null || message.isEmpty) return false;
    final normalized = message.toLowerCase();
    return normalized.contains('cancel') ||
        normalized.contains('aborted') ||
        normalized.contains('interrupted') ||
        normalized.contains('stopped by user');
  }

  String _defaultExportFileName({required String format}) {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final prefix = format == 'gif' ? 'Clingfy Clip' : 'Clingfy Export';
    if (BuildConfig.isDev()) {
      return '${prefix}_${now.year}-$month-${day}_${hour}_$minute';
    }
    return '$prefix ${now.year}-$month-$day';
  }
}
