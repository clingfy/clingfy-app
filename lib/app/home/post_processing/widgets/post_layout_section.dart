import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_control_box.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_segmented.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/platform/widgets/resolution_preset_menu_items.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class PostLayoutSection extends StatelessWidget {
  const PostLayoutSection({
    super.key,
    required this.isProcessing,
    required this.layoutPreset,
    required this.resolutionPreset,
    required this.fitMode,
    required this.padding,
    required this.radius,
    required this.showResolutionControl,
    required this.onLayoutPresetChanged,
    required this.onResolutionPresetChanged,
    required this.onFitModeChanged,
    required this.onPaddingChanged,
    required this.onPaddingChangeEnd,
    required this.onRadiusChanged,
    required this.onRadiusChangeEnd,
  });

  final bool isProcessing;
  final LayoutPreset layoutPreset;
  final ResolutionPreset resolutionPreset;
  final FitMode fitMode;
  final double padding;
  final double radius;
  final bool showResolutionControl;
  final ValueChanged<LayoutPreset> onLayoutPresetChanged;
  final ValueChanged<ResolutionPreset> onResolutionPresetChanged;
  final ValueChanged<FitMode> onFitModeChanged;
  final ValueChanged<double> onPaddingChanged;
  final ValueChanged<double> onPaddingChangeEnd;
  final ValueChanged<double> onRadiusChanged;
  final ValueChanged<double> onRadiusChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.canvasFormat,
          showHeader: false,
          children: [
            _CanvasAspectSelector(
              label: l10n.canvasAspect,
              value: layoutPreset,
              enabled: !isProcessing,
              onChanged: onLayoutPresetChanged,
              options: [
                _CanvasAspectOption(
                  preset: LayoutPreset.auto,
                  title: l10n.auto,
                  subtitle: l10n.original,
                  previewAspectRatio: 1.45,
                ),
                _CanvasAspectOption(
                  preset: LayoutPreset.youtube169,
                  title: l10n.wide,
                  subtitle: '16:9',
                  previewAspectRatio: 16 / 9,
                ),
                _CanvasAspectOption(
                  preset: LayoutPreset.reel916,
                  title: l10n.vertical,
                  subtitle: '9:16',
                  previewAspectRatio: 9 / 16,
                ),
                _CanvasAspectOption(
                  preset: LayoutPreset.square11,
                  title: l10n.square,
                  subtitle: '1:1',
                  previewAspectRatio: 1,
                ),
                _CanvasAspectOption(
                  preset: LayoutPreset.classic43,
                  title: l10n.classic,
                  subtitle: '4:3',
                  previewAspectRatio: 4 / 3,
                ),
              ],
            ),
            if (showResolutionControl) ...[
              const SizedBox(height: AppSidebarTokens.rowGap),
              AppFormRow(
                label: l10n.resolution,
                control: PlatformDropdown<ResolutionPreset>(
                  value: resolutionPreset,
                  labelText: l10n.resolution,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  expand: true,
                  items: buildResolutionPresetMenuItems(l10n),
                  onChanged: isProcessing
                      ? null
                      : (value) {
                          if (value != null) {
                            onResolutionPresetChanged(value);
                          }
                        },
                ),
              ),
            ],
            const SizedBox(height: AppSidebarTokens.rowGap),
            AppFormRow(
              label: l10n.fitMode,
              control: AppControlBox(
                expand: true,
                height: 40,
                child: AppSegmented<FitMode>(
                  value: fitMode,
                  onChanged: isProcessing ? (_) {} : onFitModeChanged,
                  items: [
                    AppSegmentedItem(
                      value: FitMode.fit,
                      label: l10n.fit,
                      icon: Icons.fit_screen,
                    ),
                    AppSegmentedItem(
                      value: FitMode.fill,
                      label: l10n.fill,
                      icon: Icons.aspect_ratio,
                    ),
                  ],
                  compact: true,
                  expand: true,
                ),
              ),
            ),
          ],
        ),
        AppSettingsGroup(
          title: l10n.framing,
          showHeader: false,
          children: [
            AppSliderRow(
              label: l10n.padding,
              slider: _buildSidebarSlider(
                value: padding,
                min: 0,
                max: 100,
                divisions: 100,
                valueLabel: '${padding.toInt()}%',
                semanticLabel: l10n.padding,
                onChanged: isProcessing ? null : onPaddingChanged,
                onChangeEnd: onPaddingChangeEnd,
              ),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            AppSliderRow(
              label: l10n.roundedCorners,
              slider: _buildSidebarSlider(
                value: radius,
                min: 0,
                max: 50,
                divisions: 50,
                valueLabel: '${radius.toInt()}px',
                semanticLabel: l10n.roundedCorners,
                onChanged: isProcessing ? null : onRadiusChanged,
                onChangeEnd: onRadiusChangeEnd,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSidebarSlider({
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required String semanticLabel,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
  }) {
    return AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      valueLabel: valueLabel,
      semanticLabel: semanticLabel,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}

class _CanvasAspectSelector extends StatelessWidget {
  const _CanvasAspectSelector({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.options,
  });

  static const double _selectorHeight = 88;
  static const double _cardWidth = 84;

  final String label;
  final LayoutPreset value;
  final bool enabled;
  final ValueChanged<LayoutPreset> onChanged;
  final List<_CanvasAspectOption> options;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final borderRadius = BorderRadius.circular(12);
    final metrics = context.shellMetricsOrNull;
    final minWidth =
        metrics?.sidebarControlMinWidth ?? AppSidebarTokens.controlMinWidth;

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppSidebarTokens.rowTitleStyle(theme)),
          const SizedBox(height: AppSidebarTokens.rowGap),
          DecoratedBox(
            key: const Key('canvas_aspect_selector'),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(
                  alpha: enabled ? 0.28 : 0.18,
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: SizedBox(
                height: _selectorHeight,
                child: SingleChildScrollView(
                  key: const Key('canvas_aspect_selector_scroll'),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in options.indexed)
                        _CanvasAspectCard(
                          width: _cardWidth,
                          option: entry.$2,
                          selected: entry.$2.preset == value,
                          enabled: enabled,
                          showTrailingDivider: entry.$1 < options.length - 1,
                          onTap: () => onChanged(entry.$2.preset),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CanvasAspectCard extends StatelessWidget {
  const _CanvasAspectCard({
    required this.width,
    required this.option,
    required this.selected,
    required this.enabled,
    required this.showTrailingDivider,
    required this.onTap,
  });

  final double width;
  final _CanvasAspectOption option;
  final bool selected;
  final bool enabled;
  final bool showTrailingDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleColor = (selected ? colorScheme.primary : colorScheme.onSurface)
        .withValues(alpha: enabled ? 1 : 0.52);
    final subtitleColor =
        (selected ? colorScheme.primary : colorScheme.onSurfaceVariant)
            .withValues(alpha: enabled ? (selected ? 0.92 : 0.94) : 0.48);
    final previewColor =
        (selected ? colorScheme.primary : colorScheme.onSurfaceVariant)
            .withValues(alpha: enabled ? (selected ? 0.74 : 0.46) : 0.28);
    final dividerColor = colorScheme.outlineVariant.withValues(alpha: 0.2);
    final selectedBorderColor = colorScheme.primary.withValues(alpha: 0.42);

    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: '${option.title} ${option.subtitle}',
      child: SizedBox(
        key: ValueKey('canvas_aspect_option_${option.preset.name}'),
        width: width,
        height: double.infinity,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onTap : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  color: Colors.transparent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 18,
                        child: Center(
                          child: _CanvasAspectPreview(
                            aspectRatio: option.previewAspectRatio,
                            color: previewColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        option.title,
                        textAlign: TextAlign.center,
                        style: AppSidebarTokens.rowTitleStyle(theme).copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle,
                        textAlign: TextAlign.center,
                        style: AppSidebarTokens.valueStyle(theme).copyWith(
                          color: subtitleColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: selectedBorderColor),
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                    ),
                  ),
                if (showTrailingDivider)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(color: dividerColor),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CanvasAspectPreview extends StatelessWidget {
  const _CanvasAspectPreview({required this.aspectRatio, required this.color});

  final double aspectRatio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const shortSide = 10.0;
    final width = aspectRatio >= 1 ? shortSide * aspectRatio : shortSide;
    final height = aspectRatio >= 1 ? shortSide : shortSide / aspectRatio;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

class _CanvasAspectOption {
  const _CanvasAspectOption({
    required this.preset,
    required this.title,
    required this.subtitle,
    required this.previewAspectRatio,
  });

  final LayoutPreset preset;
  final String title;
  final String subtitle;
  final double previewAspectRatio;
}
