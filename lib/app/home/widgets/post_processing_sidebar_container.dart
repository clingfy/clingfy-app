import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/bridges/job_progress.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'dart:async';

class PostProcessingSidebarContainer extends StatelessWidget {
  const PostProcessingSidebarContainer({
    super.key,
    required this.settingsController,
    required this.isRecording,
    required this.selectedIndex,
    required this.availableWidth,
    required this.isCompact,
    this.showHeader = true,
  });

  final SettingsController settingsController;
  final bool isRecording;
  final int selectedIndex;
  final double availableWidth;
  final bool isCompact;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final canInteractWithPreview = context.select<RecordingController, bool>(
      (r) => r.canInteractWithPreview,
    );
    final postHasError = context.select<PostProcessingController, bool>(
      (p) => p.hasError,
    );
    final postEditingLocked = context.select<PostProcessingController, bool>(
      (p) => p.isEditingLocked,
    );
    final canEditPost =
        canInteractWithPreview &&
        !isRecording &&
        !postHasError &&
        !postEditingLocked;

    return Selector<
      PostProcessingController,
      ({
        bool isEditingLocked,
        double padding,
        double radius,
        int? bg,
        String? img,
        BackgroundKind bgKind,
        CanvasBackgroundPreset? bgPreset,
        bool showCursor,
        bool cursorAvailable,
        double cursorSize,
        double zoom,
        bool zoomEffectEnabled,
        double gain,
        double volume,
        VoiceCleanup voiceCleanup,
        ColorGrade colorGrade,
        bool hasCameraAsset,
        CameraCompositionState? cameraState,
        CameraExportCapabilities cameraExportCapabilities,
        bool? sceneHasAudio,
        bool? sceneMicGainApplies,
        CaptionsCapabilityInfo? captionsCapability,
        List<Caption> captions,
        bool captionsUseMic,
        bool captionsUseSystem,
        bool isGeneratingCaptions,
        double? captionsProgress,
        ProgressStage captionsStage,
        bool hasEverGeneratedCaptions,
      })
    >(
      selector: (_, p) => (
        isEditingLocked: p.isEditingLocked,
        padding: p.padding,
        radius: p.radius,
        bg: p.backgroundColor,
        img: p.backgroundImagePath,
        bgKind: p.backgroundKind,
        bgPreset: p.backgroundPreset,
        showCursor: p.showCursor,
        cursorAvailable: p.cursorAvailable,
        cursorSize: p.cursorSize,
        zoom: p.zoomFactor,
        zoomEffectEnabled: p.zoomEffectEnabled,
        gain: p.audioGainDb,
        volume: p.audioVolumePercent,
        voiceCleanup: p.voiceCleanup,
        // Part of the record so the sidebar rebuilds when the grade changes —
        // relies on ColorGrade value equality. Without it the color sliders
        // stayed frozen even though the preview updated.
        colorGrade: p.colorGrade,
        hasCameraAsset: p.hasCameraAsset,
        cameraState: p.cameraState,
        cameraExportCapabilities: p.cameraExportCapabilities,
        sceneHasAudio: p.sceneHasAudio,
        sceneMicGainApplies: p.sceneMicGainApplies,
        captionsCapability: p.captionsCapability,
        // The controller replaces this list wholesale rather than mutating it,
        // so a plain identity comparison is enough to notice an edit — an
        // in-place mutation would not rebuild and the cue would appear stuck.
        captions: p.captions,
        captionsUseMic: p.captionsUseMic,
        captionsUseSystem: p.captionsUseSystem,
        isGeneratingCaptions: p.isGeneratingCaptions,
        captionsProgress: p.captionsProgress,
        captionsStage: p.captionsStage,
        hasEverGeneratedCaptions: p.hasEverGeneratedCaptions,
      ),
      builder: (context, vm, _) {
        final post = context.read<PostProcessingController>();
        // Audio separation (D10): prefer what the RECORDING actually
        // contains (the platform's probed scene-info verdict) over the
        // live device selection — a mic unplugged after recording must not
        // disable the gain slider, and a mic-less recording must not
        // enable it. Null = the platform didn't report (macOS today):
        // keep the legacy device-selection gate.
        final deviceHasAudio = context.select<DeviceController, bool>(
          (d) => d.selectedAudioSourceId != DeviceController.noAudioId,
        );
        final hasAudio = vm.sceneHasAudio ?? deviceHasAudio;

        return ListenableBuilder(
          listenable: settingsController.post,
          builder: (context, _) {
            final showResolutionControl =
                BuildConfig.showDevPreviewResolutionControl();
            return PostProcessingSidebar(
              selectedIndex: selectedIndex,
              availableWidth: availableWidth,
              isCompact: isCompact,
              showHeader: showHeader,
              enabled: canEditPost,
              isProcessing: vm.isEditingLocked,
              cursorAvailable: vm.cursorAvailable,
              hasAudio: hasAudio,
              // Gain/normalize availability (mic-dependent on separated
              // recordings). Null keeps the sections' hasAudio fallback.
              gainAvailable: vm.sceneMicGainApplies,
              layoutPreset: settingsController.post.layoutPreset,
              resolutionPreset: settingsController.post.resolutionPreset,
              fitMode: settingsController.post.fitMode,
              padding: vm.padding,
              radius: vm.radius,
              backgroundColor: vm.bg,
              backgroundImagePath: vm.img,
              backgroundKind: vm.bgKind,
              backgroundPreset: vm.bgPreset,
              showCursor: vm.showCursor,
              cursorSize: vm.cursorSize,
              zoomFactor: vm.zoom,
              zoomEffectEnabled: vm.zoomEffectEnabled,
              hasCameraAsset: vm.hasCameraAsset,
              cameraState: vm.cameraState,
              cameraExportCapabilities: vm.cameraExportCapabilities,
              audioGainDb: vm.gain,
              audioVolume: vm.volume,
              voiceCleanup: vm.voiceCleanup,
              captionsCapability: vm.captionsCapability,
              captions: vm.captions,
              captionsUseMic: vm.captionsUseMic,
              captionsUseSystem: vm.captionsUseSystem,
              isGeneratingCaptions: vm.isGeneratingCaptions,
              captionsProgress: vm.captionsProgress,
              captionsStageLabel: _captionsStageLabel(
                context,
                vm.captionsStage,
              ),
              hasEverGeneratedCaptions: vm.hasEverGeneratedCaptions,
              autoNormalizeOnExport:
                  settingsController.post.postAutoNormalizeEnabled,
              autoNormalizeTargetDbfs:
                  settingsController.post.postTargetLoudnessDbfs,
              showResolutionControl: showResolutionControl,
              onPaddingChanged: post.setPadding,
              onPaddingChangeEnd: (_) => post.applyProcessing(),
              onRadiusChanged: post.setRadius,
              onRadiusChangeEnd: (_) => post.applyProcessing(),
              onBackgroundColorChanged: post.setBackgroundColor,
              onBackgroundImageChanged: post.setBackgroundImagePath,
              onBackgroundKindChanged: post.setBackgroundKind,
              onBackgroundPresetChanged: post.setBackgroundPreset,
              onBackgroundPresetPreview: post.updateBackgroundPresetPreview,
              onCursorShowChanged: post.setShowCursor,
              onCursorSizeChanged: post.setCursorSize,
              onCursorSizeChangeEnd: (_) => post.applyProcessing(),
              onZoomFactorChanged: post.setZoomFactor,
              onZoomFactorChangeEnd: post.setZoomFactorEnd,
              onZoomEffectEnabledChanged: post.setZoomEffectEnabled,
              onAudioGainChanged: post.setAudioGainDb,
              onAudioGainChangeEnd: post.setAudioGainDbEnd,
              onVoiceCleanupChanged: post.setVoiceCleanup,
              onCaptionsUseMicChanged: post.setCaptionsUseMic,
              onCaptionsUseSystemChanged: post.setCaptionsUseSystem,
              onGenerateCaptions: () => unawaited(post.generateCaptions()),
              onCancelCaptions: () => unawaited(post.cancelCaptions()),
              onCaptionTextChanged: post.updateCaptionText,
              colorGrade: vm.colorGrade,
              onColorAutoEnhanceChanged: post.setColorGradeAutoEnhance,
              onColorExposureChanged: post.setColorGradeExposure,
              onColorContrastChanged: post.setColorGradeContrast,
              onColorSaturationChanged: post.setColorGradeSaturation,
              onColorTemperatureChanged: post.setColorGradeTemperature,
              onColorTintChanged: post.setColorGradeTint,
              onColorChangeEnd: post.commitColorGrade,
              onAudioVolumeChanged: post.setAudioVolumePercent,
              onAudioVolumeChangeEnd: post.setAudioVolumePercentEnd,
              onCameraVisibleChanged: post.setCameraVisible,
              onCameraLayoutPresetChanged: post.setCameraLayoutPreset,
              onCameraSizeFactorChanged: post.setCameraSizeFactor,
              onCameraSizeFactorChangeEnd: post.setCameraSizeFactorEnd,
              onCameraShapeChanged: post.setCameraShape,
              onCameraCornerRadiusChanged: post.setCameraCornerRadius,
              onCameraCornerRadiusChangeEnd: post.setCameraCornerRadiusEnd,
              onCameraMirrorChanged: post.setCameraMirror,
              onCameraContentModeChanged: post.setCameraContentMode,
              onCameraZoomBehaviorChanged: post.setCameraZoomBehavior,
              onCameraZoomScaleMultiplierChanged:
                  post.setCameraZoomScaleMultiplier,
              onCameraZoomScaleMultiplierChangeEnd:
                  post.setCameraZoomScaleMultiplierEnd,
              onCameraIntroPresetChanged: post.setCameraIntroPreset,
              onCameraOutroPresetChanged: post.setCameraOutroPreset,
              onCameraZoomEmphasisPresetChanged:
                  post.setCameraZoomEmphasisPreset,
              onCameraIntroDurationChanged: post.setCameraIntroDurationMs,
              onCameraIntroDurationChangeEnd: post.setCameraIntroDurationMsEnd,
              onCameraOutroDurationChanged: post.setCameraOutroDurationMs,
              onCameraOutroDurationChangeEnd: post.setCameraOutroDurationMsEnd,
              onCameraZoomEmphasisStrengthChanged:
                  post.setCameraZoomEmphasisStrength,
              onCameraZoomEmphasisStrengthChangeEnd:
                  post.setCameraZoomEmphasisStrengthEnd,
              onCameraManualCenterChanged: post.setCameraManualCenterPreview,
              onCameraManualCenterChangeEnd:
                  post.setCameraManualCenterPreviewEnd,
              onCameraManualCenterSnapped: post.setCameraManualCenterSnap,
              onAutoNormalizeOnExportChanged:
                  settingsController.post.updatePostAutoNormalizeEnabled,
              onAutoNormalizeTargetDbfsChanged:
                  settingsController.post.updatePostTargetLoudnessDbfs,
              onPickImage: post.pickImage,
              presetThumbnailLoader: post.presetThumbnail,
              onLayoutPresetChanged: post.setLayoutPreset,
              onResolutionPresetChanged: post.setResolutionPreset,
              onFitModeChanged: post.setFitMode,
            );
          },
        );
      },
    );
  }

  /// Only the stages a transcription actually reports. Rendering/finalizing
  /// belong to export and never reach this bar, so they fall back to the
  /// neutral preparing text rather than showing an export word here.
  static String _captionsStageLabel(BuildContext context, ProgressStage stage) {
    final l10n = AppLocalizations.of(context)!;
    return switch (stage) {
      ProgressStage.transcribing => l10n.captionsTranscribing,
      _ => l10n.captionsPreparing,
    };
  }
}
