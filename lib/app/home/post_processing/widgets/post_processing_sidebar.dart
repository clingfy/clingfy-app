import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_pane_header.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_camera_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_captions_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_cursor_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_export_settings_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_layout_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_zoom_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_color_grade_section.dart';
import 'package:clingfy/core/captions/caption_reflow.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class PostProcessingSidebarRail extends StatelessWidget {
  const PostProcessingSidebarRail({
    super.key,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final metrics = context.shellMetricsOrNull;
    final sectionGap =
        metrics?.sidebarSectionGap ?? AppSidebarTokens.sectionGap;

    return Column(
      children: [
        SizedBox(height: sectionGap),
        _PostProcessingRailItem(
          icon: Icons.dashboard_customize,
          label: l10n.canvas,
          index: 0,
          isSelected: selectedIndex == 0,
          onTap: onSelectedIndexChanged,
        ),
        SizedBox(height: sectionGap),
        _PostProcessingRailItem(
          icon: Icons.face,
          label: l10n.camera,
          index: 1,
          isSelected: selectedIndex == 1,
          onTap: onSelectedIndexChanged,
        ),
        SizedBox(height: sectionGap),
        _PostProcessingRailItem(
          icon: Icons.auto_fix_high,
          label: l10n.effects,
          index: 2,
          isSelected: selectedIndex == 2,
          onTap: onSelectedIndexChanged,
        ),
        SizedBox(height: sectionGap),
        _PostProcessingRailItem(
          icon: Icons.graphic_eq,
          label: l10n.audio,
          index: 3,
          isSelected: selectedIndex == 3,
          onTap: onSelectedIndexChanged,
        ),
      ],
    );
  }
}

class _PostProcessingRailItem extends StatelessWidget {
  const _PostProcessingRailItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int index;
  final bool isSelected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final metrics = context.shellMetricsOrNull;
    final verticalPadding =
        metrics?.sidebarRailItemVerticalPadding ??
        AppSidebarTokens.railItemVerticalPadding;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: AppSidebarRailButton(
        buttonKey: ValueKey('post_sidebar_rail_tile_$index'),
        icon: icon,
        tooltip: label,
        semanticsLabel: label,
        selected: isSelected,
        onTap: () => onTap(index),
      ),
    );
  }
}

class PostProcessingSidebar extends StatelessWidget {
  final bool isProcessing;
  final int selectedIndex;
  final LayoutPreset layoutPreset;
  final ResolutionPreset resolutionPreset;
  final FitMode fitMode;
  final double padding;
  final double radius;
  final int? backgroundColor;
  final String? backgroundImagePath;
  final BackgroundKind backgroundKind;
  final CanvasBackgroundPreset? backgroundPreset;
  final bool showCursor;
  final double cursorSize;
  final double zoomFactor;
  final bool zoomEffectEnabled;
  final bool enabled;
  final bool cursorAvailable;
  final bool hasAudio;

  /// Audio separation (Windows D10): whether gain/normalize will have an
  /// audible effect (mic-dependent on separated recordings). Null falls
  /// back to [hasAudio] in the sections.
  final bool? gainAvailable;
  final bool hasCameraAsset;
  final CameraExportCapabilities cameraExportCapabilities;
  final CameraCompositionState? cameraState;
  final String? disabledMessage;
  final bool showHeader;
  final double availableWidth;
  final bool isCompact;
  final bool showResolutionControl;
  final double audioGainDb;
  final VoiceCleanup voiceCleanup;
  final CaptionsCapabilityInfo? captionsCapability;
  final List<Caption> captions;
  final bool captionsUseMic;
  final bool captionsUseSystem;
  final bool isGeneratingCaptions;
  final bool isCancellingCaptions;

  /// A transcription this panel is not presenting is still unwinding, so
  /// Generate cannot start one. See [PostCaptionsSection.engineBusyOffScreen].
  final bool isCaptionsEngineBusyOffScreen;
  final double? captionsProgress;
  final String? captionsStageLabel;
  final bool hasEverGeneratedCaptions;
  final bool captionsFailed;
  final SubtitleMode subtitleMode;
  final ReflowedCaptions reflowedCaptions;
  final double audioVolume;
  final bool autoNormalizeOnExport;
  final double autoNormalizeTargetDbfs;

  final Function(LayoutPreset) onLayoutPresetChanged;
  final Function(ResolutionPreset) onResolutionPresetChanged;
  final Function(FitMode) onFitModeChanged;
  final Function(double) onPaddingChanged;
  final Function(double) onPaddingChangeEnd;
  final Function(double) onRadiusChanged;
  final Function(double) onRadiusChangeEnd;
  final Function(int?) onBackgroundColorChanged;
  final Function(String?) onBackgroundImageChanged;
  final Function(BackgroundKind) onBackgroundKindChanged;
  final Function(CanvasBackgroundPreset) onBackgroundPresetChanged;
  final Function(CanvasBackgroundPreset) onBackgroundPresetPreview;
  final Function(bool) onCursorShowChanged;
  final Function(double) onCursorSizeChanged;
  final Function(double) onCursorSizeChangeEnd;
  final Function(double) onZoomFactorChanged;
  final Function(double) onZoomFactorChangeEnd;
  final ValueChanged<bool> onZoomEffectEnabledChanged;
  final Future<String?> Function() onPickImage;

  /// Supplies rendered preset art for the background picker cards. Null keeps
  /// the palette-gradient placeholders.
  final PresetThumbnailLoader? presetThumbnailLoader;
  final Function(bool) onCameraVisibleChanged;
  final Function(CameraLayoutPreset) onCameraLayoutPresetChanged;
  final Function(double) onCameraSizeFactorChanged;
  final Function(double) onCameraSizeFactorChangeEnd;
  final Function(CameraShape) onCameraShapeChanged;
  final Function(double) onCameraCornerRadiusChanged;
  final Function(double) onCameraCornerRadiusChangeEnd;
  final Function(bool) onCameraMirrorChanged;
  final Function(CameraContentMode) onCameraContentModeChanged;
  final Function(CameraZoomBehavior) onCameraZoomBehaviorChanged;
  final Function(double) onCameraZoomScaleMultiplierChanged;
  final Function(double) onCameraZoomScaleMultiplierChangeEnd;
  final Function(CameraIntroPreset) onCameraIntroPresetChanged;
  final Function(CameraOutroPreset) onCameraOutroPresetChanged;
  final Function(CameraZoomEmphasisPreset) onCameraZoomEmphasisPresetChanged;
  final Function(double) onCameraIntroDurationChanged;
  final Function(double) onCameraIntroDurationChangeEnd;
  final Function(double) onCameraOutroDurationChanged;
  final Function(double) onCameraOutroDurationChangeEnd;
  final Function(double) onCameraZoomEmphasisStrengthChanged;
  final Function(double) onCameraZoomEmphasisStrengthChangeEnd;
  final ValueChanged<Offset> onCameraManualCenterChanged;
  final ValueChanged<Offset> onCameraManualCenterChangeEnd;
  final ValueChanged<Offset> onCameraManualCenterSnapped;
  final Function(double) onAudioGainChanged;
  final Function(double) onAudioGainChangeEnd;
  final ValueChanged<VoiceCleanup> onVoiceCleanupChanged;
  final ValueChanged<bool> onCaptionsUseMicChanged;
  final ValueChanged<bool> onCaptionsUseSystemChanged;
  final VoidCallback onGenerateCaptions;
  final VoidCallback onCancelCaptions;
  final void Function(String cueId, String text) onCaptionTextChanged;
  final ValueChanged<SubtitleMode> onSubtitleModeChanged;
  final ColorGrade colorGrade;
  final ValueChanged<bool> onColorAutoEnhanceChanged;
  final ValueChanged<double> onColorExposureChanged;
  final ValueChanged<double> onColorContrastChanged;
  final ValueChanged<double> onColorSaturationChanged;
  final ValueChanged<double> onColorTemperatureChanged;
  final ValueChanged<double> onColorTintChanged;
  final VoidCallback onColorChangeEnd;
  final Function(double) onAudioVolumeChanged;
  final Function(double) onAudioVolumeChangeEnd;
  final Function(bool) onAutoNormalizeOnExportChanged;
  final Function(double) onAutoNormalizeTargetDbfsChanged;

  const PostProcessingSidebar({
    super.key,
    required this.selectedIndex,
    required this.isProcessing,
    this.availableWidth = double.infinity,
    this.isCompact = false,
    required this.layoutPreset,
    required this.resolutionPreset,
    required this.fitMode,
    required this.padding,
    required this.radius,
    required this.backgroundColor,
    required this.backgroundImagePath,
    required this.backgroundKind,
    required this.backgroundPreset,
    required this.showCursor,
    required this.cursorSize,
    required this.zoomFactor,
    required this.zoomEffectEnabled,
    required this.onLayoutPresetChanged,
    required this.onResolutionPresetChanged,
    required this.onFitModeChanged,
    required this.onPaddingChanged,
    required this.onPaddingChangeEnd,
    required this.onRadiusChanged,
    required this.onRadiusChangeEnd,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onBackgroundKindChanged,
    required this.onBackgroundPresetChanged,
    required this.onBackgroundPresetPreview,
    required this.onCursorShowChanged,
    required this.onCursorSizeChanged,
    required this.onCursorSizeChangeEnd,
    required this.onZoomFactorChanged,
    required this.onZoomFactorChangeEnd,
    required this.onZoomEffectEnabledChanged,
    required this.colorGrade,
    required this.onColorAutoEnhanceChanged,
    required this.onColorExposureChanged,
    required this.onColorContrastChanged,
    required this.onColorSaturationChanged,
    required this.onColorTemperatureChanged,
    required this.onColorTintChanged,
    required this.onColorChangeEnd,
    required this.onPickImage,
    this.presetThumbnailLoader,
    required this.hasCameraAsset,
    required this.cameraExportCapabilities,
    required this.cameraState,
    required this.onCameraVisibleChanged,
    required this.onCameraLayoutPresetChanged,
    required this.onCameraSizeFactorChanged,
    required this.onCameraSizeFactorChangeEnd,
    required this.onCameraShapeChanged,
    required this.onCameraCornerRadiusChanged,
    required this.onCameraCornerRadiusChangeEnd,
    required this.onCameraMirrorChanged,
    required this.onCameraContentModeChanged,
    required this.onCameraZoomBehaviorChanged,
    required this.onCameraZoomScaleMultiplierChanged,
    required this.onCameraZoomScaleMultiplierChangeEnd,
    required this.onCameraIntroPresetChanged,
    required this.onCameraOutroPresetChanged,
    required this.onCameraZoomEmphasisPresetChanged,
    required this.onCameraIntroDurationChanged,
    required this.onCameraIntroDurationChangeEnd,
    required this.onCameraOutroDurationChanged,
    required this.onCameraOutroDurationChangeEnd,
    required this.onCameraZoomEmphasisStrengthChanged,
    required this.onCameraZoomEmphasisStrengthChangeEnd,
    required this.onCameraManualCenterChanged,
    required this.onCameraManualCenterChangeEnd,
    required this.onCameraManualCenterSnapped,
    required this.audioGainDb,
    required this.voiceCleanup,
    required this.captionsCapability,
    required this.captions,
    required this.captionsUseMic,
    required this.captionsUseSystem,
    required this.isGeneratingCaptions,
    required this.isCancellingCaptions,
    required this.isCaptionsEngineBusyOffScreen,
    required this.captionsProgress,
    required this.captionsStageLabel,
    required this.hasEverGeneratedCaptions,
    required this.captionsFailed,
    required this.subtitleMode,
    required this.reflowedCaptions,
    required this.audioVolume,
    required this.autoNormalizeOnExport,
    required this.autoNormalizeTargetDbfs,
    required this.onAudioGainChanged,
    required this.onAudioGainChangeEnd,
    required this.onVoiceCleanupChanged,
    required this.onCaptionsUseMicChanged,
    required this.onCaptionsUseSystemChanged,
    required this.onGenerateCaptions,
    required this.onCancelCaptions,
    required this.onCaptionTextChanged,
    required this.onSubtitleModeChanged,
    required this.onAudioVolumeChanged,
    required this.onAudioVolumeChangeEnd,
    required this.onAutoNormalizeOnExportChanged,
    required this.onAutoNormalizeTargetDbfsChanged,
    required this.showResolutionControl,
    this.enabled = true,
    this.cursorAvailable = true,
    this.hasAudio = true,
    this.gainAvailable,
    this.disabledMessage,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = context.shellMetricsOrNull;
    final compactWidthThreshold = metrics?.sidebarCompactWidthBreakpoint ?? 320;
    final useCompactSpacing =
        isCompact || availableWidth <= compactWidthThreshold;
    final horizontalPadding = useCompactSpacing
        ? metrics?.sidebarContentHorizontalPaddingCompact ?? 10.0
        : metrics?.sidebarContentHorizontalPadding ??
              AppSidebarTokens.contentHorizontalPadding;
    final topSpacer =
        metrics?.sidebarHeaderContentGap ?? AppSidebarTokens.headerContentGap;
    final bottomSpacer =
        (metrics?.sidebarSectionGap ?? AppSidebarTokens.sectionGap) +
        (metrics?.sidebarCompactGap ?? AppSidebarTokens.compactGap);

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              AppPaneHeader(
                headerKey: const Key('post_sidebar_header'),
                title: _headerTitle(context),
                isCompact: useCompactSpacing,
              ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                children: [
                  SizedBox(
                    key: const Key('post_sidebar_top_spacer'),
                    height: topSpacer,
                  ),
                  if (selectedIndex == 0) ..._buildCanvasTab(context),
                  if (selectedIndex == 1) ..._buildCameraTab(context),
                  if (selectedIndex == 2) ..._buildEffectsTab(context),
                  if (selectedIndex == 3) ..._buildExportTab(context),
                  SizedBox(height: bottomSpacer),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _headerTitle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (selectedIndex) {
      case 0:
        return l10n.canvasSettings;
      case 1:
        return l10n.cameraSettings;
      case 2:
        return l10n.effectsSettings;
      case 3:
        return l10n.audioSettings;
      default:
        return '';
    }
  }

  List<Widget> _buildCanvasTab(BuildContext context) {
    return [
      PostLayoutSection(
        isProcessing: isProcessing,
        layoutPreset: layoutPreset,
        resolutionPreset: resolutionPreset,
        fitMode: fitMode,
        padding: padding,
        radius: radius,
        showResolutionControl: showResolutionControl,
        onLayoutPresetChanged: onLayoutPresetChanged,
        onResolutionPresetChanged: onResolutionPresetChanged,
        onFitModeChanged: onFitModeChanged,
        onPaddingChanged: onPaddingChanged,
        onPaddingChangeEnd: onPaddingChangeEnd,
        onRadiusChanged: onRadiusChanged,
        onRadiusChangeEnd: onRadiusChangeEnd,
      ),
      PostBackgroundSection(
        isProcessing: isProcessing,
        backgroundColor: backgroundColor,
        backgroundImagePath: backgroundImagePath,
        backgroundKind: backgroundKind,
        backgroundPreset: backgroundPreset,
        onBackgroundColorChanged: onBackgroundColorChanged,
        onBackgroundImageChanged: onBackgroundImageChanged,
        onBackgroundKindChanged: onBackgroundKindChanged,
        onBackgroundPresetChanged: onBackgroundPresetChanged,
        onBackgroundPresetPreview: onBackgroundPresetPreview,
        onPickImage: onPickImage,
        presetThumbnailLoader: presetThumbnailLoader,
      ),
    ];
  }

  List<Widget> _buildCameraTab(BuildContext context) {
    return [
      PostCameraSection(
        hasCameraAsset: hasCameraAsset,
        cameraExportCapabilities: cameraExportCapabilities,
        cameraState: cameraState,
        onVisibleChanged: onCameraVisibleChanged,
        onLayoutPresetChanged: onCameraLayoutPresetChanged,
        onSizeFactorChanged: onCameraSizeFactorChanged,
        onSizeFactorChangeEnd: onCameraSizeFactorChangeEnd,
        onShapeChanged: onCameraShapeChanged,
        onCornerRadiusChanged: onCameraCornerRadiusChanged,
        onCornerRadiusChangeEnd: onCameraCornerRadiusChangeEnd,
        onMirrorChanged: onCameraMirrorChanged,
        onContentModeChanged: onCameraContentModeChanged,
        onZoomBehaviorChanged: onCameraZoomBehaviorChanged,
        onZoomScaleMultiplierChanged: onCameraZoomScaleMultiplierChanged,
        onZoomScaleMultiplierChangeEnd: onCameraZoomScaleMultiplierChangeEnd,
        onIntroPresetChanged: onCameraIntroPresetChanged,
        onOutroPresetChanged: onCameraOutroPresetChanged,
        onZoomEmphasisPresetChanged: onCameraZoomEmphasisPresetChanged,
        onIntroDurationChanged: onCameraIntroDurationChanged,
        onIntroDurationChangeEnd: onCameraIntroDurationChangeEnd,
        onOutroDurationChanged: onCameraOutroDurationChanged,
        onOutroDurationChangeEnd: onCameraOutroDurationChangeEnd,
        onZoomEmphasisStrengthChanged: onCameraZoomEmphasisStrengthChanged,
        onZoomEmphasisStrengthChangeEnd: onCameraZoomEmphasisStrengthChangeEnd,
        onManualCenterChanged: onCameraManualCenterChanged,
        onManualCenterChangeEnd: onCameraManualCenterChangeEnd,
        onManualCenterSnapped: onCameraManualCenterSnapped,
      ),
    ];
  }

  List<Widget> _buildEffectsTab(BuildContext context) {
    return [
      PostCursorSection(
        cursorAvailable: cursorAvailable,
        showCursor: showCursor,
        cursorSize: cursorSize,
        onCursorShowChanged: onCursorShowChanged,
        onCursorSizeChanged: onCursorSizeChanged,
        onCursorSizeChangeEnd: onCursorSizeChangeEnd,
      ),
      PostZoomSection(
        isProcessing: isProcessing,
        zoomEffectEnabled: zoomEffectEnabled,
        zoomFactor: zoomFactor,
        onZoomEffectEnabledChanged: onZoomEffectEnabledChanged,
        onZoomFactorChanged: onZoomFactorChanged,
        onZoomFactorChangeEnd: onZoomFactorChangeEnd,
      ),
      PostColorGradeSection(
        colorGrade: colorGrade,
        onAutoEnhanceChanged: onColorAutoEnhanceChanged,
        onExposureChanged: onColorExposureChanged,
        onContrastChanged: onColorContrastChanged,
        onSaturationChanged: onColorSaturationChanged,
        onTemperatureChanged: onColorTemperatureChanged,
        onTintChanged: onColorTintChanged,
        onChangeEnd: onColorChangeEnd,
      ),
    ];
  }

  List<Widget> _buildExportTab(BuildContext context) {
    return [
      PostAudioSection(
        hasAudio: hasAudio,
        gainAvailable: gainAvailable,
        audioVolume: audioVolume,
        audioGainDb: audioGainDb,
        voiceCleanup: voiceCleanup,
        onAudioVolumeChanged: onAudioVolumeChanged,
        onAudioVolumeChangeEnd: onAudioVolumeChangeEnd,
        onAudioGainChanged: onAudioGainChanged,
        onAudioGainChangeEnd: onAudioGainChangeEnd,
        onVoiceCleanupChanged: onVoiceCleanupChanged,
      ),
      // Sits with audio because that is what it transcribes, and above export
      // settings because burn-in is an export decision made after the cues
      // exist.
      PostCaptionsSection(
        capability: captionsCapability,
        captions: captions,
        useMic: captionsUseMic,
        useSystem: captionsUseSystem,
        isGenerating: isGeneratingCaptions,
        isCancelling: isCancellingCaptions,
        engineBusyOffScreen: isCaptionsEngineBusyOffScreen,
        progress: captionsProgress,
        stageLabel: captionsStageLabel,
        isProcessing: isProcessing,
        hasEverGenerated: hasEverGeneratedCaptions,
        failed: captionsFailed,
        onUseMicChanged: onCaptionsUseMicChanged,
        onUseSystemChanged: onCaptionsUseSystemChanged,
        onGenerate: onGenerateCaptions,
        onCancel: onCancelCaptions,
        onCueTextChanged: onCaptionTextChanged,
        subtitleMode: subtitleMode,
        reflowed: reflowedCaptions,
        onSubtitleModeChanged: onSubtitleModeChanged,
      ),
      PostExportSettingsSection(
        isProcessing: isProcessing,
        hasAudio: hasAudio,
        gainAvailable: gainAvailable,
        autoNormalizeOnExport: autoNormalizeOnExport,
        autoNormalizeTargetDbfs: autoNormalizeTargetDbfs,
        onAutoNormalizeOnExportChanged: onAutoNormalizeOnExportChanged,
        onAutoNormalizeTargetDbfsChanged: onAutoNormalizeTargetDbfsChanged,
      ),
    ];
  }
}
