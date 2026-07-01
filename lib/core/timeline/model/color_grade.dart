import 'package:flutter/foundation.dart';

/// Canvas-wide color adjustment baked into preview and export. All values
/// default to neutral; [autoEnabled] turns on the one-tap auto-enhance.
@immutable
class ColorGrade {
  const ColorGrade({
    this.autoEnabled = false,
    this.exposure = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temperature = 0,
    this.tint = 0,
  });

  final bool autoEnabled;
  final double exposure;
  final double contrast;
  final double saturation;
  final double temperature;
  final double tint;

  /// True when no adjustment is applied (lets the render path skip the pass).
  bool get isIdentity =>
      !autoEnabled &&
      exposure == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      temperature == 0 &&
      tint == 0;

  Map<String, dynamic> toMap() => {
    'autoEnabled': autoEnabled,
    'exposure': exposure,
    'contrast': contrast,
    'saturation': saturation,
    'temperature': temperature,
    'tint': tint,
  };

  factory ColorGrade.fromMap(Map<dynamic, dynamic> m) => ColorGrade(
    autoEnabled: m['autoEnabled'] as bool? ?? false,
    exposure: (m['exposure'] as num?)?.toDouble() ?? 0,
    contrast: (m['contrast'] as num?)?.toDouble() ?? 0,
    saturation: (m['saturation'] as num?)?.toDouble() ?? 0,
    temperature: (m['temperature'] as num?)?.toDouble() ?? 0,
    tint: (m['tint'] as num?)?.toDouble() ?? 0,
  );

  ColorGrade copyWith({
    bool? autoEnabled,
    double? exposure,
    double? contrast,
    double? saturation,
    double? temperature,
    double? tint,
  }) => ColorGrade(
    autoEnabled: autoEnabled ?? this.autoEnabled,
    exposure: exposure ?? this.exposure,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    temperature: temperature ?? this.temperature,
    tint: tint ?? this.tint,
  );

  // Value equality so listeners (e.g. provider `Selector`s) can detect when a
  // grade actually changed and rebuild the controls. Without this, every
  // `copyWith` produces an instance that compares unequal by identity, which is
  // what left the color sliders stuck while the preview still updated.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ColorGrade &&
          runtimeType == other.runtimeType &&
          autoEnabled == other.autoEnabled &&
          exposure == other.exposure &&
          contrast == other.contrast &&
          saturation == other.saturation &&
          temperature == other.temperature &&
          tint == other.tint;

  @override
  int get hashCode => Object.hash(
    autoEnabled,
    exposure,
    contrast,
    saturation,
    temperature,
    tint,
  );

  @override
  String toString() =>
      'ColorGrade(autoEnabled: $autoEnabled, exposure: $exposure, '
      'contrast: $contrast, saturation: $saturation, '
      'temperature: $temperature, tint: $tint)';
}
