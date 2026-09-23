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
      expect(
        caption.language,
        isNull,
        reason:
            'a missing language is unknown, not English -- defaulting it here '
            'is what put a false claim on every saved track',
      );
      expect(caption.captions, isEmpty);
    });

    test('a cue with no id refuses the whole caption track', () {
      // The edit path addresses cues by id and the panel keys rows by id, so
      // an idless cue cannot be corrected. The legacy loader refused such a
      // file outright; that check was lost when captions moved into the
      // unified state and is restored here.
      final track = CaptionTrack.fromMap({
        'kind': 'caption',
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'first'},
          {'startMs': 1000, 'endMs': 2000, 'text': 'no id'},
        ],
      });
      expect(track.captions, isEmpty);
    });

    test('duplicate cue ids refuse the whole caption track', () {
      // Correcting the second row would silently rewrite the first, and two
      // identical keys as siblings trip Flutter's duplicate-key assertion.
      final track = CaptionTrack.fromMap({
        'kind': 'caption',
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'first'},
          {'id': 'c1', 'startMs': 1000, 'endMs': 2000, 'text': 'second'},
        ],
      });
      expect(track.captions, isEmpty);
    });

    test('a refused cue list does not take the rest of the track with it', () {
      // Style and language still decode: the track is kept, its cues are not,
      // so a later regeneration writes into the settings already on disk.
      final track = CaptionTrack.fromMap({
        'kind': 'caption',
        'language': 'ar',
        'enabled': false,
        'captions': [
          {'startMs': 0, 'endMs': 1000, 'text': 'no id'},
        ],
      });
      expect(track.captions, isEmpty);
      expect(track.language, 'ar');
      expect(track.enabled, isFalse);
    });

    test('well-formed cues decode unchanged', () {
      final track = CaptionTrack.fromMap({
        'kind': 'caption',
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'first'},
          {'id': 'c2', 'startMs': 1000, 'endMs': 2000, 'text': 'second'},
        ],
      });
      expect(track.captions.map((c) => c.text), ['first', 'second']);
    });

    test('an empty timeline round-trips', () {
      const empty = Timeline();
      expect(
        codec.encode(codec.decode(codec.encode(empty))),
        codec.encode(empty),
      );
    });
  });

  group('caption language across the schema bump', () {
    const codec = TimelineCodec();

    Map<String, dynamic> bundleAtVersion(int version, Object? language) => {
      'schemaVersion': version,
      'timeline': {
        'durationMs': 1000,
        'tracks': [
          {
            'kind': 'caption',
            'id': 'caption',
            'enabled': true,
            if (language != null) 'language': language,
            'captions': const <Map<String, dynamic>>[],
          },
        ],
      },
    };

    String? languageOf(Map<String, dynamic> bundle) =>
        codec.decode(bundle).trackOfType<CaptionTrack>()?.language;

    test("a v3 'en' is a default, not a detection, and reads as unknown", () {
      // Before the bump every track carried 'en' whether or not anything had
      // detected a language. By value it is indistinguishable from real
      // English; by provenance it is not, and the version is the only witness.
      expect(
        languageOf(bundleAtVersion(3, 'en')),
        isNull,
        reason:
            'trusting this would launder a constructor default into evidence, '
            'which is the defect the bump exists to end',
      );
    });

    test("a v4 'en' is a real detection and is kept", () {
      expect(
        languageOf(bundleAtVersion(4, 'en')),
        'en',
        reason: 'at this version nothing writes a language it did not detect',
      );
    });

    test('a non-English language is trusted at any version', () {
      // Nothing ever wrote a non-'en' default, so a v3 bundle carrying one was
      // hand-edited or written by another tool -- and it means what it says.
      expect(languageOf(bundleAtVersion(3, 'ar')), 'ar');
      expect(languageOf(bundleAtVersion(4, 'ar')), 'ar');
    });

    test('an absent language stays absent', () {
      expect(languageOf(bundleAtVersion(4, null)), isNull);
      expect(languageOf(bundleAtVersion(3, null)), isNull);
    });

    test('an unknown language is written as absent, not as a guess', () {
      final encoded = codec.encode(
        const Timeline(tracks: [CaptionTrack(captions: [])]),
      );
      final track =
          ((encoded['timeline'] as Map)['tracks'] as List).single as Map;
      expect(
        track.containsKey('language'),
        isFalse,
        reason:
            'writing a placeholder is how the false English got onto disk in '
            'the first place',
      );
    });

    test('a round trip through the current schema keeps a real language', () {
      final encoded = codec.encode(
        const Timeline(
          tracks: [CaptionTrack(captions: [], language: 'ro')],
        ),
      );
      expect(codec.decode(encoded).trackOfType<CaptionTrack>()?.language, 'ro');
    });
  });
}
