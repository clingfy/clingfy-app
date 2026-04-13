import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.loudness,
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
              AppInsetGroup(
                children: [
                  AppSliderRow(
                    label: l10n.targetLoudness,
                    slider: _buildSidebarSlider(
                      value: autoNormalizeTargetDbfs,
                      min: -24,
                      max: -6,
                      divisions: 18,
                      valueLabel:
                          '${autoNormalizeTargetDbfs.toStringAsFixed(0)} dBFS',
                      semanticLabel: l10n.targetLoudness,
                      onChanged: isProcessing
                          ? null
                          : onAutoNormalizeTargetDbfsChanged,
                      onChangeEnd: onAutoNormalizeTargetDbfsChanged,
                    ),
                  ),
                ],
              ),
            ],
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
