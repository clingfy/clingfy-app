import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

class PostZoomSection extends StatelessWidget {
  const PostZoomSection({
    super.key,
    required this.isProcessing,
    required this.zoomEffectEnabled,
    required this.zoomFactor,
    required this.onZoomEffectEnabledChanged,
    required this.onZoomFactorChanged,
    required this.onZoomFactorChangeEnd,
  });

  final bool isProcessing;
  final bool zoomEffectEnabled;
  final double zoomFactor;
  final ValueChanged<bool> onZoomEffectEnabledChanged;
  final ValueChanged<double> onZoomFactorChanged;
  final ValueChanged<double> onZoomFactorChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final clampedZoom = zoomFactor.isFinite
        ? zoomFactor.clamp(1.0, 3.0).toDouble()
        : 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.zoom,
          showHeader: false,
          children: [
            AppToggleRow(
              title: l10n.zoomInEffect,
              infoTooltip: l10n.manageZoomEffects,
              value: zoomEffectEnabled,
              onChanged: isProcessing ? null : onZoomEffectEnabledChanged,
            ),
            if (zoomEffectEnabled) ...[
              const SizedBox(
                key: Key('post_zoom_intensity_gap'),
                height: AppSidebarTokens.optionsSubgroupGap,
              ),
              AppInsetGroup(
                children: [
                  AppSliderRow(
                    label: l10n.intensity,
                    slider: _buildSidebarSlider(
                      value: clampedZoom,
                      min: 1.0,
                      max: 3.0,
                      divisions: 20,
                      valueLabel: '${clampedZoom.toStringAsFixed(1)}x',
                      semanticLabel: l10n.intensity,
                      onChanged: isProcessing ? null : onZoomFactorChanged,
                      onChangeEnd: onZoomFactorChangeEnd,
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
