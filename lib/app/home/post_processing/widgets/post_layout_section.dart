import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_control_box.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_segmented.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
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
    final accentColor = Theme.of(context).colorScheme.primary;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          children: [
            AppFormRow(
              label: l10n.canvasAspect,
              control: PlatformDropdown<LayoutPreset>(
                value: layoutPreset,
                items: [
                  PlatformMenuItem(value: LayoutPreset.auto, label: l10n.auto),
                  PlatformMenuItem(
                    value: LayoutPreset.classic43,
                    label: l10n.classic43,
                  ),
                  PlatformMenuItem(
                    value: LayoutPreset.square11,
                    label: l10n.square11,
                  ),
                  PlatformMenuItem(
                    value: LayoutPreset.youtube169,
                    label: l10n.youtube169,
                  ),
                  PlatformMenuItem(
                    value: LayoutPreset.reel916,
                    label: l10n.reel916,
                  ),
                ],
                onChanged: isProcessing
                    ? null
                    : (value) {
                        if (value != null) onLayoutPresetChanged(value);
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
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
        const SizedBox(
          key: Key('post_layout_controls_gap_before_divider'),
          height: AppSidebarTokens.optionsSubgroupGap,
        ),
        Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
        const SizedBox(
          key: Key('post_layout_controls_gap_after_divider'),
          height: AppSidebarTokens.optionsSubgroupGap,
        ),
        AppSliderRow(
          label: l10n.padding,
          valueText: '${padding.toInt()}%',
          slider: _buildSidebarSlider(
            context,
            value: padding,
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: isProcessing ? null : onPaddingChanged,
            onChangeEnd: onPaddingChangeEnd,
            accentColor: accentColor,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        AppSliderRow(
          label: l10n.roundedCorners,
          valueText: '${radius.toInt()}px',
          slider: _buildSidebarSlider(
            context,
            value: radius,
            min: 0,
            max: 50,
            divisions: 50,
            onChanged: isProcessing ? null : onRadiusChanged,
            onChangeEnd: onRadiusChangeEnd,
            accentColor: accentColor,
          ),
        ),
      ],
    );
  }

  Widget _buildSidebarSlider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    required Color accentColor,
    int? divisions,
  }) {
    final slider = AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );

    if (isMac()) return slider;

    return SliderTheme(
      data: Theme.of(
        context,
      ).sliderTheme.copyWith(activeTrackColor: accentColor),
      child: slider,
    );
  }
}
