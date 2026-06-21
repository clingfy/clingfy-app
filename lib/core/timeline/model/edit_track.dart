import 'package:flutter/foundation.dart';
import 'package:clingfy/core/models/app_models.dart';

/// The kind of an [EditTrack], used as the serialization discriminator.
enum TrackKind { zoom, clip, caption, audio }

/// One lane on the editing timeline.
///
/// Immutable: edits produce new instances (see the per-track `copyWith`). The
/// hierarchy is `sealed` and lives in one library so the codec and future
/// renderers can switch over it exhaustively. Concrete tracks serialize
/// themselves via [toMap]; [fromMap] dispatches on the `kind` discriminator and
/// returns `null` for an unknown kind so old/newer projects still open.
@immutable
sealed class EditTrack {
  const EditTrack({required this.id, required this.enabled});

  final String id;
  final bool enabled;

  TrackKind get kind;

  Map<String, dynamic> toMap();

  static EditTrack? fromMap(Map<dynamic, dynamic> m) => switch (m['kind']) {
    'zoom' => ZoomTrack.fromMap(m),
    'clip' => ClipTrack.fromMap(m),
    'caption' => CaptionTrack.fromMap(m),
    'audio' => AudioTrack.fromMap(m),
    _ => null,
  };
}

List<ZoomSegment> _zoomSegments(Object? raw) => raw is List
    ? <ZoomSegment>[
        for (final e in raw)
          if (e is Map) ZoomSegment.fromMap(e),
      ]
    : const <ZoomSegment>[];

/// Zoom track — thin wrapper over the existing auto/manual [ZoomSegment] lists
/// so the long-standing zoom model is reused byte-for-byte.
final class ZoomTrack extends EditTrack {
  const ZoomTrack({
    super.id = 'zoom',
    super.enabled = true,
    this.auto = const <ZoomSegment>[],
    this.manual = const <ZoomSegment>[],
  });

  final List<ZoomSegment> auto;
  final List<ZoomSegment> manual;

  @override
  TrackKind get kind => TrackKind.zoom;

  @override
  Map<String, dynamic> toMap() => {
    'kind': 'zoom',
    'id': id,
    'enabled': enabled,
    'auto': [for (final s in auto) s.toMap()],
    'manual': [for (final s in manual) s.toMap()],
  };

  factory ZoomTrack.fromMap(Map<dynamic, dynamic> m) => ZoomTrack(
    id: m['id'] as String? ?? 'zoom',
    enabled: m['enabled'] as bool? ?? true,
    auto: _zoomSegments(m['auto']),
    manual: _zoomSegments(m['manual']),
  );

  ZoomTrack copyWith({
    String? id,
    bool? enabled,
    List<ZoomSegment>? auto,
    List<ZoomSegment>? manual,
  }) => ZoomTrack(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    auto: auto ?? this.auto,
    manual: manual ?? this.manual,
  );
}

/// A single clip: an in/out window into the captured media placed at a position
/// on the timeline. Explicit source-vs-timeline coordinates keep future
/// multi-clip arrange tractable.
@immutable
class Clip {
  const Clip({
    required this.id,
    required this.sourceInMs,
    required this.sourceOutMs,
    required this.timelineStartMs,
    this.enabled = true,
  });

  final String id;
  final int sourceInMs;
  final int sourceOutMs;
  final int timelineStartMs;
  final bool enabled;

  Map<String, dynamic> toMap() => {
    'id': id,
    'sourceInMs': sourceInMs,
    'sourceOutMs': sourceOutMs,
    'timelineStartMs': timelineStartMs,
    'enabled': enabled,
  };

  factory Clip.fromMap(Map<dynamic, dynamic> m) => Clip(
    id: m['id'] as String? ?? '',
    sourceInMs: (m['sourceInMs'] as num?)?.toInt() ?? 0,
    sourceOutMs: (m['sourceOutMs'] as num?)?.toInt() ?? 0,
    timelineStartMs: (m['timelineStartMs'] as num?)?.toInt() ?? 0,
    enabled: m['enabled'] as bool? ?? true,
  );
}

/// Clip track — split/trim/arrange. Defines the authoritative timeline duration
/// once present.
final class ClipTrack extends EditTrack {
  const ClipTrack({
    super.id = 'clip',
    super.enabled = true,
    this.clips = const <Clip>[],
  });

  final List<Clip> clips;

  @override
  TrackKind get kind => TrackKind.clip;

  @override
  Map<String, dynamic> toMap() => {
    'kind': 'clip',
    'id': id,
    'enabled': enabled,
    'clips': [for (final c in clips) c.toMap()],
  };

  factory ClipTrack.fromMap(Map<dynamic, dynamic> m) => ClipTrack(
    id: m['id'] as String? ?? 'clip',
    enabled: m['enabled'] as bool? ?? true,
    clips: m['clips'] is List
        ? <Clip>[
            for (final e in m['clips'] as List)
              if (e is Map) Clip.fromMap(e),
          ]
        : const <Clip>[],
  );

  ClipTrack copyWith({String? id, bool? enabled, List<Clip>? clips}) =>
      ClipTrack(
        id: id ?? this.id,
        enabled: enabled ?? this.enabled,
        clips: clips ?? this.clips,
      );
}

/// One word with its own timing — powers click-to-edit and reflow-on-split.
@immutable
class CaptionWord {
  const CaptionWord({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toMap() => {
    'text': text,
    'startMs': startMs,
    'endMs': endMs,
  };

  factory CaptionWord.fromMap(Map<dynamic, dynamic> m) => CaptionWord(
    text: m['text'] as String? ?? '',
    startMs: (m['startMs'] as num?)?.toInt() ?? 0,
    endMs: (m['endMs'] as num?)?.toInt() ?? 0,
  );
}

/// A single caption cue.
@immutable
class Caption {
  const Caption({
    required this.id,
    required this.startMs,
    required this.endMs,
    this.text = '',
    this.words = const <CaptionWord>[],
    this.translatedText,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final List<CaptionWord> words;
  final String? translatedText;

  Map<String, dynamic> toMap() => {
    'id': id,
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
    'words': [for (final w in words) w.toMap()],
    if (translatedText != null) 'translatedText': translatedText,
  };

  factory Caption.fromMap(Map<dynamic, dynamic> m) => Caption(
    id: m['id'] as String? ?? '',
    startMs: (m['startMs'] as num?)?.toInt() ?? 0,
    endMs: (m['endMs'] as num?)?.toInt() ?? 0,
    text: m['text'] as String? ?? '',
    words: m['words'] is List
        ? <CaptionWord>[
            for (final e in m['words'] as List)
              if (e is Map) CaptionWord.fromMap(e),
          ]
        : const <CaptionWord>[],
    translatedText: m['translatedText'] as String?,
  );
}

/// Visual style for burned-in / rendered captions. Colors are ARGB ints.
@immutable
class CaptionStyle {
  const CaptionStyle({
    this.fontSizePx = 28,
    this.textColorArgb = 0xFFFFFFFF,
    this.backgroundColorArgb = 0x99000000,
    this.bottomMarginFraction = 0.08,
  });

  final double fontSizePx;
  final int textColorArgb;
  final int backgroundColorArgb;
  final double bottomMarginFraction;

  Map<String, dynamic> toMap() => {
    'fontSizePx': fontSizePx,
    'textColorArgb': textColorArgb,
    'backgroundColorArgb': backgroundColorArgb,
    'bottomMarginFraction': bottomMarginFraction,
  };

  factory CaptionStyle.fromMap(Map<dynamic, dynamic> m) => CaptionStyle(
    fontSizePx: (m['fontSizePx'] as num?)?.toDouble() ?? 28,
    textColorArgb: (m['textColorArgb'] as num?)?.toInt() ?? 0xFFFFFFFF,
    backgroundColorArgb:
        (m['backgroundColorArgb'] as num?)?.toInt() ?? 0x99000000,
    bottomMarginFraction:
        (m['bottomMarginFraction'] as num?)?.toDouble() ?? 0.08,
  );
}

/// Caption track — an editable list of timed cues plus the source/target
/// language and render style.
final class CaptionTrack extends EditTrack {
  const CaptionTrack({
    super.id = 'caption',
    super.enabled = true,
    this.language = 'en',
    this.sourceLanguage,
    this.style = const CaptionStyle(),
    this.captions = const <Caption>[],
  });

  final String language;
  final String? sourceLanguage;
  final CaptionStyle style;
  final List<Caption> captions;

  @override
  TrackKind get kind => TrackKind.caption;

  @override
  Map<String, dynamic> toMap() => {
    'kind': 'caption',
    'id': id,
    'enabled': enabled,
    'language': language,
    if (sourceLanguage != null) 'sourceLanguage': sourceLanguage,
    'style': style.toMap(),
    'captions': [for (final c in captions) c.toMap()],
  };

  factory CaptionTrack.fromMap(Map<dynamic, dynamic> m) => CaptionTrack(
    id: m['id'] as String? ?? 'caption',
    enabled: m['enabled'] as bool? ?? true,
    language: m['language'] as String? ?? 'en',
    sourceLanguage: m['sourceLanguage'] as String?,
    style: m['style'] is Map
        ? CaptionStyle.fromMap(m['style'] as Map)
        : const CaptionStyle(),
    captions: m['captions'] is List
        ? <Caption>[
            for (final e in m['captions'] as List)
              if (e is Map) Caption.fromMap(e),
          ]
        : const <Caption>[],
  );

  CaptionTrack copyWith({
    String? id,
    bool? enabled,
    String? language,
    String? sourceLanguage,
    CaptionStyle? style,
    List<Caption>? captions,
  }) => CaptionTrack(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    language: language ?? this.language,
    sourceLanguage: sourceLanguage ?? this.sourceLanguage,
    style: style ?? this.style,
    captions: captions ?? this.captions,
  );
}

/// User-facing voice-cleanup strength. The actual engine (RNNoise vs
/// DeepFilterNet) is chosen internally and never surfaced in the UI.
enum CleanupMode {
  light('light'),
  balanced('balanced'),
  highQuality('highQuality');

  const CleanupMode(this.wire);

  final String wire;

  static CleanupMode fromWire(Object? raw) => CleanupMode.values.firstWhere(
    (m) => m.wire == raw,
    orElse: () => CleanupMode.balanced,
  );
}

/// Mic noise-reduction settings (the strength; the engine is internal).
@immutable
class VoiceCleanup {
  const VoiceCleanup({this.enabled = false, this.mode = CleanupMode.balanced});

  final bool enabled;
  final CleanupMode mode;

  Map<String, dynamic> toMap() => {'enabled': enabled, 'mode': mode.wire};

  factory VoiceCleanup.fromMap(Map<dynamic, dynamic> m) => VoiceCleanup(
    enabled: m['enabled'] as bool? ?? false,
    mode: CleanupMode.fromWire(m['mode']),
  );
}

/// One audio source (mic or system) kept separate until export so cleanup and
/// gain can be applied to the mic without touching system audio.
@immutable
class AudioTrackSource {
  const AudioTrackSource({
    this.path,
    this.gainDb = 0,
    this.normalize = false,
    this.cleanup,
  });

  final String? path;
  final double gainDb;
  final bool normalize;
  final VoiceCleanup? cleanup;

  Map<String, dynamic> toMap() => {
    if (path != null) 'path': path,
    'gainDb': gainDb,
    'normalize': normalize,
    if (cleanup != null) 'voiceCleanup': cleanup!.toMap(),
  };

  factory AudioTrackSource.fromMap(Map<dynamic, dynamic> m) => AudioTrackSource(
    path: m['path'] as String?,
    gainDb: (m['gainDb'] as num?)?.toDouble() ?? 0,
    normalize: m['normalize'] as bool? ?? false,
    cleanup: m['voiceCleanup'] is Map
        ? VoiceCleanup.fromMap(m['voiceCleanup'] as Map)
        : null,
  );

  AudioTrackSource copyWith({
    String? path,
    double? gainDb,
    bool? normalize,
    VoiceCleanup? cleanup,
  }) => AudioTrackSource(
    path: path ?? this.path,
    gainDb: gainDb ?? this.gainDb,
    normalize: normalize ?? this.normalize,
    cleanup: cleanup ?? this.cleanup,
  );
}

/// Audio track — separated mic/system sources plus the master mix. Legacy
/// recordings without separated capture fall back to [mixedFallbackPath].
final class AudioTrack extends EditTrack {
  const AudioTrack({
    super.id = 'audio',
    super.enabled = true,
    this.mic,
    this.system,
    this.mixedFallbackPath,
    this.masterGainDb = 0,
    this.limiter = true,
  });

  final AudioTrackSource? mic;
  final AudioTrackSource? system;
  final String? mixedFallbackPath;
  final double masterGainDb;
  final bool limiter;

  @override
  TrackKind get kind => TrackKind.audio;

  @override
  Map<String, dynamic> toMap() => {
    'kind': 'audio',
    'id': id,
    'enabled': enabled,
    'sources': {
      if (mic != null) 'mic': mic!.toMap(),
      if (system != null) 'system': system!.toMap(),
    },
    'mixedFallbackPath': mixedFallbackPath,
    'mix': {'masterGainDb': masterGainDb, 'limiter': limiter},
  };

  factory AudioTrack.fromMap(Map<dynamic, dynamic> m) {
    final sources = m['sources'] is Map ? m['sources'] as Map : const {};
    final mix = m['mix'] is Map ? m['mix'] as Map : const {};
    return AudioTrack(
      id: m['id'] as String? ?? 'audio',
      enabled: m['enabled'] as bool? ?? true,
      mic: sources['mic'] is Map
          ? AudioTrackSource.fromMap(sources['mic'] as Map)
          : null,
      system: sources['system'] is Map
          ? AudioTrackSource.fromMap(sources['system'] as Map)
          : null,
      mixedFallbackPath: m['mixedFallbackPath'] as String?,
      masterGainDb: (mix['masterGainDb'] as num?)?.toDouble() ?? 0,
      limiter: mix['limiter'] as bool? ?? true,
    );
  }

  AudioTrack copyWith({
    String? id,
    bool? enabled,
    AudioTrackSource? mic,
    AudioTrackSource? system,
    String? mixedFallbackPath,
    double? masterGainDb,
    bool? limiter,
  }) => AudioTrack(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    mic: mic ?? this.mic,
    system: system ?? this.system,
    mixedFallbackPath: mixedFallbackPath ?? this.mixedFallbackPath,
    masterGainDb: masterGainDb ?? this.masterGainDb,
    limiter: limiter ?? this.limiter,
  );
}
