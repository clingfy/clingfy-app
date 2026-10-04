import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/timeline/commands/set_audio_command.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

void main() {
  group('SetAudioCommand', () {
    test('apply sets the next track, revert restores the previous', () {
      var audio = const AudioTrack(mic: AudioTrackSource(gainDb: 3));
      final cmd = SetAudioCommand(
        get: () => audio,
        set: (a) => audio = a,
        next: const AudioTrack(mic: AudioTrackSource(gainDb: 12)),
      );

      cmd.apply();
      expect(audio.mic!.gainDb, 12);

      cmd.revert();
      expect(audio.mic!.gainDb, 3);
    });

    test('reports the audio domain', () {
      var audio = const AudioTrack();
      final cmd = SetAudioCommand(
        get: () => audio,
        set: (a) => audio = a,
        next: const AudioTrack(masterVolumePercent: 50),
      );
      expect(cmd.domain, EditDomain.audio);
    });

    test('round-trips through EditSession undo/redo and flushes audio', () {
      var audio = const AudioTrack();
      final flushed = <Set<EditDomain>>[];
      final session = EditSession(onFlush: flushed.add);

      session.execute(
        SetAudioCommand(
          get: () => audio,
          set: (a) => audio = a,
          next: const AudioTrack(masterVolumePercent: 40),
        ),
      );
      expect(audio.masterVolumePercent, 40);
      expect(flushed.last, contains(EditDomain.audio));

      session.undo();
      expect(audio.masterVolumePercent, 100);

      session.redo();
      expect(audio.masterVolumePercent, 40);
    });

    /// The gain slider and the cleanup toggle live on one panel and are one
    /// value object, so a gesture touching both must undo as one step rather
    /// than leaving the user to press undo twice for a single action.
    test('one command covers gain, volume and cleanup together', () {
      var audio = const AudioTrack();
      final session = EditSession();

      session.execute(
        SetAudioCommand(
          get: () => audio,
          set: (a) => audio = a,
          next: const AudioTrack(
            mic: AudioTrackSource(
              gainDb: 6,
              cleanup: VoiceCleanup(enabled: true, mode: CleanupMode.light),
            ),
            masterVolumePercent: 80,
          ),
        ),
      );

      session.undo();
      expect(audio.mic, isNull);
      expect(audio.masterVolumePercent, 100);
      expect(session.canUndo, isFalse, reason: 'it was a single entry');
    });
  });
}
