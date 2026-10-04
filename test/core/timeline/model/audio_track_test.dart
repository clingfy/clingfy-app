import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

void main() {
  /// Value equality is not decoration here. Every audio setter guards on
  /// `if (next == current) return;` and the controller compares a pre-gesture
  /// snapshot against the current track to decide whether a drag earned a
  /// history entry. With the default identity equality both comparisons are
  /// always false, so a drag that landed back where it started would still
  /// push an undo entry and a disk write.
  group('AudioTrackSource equality', () {
    test('two sources with the same values are equal', () {
      const a = AudioTrackSource(
        path: 'capture/mic.wav',
        gainDb: 6,
        normalize: true,
        cleanup: VoiceCleanup(enabled: true, mode: CleanupMode.light),
      );
      const b = AudioTrackSource(
        path: 'capture/mic.wav',
        gainDb: 6,
        normalize: true,
        cleanup: VoiceCleanup(enabled: true, mode: CleanupMode.light),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('every field participates', () {
      const base = AudioTrackSource(path: 'p', gainDb: 1, normalize: false);
      expect(base, isNot(equals(base.copyWith(path: 'q'))));
      expect(base, isNot(equals(base.copyWith(gainDb: 2))));
      expect(base, isNot(equals(base.copyWith(normalize: true))));
      expect(base, isNot(equals(base.copyWith(cleanup: const VoiceCleanup()))));
    });
  });

  group('AudioTrack equality', () {
    test('two tracks with the same values are equal', () {
      const a = AudioTrack(
        mic: AudioTrackSource(gainDb: 3),
        masterVolumePercent: 80,
      );
      const b = AudioTrack(
        mic: AudioTrackSource(gainDb: 3),
        masterVolumePercent: 80,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('every field participates', () {
      const base = AudioTrack(mic: AudioTrackSource(gainDb: 1));
      expect(base, isNot(equals(base.copyWith(enabled: false))));
      expect(base, isNot(equals(base.copyWith(id: 'other'))));
      expect(
        base,
        isNot(equals(base.copyWith(mic: const AudioTrackSource(gainDb: 2)))),
      );
      expect(
        base,
        isNot(equals(base.copyWith(system: const AudioTrackSource()))),
      );
      expect(base, isNot(equals(base.copyWith(mixedFallbackPath: 'x.m4a'))));
      expect(base, isNot(equals(base.copyWith(masterGainDb: 1))));
      expect(base, isNot(equals(base.copyWith(masterVolumePercent: 50))));
      expect(base, isNot(equals(base.copyWith(limiter: false))));
    });
  });

  group('masterVolumePercent', () {
    test('round-trips through toMap/fromMap', () {
      const track = AudioTrack(masterVolumePercent: 42.5);
      final decoded = AudioTrack.fromMap(track.toMap());
      expect(decoded.masterVolumePercent, 42.5);
    });

    /// The field was added after the rest of the class, so a `post/state.json`
    /// written by any earlier build has no `masterVolumePercent` in its `mix`
    /// block. Unity is what those recordings actually played at, so defaulting
    /// to 100 is what keeps them sounding the same — this is the reason the
    /// addition needed no schema bump.
    test('an older file with no masterVolumePercent decodes to unity', () {
      final decoded = AudioTrack.fromMap({
        'kind': 'audio',
        'sources': {
          'mic': {'path': 'capture/mic.wav', 'gainDb': 6.0},
        },
        'mix': {'masterGainDb': 0.0, 'limiter': true},
      });
      expect(decoded.masterVolumePercent, 100);
      expect(decoded.mic!.gainDb, 6.0, reason: 'the rest still decodes');
    });
  });
}
