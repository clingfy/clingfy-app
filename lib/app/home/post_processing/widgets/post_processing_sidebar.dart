import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_cursor_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_export_settings_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_layout_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_zoom_section.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class PostProcessingSidebar extends StatefulWidget {
  final bool isProcessing;
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
    required this.isProcessing,
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
  State<PostProcessingSidebar> createState() => _PostProcessingSidebarState();
}

class _PostProcessingSidebarState extends State<PostProcessingSidebar> {
  int _selectedIndex = 0; // 0: Layout, 1: Effects, 2: Export

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final colorScheme = theme.colorScheme;
    final controlFill =
        theme.inputDecorationTheme.fillColor ?? colorScheme.secondaryContainer;
    final railColor = Color.alphaBlend(
      controlFill.withValues(alpha: 0.18),
      colorScheme.surface,
    );
    final accentColor = colorScheme.primary;
    final headerStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        );

    return Row(
      children: [
        Container(
          key: const Key('post_sidebar_rail'),
          width: chrome.editorRailWidth,
          color: railColor,
          child: Column(
            children: [
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.dashboard_customize,
                label: AppLocalizations.of(context)!.layout,
                index: 0,
                isSelected: _selectedIndex == 0,
                accentColor: accentColor,
              ),
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.auto_fix_high,
                label: AppLocalizations.of(context)!.effects,
                index: 1,
                isSelected: _selectedIndex == 1,
                accentColor: accentColor,
              ),
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.ios_share,
                label: AppLocalizations.of(context)!.export,
                index: 2,
                isSelected: _selectedIndex == 2,
                accentColor: accentColor,
              ),
            ],
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          indent: AppSidebarTokens.headerTopPadding,
          endIndent: AppSidebarTokens.headerTopPadding,
          color: theme.dividerColor.withValues(alpha: 0.14),
        ),
        Expanded(
          child: Opacity(
            opacity: widget.enabled ? 1.0 : 0.45,
            child: IgnorePointer(
              ignoring: !widget.enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    key: const Key('post_sidebar_header'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSidebarTokens.contentHorizontalPadding,
                      AppSidebarTokens.sectionGap,
                      AppSidebarTokens.contentHorizontalPadding,
                      AppSidebarTokens.rowGap,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSidebarTokens.contentHorizontalPadding,
                      ),
                      children: [
                        const SizedBox(height: AppSidebarTokens.rowGap),
                        if (_selectedIndex == 0) ..._buildLayoutTab(context),
                        if (_selectedIndex == 1) ..._buildEffectsTab(context),
                        if (_selectedIndex == 2) ..._buildExportTab(context),
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
          ),
        ),
      ],
    );
  }

  String _headerTitle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (_selectedIndex) {
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
        isProcessing: widget.isProcessing,
        layoutPreset: widget.layoutPreset,
        resolutionPreset: widget.resolutionPreset,
        fitMode: widget.fitMode,
        padding: widget.padding,
        radius: widget.radius,
        onLayoutPresetChanged: widget.onLayoutPresetChanged,
        onResolutionPresetChanged: widget.onResolutionPresetChanged,
        onFitModeChanged: widget.onFitModeChanged,
        onPaddingChanged: widget.onPaddingChanged,
        onPaddingChangeEnd: widget.onPaddingChangeEnd,
        onRadiusChanged: widget.onRadiusChanged,
        onRadiusChangeEnd: widget.onRadiusChangeEnd,
      ),
      const SizedBox(height: AppSidebarTokens.rowGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.rowGap),
      PostBackgroundSection(
        isProcessing: widget.isProcessing,
        backgroundColor: widget.backgroundColor,
        backgroundImagePath: widget.backgroundImagePath,
        onBackgroundColorChanged: widget.onBackgroundColorChanged,
        onBackgroundImageChanged: widget.onBackgroundImageChanged,
        onPickImage: widget.onPickImage,
      ),
    ];
  }

  List<Widget> _buildEffectsTab(BuildContext context) {
    final theme = Theme.of(context);

    return [
      PostCursorSection(
        cursorAvailable: widget.cursorAvailable,
        showCursor: widget.showCursor,
        cursorSize: widget.cursorSize,
        onCursorShowChanged: widget.onCursorShowChanged,
        onCursorSizeChanged: widget.onCursorSizeChanged,
        onCursorSizeChangeEnd: widget.onCursorSizeChangeEnd,
      ),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      PostZoomSection(
        isProcessing: widget.isProcessing,
        zoomFactor: widget.zoomFactor,
        onZoomFactorChanged: widget.onZoomFactorChanged,
        onZoomFactorChangeEnd: widget.onZoomFactorChangeEnd,
      ),
      const SizedBox(height: AppSidebarTokens.compactGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      PostAudioSection(
        hasAudio: widget.hasAudio,
        audioVolume: widget.audioVolume,
        audioGainDb: widget.audioGainDb,
        onAudioVolumeChanged: widget.onAudioVolumeChanged,
        onAudioVolumeChangeEnd: widget.onAudioVolumeChangeEnd,
        onAudioGainChanged: widget.onAudioGainChanged,
        onAudioGainChangeEnd: widget.onAudioGainChangeEnd,
      ),
    ];
  }

  List<Widget> _buildExportTab(BuildContext context) {
    return [
      PostExportSettingsSection(
        isProcessing: widget.isProcessing,
        autoNormalizeOnExport: widget.autoNormalizeOnExport,
        autoNormalizeTargetDbfs: widget.autoNormalizeTargetDbfs,
        onAutoNormalizeOnExportChanged: widget.onAutoNormalizeOnExportChanged,
        onAutoNormalizeTargetDbfsChanged:
            widget.onAutoNormalizeTargetDbfsChanged,
      ),
    ];
  }

  Widget _buildRailItem({
    required IconData icon,
    required String label,
    required int index,
    required bool isSelected,
    required Color accentColor,
  }) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final controlFill =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;
    final inactiveColor = theme.colorScheme.onSurfaceVariant;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _selectedIndex = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSidebarTokens.railItemVerticalPadding,
          ),
          child: Column(
            children: [
              Container(
                key: ValueKey('post_sidebar_rail_tile_$index'),
                width: chrome.inspectorTabHeight + 8,
                height: chrome.inspectorTabHeight + 8,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? accentColor.withValues(alpha: 0.16)
                      : controlFill.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(chrome.controlRadius + 2),
                  border: Border.all(
                    color: isSelected
                        ? accentColor.withValues(alpha: 0.3)
                        : theme.dividerColor.withValues(alpha: 0.08),
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.14),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  icon,
                  color: isSelected ? accentColor : inactiveColor,
                  size: 20,
                ),
              ),
              const SizedBox(height: AppSidebarTokens.compactGap / 2),
              Text(
                label,
                textAlign: TextAlign.center,
                style: AppSidebarTokens.railLabelStyle(
                  theme,
                  selected: isSelected,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
