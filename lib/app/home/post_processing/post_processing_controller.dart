import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
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
import 'package:clingfy/core/timeline/model/canvas_state.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/color/auto_grade_heuristic.dart';
import 'package:clingfy/core/models/background_preset_catalog.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/home/post_processing/support/audio_debouncer.dart';
import 'package:clingfy/app/home/export/widgets/export_file_dialog.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/bridges/job_progress.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'dart:convert';
import 'package:clingfy/core/captions/caption_rasterizer.dart';
import 'package:clingfy/core/captions/caption_reflow.dart';

/// Who asked the in-flight transcription to stop.
///
/// The distinction decides what may be done with the transcript the job
/// returns anyway — native cancellation is POLLED, so a job already past its
/// last check finishes normally however firmly it was stopped. Collapsing the
/// two into one "cancel requested" flag is how a transcript the user pressed
/// Stop on was still written to disk (it was salvaged as if the controller had
/// merely moved on) and came back on the next open — with
/// [SubtitleMode.burnIn] the default, into a published video.
enum _CaptionsCancelOrigin {
  /// Nobody stopped it. The result is applied and stored normally.
  none,

  /// The user pressed Stop. Its result may be written NOWHERE — not to the
  /// recording on screen, not to the one it ran against.
  user,

  /// The controller moved to another recording, which cancels to free the
  /// engine. Nobody refused this transcript, so it may still be salvaged into
  /// the project it ran against when that project has nothing to lose.
  recordingSwitch,
}

class PostProcessingController extends ChangeNotifier {
  final NativeBridge _nativeBridge;
  final SettingsController _settings;
  final PlayerController _player;

  /// How caption cues become PNGs for the export to composite.
  ///
  /// Injectable for one reason: the only way a burn-in half-fails is a PNG
  /// encode returning no bytes for some cues and not others, and that cannot be
  /// provoked through the real rasterizer from a test. Without a seam here the
  /// branch that turns "Export successful" into "saved without subtitles" is
  /// untestable — and it was silently deletable, proven by a reviewer removing
  /// it with the whole suite still green.
  final CaptionRasterizer _captionRasterizer;

  PostProcessingController({
    required SettingsController settings,
    required PlayerController player,
    required NativeBridge channel,
    CaptionRasterizer captionRasterizer = const CaptionRasterizer(),
  }) : _settings = settings,
       _player = player,
       _nativeBridge = channel,
       _captionRasterizer = captionRasterizer {
    _player.addListener(_onPlayerChanged);
    _warningSub = _player.warningCodeStream.listen(_onPlayerWarning);
    _cameraManualPositionSub = _player.cameraManualPositionStream.listen(
      _onCameraManualPositionChanged,
    );
    _resetForNewRecording();
  }

  /// Player notifications also carry CLIP edits (the clip editor forwards
  /// through `PlayerController`), and a clip edit moves every caption's edited
  /// position. The push de-duplicates on its own signature, so the 60Hz
  /// notifications a trim drag produces collapse to one real push.
  void _onPlayerChanged() {
    notifyListeners();
    unawaited(pushPreviewCaptions());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _player.removeListener(_onPlayerChanged);
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

  /// True when the last export was asked to burn subtitles in and could not.
  ///
  /// A skipped burn-in leaves an `exportVideo` payload byte-identical to one
  /// from before captions existed, so nothing downstream can tell the
  /// difference — native renders happily, the export succeeds, and the user
  /// ships a file they believe is subtitled. This is the only signal that says
  /// otherwise, which is why the saved-file notice reads it.
  bool _lastExportBurnInFailed = false;
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

  // ---- Subtitles -----------------------------------------------------------

  /// What native says about captioning this machine and this recording.
  /// `null` until the probe answers; the section shows nothing until then
  /// rather than flashing controls that may be replaced by a refusal.
  CaptionsCapabilityInfo? _captionsCapability;

  List<Caption> _captions = const [];
  bool _captionsUseMic = true;
  bool _captionsUseSystem = true;

  /// True while THIS recording is transcribing. Cleared when the controller
  /// moves to another recording, because a progress bar and a Stop button that
  /// belong to a different project's job are worse than no bar at all.
  bool _isGeneratingCaptions = false;

  /// The project a native transcription is currently running against, or null
  /// when the engine is idle.
  ///
  /// Separate from [_isGeneratingCaptions] because the two answer different
  /// questions once the user can switch recordings mid-job: this one is "is the
  /// engine busy" (it takes one job at a time and is not re-entrant), the other
  /// is "is the recording on screen the one transcribing". Conflating them is
  /// how a job on recording A drove recording B's bar, and how B's cues would
  /// have been able to start a second native job.
  String? _captionsJobProjectPath;

  /// Who stopped the job [_captionsJobProjectPath] names, if anyone.
  ///
  /// Separate from [_isCancellingCaptions], which is UI state for the recording
  /// ON SCREEN and is therefore cleared the moment the user opens another one.
  /// This belongs to the JOB and has to outlive that, because native
  /// cancellation is POLLED: a job already past its last check returns a full
  /// transcript however loudly it was told to stop, and what may be done with
  /// that transcript depends on WHO told it to stop. See
  /// [_CaptionsCancelOrigin].
  _CaptionsCancelOrigin _captionsCancelOrigin = _CaptionsCancelOrigin.none;

  /// Set the moment the user asks to stop, and cleared when the engine
  /// actually finishes unwinding.
  ///
  /// Its whole job is to acknowledge the press. A model download is not
  /// interruptible, so a cancel can take a while to land; with nothing changing
  /// on screen the button reads as broken, which is exactly what happened —
  /// eleven presses in four seconds, in the logs.
  bool _isCancellingCaptions = false;

  /// `null` = indeterminate. The model download and Core ML specialisation take
  /// tens of seconds before any real fraction exists.
  double? _captionsProgress;
  ProgressStage _captionsStage = ProgressStage.preparing;

  /// Separates "not run yet" from "ran and found nothing" — very different
  /// things to tell someone.
  bool _hasEverGeneratedCaptions = false;

  /// Set when the last run FAILED, so "ran and found nothing" is not reported
  /// for a model that would not download or a decode that threw. Cleared at the
  /// start of every run and by a successful one.
  String? _captionsErrorCode;
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

  /// Editing is unavailable: a preview render or an export is in flight, and
  /// both are reading the state the sidebar edits.
  ///
  /// A running transcription is deliberately NOT here, even though
  /// [isExportLocked] adds it. This getter dims the WHOLE post-processing
  /// sidebar and puts an `IgnorePointer` over it — and the captions Stop button
  /// lives inside that subtree, with no other route to [cancelCaptions]
  /// anywhere in the app. Adding captions here left someone watching a 626 MB
  /// model download with the only button that stops it unclickable.
  bool get isEditingLocked => _isProcessingPreview || _isExporting;

  /// Export is unavailable: everything [isEditingLocked] covers, plus a running
  /// transcription.
  ///
  /// Captions are in this set because a transcription that lands mid-export
  /// re-rasterises the NEW transcript for the preview, and that pass sweeps
  /// every bitmap the old transcript owned. Before this, Export stayed enabled
  /// throughout a "Generate again", so pressing it produced a file with
  /// subtitles for the first part and none after — reported as a success. The
  /// export rasterises into a directory of its own too; that stops the race
  /// once started, this stops it being started.
  ///
  /// Gate the Export ACTION on this, never a whole panel: see [isEditingLocked]
  /// for what disabling the sidebar costs while a transcription runs.
  bool get isExportLocked => isEditingLocked || _isGeneratingCaptions;
  bool get isExporting => _isExporting;
  bool get isExportCancelRequested => _isExportCancelRequested;
  bool get isExportInBackground => _isExportInBackground;
  bool get isExportDockCollapsed => _isExportInBackground;
  bool get lastExportWasCancelled => _lastExportWasCancelled;

  /// True when the file that was just written was supposed to have subtitles
  /// burned in and does not. See [_lastExportBurnInFailed].
  bool get lastExportBurnInFailed => _lastExportBurnInFailed;
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

  CaptionsCapabilityInfo? get captionsCapability => _captionsCapability;
  List<Caption> get captions => _captions;
  bool get captionsUseMic => _captionsUseMic;
  bool get captionsUseSystem => _captionsUseSystem;
  bool get isGeneratingCaptions => _isGeneratingCaptions;
  bool get isCancellingCaptions => _isCancellingCaptions;

  /// True when the engine is still unwinding a transcription the panel is NOT
  /// presenting, so a Generate pressed here cannot start one.
  ///
  /// The panel needs this because the engine takes one job at a time and the
  /// cancel that frees it is best-effort against a download that cannot be
  /// interrupted — minutes, in the worst case. Without it the recording on
  /// screen shows a live "Generate subtitles" button whose press is silently
  /// dropped by the engine-busy guard in [generateCaptions], with nothing on
  /// screen to explain why.
  ///
  /// Keyed on [isGeneratingCaptions] rather than on the job's project, because
  /// "not mine" is not the same question as "not shown". Coming BACK to the
  /// recording whose job is still unwinding lands on the same project path with
  /// the progress row already torn down — a project comparison calls that
  /// engine free and hands back the same dead button.
  bool get isCaptionsEngineBusyOffScreen =>
      _captionsJobProjectPath != null && !_isGeneratingCaptions;
  double? get captionsProgress => _captionsProgress;
  ProgressStage get captionsStage => _captionsStage;
  bool get hasEverGeneratedCaptions => _hasEverGeneratedCaptions;

  /// True when the last transcription failed rather than finding no speech.
  bool get captionsFailed => _captionsErrorCode != null;

  /// The caption manifest the preview is currently showing, so an identical
  /// re-push (a rebuild, a clip nudge that changed nothing) does no work.
  bool _isDisposed = false;
  String? _pushedCaptionSignature;

  /// Pushes run one at a time, and everything requested while one is running
  /// collapses into a SINGLE follow-up run.
  ///
  /// One at a time because the signature that suppresses redundant work is only
  /// assigned after the rasterization await, so two overlapping pushes race on
  /// it. Concretely: generate captions, then immediately switch subtitles off,
  /// and the clear reads a still-null signature, decides nothing is installed,
  /// and returns — while the generate push it overlapped goes on to install
  /// captions that nothing will ever take down.
  ///
  /// Collapsed rather than queued because `_onPlayerChanged` fires on every
  /// position update during playback. A chain would grow one link per tick and
  /// each link re-reads live state anyway, so all but the last are wasted work
  /// on results that are already stale by the time they run.
  bool _captionPushRunning = false;
  Completer<void>? _captionPushQueued;

  /// The export canvas, cached per (project, layout, resolution).
  ///
  /// Resolving it is a native round trip that loads the project, parses its
  /// metadata and reads the screen track — far too expensive to repeat per
  /// player tick, and the answer only moves when one of those three does.
  Size? _cachedExportSize;
  String? _cachedExportSizeKey;

  /// Memoized so the sidebar selector, which calls this on every notification,
  /// does not re-run an O(cues x clips) reflow each time.
  ReflowedCaptions? _reflowCache;
  List<Caption>? _reflowCacheCaptions;
  List<Clip>? _reflowCacheClips;

  /// Rasterizes the reflowed cues and hands them to the live preview.
  ///
  /// Gated on [exportSubtitleMode] burning in, because the preview's job is to
  /// show what the exported FRAMES will contain. With subtitles off there is
  /// nothing to show; with sidecar-only the captions go in a separate file and
  /// burning them into the preview would have the user proof-read a look the
  /// export will not produce.
  ///
  /// Best-effort and fire-and-forget everywhere it is called from: a preview
  /// without captions must never block an edit.
  Future<void> pushPreviewCaptions() {
    if (_captionPushRunning) {
      // Everything that lands mid-flight shares one follow-up run, and the
      // returned future still completes only once that run has finished, so an
      // `await` in a test or an export pre-flight remains honest.
      return (_captionPushQueued ??= Completer<void>()).future;
    }
    return _drainCaptionPushes();
  }

  Future<void> _drainCaptionPushes() async {
    _captionPushRunning = true;
    try {
      await _pushPreviewCaptionsGuarded();
      while (_captionPushQueued != null && !_isDisposed) {
        final pending = _captionPushQueued!;
        _captionPushQueued = null;
        await _pushPreviewCaptionsGuarded();
        pending.complete();
      }
    } finally {
      _captionPushRunning = false;
      // Disposal mid-drain must not strand a waiter on a future that will
      // never complete.
      final stranded = _captionPushQueued;
      _captionPushQueued = null;
      stranded?.complete();
    }
  }

  /// A failed push must not take the queued one down with it.
  Future<void> _pushPreviewCaptionsGuarded() async {
    try {
      await _pushPreviewCaptions();
    } catch (e, st) {
      Log.e("Captions", "Preview caption push failed", e, st);
    }
  }

  /// The canvas the EXPORT will use, cached per project and preset pair.
  Future<Size?> _exportCanvasSize(String projectPath) async {
    final key = [
      projectPath,
      _settings.post.layoutPreset.name,
      _settings.post.resolutionPreset.name,
    ].join('\u0000');
    final cached = _cachedExportSize;
    if (cached != null && key == _cachedExportSizeKey) return cached;

    final size = await _nativeBridge.resolveExportSize(
      projectPath: projectPath,
      layoutPreset: _settings.post.layoutPreset.name,
      resolutionPreset: _settings.post.resolutionPreset.name,
    );
    if (size == null) return null;
    _cachedExportSizeKey = key;
    _cachedExportSize = size;
    return size;
  }

  Future<void> _pushPreviewCaptions() async {
    if (_isDisposed) return;
    final projectPath = _projectPath;
    final sessionId = _activeSessionId;
    if (projectPath == null) return;

    final spans = exportSubtitleMode.burnsIn
        ? reflowedCaptions().sidecar
        : const <CaptionSpan>[];

    if (spans.isEmpty) {
      if (_pushedCaptionSignature == null) return;
      _pushedCaptionSignature = null;
      Log.i("Captions", "Preview captions cleared", null, null, {
        'mode': exportSubtitleMode.wireValue,
        'cues': _captions.length,
      });
      await _nativeBridge.previewSetCaptions(
        sessionId: sessionId,
        bitmapDirectory: null,
        cues: const [],
        canvasWidth: 0,
        canvasHeight: 0,
      );
      return;
    }

    try {
      // The canvas the EXPORT will use, not the preview's on-screen size: the
      // preview canvas is the same pixel space, shrunk by a layer transform, so
      // one rasterization serves both and the placement math is identical.
      // Cached: this is a native round trip and the signature check below is
      // downstream of it, so an uncached call would pay full price per tick.
      final size = await _exportCanvasSize(projectPath);
      if (size == null || _isDisposed || _projectPath != projectPath) return;

      final signature = [
        size.width.round(),
        size.height.round(),
        for (final span in spans)
          '${span.id}|${span.outputStartMs}|${span.outputEndMs}|${span.text}',
      ].join('\u0000');
      if (signature == _pushedCaptionSignature) return;

      final manifest = await _captionRasterizer.rasterize(
        captions: [for (final span in spans) span.asOutputCue()],
        videoSize: size,
        directory: Directory('$projectPath/post/captions'),
      );
      if (_isDisposed || _projectPath != projectPath) return;

      _pushedCaptionSignature = signature;
      Log.i("Captions", "Preview captions pushed", null, null, {
        'cues': manifest.entries.length,
        'canvas': '${size.width.toInt()}x${size.height.toInt()}',
      });
      await _nativeBridge.previewSetCaptions(
        sessionId: sessionId,
        bitmapDirectory: manifest.directoryPath,
        cues: [for (final entry in manifest.entries) entry.toExportArgs()],
        canvasWidth: size.width,
        canvasHeight: size.height,
      );
    } catch (e, st) {
      Log.e("PostProcessing", "Preview caption push failed", e, st);
    }
  }

  /// The transcript mapped onto the edited timeline.
  ///
  /// Cues are transcribed against the ORIGINAL audio, so their times are source
  /// times; cuts, splits and reordering change where each one lands in the
  /// exported file. Evaluated once per export and shared by both destinations,
  /// so the burned-in caption and the sidecar entry can never be computed
  /// against different clip lists.
  ReflowedCaptions reflowedCaptions() {
    // `clipEditor.clips` hands back a fresh unmodifiable wrapper every call, so
    // the cache key compares values. Clips are few and carry `==`; the reflow
    // it skips is O(cues x clips) and runs on every controller notification.
    final clips = _player.clipEditor?.clips ?? const <Clip>[];
    final cached = _reflowCache;
    if (cached != null &&
        identical(_reflowCacheCaptions, _captions) &&
        listEquals(_reflowCacheClips, clips)) {
      return cached;
    }
    final reflowed = CaptionReflow.reflow(captions: _captions, clips: clips);
    _reflowCacheCaptions = _captions;
    _reflowCacheClips = clips;
    _reflowCache = reflowed;
    return reflowed;
  }

  /// The destination the next export will actually use.
  ///
  /// The stored preference is overridden to [SubtitleMode.none] when there is
  /// no transcript, so a stored "burn in" never puts native into a caption
  /// path with an empty track.
  SubtitleMode get exportSubtitleMode =>
      _captions.isEmpty ? SubtitleMode.none : _settings.post.postSubtitleMode;

  /// Asks native whether captions are possible here, and seeds the source
  /// selection from what the recording actually contains.
  Future<void> refreshCaptionsCapability() async {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    try {
      final info = await _nativeBridge.captionsCapability(projectPath);
      if (_projectPath != projectPath) return; // switched project mid-flight
      _captionsCapability = info;
      _captionsUseMic = info.defaultUsesMic;
      _captionsUseSystem = info.defaultUsesSystem;
      notifyListeners();
    } catch (e, st) {
      Log.e("PostProcessing", "Captions capability probe failed", e, st);
    }
  }

  void setCaptionsUseMic(bool value) {
    if (value == _captionsUseMic) return;
    _captionsUseMic = value;
    notifyListeners();
  }

  void setCaptionsUseSystem(bool value) {
    if (value == _captionsUseSystem) return;
    _captionsUseSystem = value;
    notifyListeners();
  }

  /// Routed here from the shared job-progress callback when the tick is tagged
  /// `captions`, so a transcription never moves the export bar.
  void updateCaptionsProgress(JobProgress progress) {
    // A cancelled job keeps emitting for as long as it takes to unwind. Letting
    // those ticks through would move a bar the user has already stopped.
    //
    // [_isGeneratingCaptions] is also what keeps a transcription of recording A
    // from driving recording B's bar: the tick arrives on one shared callback,
    // and the flag means "the recording ON SCREEN is transcribing", so
    // [_resetForNewRecording] clearing it is what shuts this path off the
    // moment the user opens something else.
    if (!_isGeneratingCaptions || _isCancellingCaptions) return;
    _captionsProgress = progress.fraction;
    _captionsStage = progress.stage;
    notifyListeners();
  }

  Future<void> generateCaptions() async {
    final projectPath = _projectPath;
    // The engine takes one job at a time and is not re-entrant, so the guard is
    // "the engine is busy", not "this recording is busy" — otherwise switching
    // recordings mid-job would let a second native transcription start.
    if (projectPath == null || _captionsJobProjectPath != null) return;
    if (!_captionsUseMic && !_captionsUseSystem) return;

    _captionsJobProjectPath = projectPath;
    _captionsCancelOrigin = _CaptionsCancelOrigin.none;
    _isGeneratingCaptions = true;
    // Not reset here: the `finally` below always runs once past the guards
    // above, so a previous run cannot leave this set.
    _captionsProgress = null;
    _captionsStage = ProgressStage.preparing;
    // Reset here, because a retry that succeeds must stop reporting the last
    // failure and the `finally` cannot tell the two outcomes apart.
    _captionsErrorCode = null;
    notifyListeners();

    try {
      final raw = await _nativeBridge.generateCaptions(
        projectPath: projectPath,
        useMic: _captionsUseMic,
        useSystem: _captionsUseSystem,
      );
      final cues = [for (final m in raw) Caption.fromMap(m)];
      if (_captionsCancelOrigin != _CaptionsCancelOrigin.none) {
        // A run nobody is waiting for any more. Native cancellation is POLLED,
        // so a job already past its last check finishes normally and arrives
        // here with a full transcript regardless — and what may be done with it
        // depends entirely on who stopped it.
        //
        // A Stop the USER pressed is an instruction, not a hint: the result is
        // dropped, everywhere. Writing it "somewhere harmless" is exactly the
        // bug — the abandoned transcript landed on the recording it ran against,
        // reappeared the next time that recording was opened, and with
        // [SubtitleMode.burnIn] the default could be burned into a published
        // video.
        //
        // A cancel the CONTROLLER issued to free the engine ([attachToRecording]
        // → [_resetForNewRecording]) refused nothing, so the cues are still
        // worth having. They may be written only where they can destroy
        // nothing: the project the job ran against, which the user has already
        // left, and only when it holds no transcript of its own — overwriting
        // is how hand corrections were replaced by a machine transcript from a
        // regeneration the user had walked away from. Filling an empty one
        // loses nothing and saves minutes of compute, which is why this is not
        // simply dropped.
        //
        // Never the project on SCREEN, even when that is the same one (the user
        // left recording A and came back to it): the panel there says "not
        // transcribed", and a write it cannot see is the same surprise-on-next-
        // open as above.
        if (_captionsCancelOrigin == _CaptionsCancelOrigin.recordingSwitch &&
            _projectPath != projectPath) {
          _persistCaptions(projectPath, cues, onlyWhenAbsent: true);
        }
        return;
      }
      // Nobody stopped this run, so it is still the OPEN recording's own
      // transcription: every path that changes the open recording cancels the
      // job first ([_resetForNewRecording]), and a cancelled run has returned
      // above. That is why there is no "is this still the open project" guard
      // here — it could not fire, and pretending otherwise described a hazard
      // that cannot happen. If a future change ever lets a live job outlive the
      // switch, this needs that guard back before [_captions] is assigned.
      _persistCaptions(projectPath, cues);
      _captions = cues;
      _hasEverGeneratedCaptions = true;
      unawaited(pushPreviewCaptions());
    } on PlatformException catch (e) {
      // Cancelling is a normal outcome, not a failure worth surfacing.
      if (e.code != 'CAPTIONS_CANCELLED') {
        Log.e(
          "PostProcessing",
          "Caption generation failed: ${e.code}",
          e,
          null,
        );
        // Same guard the success path uses: a job that fails after the user
        // has moved to another recording must not report its failure against
        // that one.
        if (_projectPath != projectPath) return;
        _hasEverGeneratedCaptions = true;
        // Without this the section reads "no speech found", because that
        // notice keys off `hasEverGenerated` plus an empty cue list — which is
        // exactly the state a failure leaves behind. A model that would not
        // download and a recording of silence are not the same thing to tell
        // someone, and only one of them is worth retrying.
        _captionsErrorCode = e.code;
      }
    } catch (e, st) {
      Log.e("PostProcessing", "Caption generation failed", e, st);
      if (_projectPath != projectPath) return;
      _hasEverGeneratedCaptions = true;
      _captionsErrorCode = 'CAPTIONS_FAILED';
    } finally {
      // The engine is free again whoever was watching — this is what lets the
      // next Generate through, on this recording or another, and what clears
      // [isCaptionsEngineBusyOffScreen] on the recording that is waiting.
      _captionsJobProjectPath = null;
      _captionsCancelOrigin = _CaptionsCancelOrigin.none;
      // Safe to clear unconditionally only because the guard above serialises
      // jobs: no second transcription can have started while this one was in
      // flight, so there is never another recording's in-flight state here to
      // trample. If that guard is ever relaxed, this has to be keyed on
      // [projectPath] as well.
      _isGeneratingCaptions = false;
      _isCancellingCaptions = false;
      _captionsProgress = null;
      notifyListeners();
    }
  }

  /// Routed through the controller rather than written straight to settings,
  /// so switching subtitles off — or to sidecar-only — actually clears the
  /// burned-in captions from the preview. Written directly, the preview would
  /// keep showing a burn-in the export is not going to produce.
  void setSubtitleMode(SubtitleMode value) {
    if (value == _settings.post.postSubtitleMode) return;
    unawaited(_settings.post.updatePostSubtitleMode(value));
    notifyListeners();
    unawaited(pushPreviewCaptions());
  }

  Future<void> cancelCaptions() async {
    if (!_isGeneratingCaptions || _isCancellingCaptions) return;
    // Marks the JOB, not the screen: the transcript it may still return has to
    // be treated as refused even if the user opens another recording before it
    // lands — a Stop is not undone by walking away. See
    // [_CaptionsCancelOrigin.user].
    _captionsCancelOrigin = _CaptionsCancelOrigin.user;
    // Flip the UI first. The engine may take seconds to unwind — it cannot be
    // interrupted mid-download — and the press has to be visibly received or
    // the user just presses again.
    _isCancellingCaptions = true;
    _captionsProgress = null;
    notifyListeners();
    await _nativeBridge.cancelCaptions();
  }

  /// Corrects one cue's text.
  ///
  /// The edited track is the truth from here on: re-generating replaces it
  /// wholesale, which is why the button says so once cues exist.
  void updateCaptionText(String cueId, String text) {
    final index = _captions.indexWhere((c) => c.id == cueId);
    if (index < 0) return;
    final trimmed = text.trim();
    if (trimmed == _captions[index].text) return;
    final next = List<Caption>.from(_captions);
    final existing = next[index];
    next[index] = Caption(
      id: existing.id,
      startMs: existing.startMs,
      endMs: existing.endMs,
      text: trimmed,
      words: existing.words,
      translatedText: existing.translatedText,
    );
    _captions = next;
    notifyListeners();
    final projectPath = _projectPath;
    if (projectPath != null) _persistCaptions(projectPath, next);
    unawaited(pushPreviewCaptions());
  }

  /// Fire-and-forget, like every other per-project editor write. The store
  /// serialises overlapping saves itself, so a correction landing while a
  /// regeneration completes cannot interleave into unparseable JSON.
  ///
  /// Takes the project and the cues explicitly rather than reading the live
  /// fields: a transcription outlives the recording it was started on, and the
  /// only correct destination for its result is the project it ran against —
  /// which by then may not be the one open.
  ///
  /// [onlyWhenAbsent] refuses to replace a transcript that is already stored,
  /// for a result the user abandoned. The test is done inside the store's
  /// mutation so it reads the same state the write is about to replace — a
  /// read outside it would race a correction being saved at that moment, which
  /// is precisely the hand-typed work this exists to protect.
  void _persistCaptions(
    String projectPath,
    List<Caption> captions, {
    bool onlyWhenAbsent = false,
  }) {
    unawaited(
      PostStateStore.update(projectPath, (state) {
        if (onlyWhenAbsent) {
          final stored = state.trackOfType<CaptionTrack>();
          if (stored != null && stored.captions.isNotEmpty) return state;
        }
        return state.withTrack(CaptionTrack(captions: captions));
      }),
    );
  }

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

  /// Rendered thumbnail path for a background-preset card, or null when the
  /// platform cannot produce one (the picker then keeps its palette swatch).
  ///
  /// Intensity, blur and seed are FIXED here rather than taken from the live
  /// preset. The card says "this is Graphic Mesh", not "this is Graphic Mesh at
  /// 62% intensity" — and passing the live values would render and cache a new
  /// PNG on every frame of a slider drag. Only the preset id and palette vary,
  /// which are discrete taps, so the cache holds one file per combination.
  ///
  /// The seed is fixed for the same reason: Randomize would otherwise
  /// invalidate every thumbnail on the screen.
  Future<String?> presetThumbnail(String presetId, String paletteId) {
    return _nativeBridge.canvasPresetThumbnail(
      presetId: presetId,
      palette: paletteId,
      intensity: BackgroundPresetCatalog.defaultIntensity,
      blur: BackgroundPresetCatalog.defaultBlur,
      seed: 1,
      width: 72,
      height: 48,
    );
  }

  void setLayoutPreset(LayoutPreset v) {
    _settings.post.updateLayoutPreset(v);
    // [applyProcessing] drives `processVideo`, which is a no-op on Windows —
    // so without this the layout reached the export and nothing else. Native
    // needs it on the canvas channel for two reasons: padding/radius are
    // normalised against the export target these presets resolve, and a layout
    // that changes the canvas ASPECT requires the preview session to be
    // rebuilt (the shared texture is sized to it and cannot be resized).
    _pushCanvas();
    applyProcessing();
    // The caption bitmaps are sized to the export canvas this preset resolves,
    // so a preset change makes them the wrong size — and, once the wrap width
    // changes, sometimes the wrong line count. Native hides them until this
    // re-rasterization lands.
    unawaited(pushPreviewCaptions());
  }

  void setResolutionPreset(ResolutionPreset v) {
    _settings.post.updateResolutionPreset(v);
    // Same as [setLayoutPreset]: the resolution is half of the export target
    // that padding and corner radius are normalised against. It does not
    // reshape the preview texture (that stays aspect-only inside a fixed
    // budget), so this pushes the value without forcing a rebuild.
    _pushCanvas();
    applyProcessing();
    unawaited(pushPreviewCaptions());
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
    // A new recording has its own audio and its own answer, so nothing from the
    // last one may survive — a stale capability would offer sources this
    // project does not have, and stale cues would show another recording's
    // subtitles.
    _captionsCapability = null;
    // Restored, not cleared: a transcript costs minutes of compute and carries
    // the user's own corrections, so reopening a recording that has one must
    // not silently present it as never transcribed.
    final storedCaptions = PostStateStore.load(
      projectPath,
    ).trackOfType<CaptionTrack>();
    _captions = storedCaptions?.captions ?? const [];
    _hasEverGeneratedCaptions = _captions.isNotEmpty;
    // Another recording's manifest may still be installed natively.
    _pushedCaptionSignature = null;
    notifyListeners();
    unawaited(_loadRecordingSceneInfo(projectPath));
    unawaited(refreshCaptionsCapability());
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
    // Per-recording, like everything else here: a failure belongs to the
    // recording it happened on, not to the next one opened.
    _captionsErrorCode = null;
    // A transcription belongs to the recording it was started on. Left set,
    // these gave the newly-opened recording someone else's progress bar and
    // Stop button, and its Generate did nothing at all.
    _isGeneratingCaptions = false;
    _isCancellingCaptions = false;
    _captionsProgress = null;
    _captionsStage = ProgressStage.preparing;
    // Cancelled rather than left to run, deliberately. The engine takes ONE job
    // at a time, so a job left running keeps Generate on the newly-opened
    // recording inert for however long the old transcription has left —
    // [isCaptionsEngineBusyOffScreen] is what says so on screen meanwhile.
    // Cancelling frees the engine promptly. The cancel is asynchronous and a
    // model download cannot be interrupted, so the job may still finish:
    // [generateCaptions] writes its cues to the project it started on when
    // there is nothing there to lose, which is why a first transcription is not
    // thrown away — and why a REgeneration cannot overwrite the corrections on
    // the recording being left behind.
    if (_captionsJobProjectPath != null) {
      // Never downgrades a Stop the user pressed. Overwriting it here is what
      // turned "I stopped that transcript" into "it was saved anyway": the
      // switch relabelled the job as merely abandoned, and the salvage write
      // below became legal again.
      if (_captionsCancelOrigin == _CaptionsCancelOrigin.none) {
        _captionsCancelOrigin = _CaptionsCancelOrigin.recordingSwitch;
      }
      unawaited(_nativeBridge.cancelCaptions().catchError((Object _) {}));
    }
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
    if (_projectPath != projectPath) return;
    // Nothing persisted means nothing to restore. Falling through would clear
    // the colour history and overwrite an edit the user made while the scene
    // was still loading.
    if (!PostStateStore.hasStoredCanvas(projectPath)) return;
    final stored = PostStateStore.load(projectPath);
    final canvas = stored.canvas;
    _videoPadding = canvas.padding;
    _videoRadius = canvas.cornerRadius;
    _backgroundKind = canvas.backgroundKind;
    _backgroundColor = canvas.backgroundColorArgb;
    _backgroundImagePath = canvas.backgroundImagePath;
    _backgroundPreset = canvas.backgroundPreset;
    _colorGrade = stored.grade;
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
      PostStateStore.update(
        projectPath,
        (state) => state.copyWith(
          grade: _colorGrade,
          canvas: CanvasState(
            padding: _videoPadding,
            cornerRadius: _videoRadius,
            backgroundKind: _backgroundKind,
            backgroundColorArgb: _backgroundColor,
            backgroundImagePath: _backgroundImagePath,
            backgroundPreset: _backgroundPreset,
          ),
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
        // Speaker-to-mic bleed removal. Native runs it only when BOTH
        // separated sidecars exist and only when it measures real bleed,
        // so sending it unconditionally is safe.
        'micEchoCancellationEnabled':
            _settings.recording.micEchoCancellationEnabled,
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

  /// Renders each cue to a PNG and returns the `exportVideo` arguments that
  /// point native at them.
  ///
  /// Burn-in composites bitmaps, not strings, because the caption font is
  /// bundled with the Flutter side and Arabic needs bidi reordering and
  /// contextual shaping — text handed to native as a string would draw as
  /// disconnected letters in the wrong order.
  ///
  /// Returns null whenever burn-in cannot be done honestly: no cues, or native
  /// declining to say what size the frames will be. Skipping is the right
  /// render decision — rasterising at a guessed size burns permanently wrong
  /// captions into the video, which is worse than none — but a skip that was
  /// ASKED for and failed sets [lastExportBurnInFailed], because the resulting
  /// `exportVideo` payload is byte-identical to a pre-captions export and would
  /// otherwise end in a plain success toast over a video with no subtitles.
  @visibleForTesting
  Future<Map<String, dynamic>?> rasterizeCaptionsForExport([
    ReflowedCaptions? reflowed,
  ]) async {
    final projectPath = _projectPath;
    // The burn-in view: source-timed, and guaranteed free of overlapping spans
    // so native's cue track accepts every one of them.
    final spans = (reflowed ?? reflowedCaptions()).burnIn;
    // Nothing to draw is a legitimate no-op, not a failure: there is genuinely
    // no difference between that export and one from before captions existed.
    // Everything past this point was asked for, so every other exit is a
    // failure the user has to be told about.
    _lastExportBurnInFailed = false;
    if (projectPath == null || spans.isEmpty) {
      Log.i("Captions", "No burn-in payload", null, null, {
        'hasProject': projectPath != null,
        'cues': _captions.length,
        'burnInSpans': spans.length,
        'mode': exportSubtitleMode.wireValue,
      });
      return null;
    }

    try {
      final size = await _nativeBridge.resolveExportSize(
        projectPath: projectPath,
        layoutPreset: _settings.post.layoutPreset.name,
        resolutionPreset: _settings.post.resolutionPreset.name,
        // Read AFTER the export dialog has been applied to settings, so these
        // are the format and GIF size the render will actually use. A GIF is
        // not rendered at the resolution preset: the exporter caps its
        // intermediate to the GIF long-edge preset, and a bitmap laid out for
        // the uncapped canvas is composited ~1.8x too large — the caption
        // renderer only ever scales a bitmap DOWN, and only when it is wider
        // than the frame, so a short cue is drawn 1:1 at the wrong scale.
        format: _settings.export.exportFormat,
        gifSize: _settings.export.gifSize,
      );
      if (size == null) {
        _lastExportBurnInFailed = true;
        Log.w(
          "Captions",
          "Skipping caption burn-in: native did not report an export size",
        );
        return null;
      }

      // Inside the project bundle, not a temp dir: the export can be cancelled
      // or fail partway, and a cache the OS may reap mid-render would leave
      // native reading bitmaps that have vanished.
      //
      // In a directory of its OWN, not the preview's `post/captions`: the
      // preview push rasterises into that directory and then sweeps every PNG
      // the current transcript does not reference. A "Generate again" landing
      // mid-render therefore deleted the bitmaps this export was still reading,
      // and native composited nothing from that point on — a video with
      // subtitles for the first part and none after, reported as a success. The
      // sweep only ever touches the directory it is handed, and it skips
      // non-file entries, so a subdirectory is out of reach from both sides.
      final directory = Directory(
        '$projectPath/post/captions/$_exportCaptionDirName',
      );
      final manifest = await _captionRasterizer.rasterize(
        captions: [for (final span in spans) span.asSourceCue()],
        videoSize: size,
        directory: directory,
      );
      final args = manifest.toExportArgs();
      // A span with visible text that produced no manifest entry is one whose
      // PNG encode failed. The rasterizer logs it and carries on so the rest
      // still burn in, which is right — but the file is then missing a subtitle
      // the user wrote, and that is not a success either.
      final drawable = spans.where((s) => s.text.trim().isNotEmpty).length;
      if (manifest.entries.length < drawable) {
        _lastExportBurnInFailed = true;
      }
      Log.i("Captions", "Export burn-in payload prepared", null, null, {
        'cues': manifest.entries.length,
        'spans': spans.length,
        'drawable': drawable,
        'canvas': '${size.width.toInt()}x${size.height.toInt()}',
        'directory': manifest.directoryPath,
      });
      // Empty because nothing had visible text (every cue blanked by hand) is
      // a no-op; empty when something WAS drawable is the encode failure the
      // check above already flagged.
      if (args.isEmpty) return null;
      return args;
    } catch (e, st) {
      _lastExportBurnInFailed = true;
      Log.e("PostProcessing", "Caption rasterization failed", e, st);
      return null;
    }
  }

  /// The export's caption-bitmap directory, inside the preview's
  /// `post/captions`. One stable name, kept between exports.
  ///
  /// Stable rather than unique-per-export because the bitmap names are a hash
  /// of the text and the canvas: a re-export of the same cues finds every PNG
  /// already on disk and re-encodes nothing. A per-export name made a 300-cue
  /// transcript re-run TextPainter layout, `toImage` and PNG encode for all 300
  /// on EVERY export, awaited serially on the UI isolate — the cache exists
  /// precisely to stop that.
  ///
  /// Kept rather than deleted afterwards for the same reason; it cannot grow
  /// without bound because [CaptionRasterizer.rasterize] sweeps the directory it
  /// renders into, so this holds exactly the last export's cues. Only one export
  /// runs at a time ([_isExporting] guards that), so that sweep can never delete
  /// a bitmap another export is still reading.
  static const String _exportCaptionDirName = 'export';

  /// Strips a trailing file extension, if there is one.
  ///
  /// Only a dot in the last path segment counts: `~/My.Videos/clip` has no
  /// extension, and naively cutting at the last dot would write the sidecar
  /// into a sibling of the directory rather than beside the video.
  static String _withoutExtension(String path) {
    final lastSeparator = path.lastIndexOf(Platform.pathSeparator);
    final dot = path.lastIndexOf('.');
    if (dot <= lastSeparator + 1) return path;
    return path.substring(0, dot);
  }

  /// Writes `.srt` and `.vtt` beside the exported video.
  ///
  /// Done here rather than natively because the formats are pure text and the
  /// serializer is already shared, and because native has just told us where
  /// the file actually landed — after its own name-collision handling, which
  /// is the only path that knows the final name.
  ///
  /// A sidecar failure never fails the export. The video is already on disk
  /// and re-running the whole render to retry two small text files would be a
  /// far worse outcome than a missing subtitle track the user can regenerate.
  @visibleForTesting
  Future<void> writeSubtitleSidecars(
    String videoPath,
    SubtitleMode mode, [
    ReflowedCaptions? reflowed,
  ]) async {
    // The sidecar view: timestamps on the EXPORTED timeline. Writing source
    // times here would put every subtitle at the wrong moment the instant a
    // recording has a single cut.
    final spans = (reflowed ?? reflowedCaptions()).sidecar;
    if (!mode.writesSidecar || spans.isEmpty) return;
    final cues = [for (final span in spans) span.asOutputCue()];

    final stem = _withoutExtension(videoPath);

    for (final entry in {
      '$stem.srt': SubtitleSerializer.toSrt(cues),
      '$stem.vtt': SubtitleSerializer.toWebVtt(cues),
    }.entries) {
      try {
        // Written as UTF-8 without a BOM: WebVTT requires UTF-8, and SubRip
        // has no encoding declaration at all, so UTF-8 is what every modern
        // parser assumes.
        await File(entry.key).writeAsString(entry.value, encoding: utf8);
      } catch (e, st) {
        Log.e("PostProcessing", "Failed to write ${entry.key}", e, st);
      }
    }
  }

  Future<String?> exportCurrentRecording(BuildContext context) async {
    _lastExportWasCancelled = false;
    // Belongs to the export about to run, not to the last one — the notice this
    // drives is shown against the file this call produces.
    _lastExportBurnInFailed = false;

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

      final subtitleMode = exportSubtitleMode;
      // Once, before either destination runs: the clip list must not be read
      // twice across the awaits that follow.
      final reflowed = reflowedCaptions();
      final captionArgs = subtitleMode.burnsIn
          ? await rasterizeCaptionsForExport(reflowed)
          : null;

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
        // Speaker-to-mic bleed removal. Native runs it only when BOTH
        // separated sidecars exist and only when it measures real bleed,
        // so sending it unconditionally is safe.
        'micEchoCancellationEnabled':
            _settings.recording.micEchoCancellationEnabled,
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
        // Caption bitmaps and their directory, or nothing at all. Native
        // composites pre-rendered PNGs rather than text: the bundled font and
        // the bidi/shaping engine live on this side, so a transcript sent as
        // strings could not be drawn correctly for every script we ship.
        ...?captionArgs,
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
        await writeSubtitleSidecars(newPath, subtitleMode, reflowed);
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

  /// `null` means the job cannot report a fraction, which the UI shows as an
  /// indeterminate spinner. Distinct from 0.0, which means "just started" —
  /// conflating them is how a determinate bar gets stuck at 0% forever.
  ///
  /// Range normalisation already happened in [JobProgress]; this only stores.
  void updateProgress(double? p) {
    _exportProgress = p;
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
