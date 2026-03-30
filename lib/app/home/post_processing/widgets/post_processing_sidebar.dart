import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_pane_header.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_camera_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_cursor_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_export_settings_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_layout_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_zoom_section.dart';
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
    return Column(
      children: [
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _PostProcessingRailItem(
          icon: Icons.dashboard_customize,
          label: AppLocalizations.of(context)!.layout,
          index: 0,
          isSelected: selectedIndex == 0,
          onTap: onSelectedIndexChanged,
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _PostProcessingRailItem(
          icon: Icons.auto_fix_high,
          label: AppLocalizations.of(context)!.effects,
          index: 1,
          isSelected: selectedIndex == 1,
          onTap: onSelectedIndexChanged,
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _PostProcessingRailItem(
          icon: Icons.ios_share,
          label: AppLocalizations.of(context)!.export,
          index: 2,
          isSelected: selectedIndex == 2,
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
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSidebarTokens.railItemVerticalPadding,
      ),
      child: AppSidebarRailButton(
        buttonKey: ValueKey('post_sidebar_rail_tile_$index'),
        icon: icon,
        tooltip: label,
        semanticsLabel: label,
        selected: isSelected,
        onTap: () => onTap(index),
        iconSize: 28,
        buttonSize: 40,
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
  final bool showCursor;
  final double cursorSize;
  final double zoomFactor;
  final bool enabled;
  final bool cursorAvailable;
  final bool hasAudio;
  final bool hasCameraAsset;
  final CameraExportCapabilities cameraExportCapabilities;
  final CameraCompositionState? cameraState;
  final String? disabledMessage;
  final bool showHeader;
  final double availableWidth;
  final bool isCompact;
  final double audioGainDb;
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
  final Function(bool) onCursorShowChanged;
  final Function(double) onCursorSizeChanged;
  final Function(double) onCursorSizeChangeEnd;
  final Function(double) onZoomFactorChanged;
  final Function(double) onZoomFactorChangeEnd;
  final Future<String?> Function() onPickImage;
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
  final Function(double) onAudioGainChanged;
  final Function(double) onAudioGainChangeEnd;
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
    required this.showCursor,
    required this.cursorSize,
    required this.zoomFactor,
    required this.onLayoutPresetChanged,
    required this.onResolutionPresetChanged,
    required this.onFitModeChanged,
    required this.onPaddingChanged,
    required this.onPaddingChangeEnd,
    required this.onRadiusChanged,
    required this.onRadiusChangeEnd,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onCursorShowChanged,
    required this.onCursorSizeChanged,
    required this.onCursorSizeChangeEnd,
    required this.onZoomFactorChanged,
    required this.onZoomFactorChangeEnd,
    required this.onPickImage,
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
    required this.audioGainDb,
    required this.audioVolume,
    required this.autoNormalizeOnExport,
    required this.autoNormalizeTargetDbfs,
    required this.onAudioGainChanged,
    required this.onAudioGainChangeEnd,
    required this.onAudioVolumeChanged,
    required this.onAudioVolumeChangeEnd,
    required this.onAutoNormalizeOnExportChanged,
    required this.onAutoNormalizeTargetDbfsChanged,
    this.enabled = true,
    this.cursorAvailable = true,
    this.hasAudio = true,
    this.disabledMessage,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    final useCompactSpacing = isCompact || availableWidth <= 320;
    final horizontalPadding = useCompactSpacing
        ? 10.0
        : AppSidebarTokens.contentHorizontalPadding;

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
                  const SizedBox(
                    key: Key('post_sidebar_top_spacer'),
                    height: AppSidebarTokens.headerContentGap,
                  ),
                  if (selectedIndex == 0) ..._buildLayoutTab(context),
                  if (selectedIndex == 1) ..._buildEffectsTab(context),
                  if (selectedIndex == 2) ..._buildExportTab(context),
                  const SizedBox(
                    height:
                        AppSidebarTokens.sectionGap +
                        AppSidebarTokens.compactGap,
                  ),
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
        return l10n.layoutSettings;
      case 1:
        return l10n.effectsSettings;
      case 2:
        return l10n.exportSettings;
      default:
        return '';
    }
  }

  List<Widget> _buildLayoutTab(BuildContext context) {
    final theme = Theme.of(context);

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
      ),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      PostLayoutSection(
        isProcessing: isProcessing,
        layoutPreset: layoutPreset,
        resolutionPreset: resolutionPreset,
        fitMode: fitMode,
        padding: padding,
        radius: radius,
        onLayoutPresetChanged: onLayoutPresetChanged,
        onResolutionPresetChanged: onResolutionPresetChanged,
        onFitModeChanged: onFitModeChanged,
        onPaddingChanged: onPaddingChanged,
        onPaddingChangeEnd: onPaddingChangeEnd,
        onRadiusChanged: onRadiusChanged,
        onRadiusChangeEnd: onRadiusChangeEnd,
      ),
      const SizedBox(
        key: Key('post_layout_background_gap_before_divider'),
        height: AppSidebarTokens.optionsGroupGap,
      ),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(
        key: Key('post_layout_background_gap_after_divider'),
        height: AppSidebarTokens.optionsGroupGap,
      ),
      PostBackgroundSection(
        isProcessing: isProcessing,
        backgroundColor: backgroundColor,
        backgroundImagePath: backgroundImagePath,
        onBackgroundColorChanged: onBackgroundColorChanged,
        onBackgroundImageChanged: onBackgroundImageChanged,
        onPickImage: onPickImage,
      ),
    ];
  }

  List<Widget> _buildEffectsTab(BuildContext context) {
    final theme = Theme.of(context);

    return [
      PostCursorSection(
        cursorAvailable: cursorAvailable,
        showCursor: showCursor,
        cursorSize: cursorSize,
        onCursorShowChanged: onCursorShowChanged,
        onCursorSizeChanged: onCursorSizeChanged,
        onCursorSizeChangeEnd: onCursorSizeChangeEnd,
      ),
      const SizedBox(
        key: Key('post_effects_cursor_zoom_gap'),
        height: AppSidebarTokens.optionsGroupGap,
      ),
      PostZoomSection(
        isProcessing: isProcessing,
        zoomFactor: zoomFactor,
        onZoomFactorChanged: onZoomFactorChanged,
        onZoomFactorChangeEnd: onZoomFactorChangeEnd,
      ),
      const SizedBox(
        key: Key('post_effects_audio_gap_before_divider'),
        height: AppSidebarTokens.optionsSubgroupGap,
      ),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(
        key: Key('post_effects_audio_gap_after_divider'),
        height: AppSidebarTokens.optionsGroupGap,
      ),
      PostAudioSection(
        hasAudio: hasAudio,
        audioVolume: audioVolume,
        audioGainDb: audioGainDb,
        onAudioVolumeChanged: onAudioVolumeChanged,
        onAudioVolumeChangeEnd: onAudioVolumeChangeEnd,
        onAudioGainChanged: onAudioGainChanged,
        onAudioGainChangeEnd: onAudioGainChangeEnd,
      ),
    ];
  }

  List<Widget> _buildExportTab(BuildContext context) {
    return [
      PostExportSettingsSection(
        isProcessing: isProcessing,
        autoNormalizeOnExport: autoNormalizeOnExport,
        autoNormalizeTargetDbfs: autoNormalizeTargetDbfs,
        onAutoNormalizeOnExportChanged: onAutoNormalizeOnExportChanged,
        onAutoNormalizeTargetDbfsChanged: onAutoNormalizeTargetDbfsChanged,
      ),
    ];
  }
}
