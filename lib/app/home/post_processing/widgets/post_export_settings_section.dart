import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

class PostExportSettingsSection extends StatelessWidget {
  const PostExportSettingsSection({
    super.key,
    required this.isProcessing,
    required this.autoNormalizeOnExport,
    required this.autoNormalizeTargetDbfs,
    required this.onAutoNormalizeOnExportChanged,
    required this.onAutoNormalizeTargetDbfsChanged,
  });

  final bool isProcessing;
  final bool autoNormalizeOnExport;
  final double autoNormalizeTargetDbfs;
  final ValueChanged<bool> onAutoNormalizeOnExportChanged;
  final ValueChanged<double> onAutoNormalizeTargetDbfsChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToggleRow(
          title: l10n.autoNormalizeOnExport,
          value: autoNormalizeOnExport,
          onChanged: isProcessing ? null : onAutoNormalizeOnExportChanged,
        ),
        if (autoNormalizeOnExport) ...[
          const SizedBox(
            key: Key('post_export_target_loudness_gap'),
            height: AppSidebarTokens.optionsSubgroupGap,
          ),
          AppSliderRow(
            label: l10n.targetLoudness,
            valueText: '${autoNormalizeTargetDbfs.toStringAsFixed(0)} dBFS',
            slider: _buildSidebarSlider(
              context,
              value: autoNormalizeTargetDbfs,
              min: -24,
              max: -6,
              divisions: 18,
              onChanged: isProcessing ? null : onAutoNormalizeTargetDbfsChanged,
              onChangeEnd: onAutoNormalizeTargetDbfsChanged,
              accentColor: accentColor,
            ),
          ),
        ],
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
