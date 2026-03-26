import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

class PostZoomSection extends StatelessWidget {
  const PostZoomSection({
    super.key,
    required this.isProcessing,
    required this.zoomFactor,
    required this.onZoomFactorChanged,
    required this.onZoomFactorChangeEnd,
  });

  final bool isProcessing;
  final double zoomFactor;
  final ValueChanged<double> onZoomFactorChanged;
  final ValueChanged<double> onZoomFactorChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToggleRow(
          title: l10n.zoomInEffect,
          infoTooltip: l10n.manageZoomEffects,
          value: zoomFactor > 1.0,
          onChanged: isProcessing
              ? null
              : (value) {
                  if (value) {
                    onZoomFactorChanged(1.5);
                    onZoomFactorChangeEnd(1.5);
                  } else {
                    onZoomFactorChanged(1.0);
                    onZoomFactorChangeEnd(1.0);
                  }
                },
        ),
        if (zoomFactor > 1.0) ...[
          const SizedBox(
            key: Key('post_zoom_intensity_gap'),
            height: AppSidebarTokens.optionsSubgroupGap,
          ),
          AppSliderRow(
            label: l10n.intensity,
            valueText: '${zoomFactor.toStringAsFixed(1)}x',
            slider: _buildSidebarSlider(
              context,
              value: zoomFactor,
              min: 1.0,
              max: 3.0,
              divisions: 20,
              onChanged: isProcessing ? null : onZoomFactorChanged,
              onChangeEnd: onZoomFactorChangeEnd,
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
