import 'dart:io';

import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audio settings belong to the recording, not to the app.
///
/// Until this landed, gain, master volume and voice cleanup lived only in
/// app-wide SharedPreferences and were re-seeded onto every project the moment
/// it opened. Two recordings could not hold different audio settings at all:
/// boosting the mic on today's take silently changed what last week's take
/// exported. These pin the storage half of the fix.
void main() {
  late Directory project;
  late Directory other;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('clingfy_audio_state');
    other = await Directory.systemTemp.createTemp('clingfy_audio_state_b');
  });

  tearDown(() async {
    await PostStateStore.settled();
    if (project.existsSync()) project.deleteSync(recursive: true);
    if (other.existsSync()) other.deleteSync(recursive: true);
  });

  test('an audio track survives a save/load round trip', () async {
    await PostStateStore.save(
      project.path,
      const Timeline(
        tracks: [
          AudioTrack(
            mic: AudioTrackSource(
              path: 'capture/mic.wav',
              gainDb: 9,
              cleanup: VoiceCleanup(enabled: true, mode: CleanupMode.light),
            ),
            masterVolumePercent: 65,
          ),
        ],
      ),
    );

    final audio = PostStateStore.load(project.path).trackOfType<AudioTrack>()!;
    expect(audio.mic!.gainDb, 9);
    expect(audio.mic!.cleanup!.enabled, isTrue);
    expect(audio.mic!.cleanup!.mode, CleanupMode.light);
    expect(audio.masterVolumePercent, 65);
  });

  test(
    'two recordings hold different audio settings at the same time',
    () async {
      await PostStateStore.save(
        project.path,
        const Timeline(tracks: [AudioTrack(mic: AudioTrackSource(gainDb: 12))]),
      );
      await PostStateStore.save(
        other.path,
        const Timeline(tracks: [AudioTrack(mic: AudioTrackSource(gainDb: 0))]),
      );

      expect(
        PostStateStore.load(
          project.path,
        ).trackOfType<AudioTrack>()!.mic!.gainDb,
        12,
      );
      expect(
        PostStateStore.load(other.path).trackOfType<AudioTrack>()!.mic!.gainDb,
        0,
        reason: 'saving one project must not reach into another',
      );
    },
  );

  /// `withTrack` is what the controller uses to persist. It must replace the
  /// audio track in place rather than appending a second one, or every commit
  /// would grow the file and `trackOfType` would start returning a stale entry.
  test('withTrack replaces the audio track instead of appending', () async {
    await PostStateStore.save(
      project.path,
      const Timeline(tracks: [AudioTrack(mic: AudioTrackSource(gainDb: 3))]),
    );

    await PostStateStore.update(
      project.path,
      (state) =>
          state.withTrack(const AudioTrack(mic: AudioTrackSource(gainDb: 7))),
    );

    final loaded = PostStateStore.load(project.path);
    expect(loaded.tracks.whereType<AudioTrack>().length, 1);
    expect(loaded.trackOfType<AudioTrack>()!.mic!.gainDb, 7);
  });

  /// An audio commit shares `post/state.json` with captions, clips and the
  /// canvas. Writing audio must not drop what the other editors stored.
  test('persisting audio leaves the other tracks alone', () async {
    await PostStateStore.save(
      project.path,
      const Timeline(
        tracks: [
          CaptionTrack(
            captions: [Caption(id: 'a', startMs: 0, endMs: 900, text: 'hi')],
          ),
        ],
      ),
    );

    await PostStateStore.update(
      project.path,
      (state) =>
          state.withTrack(const AudioTrack(mic: AudioTrackSource(gainDb: 4))),
    );

    final loaded = PostStateStore.load(project.path);
    expect(loaded.trackOfType<AudioTrack>()!.mic!.gainDb, 4);
    expect(
      loaded.trackOfType<CaptionTrack>()!.captions.single.text,
      'hi',
      reason: 'the caption track shares the file and must survive',
    );
  });

  /// A recording made before this change has no audio track at all. It must
  /// open cleanly, so the controller falls back to the app preference as the
  /// seed rather than finding a half-built track.
  test('a project with no audio track loads as null, not as a default', () {
    expect(PostStateStore.load(project.path).trackOfType<AudioTrack>(), isNull);
  });
}
