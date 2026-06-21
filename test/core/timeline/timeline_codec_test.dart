import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/codec/timeline_codec.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';

/// A timeline exercising every track type, nested lists, optional fields, and a
/// fixed-target zoom segment.
Timeline _richTimeline() => Timeline(
  durationMs: 60000,
  grade: const ColorGrade(
    autoEnabled: true,
    exposure: 0.2,
    contrast: -0.1,
    saturation: 0.3,
    temperature: 0.05,
    tint: -0.02,
  ),
  tracks: const [
    ZoomTrack(
      auto: [ZoomSegment(id: 'auto_0', startMs: 1000, endMs: 2000)],
      manual: [
        ZoomSegment(
          id: 'm1',
          startMs: 3000,
          endMs: 4000,
          source: 'manual',
          baseId: 'auto_0',
          focusMode: ZoomFocusMode.fixedTarget,
          fixedTarget: NormalizedPoint(0.4, 0.6),
        ),
      ],
    ),
    ClipTrack(
      clips: [
        Clip(id: 'c1', sourceInMs: 0, sourceOutMs: 5000, timelineStartMs: 0),
        Clip(
          id: 'c2',
          sourceInMs: 6000,
          sourceOutMs: 8000,
          timelineStartMs: 5000,
          enabled: false,
        ),
      ],
    ),
    AudioTrack(
      mic: AudioTrackSource(
        path: 'capture/mic.wav',
        gainDb: 3,
        normalize: true,
        cleanup: VoiceCleanup(enabled: true, mode: CleanupMode.highQuality),
      ),
      system: AudioTrackSource(path: 'capture/system.wav', gainDb: -2),
      masterGainDb: 1.5,
      limiter: true,
    ),
    CaptionTrack(
      language: 'en',
      sourceLanguage: 'es',
      captions: [
        Caption(
          id: 'cap1',
          startMs: 1000,
          endMs: 2500,
          text: 'hello',
          words: [CaptionWord(text: 'hello', startMs: 1000, endMs: 2500)],
          translatedText: 'hola',
        ),
      ],
    ),
  ],
);

void main() {
  const codec = TimelineCodec();

  group('TimelineCodec round-trip', () {
    test('encode -> decode -> encode is stable for a rich timeline', () {
      final original = _richTimeline();
      final encoded = codec.encode(original);

      final reencoded = codec.encode(codec.decode(encoded));

      expect(reencoded, encoded);
    });

    test('JSON string round-trips losslessly', () {
      final original = _richTimeline();
      final encoded = codec.encode(original);

      final viaJson = codec.decodeJson(codec.encodeJson(original));

      expect(codec.encode(viaJson), encoded);
    });

    test('preserves values across every track type', () {
      final decoded = codec.decode(codec.encode(_richTimeline()));

      expect(decoded.durationMs, 60000);
      expect(decoded.schemaVersion, kTimelineSchemaVersion);
      expect(decoded.grade.autoEnabled, isTrue);
      expect(decoded.grade.exposure, 0.2);

      final zoom = decoded.trackOfType<ZoomTrack>()!;
      expect(zoom.auto.single.id, 'auto_0');
      expect(zoom.manual.single.focusMode, ZoomFocusMode.fixedTarget);
      expect(zoom.manual.single.fixedTarget, const NormalizedPoint(0.4, 0.6));
      expect(zoom.manual.single.baseId, 'auto_0');

      final clips = decoded.trackOfType<ClipTrack>()!;
      expect(clips.clips, hasLength(2));
      expect(clips.clips[1].enabled, isFalse);
      expect(clips.clips[1].timelineStartMs, 5000);

      final audio = decoded.trackOfType<AudioTrack>()!;
      expect(audio.mic!.path, 'capture/mic.wav');
      expect(audio.mic!.normalize, isTrue);
      expect(audio.mic!.cleanup!.mode, CleanupMode.highQuality);
      expect(audio.system!.gainDb, -2);
      expect(audio.system!.cleanup, isNull);
      expect(audio.masterGainDb, 1.5);

      final caption = decoded.trackOfType<CaptionTrack>()!;
      expect(caption.sourceLanguage, 'es');
      expect(caption.captions.single.translatedText, 'hola');
      expect(caption.captions.single.words.single.text, 'hello');
    });
  });

  group('TimelineCodec resilience', () {
    test('an unknown track kind is dropped without crashing', () {
      final raw = {
        'schemaVersion': 2,
        'timeline': {
          'durationMs': 1000,
          'grade': const ColorGrade().toMap(),
          'tracks': [
            {'kind': 'zoom', 'auto': [], 'manual': []},
            {'kind': 'frobnicate', 'foo': 1},
          ],
        },
      };

      final decoded = codec.decode(raw);

      expect(decoded.tracks, hasLength(1));
      expect(decoded.tracks.single, isA<ZoomTrack>());
    });

    test('a missing timeline body yields an empty timeline', () {
      expect(codec.decode(const {}).tracks, isEmpty);
      expect(codec.decode(const {}).durationMs, 0);
      expect(codec.decode(const {'schemaVersion': 2}).tracks, isEmpty);
    });

    test('missing fields fall back to defaults', () {
      final decoded = codec.decode({
        'timeline': {
          'tracks': [
            {'kind': 'audio'},
            {'kind': 'caption'},
          ],
        },
      });

      final audio = decoded.trackOfType<AudioTrack>()!;
      expect(audio.mic, isNull);
      expect(audio.system, isNull);
      expect(audio.limiter, isTrue);

      final caption = decoded.trackOfType<CaptionTrack>()!;
      expect(caption.language, 'en');
      expect(caption.captions, isEmpty);
    });

    test('an empty timeline round-trips', () {
      const empty = Timeline();
      expect(
        codec.encode(codec.decode(codec.encode(empty))),
        codec.encode(empty),
      );
    });
  });
}
