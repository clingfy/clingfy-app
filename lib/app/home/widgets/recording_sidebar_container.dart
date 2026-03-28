import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RecordingSidebarContainer extends StatelessWidget {
  const RecordingSidebarContainer({
    super.key,
    required this.isRecording,
    required this.uiState,
    required this.actions,
    required this.settingsController,
    required this.selectedIndex,
    required this.availableWidth,
    required this.isCompact,
    this.showHeader = true,
  });

  final bool isRecording;
  final HomeUiState uiState;
  final HomeActions actions;
  final SettingsController settingsController;
  final int selectedIndex;
  final double availableWidth;
  final bool isCompact;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    return Consumer2<DeviceController, OverlayController>(
      builder: (context, device, overlay, _) {
        return RecordingOptionsSidebar(
          isRecording: isRecording,
          selectedIndex: selectedIndex,
          availableWidth: availableWidth,
          isCompact: isCompact,
          showHeader: showHeader,
          targetMode: uiState.targetMode,
          displays: device.displays,
          selectedDisplayId: device.selectedDisplayId,
          appWindows: device.appWindows,
          selectedAppWindowId: device.selectedAppWindowId,
          loadingAppWindows: device.loadingAppWindows,
          audioSources: device.audioSources,
          selectedAudioSourceId: device.selectedAudioSourceId,
          loadingAudio: device.loadingAudio,
          micInputLevelLinear: device.micInputLevelLinear,
          micInputLevelDbfs: device.micInputLevelDbfs,
          micInputTooLow: device.micInputTooLow,
          cams: device.cams,
          selectedCamId: device.selectedCamId,
          loadingCams: device.loadingCams,
          areaDisplayId: overlay.areaDisplayId,
          areaRect: overlay.areaRect,
          onPickArea: overlay.pickAreaRecordingRegion,
          onRevealArea: overlay.revealAreaRecordingRegion,
          onClearArea: overlay.clearAreaRecordingSelection,
          onTargetModeChanged: actions.setDisplayTargetMode,
          onDisplayChanged: device.setDisplay,
          onRefreshDisplays: device.reloadDisplays,
          onAppWindowChanged: device.setAppWindow,
          onRefreshAppWindows: device.reloadAppWindows,
          onAudioSourceChanged: device.setAudioSource,
          onRefreshAudio: device.reloadAudioSources,
          systemAudioEnabled: settingsController.recording.systemAudioEnabled,
          onSystemAudioEnabledChanged:
              settingsController.recording.updateSystemAudioEnabled,
          excludeMicFromSystemAudio:
              settingsController.recording.excludeMicFromSystemAudio,
          onExcludeMicFromSystemAudioChanged:
              settingsController.recording.updateExcludeMicFromSystemAudio,
          onCamSourceChanged: device.setCamSource,
          onRefreshCams: device.reloadCameras,
          captureFrameRate: settingsController.recording.captureFrameRate,
          onFrameRateChanged:
              settingsController.recording.updateCaptureFrameRate,
          autoStopEnabled: settingsController.recording.autoStopEnabled,
          autoStopAfter: settingsController.recording.autoStopAfter,
          onAutoStopEnabledChanged:
              settingsController.recording.updateAutoStopEnabled,
          onAutoStopAfterChanged:
              settingsController.recording.updateAutoStopAfter,
          countdownEnabled: settingsController.recording.countdownEnabled,
          countdownDuration: settingsController.recording.countdownDuration,
          onCountdownEnabledChanged:
              settingsController.recording.updateCountdownEnabled,
          onCountdownDurationChanged:
              settingsController.recording.updateCountdownDuration,
          excludeRecorderAppFromCapture:
              settingsController.recording.excludeRecorderAppFromCapture,
          onExcludeRecorderAppFromCaptureChanged:
              settingsController.recording.updateExcludeRecorderAppFromCapture,
          overlayMode: overlay.overlayMode,
          overlayShape: overlay.overlayShape,
          overlaySize: overlay.overlaySize,
          overlayShadow: overlay.overlayShadow,
          overlayBorder: overlay.overlayBorder,
          overlayPosition: overlay.overlayPosition,
          overlayUseCustomPosition: overlay.overlayUseCustomPosition,
          overlayRoundness: overlay.overlayRoundness,
          onOverlayRoundnessChanged: overlay.setOverlayRoundness,
          overlayOpacity: overlay.overlayOpacity,
          onOverlayOpacityChanged: overlay.setOverlayOpacity,
          overlayMirror: overlay.overlayMirror,
          onOverlayMirrorChanged: overlay.setOverlayMirror,
          overlayRecordingHighlightEnabled:
              overlay.overlayRecordingHighlightEnabled,
          overlayRecordingHighlightStrength:
              overlay.overlayRecordingHighlightStrength,
          onOverlayRecordingHighlightEnabledChanged:
              overlay.setOverlayRecordingHighlightEnabled,
          onOverlayRecordingHighlightStrengthChanged:
              overlay.setOverlayRecordingHighlightStrength,
          overlayBorderWidth: overlay.overlayBorderWidth,
          overlayBorderColor: overlay.overlayBorderColor,
          onOverlayBorderWidthChanged: overlay.setOverlayBorderWidth,
          onOverlayBorderColorChanged: overlay.setOverlayBorderColor,
          chromaKeyEnabled: overlay.chromaKeyEnabled,
          chromaKeyStrength: overlay.chromaKeyStrength,
          chromaKeyColor: overlay.chromaKeyColor,
          onChromaKeyEnabledChanged: overlay.setChromaKeyEnabled,
          onChromaKeyStrengthChanged: overlay.setChromaKeyStrength,
          onChromaKeyColorChanged: overlay.setChromaKeyColor,
          indicatorPinned: uiState.indicatorPinned,
          onIndicatorPinnedChanged: actions.setIndicatorPinned,
          cursorEnabled: overlay.cursorEnabled,
          onCursorModeChanged: (OverlayMode mode) =>
              overlay.setCursorMode(context, mode),
          cursorLinkedToRecording: overlay.cursorLinkedToRecording,
          onOverlayModeChanged: overlay.setOverlayMode,
          onOverlayShapeChanged: overlay.setOverlayShape,
          onOverlaySizeChanged: overlay.setOverlaySize,
          onOverlayShadowChanged: overlay.setOverlayShadow,
          onOverlayBorderChanged: overlay.setOverlayBorder,
          onOverlayPositionChanged: overlay.setOverlayPosition,
        );
      },
    );
  }
}
