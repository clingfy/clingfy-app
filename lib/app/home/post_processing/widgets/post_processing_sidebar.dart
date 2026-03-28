import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
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
  final String? disabledMessage;
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
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final useCompactSpacing = isCompact || availableWidth <= 320;
    final horizontalPadding = useCompactSpacing
        ? 10.0
        : AppSidebarTokens.contentHorizontalPadding;
    final headerTopPadding = useCompactSpacing
        ? 10.0
        : AppSidebarTokens.headerTopPadding;
    final headerBottomPadding = useCompactSpacing
        ? 8.0
        : AppSidebarTokens.headerBottomPadding;
    final headerStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        );

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('post_sidebar_header'),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                headerTopPadding,
                horizontalPadding,
                headerBottomPadding,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Text(_headerTitle(context), style: headerStyle),
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
