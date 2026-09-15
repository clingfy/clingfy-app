import 'package:flutter/foundation.dart';

/// What the on-device speech model costs on disk, and whether it can go.
///
/// Two buckets because the weights are not the whole story: Core ML compiles an
/// ANE-specialised bundle beside them, and on a real machine that second
/// directory was 259 MB against 600 MB of weights. Reporting only the weights
/// would understate the footprint by a third and leave most of it behind after
/// a delete.
@immutable
class CaptionModelInfo {
  const CaptionModelInfo({
    required this.installed,
    required this.modelBytes,
    required this.compiledCacheBytes,
    required this.modelPath,
    required this.variant,
    required this.busy,
    required this.loaded,
  });

  /// Nothing downloaded, or a platform that cannot caption at all.
  static const CaptionModelInfo notInstalled = CaptionModelInfo(
    installed: false,
    modelBytes: 0,
    compiledCacheBytes: 0,
    modelPath: '',
    variant: '',
    busy: false,
    loaded: false,
  );

  /// Keyed off bytes, never directory existence: an empty folder is not a
  /// model, and the engine creates one the first time it looks.
  final bool installed;
  final int modelBytes;
  final int compiledCacheBytes;
  final String modelPath;
  final String variant;

  /// A transcription is touching the model. Advisory only — this can be stale
  /// by the time the user clicks, and native re-checks before deleting.
  final bool busy;

  /// The model is held in memory, so deleting also unloads it.
  final bool loaded;

  int get totalBytes => modelBytes + compiledCacheBytes;

  bool get canDelete => installed && !busy;

  /// Forgiving: a missing or malformed key reads as "nothing installed" rather
  /// than throwing, because this only ever feeds a settings card.
  factory CaptionModelInfo.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return notInstalled;
    // Type-checked rather than cast: a wrong-typed value has to fall back too,
    // or "forgiving" only covers the missing-key half and a bad payload throws
    // into the settings page.
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    bool asBool(Object? v) => v is bool ? v : false;
    String asString(Object? v) => v is String ? v : '';
    return CaptionModelInfo(
      installed: asBool(map['installed']),
      modelBytes: asInt(map['modelBytes']),
      compiledCacheBytes: asInt(map['compiledCacheBytes']),
      modelPath: asString(map['modelPath']),
      variant: asString(map['variant']),
      busy: asBool(map['busy']),
      loaded: asBool(map['loaded']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptionModelInfo &&
          runtimeType == other.runtimeType &&
          installed == other.installed &&
          modelBytes == other.modelBytes &&
          compiledCacheBytes == other.compiledCacheBytes &&
          modelPath == other.modelPath &&
          variant == other.variant &&
          busy == other.busy &&
          loaded == other.loaded;

  @override
  int get hashCode => Object.hash(
    installed,
    modelBytes,
    compiledCacheBytes,
    modelPath,
    variant,
    busy,
    loaded,
  );
}
