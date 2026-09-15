import 'package:flutter/foundation.dart';
import 'package:clingfy/core/models/app_models.dart';

/// Per-recording canvas appearance: how the video sits inside the exported
/// frame, and what is behind it.
///
/// Part of [Timeline] rather than a store of its own because it is editor state
/// for one recording, exactly like the clip and caption tracks it is saved
/// beside. It was previously `editor_state.json`, written by a `lib/app` store;
/// the types it holds ([BackgroundKind], [CanvasBackgroundPreset]) were always
/// `lib/core`, so nothing had to move down a layer to bring it here.
///
/// Layout / resolution / fit are deliberately absent: those are global app
/// settings (`SettingsController.post`), not per-project, and making them
/// per-project would be a behaviour change rather than a storage change.
@immutable
class CanvasState {
  const CanvasState({
    this.padding = 0.0,
    this.cornerRadius = 0.0,
    this.backgroundKind = BackgroundKind.color,
    this.backgroundColorArgb,
    this.backgroundImagePath,
    this.backgroundPreset,
  });

  final double padding;
  final double cornerRadius;
  final BackgroundKind backgroundKind;
  final int? backgroundColorArgb;
  final String? backgroundImagePath;
  final CanvasBackgroundPreset? backgroundPreset;

  /// True when nothing has been changed from the defaults. Lets the codec skip
  /// writing an empty `canvas` block, so an untouched recording produces the
  /// same file it would have before this existed.
  bool get isDefault =>
      padding == 0.0 &&
      cornerRadius == 0.0 &&
      backgroundKind == BackgroundKind.color &&
      backgroundColorArgb == null &&
      backgroundImagePath == null &&
      backgroundPreset == null;

  CanvasState copyWith({
    double? padding,
    double? cornerRadius,
    BackgroundKind? backgroundKind,
    int? backgroundColorArgb,
    String? backgroundImagePath,
    CanvasBackgroundPreset? backgroundPreset,
    bool clearBackgroundColor = false,
    bool clearBackgroundImage = false,
    bool clearBackgroundPreset = false,
  }) => CanvasState(
    padding: padding ?? this.padding,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    backgroundKind: backgroundKind ?? this.backgroundKind,
    backgroundColorArgb: clearBackgroundColor
        ? null
        : (backgroundColorArgb ?? this.backgroundColorArgb),
    backgroundImagePath: clearBackgroundImage
        ? null
        : (backgroundImagePath ?? this.backgroundImagePath),
    backgroundPreset: clearBackgroundPreset
        ? null
        : (backgroundPreset ?? this.backgroundPreset),
  );

  Map<String, dynamic> toMap() => {
    'padding': padding,
    'cornerRadius': cornerRadius,
    'background': {
      'kind': backgroundKind.name,
      'colorArgb': backgroundColorArgb,
      'imagePath': backgroundImagePath,
      'preset': backgroundPreset?.toJson(),
    },
  };

  /// Forgiving on purpose, like the rest of the codec: a malformed block yields
  /// defaults so a project always opens.
  factory CanvasState.fromMap(Map<dynamic, dynamic> m) {
    final bg = m['background'];
    final bgMap = bg is Map ? bg.cast<String, dynamic>() : const {};
    return CanvasState(
      padding: (m['padding'] as num?)?.toDouble() ?? 0.0,
      cornerRadius: (m['cornerRadius'] as num?)?.toDouble() ?? 0.0,
      backgroundKind: BackgroundKind.values.firstWhere(
        (k) => k.name == bgMap['kind'],
        orElse: () => BackgroundKind.color,
      ),
      backgroundColorArgb: (bgMap['colorArgb'] as num?)?.toInt(),
      backgroundImagePath: bgMap['imagePath'] is String
          ? bgMap['imagePath'] as String
          : null,
      backgroundPreset: CanvasBackgroundPreset.fromJson(
        (bgMap['preset'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasState &&
          runtimeType == other.runtimeType &&
          padding == other.padding &&
          cornerRadius == other.cornerRadius &&
          backgroundKind == other.backgroundKind &&
          backgroundColorArgb == other.backgroundColorArgb &&
          backgroundImagePath == other.backgroundImagePath &&
          backgroundPreset == other.backgroundPreset;

  @override
  int get hashCode => Object.hash(
    padding,
    cornerRadius,
    backgroundKind,
    backgroundColorArgb,
    backgroundImagePath,
    backgroundPreset,
  );
}
