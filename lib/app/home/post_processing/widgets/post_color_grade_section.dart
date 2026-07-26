import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

/// Color-correction controls: a one-tap auto-enhance toggle plus exposure /
/// contrast / saturation / temperature / tint sliders, each normalized to
/// `[-1, 1]` (0 = neutral). Live changes drive the macOS preview; release
/// commits via [onChangeEnd].
class PostColorGradeSection extends StatelessWidget {
  const PostColorGradeSection({
    super.key,
    required this.colorGrade,
    required this.onAutoEnhanceChanged,
    required this.onExposureChanged,
    required this.onContrastChanged,
    required this.onSaturationChanged,
    required this.onTemperatureChanged,
    required this.onTintChanged,
    required this.onChangeEnd,
  });

  final ColorGrade colorGrade;
  final ValueChanged<bool> onAutoEnhanceChanged;
  final ValueChanged<double> onExposureChanged;
  final ValueChanged<double> onContrastChanged;
  final ValueChanged<double> onSaturationChanged;
  final ValueChanged<double> onTemperatureChanged;
  final ValueChanged<double> onTintChanged;
  final VoidCallback onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.colorCorrection,
          showHeader: false,
          children: [
            AppToggleRow(
              key: const Key('color_auto_enhance_toggle'),
              title: l10n.autoEnhance,
              value: colorGrade.autoEnabled,
              onChanged: onAutoEnhanceChanged,
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            _slider(
              l10n.exposure,
              colorGrade.exposure,
              onExposureChanged,
              sliderKey: const Key('color_slider_exposure'),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            _slider(
              l10n.contrast,
              colorGrade.contrast,
              onContrastChanged,
              sliderKey: const Key('color_slider_contrast'),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            _slider(
              l10n.saturation,
              colorGrade.saturation,
              onSaturationChanged,
              sliderKey: const Key('color_slider_saturation'),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            _slider(
              l10n.temperature,
              colorGrade.temperature,
              onTemperatureChanged,
              sliderKey: const Key('color_slider_temperature'),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            _slider(
              l10n.tint,
              colorGrade.tint,
              onTintChanged,
              sliderKey: const Key('color_slider_tint'),
            ),
          ],
        ),
      ],
    );
  }

  /// [sliderKey] makes each row addressable from `flutter_driver` — the MCP
  /// bridge cannot build Descendant/Ancestor finders, so without a key on the
  /// slider itself there is no way to drive one specific colour control live.
  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    Key? sliderKey,
  }) {
    return AppSliderRow(
      label: label,
      slider: AppSlider(
        key: sliderKey,
        value: value,
        min: -1.0,
        max: 1.0,
        divisions: 40,
        valueLabel: value == 0 ? '0' : value.toStringAsFixed(2),
        semanticLabel: label,
        onChanged: onChanged,
        onChangeEnd: (_) => onChangeEnd(),
      ),
    );
  }
}
