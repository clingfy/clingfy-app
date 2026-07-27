import 'dart:async';
import 'dart:io';
import 'package:clingfy/app/infrastructure/analytics/analytics_events.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_service.dart';
import 'package:clingfy/app/config/build_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/commands/set_color_grade_command.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/color/auto_grade_heuristic.dart';
import 'package:clingfy/core/models/background_preset_catalog.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/home/post_processing/support/audio_debouncer.dart';
import 'package:clingfy/app/home/post_processing/support/canvas_appearance_store.dart';
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
    _colorGradePreviewThrottler.dispose();
    _cameraManualPreviewThrottler.dispose();
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
  BackgroundKind _backgroundKind = BackgroundKind.color;
  CanvasBackgroundPreset? _backgroundPreset;
  double _cursorSize = 1.5;
  double _zoomFactor = 1.0;
  bool _zoomEffectEnabled = false;
  bool _showCursor = true;
  String? _previewPath;
  String? _projectPath;
  String? _activeSessionId;
  bool _cursorAvailable = true;
  double _audioGainDb = 0.0;
  VoiceCleanup _voiceCleanup = const VoiceCleanup();
  double _audioVolumePercent = 100.0;
  String? _cameraPath;
  CameraCompositionState? _cameraState;
  CameraExportCapabilities _cameraExportCapabilities =
      const CameraExportCapabilities.allSupported();
  // Audio separation (D10): whether the OPEN RECORDING contains audio, as
  // reported by the platform's scene info (Windows probes the mic/system
  // sidecars). Null = platform didn't report (macOS today) — the sidebar
  // falls back to its legacy device-selection gate.
  bool? _sceneHasAudio;
  bool? _sceneMicGainApplies;
  final AudioDebouncer _audioPreviewDebouncer = AudioDebouncer(
    delay: Duration(milliseconds: 150),
  );
  ColorGrade _colorGrade = const ColorGrade();
  // Color edits stream live while the slider is dragged. A *throttle*
  // (leading + trailing) pushes the first change immediately and then at most
  // once per interval, so the preview tracks the drag. A trailing debounce kept
  // deferring the push until the drag settled, which is why color only appeared
  // once the slider was dropped. The slider's onChangeEnd still flushes the
  // final value via [commitColorGrade].
  final ActionThrottler _colorGradePreviewThrottler = ActionThrottler(
    interval: Duration(milliseconds: 40),
  );
  // Undo/redo history for the color track. Its own session (like the clip and
  // zoom editors own theirs) — the unified cross-track stack is a later step.
  late final EditSession _colorSession = EditSession(
    onFlush: _onColorEditFlushed,
  );
  // Grade as it was when the current slider gesture started, i.e. before the
  // live drag ticks. Non-null only between the first tick and the matching
  // [commitColorGrade], so a whole drag collapses into ONE history entry
  // instead of one per tick.
  ColorGrade? _colorGestureBaseline;
  final ActionThrottler _cameraManualPreviewThrottler = ActionThrottler();
  CameraPreviewChangeKind _pendingCameraPreviewChangeKind =
      CameraPreviewChangeKind.none;

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
  BackgroundKind get backgroundKind => _backgroundKind;
  CanvasBackgroundPreset? get backgroundPreset => _backgroundPreset;
  double get cursorSize => _cursorSize;
  double get zoomFactor => _zoomFactor;
  bool get zoomEffectEnabled => _zoomEffectEnabled;
  bool get showCursor => _showCursor;
  String? get previewPath => _previewPath;
  bool get cursorAvailable => _cursorAvailable;
  double get audioGainDb => _audioGainDb;
  VoiceCleanup get voiceCleanup => _voiceCleanup;
  double get audioVolumePercent => _audioVolumePercent;
  ColorGrade get colorGrade => _colorGrade;

  /// True when there is a committed color edit to step back to. A slider drag
  /// in flight does not count until [commitColorGrade] closes it.
  bool get canUndoColorGrade => _colorSession.canUndo;
  bool get canRedoColorGrade => _colorSession.canRedo;
  String? get cameraPath => _cameraPath;
  bool get hasCameraAsset => _cameraPath != null && _cameraPath!.isNotEmpty;
  CameraCompositionState? get cameraState => _cameraState;
  CameraExportCapabilities get cameraExportCapabilities =>
      _cameraExportCapabilities;
  bool? get sceneHasAudio => _sceneHasAudio;
  bool? get sceneMicGainApplies => _sceneMicGainApplies;

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

  /// Pushes the canvas framing to the live preview.
  ///
  /// Every canvas mutator routes through here. Before this existed,
  /// [setPadding] and [setRadius] only called `notifyListeners()` while the
  /// three background setters also called [applyProcessing] — so once the
  /// preview started drawing the canvas, two of the five controls would have
  /// looked dead. One helper keeps the next canvas control correct by default
  /// instead of correct by memory.
  ///
  /// `padding` and `cornerRadius` are export-output pixels; native normalises
  /// them against the export canvas it resolves from the layout and resolution
  /// presets, so the preview's smaller surface shows proportionally identical
  /// framing rather than ~3x thicker padding at 4K. See
  /// `windows/runner/Core/canvas_composition.h`.
  void _pushCanvas() {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    // Best-effort: a stale session is dropped native-side, and a preview that
    // is not open simply has nothing to repaint.
    unawaited(
      _nativeBridge
          .previewSetCanvas(
            padding: _videoPadding,
            cornerRadius: _videoRadius,
            backgroundColor: _backgroundColor,
            backgroundImagePath: _backgroundImagePath,
            backgroundKind: _backgroundKind.name,
            backgroundPresetId: _backgroundPreset?.id,
            backgroundPresetPalette: _backgroundPreset?.palette,
            backgroundPresetIntensity: _backgroundPreset?.intensity ?? 0.5,
            backgroundPresetBlur: _backgroundPreset?.blur ?? 0.0,
            backgroundPresetSeed: _backgroundPreset?.seed ?? 0,
            layoutPreset: _settings.post.layoutPreset.name,
            resolutionPreset: _settings.post.resolutionPreset.name,
            sessionId: sessionId,
          )
          .catchError((Object _) {}),
    );
  }

  void setPadding(double v) {
    _videoPadding = v;
    notifyListeners();
    _pushCanvas();
  }

  void setRadius(double v) {
    _videoRadius = v;
    notifyListeners();
    _pushCanvas();
  }

  void setBackgroundColor(int? v) {
    _backgroundColor = v;
    _backgroundImagePath = null;
    _backgroundPreset = null;
    _backgroundKind = BackgroundKind.color;
    notifyListeners();
    _pushCanvas();
    applyProcessing();
  }

  void setBackgroundImagePath(String? path) {
    _backgroundImagePath = path;
    _backgroundColor = null;
    _backgroundPreset = null;
    _backgroundKind = path != null
        ? BackgroundKind.image
        : BackgroundKind.color;
    notifyListeners();
    _pushCanvas();
    applyProcessing();
  }

  void setBackgroundPreset(CanvasBackgroundPreset preset) {
    _backgroundPreset = preset;
    _backgroundColor = null;
    _backgroundImagePath = null;
    _backgroundKind = BackgroundKind.preset;
    notifyListeners();
    _pushCanvas();
    applyProcessing();
  }

  /// Live, UI-only preset update for slider drags — refreshes the controls
  /// without kicking a (debounced) preview re-render on every tick. The
  /// caller commits the final value with [setBackgroundPreset] on release.
  void updateBackgroundPresetPreview(CanvasBackgroundPreset preset) {
    _backgroundPreset = preset;
    _backgroundColor = null;
    _backgroundImagePath = null;
    _backgroundKind = BackgroundKind.preset;
    notifyListeners();
  }

  /// Switches the background mode from the Color / Image / Preset picker.
  /// Switching applies a sensible default for the chosen mode so the
  /// preview reflects the change immediately.
  void setBackgroundKind(BackgroundKind kind) {
    switch (kind) {
      case BackgroundKind.color:
        setBackgroundColor(_backgroundColor);
      case BackgroundKind.image:
        _backgroundKind = BackgroundKind.image;
        _backgroundColor = null;
        _backgroundPreset = null;
        notifyListeners();
        applyProcessing();
      case BackgroundKind.preset:
        setBackgroundPreset(
          _backgroundPreset ?? BackgroundPresetCatalog.defaultPreset(),
        );
    }
  }

  void setCursorSize(double v) {
    _cursorSize = v;
    notifyListeners();
  }

  void setZoomFactor(double v) {
    final next = v.isFinite ? v.clamp(1.0, 3.0).toDouble() : 1.0;
    _zoomFactor = next;
    notifyListeners();
  }

  void setZoomFactorEnd(double v) {
    setZoomFactor(v);
    unawaited(_settings.post.updatePostZoomFactor(_zoomFactor));
    applyProcessing();
  }

  void setZoomEffectEnabled(bool enabled) {
    _zoomEffectEnabled = enabled;
    if (!_zoomFactor.isFinite || _zoomFactor < 1.0) {
      _zoomFactor = 1.0;
    } else {
      _zoomFactor = _zoomFactor.clamp(1.0, 3.0).toDouble();
    }
    notifyListeners();
    unawaited(_settings.post.updatePostZoomEffectEnabled(_zoomEffectEnabled));
    unawaited(_settings.post.updatePostZoomFactor(_zoomFactor));
    applyProcessing();
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
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
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
      introDurationMs: value.round().clamp(80, 600).toInt(),
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
      outroDurationMs: value.round().clamp(80, 600).toInt(),
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
    _cameraManualPreviewThrottler.cancel();
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(clearNormalizedCanvasCenter: true);
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
    notifyListeners();
    applyProcessing();
  }

  void setCameraManualCenter(Offset? center) {
    _cameraManualPreviewThrottler.cancel();
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: center,
      clearNormalizedCanvasCenter: center == null,
    );
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
    notifyListeners();
    applyProcessing();
  }

  void setCameraManualCenterSnap(Offset center) {
    _cameraManualPreviewThrottler.cancel();
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(
        center.dx.clamp(0.0, 1.0),
        (1.0 - center.dy).clamp(0.0, 1.0),
      ),
    );
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
    notifyListeners();
    applyProcessing();
  }

  void setCameraManualCenterPreview(Offset center) {
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(
        center.dx.clamp(0.0, 1.0),
        (1.0 - center.dy).clamp(
          0.0,
          1.0,
        ), // Invert: Flutter top-down -> native bottom-up
      ),
    );
    notifyListeners();
    _cameraManualPreviewThrottler.run(() {
      unawaited(
        _pushPreviewCameraPlacement(CameraPreviewChangeKind.dragPreview),
      );
    });
  }

  void setCameraManualCenterPreviewEnd(Offset center) {
    _cameraManualPreviewThrottler.cancel();
    final current = _cameraState ?? const CameraCompositionState.hidden();
    _cameraState = current.copyWith(
      normalizedCanvasCenter: Offset(
        center.dx.clamp(0.0, 1.0),
        (1.0 - center.dy).clamp(0.0, 1.0),
      ),
    );
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
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
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
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
    _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.placementJump;
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

  /// Voice cleanup is a discrete choice, not a dragged slider, so there is no
  /// separate "end" setter: it persists and pushes to the preview immediately.
  /// The push re-resolves the mic file natively (an O(recording) pass on the
  /// first use of each mode), which is why it must never be called from a
  /// continuous gesture.
  void setVoiceCleanup(VoiceCleanup value) {
    if (value == _voiceCleanup) return;
    _voiceCleanup = value;
    notifyListeners();
    unawaited(_settings.post.updatePostVoiceCleanup(value));
    _pushPreviewVoiceCleanup();
  }

  void _pushPreviewVoiceCleanup() {
    if (_previewPath == null) return;
    unawaited(
      _nativeBridge
          .previewSetVoiceCleanup(
            voiceCleanup: _voiceCleanup,
            sessionId: _activeSessionId,
          )
          .catchError((Object e, StackTrace st) {
            Log.e("PostProcessing", "Failed to update voice cleanup", e, st);
          }),
    );
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

  // --- Color grade ---

  void setColorGradeExposure(double v) {
    _applyLiveColorGrade(_colorGrade.copyWith(exposure: v.clamp(-1.0, 1.0)));
  }

  void setColorGradeContrast(double v) {
    _applyLiveColorGrade(_colorGrade.copyWith(contrast: v.clamp(-1.0, 1.0)));
  }

  void setColorGradeSaturation(double v) {
    _applyLiveColorGrade(_colorGrade.copyWith(saturation: v.clamp(-1.0, 1.0)));
  }

  void setColorGradeTemperature(double v) {
    _applyLiveColorGrade(_colorGrade.copyWith(temperature: v.clamp(-1.0, 1.0)));
  }

  void setColorGradeTint(double v) {
    _applyLiveColorGrade(_colorGrade.copyWith(tint: v.clamp(-1.0, 1.0)));
  }

  /// Applies a drag tick: the grade moves (so the preview tracks the slider)
  /// but nothing is recorded yet. The pre-gesture grade is snapshotted on the
  /// first tick so [commitColorGrade] can record the whole drag as one edit.
  void _applyLiveColorGrade(ColorGrade next) {
    _colorGestureBaseline ??= _colorGrade;
    _colorGrade = next;
    notifyListeners();
    _schedulePreviewColorGrade();
  }

  /// Flush the debounce and push the final grade immediately (slider release).
  /// This is the color-edit commit point: it closes the gesture into a single
  /// undoable entry and persists the grade to the project bundle (drag ticks
  /// only update the preview).
  void commitColorGrade() {
    final baseline = _colorGestureBaseline;
    _colorGestureBaseline = null;
    if (baseline == null || baseline == _colorGrade) {
      // Nothing moved since the last commit (a tap on the track, or a drag
      // that landed back where it started) — push and persist, no history
      // entry for a no-op.
      _syncColorGradeToPreviewAndDisk();
      return;
    }
    final next = _colorGrade;
    // Rewind to the pre-gesture grade so the command snapshots the honest
    // "previous" through its own live getter; execute() immediately re-applies
    // [next], so this is invisible (no notifyListeners in between).
    _colorGrade = baseline;
    _executeColorGradeEdit(next);
  }

  /// One-tap auto enhance: apply a tasteful preset, or clear back to neutral.
  void setColorGradeAutoEnhance(bool enabled) {
    // A discrete toggle can land while a slider gesture is still open (drag,
    // then click Auto without releasing). Close that gesture first so the drag
    // keeps its own history entry instead of being swallowed by this one.
    // Only when that gesture actually moved something: committing a zero-net
    // gesture (or none at all) would push and persist the PRE-toggle grade
    // immediately before this method pushes and persists the new one.
    if (_colorGestureBaseline != null && _colorGestureBaseline != _colorGrade) {
      commitColorGrade();
    }
    _colorGestureBaseline = null;
    final next = enabled ? autoEnhanceGrade() : const ColorGrade();
    if (next == _colorGrade) {
      _syncColorGradeToPreviewAndDisk();
      return;
    }
    _executeColorGradeEdit(next);
  }

  /// Steps the color grade back to the state before the last committed edit.
  /// No-op when the history is empty.
  void undoColorGrade() {
    if (!_colorSession.canUndo) return;
    // An in-flight drag is abandoned rather than committed: the user asked for
    // the *previous* state, so its uncommitted ticks must not become an entry.
    _colorGestureBaseline = null;
    _colorSession.undo();
  }

  /// Re-applies the last undone color edit. No-op when nothing was undone.
  void redoColorGrade() {
    if (!_colorSession.canRedo) return;
    _colorGestureBaseline = null;
    _colorSession.redo();
  }

  void _executeColorGradeEdit(ColorGrade next) {
    _colorSession.execute(
      SetColorGradeCommand(
        get: () => _colorGrade,
        set: (grade) => _colorGrade = grade,
        next: next,
      ),
    );
  }

  /// Every history-recorded color change lands here via [EditSession.onFlush]
  /// — execute, undo and redo alike. No-op commits skip the history and sync
  /// straight through [_syncColorGradeToPreviewAndDisk].
  void _onColorEditFlushed(Set<EditDomain> dirtyDomains) {
    if (!dirtyDomains.contains(EditDomain.color)) return;
    notifyListeners();
    _syncColorGradeToPreviewAndDisk();
  }

  void _syncColorGradeToPreviewAndDisk() {
    _colorGradePreviewThrottler.cancel();
    _pushPreviewColorGrade();
    _persistEditorStateIfActive();
  }

  void _schedulePreviewColorGrade() {
    _colorGradePreviewThrottler.run(_pushPreviewColorGrade);
  }

  void _pushPreviewColorGrade() {
    if (_previewPath == null) {
      Log.d(
        "PostProcessing",
        "Skipping color preview push (no preview path yet)",
      );
      return;
    }
    Log.d("PostProcessing", "Pushing color grade to preview", null, null, {
      'sessionId': _activeSessionId,
      'autoEnabled': _colorGrade.autoEnabled,
      'exposure': _colorGrade.exposure,
      'contrast': _colorGrade.contrast,
      'saturation': _colorGrade.saturation,
      'temperature': _colorGrade.temperature,
      'tint': _colorGrade.tint,
    });
    unawaited(
      _nativeBridge
          .previewSetColorGrade(
            colorGrade: _colorGrade,
            sessionId: _activeSessionId,
          )
          .catchError((Object e, StackTrace st) {
            Log.e("PostProcessing", "Failed to update color preview", e, st);
          }),
    );
  }

  Map<String, dynamic>? _cameraPreviewMethodArgs(
    CameraPreviewChangeKind changeKind,
  ) {
    if (_projectPath == null) {
      return null;
    }

    return {
      'cameraPreviewChangeKind': changeKind.name,
      if (_cameraPath != null) 'cameraPath': _cameraPath,
      ...?_cameraState?.toMap(),
    };
  }

  Future<void> _pushPreviewCameraPlacement(
    CameraPreviewChangeKind changeKind,
  ) async {
    final projectPath = _projectPath;
    final args = _cameraPreviewMethodArgs(changeKind);
    if (projectPath == null || args == null) {
      return;
    }

    try {
      await _nativeBridge.previewSetCameraPlacement(
        projectPath: projectPath,
        changeKind: changeKind,
        sessionId: _activeSessionId,
        cameraPath: args['cameraPath'] as String?,
        cameraState: _cameraState,
      );
    } catch (e, st) {
      Log.e(
        "PostProcessing",
        "Failed to update preview camera placement",
        e,
        st,
      );
    }
  }

  // --- Actions ---

  void attachToRecording({
    required String sessionId,
    required String projectPath,
  }) {
    _resetForNewRecording();
    _activeSessionId = sessionId;
    _projectPath = projectPath;
    _previewPath = projectPath;
    notifyListeners();
    unawaited(_loadRecordingSceneInfo(projectPath));
  }

  void detachRecording() {
    _resetForNewRecording();
    notifyListeners();
  }

  Future<void> prepareInitialPreview({required String sessionId}) async {
    if (_activeSessionId != sessionId || _projectPath == null) return;
    await applyProcessing();
  }

  Future<void> reapplyPreviewComposition({required String sessionId}) async {
    if (_activeSessionId != sessionId || _projectPath == null) return;
    await applyProcessing();
  }

  /// Re-push every piece of preview state this controller owns to a native
  /// session that was rebuilt in place (Windows `previewInvalidated` after a
  /// standby resume — previewOpen carries no editing state): the color grade
  /// rides its own channel, and [applyProcessing] re-sends the canvas
  /// composition (padding, background, cursor, zoom, camera placement,
  /// audio).
  Future<void> resyncPreviewAfterRebuild({required String sessionId}) async {
    if (_activeSessionId != sessionId || _projectPath == null) return;
    _pushPreviewColorGrade();
    _pushPreviewVoiceCleanup();
    await applyProcessing();
  }

  void _resetForNewRecording() {
    _videoPadding = 0;
    _videoRadius = 0;
    _backgroundColor = null;
    _backgroundImagePath = null;
    _backgroundKind = BackgroundKind.color;
    _backgroundPreset = null;
    _cursorSize = 1.5;
    _zoomFactor = _settings.post.postZoomFactor;
    _zoomEffectEnabled = _settings.post.postZoomEffectEnabled;
    _showCursor = true;
    _previewPath = null;
    _projectPath = null;
    _activeSessionId = null;
    _cursorAvailable = true;
    _audioGainDb = _settings.post.postAudioGainDb;
    _voiceCleanup = _settings.post.postVoiceCleanup;
    _audioVolumePercent = _settings.post.postAudioVolumePercent;
    _colorGrade = const ColorGrade();
    // History belongs to the recording that produced it — never let an undo
    // from the previous project reach into this one.
    _colorSession.clear();
    _colorGestureBaseline = null;
    _cameraPath = null;
    _cameraState = null;
    _cameraExportCapabilities = const CameraExportCapabilities.allSupported();
    _sceneHasAudio = null;
    _sceneMicGainApplies = null;
    _hasExportedCurrentRecording = false;
  }

  Future<void> _loadRecordingSceneInfo(String projectPath) async {
    try {
      final sceneInfo = await _nativeBridge.getRecordingSceneInfo(projectPath);
      if (_projectPath != projectPath) {
        return;
      }
      _cameraPath = sceneInfo.cameraPath;
      _cameraState = sceneInfo.camera;
      _cameraExportCapabilities = sceneInfo.cameraExportCapabilities;
      // Audio separation (D10): what the RECORDING contains, when the
      // platform reports it (Windows probes the sidecars). Null = unknown
      // (macOS today) — the sidebar keeps its device-selection gate.
      _sceneHasAudio = sceneInfo.hasRecordedAudio;
      _sceneMicGainApplies = sceneInfo.micGainApplies;
      // Restore persisted canvas appearance (padding / corner radius /
      // background / color grade) before the first preview render, so the
      // recording reopens exactly as it was last edited. Synchronous — keeps
      // the scene-load → applyProcessing ordering unchanged.
      _loadCanvasAppearance(projectPath);
      // Push the restored grade to the preview. The native side stores it and
      // applies it to whatever preview item loads (deferred if the item isn't
      // live yet), so the reopened recording shows the last color adjustment.
      // Guarded like [_loadCanvasAppearance] so a session swap mid-load never
      // pushes this recording's grade onto a different one.
      if (_projectPath == projectPath) {
        _pushPreviewColorGrade();
      }
      notifyListeners();
      await applyProcessing();
    } catch (e, st) {
      Log.e("PostProcessing", "Failed to load recording scene info: $e", e, st);
    }
  }

  /// Reads `editor_state.json` from the project bundle and applies it to
  /// the canvas fields. Best-effort: a missing/old file leaves the
  /// defaults in place (back-compatible with pre-persistence recordings).
  void _loadCanvasAppearance(String projectPath) {
    final state = CanvasAppearanceStore.load(projectPath);
    if (state == null || _projectPath != projectPath) return;
    _videoPadding = state.padding;
    _videoRadius = state.cornerRadius;
    _backgroundKind = state.backgroundKind;
    _backgroundColor = state.backgroundColorArgb;
    _backgroundImagePath = state.backgroundImagePath;
    _backgroundPreset = state.backgroundPreset;
    _colorGrade = state.colorGrade;
    // Restoring saved state is not an edit: nothing here is undoable, and this
    // lands asynchronously (scene load) after [attachToRecording], so any entry
    // recorded in that window would now point at a stale pre-restore grade.
    _colorSession.clear();
    _colorGestureBaseline = null;
  }

  /// Persists the current editor state (canvas appearance + color grade) to the
  /// project bundle. Fire-and-forget — invoked from [applyProcessing] on every
  /// committed canvas edit and from the color-grade commit points.
  void _persistCanvasAppearance(String projectPath) {
    unawaited(
      CanvasAppearanceStore.save(
        projectPath,
        CanvasAppearanceState(
          padding: _videoPadding,
          cornerRadius: _videoRadius,
          backgroundKind: _backgroundKind,
          backgroundColorArgb: _backgroundColor,
          backgroundImagePath: _backgroundImagePath,
          backgroundPreset: _backgroundPreset,
          colorGrade: _colorGrade,
        ),
      ),
    );
  }

  /// Persists the editor state only when a recording is attached. Used by the
  /// color-grade commit points, which (unlike canvas edits) do not route
  /// through [applyProcessing].
  void _persistEditorStateIfActive() {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    _persistCanvasAppearance(projectPath);
  }

  void togglePlayback() {
    if (_player.isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  Future<void> applyProcessing() async {
    final projectPath = _projectPath;
    if (projectPath == null) return;

    // Persist the canvas appearance on every committed edit (this method
    // is the debounced canvas-update path). Best-effort, non-blocking.
    _persistCanvasAppearance(projectPath);

    // Phase 6 Slice 1 (PR landing this change) wires `processVideo` on
    // Windows to a null-returning handler — it no longer throws
    // WINDOWS_NOT_IMPLEMENTED, so the previous suppression is gone. The
    // null return signals "no new preview file was generated, keep using
    // the raw recording", which matches today's Windows preview behavior.
    // Slices 2+ will start producing a composited preview path here.

    _isProcessingPreview = true;
    notifyListeners();

    try {
      final cameraPreviewChangeKind = _pendingCameraPreviewChangeKind;
      _pendingCameraPreviewChangeKind = CameraPreviewChangeKind.none;
      final cameraPreviewArgs = _cameraPreviewMethodArgs(
        cameraPreviewChangeKind,
      );
      final layoutPresetName = _settings.post.layoutPreset.name;
      final resolutionPresetName = _settings.post.resolutionPreset.name;

      Map<String, dynamic> args = {
        'layoutPreset': layoutPresetName,
        'resolutionPreset': resolutionPresetName,
        'fitMode': _settings.post.fitMode.name,
        'projectPath': projectPath,
        'padding': _videoPadding,
        'cornerRadius': _videoRadius,
        'backgroundColor': _backgroundColor,
        'backgroundImagePath': _backgroundImagePath,
        'backgroundKind': _backgroundKind.name,
        'backgroundPresetId': _backgroundPreset?.id,
        'backgroundPresetPalette': _backgroundPreset?.palette,
        'backgroundPresetIntensity': _backgroundPreset?.intensity,
        'backgroundPresetBlur': _backgroundPreset?.blur,
        'backgroundPresetSeed': _backgroundPreset?.seed,
        'cursorSize': _cursorSize,
        'zoomFactor': _zoomFactor,
        'zoomEffectEnabled': _zoomEffectEnabled,
        'showCursor': _showCursor,
        'audioGainDb': _audioGainDb,
        'voiceCleanup': _voiceCleanup.toMap(),
        'audioVolumePercent': _audioVolumePercent,
        'sessionId': _activeSessionId,
        // For preview, we still use mov/hevc for maximum quality/performance
        'format': 'mov',
        'codec': 'hevc',
        'bitrate': 'auto',
        ...?cameraPreviewArgs,
      };

      final zoomSegments = _player.previewCompositionZoomSegments;
      if (zoomSegments != null) {
        args['zoomSegments'] = zoomSegments
            .map((s) => {'startMs': s.startMs, 'endMs': s.endMs})
            .toList();
      }

      Log.d(
        "PostProcessing",
        "Applying preview composition request",
        null,
        null,
        {
          'sessionId': _activeSessionId,
          'projectPath': projectPath,
          'layoutPreset': layoutPresetName,
          'resolutionPreset': resolutionPresetName,
          'cameraPreviewChangeKind': cameraPreviewChangeKind.name,
        },
      );

      final newPath = await _nativeBridge.invokeMethod<String>(
        'processVideo',
        args,
      );

      if (newPath != null) {
        _previewPath = newPath;
        Log.d(
          "PostProcessing",
          "Preview composition request completed",
          null,
          null,
          {
            'sessionId': _activeSessionId,
            'projectPath': projectPath,
            'previewPath': newPath,
            'layoutPreset': layoutPresetName,
            'resolutionPreset': resolutionPresetName,
            'cameraPreviewChangeKind': cameraPreviewChangeKind.name,
          },
        );
      } else {
        Log.d(
          "PostProcessing",
          "Preview composition request returned no preview path",
          null,
          null,
          {
            'sessionId': _activeSessionId,
            'projectPath': projectPath,
            'layoutPreset': layoutPresetName,
            'resolutionPreset': resolutionPresetName,
            'cameraPreviewChangeKind': cameraPreviewChangeKind.name,
          },
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
          'voiceCleanup': _voiceCleanup.enabled
              ? _voiceCleanup.mode.wire
              : 'off',
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
          'voiceCleanup': _voiceCleanup.enabled
              ? _voiceCleanup.mode.wire
              : 'off',
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

    final projectPath = _projectPath;
    if (projectPath == null) return null;

    final l10n = AppLocalizations.of(context)!;
    final dialogResult = await ExportFileDialog.show(
      context,
      initialFileName: _defaultExportFileName(
        l10n,
        format: _settings.export.exportFormat.trim().toLowerCase(),
      ),
      initialDirectory:
          _settings.workspace.saveFolderPath ?? l10n.defaultSaveFolder,
      initialResolutionPreset: _settings.post.resolutionPreset,
      initialExportFormat: _settings.export.exportFormatType,
      initialExportCodec: _settings.export.exportCodecType,
      initialExportBitrate: _settings.export.exportBitrateType,
      initialGifSize: _settings.export.gifSizeType,
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

    // Apply and persist the GIF size (only meaningful for GIF exports, but the
    // dialog always returns the current selection).
    final chosenGifSize = dialogResult.gifSize.wireValue;
    if (chosenGifSize != _settings.export.gifSize) {
      await _settings.export.updateGifSize(chosenGifSize);
    }

    // Determine target size
    _isExporting = true;
    _lastExportWasCancelled = false;
    _isExportCancelRequested = false;
    _isExportInBackground = false;
    _exportProgress = null;
    notifyListeners();

    ClingfyAnalytics.capture(
      AnalyticsEvents.exportJobStart,
      properties: {
        'format': _settings.export.exportFormat,
        'resolution': _settings.post.resolutionPreset.name,
        'layout': _settings.post.layoutPreset.name,
      },
    );

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
        'export.gif_size',
        _settings.export.gifSize,
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
      _activeExportTransaction!.setTag(
        'color.grade_active',
        _colorGrade.isIdentity ? 'false' : 'true',
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
        'projectPath': projectPath,
        'padding': _videoPadding,
        'cornerRadius': _videoRadius,
        'backgroundColor': _backgroundColor,
        'backgroundImagePath': _backgroundImagePath,
        'backgroundKind': _backgroundKind.name,
        'backgroundPresetId': _backgroundPreset?.id,
        'backgroundPresetPalette': _backgroundPreset?.palette,
        'backgroundPresetIntensity': _backgroundPreset?.intensity,
        'backgroundPresetBlur': _backgroundPreset?.blur,
        'backgroundPresetSeed': _backgroundPreset?.seed,
        'cursorSize': _cursorSize,
        'zoomFactor': _zoomFactor,
        'zoomEffectEnabled': _zoomEffectEnabled,
        'showCursor': _showCursor,
        'audioGainDb': _audioGainDb,
        'voiceCleanup': _voiceCleanup.toMap(),
        'audioVolumePercent': _audioVolumePercent,
        // Bake the same grade the user sees in the live preview into the
        // exported file. Identity (no adjustment) is a no-op on the native
        // side, so it's always safe to send.
        'colorGrade': _colorGrade.toMap(),
        'autoNormalizeOnExport': autoNormalizeOnExport,
        'targetLoudnessDbfs': targetLoudnessDbfs,
        'filename': dialogResult.fileName.trim(),
        // Fall back to the workspace save folder when the user didn't pick
        // a folder in the export dialog itself, so a folder chosen in
        // Settings → Workspace is honored without re-picking. Native
        // resolves its own default if this is still null.
        'directoryOverride':
            dialogResult.directoryOverride ??
            _settings.workspace.saveFolderPath,
        'sessionId': _activeSessionId,
        'format': _settings.export.exportFormat,
        'codec': _settings.export.exportCodec,
        'bitrate': _settings.export.exportBitrate,
        // GIF-only: long-edge size preset (small/medium/large). Native ignores
        // it for non-GIF formats. Older payloads that omit it default to large.
        'gifSize': _settings.export.gifSize,
        if (_cameraPath != null) 'cameraPath': _cameraPath,
        ...?_cameraState?.toMap(),
        // PR-3d: the kept clip ranges (split / cut / trim) so native bakes the
        // cuts into the exported file. An unedited recording sends the whole
        // span, which is a passthrough (no cutting) on the native side.
        'clips':
            _player.clipEditor?.clips.map((c) => c.toMap()).toList() ??
            const <Map<String, dynamic>>[],
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
        ClingfyAnalytics.capture(
          AnalyticsEvents.exportJobComplete,
          properties: {
            'format': _settings.export.exportFormat,
            'resolution': _settings.post.resolutionPreset.name,
          },
        );
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
      ClingfyAnalytics.capture(
        AnalyticsEvents.exportJobFail,
        properties: {'error_code': e.code},
      );
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
          'voiceCleanup': _voiceCleanup.enabled
              ? _voiceCleanup.mode.wire
              : 'off',
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
      // Phase 10.4: a requested cancel alone no longer classifies the
      // failure — only an explicit cancellation signal does. Real errors
      // that race the user's cancel must still surface and be logged.
      if (isExportCancellationError(e)) {
        _lastExportWasCancelled = true;
        exportStatus = const SpanStatus.cancelled();
        return null;
      }
      exportStatus = const SpanStatus.internalError();
      Log.e("PostProcessing", "Export failed: $e");
      ClingfyAnalytics.capture(
        AnalyticsEvents.exportJobFail,
        properties: {'error_code': 'internal'},
      );
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
          'voiceCleanup': _voiceCleanup.enabled
              ? _voiceCleanup.mode.wire
              : 'off',
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

  /// Name of the directory inside a `.clingfyproj` that holds bundled canvas
  /// assets. Kept next to the other project state rather than beside the media.
  static const String kCanvasAssetsDirName = 'canvas_assets';

  Future<String?> pickImage() async {
    try {
      final picked = await _nativeBridge.invokeMethod<String>('pickImage');
      if (picked == null || picked.isEmpty) return null;
      // Bundle a copy into the project. A raw path breaks the moment the
      // original moves or is deleted, and a macOS path is meaningless on
      // Windows — so a project referencing one would render a missing
      // background on the other platform, which is the WYSIWYG failure this
      // whole port exists to remove.
      return await _bundleBackgroundImage(picked) ?? picked;
    } catch (e) {
      Log.e("PostProcessing", 'Error picking image: $e');
      return null;
    }
  }

  /// Copies [sourcePath] into the active project's canvas-assets directory and
  /// returns the bundled copy's path.
  ///
  /// Returns null when there is no open project or the copy fails; the caller
  /// then falls back to the original path, which still works on this machine
  /// even though it will not travel with the project.
  Future<String?> _bundleBackgroundImage(String sourcePath) async {
    final projectPath = _projectPath;
    if (projectPath == null) return null;
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return null;

      final sep = Platform.pathSeparator;
      final assetsDir = Directory('$projectPath$sep$kCanvasAssetsDirName');
      await assetsDir.create(recursive: true);

      // Split the basename by hand: this repo does not depend on package:path
      // (canvas_appearance_store.dart joins with Platform.pathSeparator too).
      // Accept BOTH separators so a path that came from a macOS-authored
      // project still splits correctly on Windows.
      final lastSep = sourcePath.lastIndexOf(RegExp(r'[\\/]'));
      final fileName = lastSep >= 0
          ? sourcePath.substring(lastSep + 1)
          : sourcePath;
      final dot = fileName.lastIndexOf('.');
      final base = dot > 0 ? fileName.substring(0, dot) : fileName;
      final ext = dot > 0 ? fileName.substring(dot) : '';

      // Name carries the source's modified stamp, so re-picking the same
      // unchanged file reuses the existing copy instead of growing the bundle
      // on every selection, while an edited original still produces a new one.
      final stat = await source.stat();
      final stamp = stat.modified.millisecondsSinceEpoch;
      final destPath = '${assetsDir.path}${sep}bg_${base}_$stamp$ext';

      final dest = File(destPath);
      if (!await dest.exists()) {
        await source.copy(destPath);
      }
      return destPath;
    } catch (e) {
      Log.e("PostProcessing", 'Error bundling background image: $e');
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
    if (e.code == NativeErrorCode.exportDiskFull) {
      return const SpanStatus.resourceExhausted();
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

  /// Phase 10.4: the structured EXPORT_CANCELLED code is the primary
  /// cancellation signal (Windows emits it); the legacy message sniffing
  /// stays as the fallback because macOS still cancels with prose-only
  /// errors. CRITICAL audit fix: this no longer consults
  /// `_isExportCancelRequested` — pressing Cancel used to turn ANY
  /// subsequent failure into a silent "clean cancel", eating real errors.
  bool _isExportCancellationException(PlatformException e) {
    return isExportCancellationError(e);
  }

  @visibleForTesting
  static bool isExportCancellationError(Object error) {
    if (error is PlatformException) {
      if (error.code == NativeErrorCode.exportCancelled) return true;
      if (_isLikelyCancellationMessage(error.message) ||
          _isLikelyCancellationMessage(error.details?.toString())) {
        return true;
      }
      return error.code.toLowerCase().contains('cancel');
    }
    return _isLikelyCancellationMessage(error.toString());
  }

  static bool _isLikelyCancellationMessage(String? message) {
    if (message == null || message.isEmpty) return false;
    final normalized = message.toLowerCase();
    return normalized.contains('cancel') ||
        normalized.contains('aborted') ||
        normalized.contains('interrupted') ||
        normalized.contains('stopped by user');
  }

  String _defaultExportFileName(
    AppLocalizations l10n, {
    required String format,
  }) {
    return buildDefaultExportFileName(l10n, format: format);
  }

  @visibleForTesting
  static String buildDefaultExportFileName(
    AppLocalizations l10n, {
    required String format,
    DateTime? now,
    bool? isDev,
  }) {
    final timestamp = now ?? DateTime.now();
    final month = timestamp.month.toString().padLeft(2, '0');
    final day = timestamp.day.toString().padLeft(2, '0');
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final label = format == 'gif'
        ? l10n.defaultClipFileNameLabel
        : l10n.defaultExportFileNameLabel;
    final prefix = 'Clingfy $label';
    if (isDev ?? BuildConfig.isDev()) {
      return '${prefix}_${timestamp.year}-$month-${day}_${hour}_$minute';
    }
    return '$prefix ${timestamp.year}-$month-$day';
  }
}
