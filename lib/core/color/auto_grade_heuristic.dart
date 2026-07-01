import 'package:clingfy/core/timeline/model/color_grade.dart';

/// Inclusive value range for each adjustable [ColorGrade] parameter.
///
/// Normalized to `[-1, 1]` with `0` = neutral. Shared by the slider UI and the
/// native renderer so a stored value always means the same thing on both sides.
abstract final class ColorGradeRanges {
  static const double min = -1.0;
  static const double max = 1.0;
}

/// Clamps every adjustable field of [grade] into [ColorGradeRanges]
/// (leaving [ColorGrade.autoEnabled] untouched).
ColorGrade clampColorGrade(ColorGrade grade) => grade.copyWith(
  exposure: grade.exposure.clamp(ColorGradeRanges.min, ColorGradeRanges.max),
  contrast: grade.contrast.clamp(ColorGradeRanges.min, ColorGradeRanges.max),
  saturation: grade.saturation.clamp(
    ColorGradeRanges.min,
    ColorGradeRanges.max,
  ),
  temperature: grade.temperature.clamp(
    ColorGradeRanges.min,
    ColorGradeRanges.max,
  ),
  tint: grade.tint.clamp(ColorGradeRanges.min, ColorGradeRanges.max),
);

/// One-tap "auto enhance": a gentle, tasteful lift applied without frame
/// analysis — a small exposure / contrast / saturation bump.
///
/// [intensity] in `[0, 1]` scales the effect (0 = neutral but flagged auto-on,
/// 1 = full). Manual editing sets [ColorGrade] fields directly; this only backs
/// the Auto button.
ColorGrade autoEnhanceGrade({double intensity = 1.0}) {
  final i = intensity.clamp(0.0, 1.0);
  return ColorGrade(
    autoEnabled: true,
    exposure: 0.04 * i,
    contrast: 0.12 * i,
    saturation: 0.10 * i,
  );
}
