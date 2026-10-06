import 'package:flutter/foundation.dart';

/// What the on-device speech model costs on disk, and whether it can go.
///
/// Two buckets because the weights are not the whole story: Core ML compiles an
/// ANE-specialised bundle beside them, and on a real machine that second
/// directory holds what Clingfy can free of it. Reporting only the weights
/// would understate the footprint by a third and leave most of it behind after
/// a delete.
/// One speech-model variant as it exists on disk.
///
/// Models are variant-scoped natively — WhisperKit downloads into a folder
/// named after the variant — so a second one lands beside the first rather than
/// replacing it. Without this list the Storage card measured the whole models
/// tree as a single number, which meant a user carrying two models saw one
/// figure, no names, and one button that removed both.
@immutable
class CaptionModelVariant {
  const CaptionModelVariant({
    required this.variant,
    required this.bytes,
    required this.complete,
  });

  /// The folder name, e.g. `openai_whisper-large-v3-v20240930_626MB`.
  final String variant;

  /// This variant's own folder only. The variants do NOT sum to
  /// [CaptionModelInfo.modelBytes]: the tokenizer repo sits outside them and
  /// the compiled cache is app-wide.
  final int bytes;

  /// Whether the engine could LOAD this one — all three compiled bundles plus
  /// `config.json`, the same rule the transcriber uses before skipping a
  /// download.
  ///
  /// Not the same question as [CaptionModelInfo.installed], which means "there
  /// are bytes here to free". An interrupted download is installed and not
  /// complete. A picker that read `installed` for readiness would tell the user
  /// nothing needs fetching immediately before a 626 MB fetch.
  final bool complete;

  /// The variant trimmed for display: `openai_whisper-large-v3-v20240930_626MB`
  /// becomes `large-v3-v20240930_626MB`.
  ///
  /// Only the vendor prefix goes. The date and the size stay because they are
  /// what distinguishes two otherwise identically-named builds, and a card that
  /// says just "large-v3" twice tells the user nothing about which to remove.
  String get displayName {
    const prefix = 'openai_whisper-';
    return variant.startsWith(prefix)
        ? variant.substring(prefix.length)
        : variant;
  }

  factory CaptionModelVariant.fromMap(Map<dynamic, dynamic> map) {
    return CaptionModelVariant(
      variant: map['variant'] is String ? map['variant'] as String : '',
      bytes: map['bytes'] is num ? (map['bytes'] as num).toInt() : 0,
      complete: map['complete'] is bool ? map['complete'] as bool : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptionModelVariant &&
          variant == other.variant &&
          bytes == other.bytes &&
          complete == other.complete;

  @override
  int get hashCode => Object.hash(variant, bytes, complete);
}

@immutable
class CaptionModelInfo {
  const CaptionModelInfo({
    required this.installed,
    required this.modelBytes,
    required this.compiledCacheBytes,
    required this.modelPath,
    required this.variant,
    required this.variants,
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
    variants: <CaptionModelVariant>[],
    busy: false,
    loaded: false,
  );

  /// Keyed off bytes, never directory existence: an empty folder is not a
  /// model, and the engine creates one the first time it looks.
  final bool installed;
  final int modelBytes;
  final int compiledCacheBytes;
  final String modelPath;

  /// The variant the engine would use — which of [variants] is active.
  final String variant;

  /// Every variant found on disk. May be empty while [installed] is true: a
  /// download interrupted before it created the variant folder leaves bytes in
  /// the tokenizer repo with no variant yet.
  final List<CaptionModelVariant> variants;

  /// A transcription is touching the model. Advisory only — this can be stale
  /// by the time the user clicks, and native re-checks before deleting.
  final bool busy;

  /// The model is held in memory, so deleting also unloads it.
  final bool loaded;

  int get totalBytes => modelBytes + compiledCacheBytes;

  /// Size of the variant the engine would use, or null when it is not on disk.
  ///
  /// This is the figure the delete confirmation should quote, not [modelBytes]:
  /// a re-download fetches ONE variant, so with two on disk the root total
  /// overstates what the next Generate would pull by roughly double.
  int? get activeVariantBytes {
    for (final v in variants) {
      if (v.variant == variant) return v.bytes;
    }
    return null;
  }

  /// True when more than one model is on disk, so the card should name them
  /// rather than show a single anonymous total.
  bool get hasMultipleVariants => variants.length > 1;

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
      // Absent on payloads from before per-variant reporting, and from the
      // Windows stub; an empty list is the honest reading of "nothing to list".
      variants: map['variants'] is List
          ? [
              for (final entry in map['variants'] as List<dynamic>)
                if (entry is Map) CaptionModelVariant.fromMap(entry),
            ]
          : const <CaptionModelVariant>[],
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
          listEquals(variants, other.variants) &&
          busy == other.busy &&
          loaded == other.loaded;

  @override
  int get hashCode => Object.hash(
    installed,
    modelBytes,
    compiledCacheBytes,
    modelPath,
    variant,
    Object.hashAll(variants),
    busy,
    loaded,
  );
}
