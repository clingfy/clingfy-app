import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
        bool showCursor,
        bool cursorAvailable,
        double cursorSize,
        double zoom,
        double gain,
        double volume,
        bool hasCameraAsset,
        CameraCompositionState? cameraState,
        CameraExportCapabilities cameraExportCapabilities,
      })
    >(
      selector: (_, p) => (
        isEditingLocked: p.isEditingLocked,
        padding: p.padding,
        radius: p.radius,
        bg: p.backgroundColor,
        img: p.backgroundImagePath,
        showCursor: p.showCursor,
        cursorAvailable: p.cursorAvailable,
        cursorSize: p.cursorSize,
        zoom: p.zoomFactor,
        gain: p.audioGainDb,
        volume: p.audioVolumePercent,
        hasCameraAsset: p.hasCameraAsset,
        cameraState: p.cameraState,
        cameraExportCapabilities: p.cameraExportCapabilities,
      ),
      builder: (context, vm, _) {
        final post = context.read<PostProcessingController>();
        final hasAudio = context.select<DeviceController, bool>(
          (d) => d.selectedAudioSourceId != DeviceController.noAudioId,
        );

        return ListenableBuilder(
          listenable: settingsController.post,
          builder: (context, _) {
            return PostProcessingSidebar(
              selectedIndex: selectedIndex,
              availableWidth: availableWidth,
              isCompact: isCompact,
              showHeader: showHeader,
              enabled: canEditPost,
              isProcessing: vm.isEditingLocked,
              cursorAvailable: vm.cursorAvailable,
              hasAudio: hasAudio,
              layoutPreset: settingsController.post.layoutPreset,
              resolutionPreset: settingsController.post.resolutionPreset,
              fitMode: settingsController.post.fitMode,
              padding: vm.padding,
              radius: vm.radius,
              backgroundColor: vm.bg,
              backgroundImagePath: vm.img,
              showCursor: vm.showCursor,
              cursorSize: vm.cursorSize,
              zoomFactor: vm.zoom,
              hasCameraAsset: vm.hasCameraAsset,
              cameraState: vm.cameraState,
              cameraExportCapabilities: vm.cameraExportCapabilities,
              audioGainDb: vm.gain,
              audioVolume: vm.volume,
              autoNormalizeOnExport:
                  settingsController.post.postAutoNormalizeEnabled,
              autoNormalizeTargetDbfs:
                  settingsController.post.postTargetLoudnessDbfs,
              onPaddingChanged: post.setPadding,
              onPaddingChangeEnd: (_) => post.applyProcessing(),
              onRadiusChanged: post.setRadius,
              onRadiusChangeEnd: (_) => post.applyProcessing(),
              onBackgroundColorChanged: post.setBackgroundColor,
              onBackgroundImageChanged: post.setBackgroundImagePath,
              onCursorShowChanged: post.setShowCursor,
              onCursorSizeChanged: post.setCursorSize,
              onCursorSizeChangeEnd: (_) => post.applyProcessing(),
              onZoomFactorChanged: post.setZoomFactor,
              onZoomFactorChangeEnd: (_) => post.applyProcessing(),
              onAudioGainChanged: post.setAudioGainDb,
              onAudioGainChangeEnd: post.setAudioGainDbEnd,
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
              onAutoNormalizeOnExportChanged:
                  settingsController.post.updatePostAutoNormalizeEnabled,
              onAutoNormalizeTargetDbfsChanged:
                  settingsController.post.updatePostTargetLoudnessDbfs,
              onPickImage: post.pickImage,
              onLayoutPresetChanged: post.setLayoutPreset,
              onResolutionPresetChanged: post.setResolutionPreset,
              onFitModeChanged: post.setFitMode,
            );
          },
        );
      },
    );
  }
}
