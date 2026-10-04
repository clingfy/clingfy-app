import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Audio settings belong to the recording, through the real controller wiring.
///
/// The bug this closes: gain, master volume and voice cleanup lived only in
/// app-wide SharedPreferences, and `_resetForNewRecording` re-seeded them from
/// those globals every time a project opened. Boosting the mic +12 dB on one
/// take therefore changed what every other take previewed and exported, and
/// there was no way to undo any of it.
///
/// `audio_track_persistence_test.dart` covers the storage layer on its own;
/// this closes the live seam only the running controller exercises.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory projectA;
  late Directory projectB;

  setUp(() async {
    await installCommonNativeMocks();
    projectA = await Directory.systemTemp.createTemp('clingfy_audio_a_');
    projectB = await Directory.systemTemp.createTemp('clingfy_audio_b_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'processVideo':
          return '${projectA.path}${Platform.pathSeparator}preview.mov';
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    await PostStateStore.settled();
    if (await projectA.exists()) await projectA.delete(recursive: true);
    if (await projectB.exists()) await projectB.delete(recursive: true);
  });

  Future<PostProcessingController> attach(String projectPath) async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final player = PlayerController(nativeBridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    addTearDown(() {
      post.dispose();
      player.dispose();
      settings.dispose();
    });
    post.attachToRecording(sessionId: 'rec_audio', projectPath: projectPath);
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return post;
  }

  test('a committed gain change lands in the project bundle', () async {
    final post = await attach(projectA.path);
    post.setAudioGainDb(9);
    post.setAudioGainDbEnd(9);
    await PostStateStore.settled();

    final stored = PostStateStore.load(projectA.path).trackOfType<AudioTrack>();
    expect(stored, isNotNull, reason: 'the commit must write an audio track');
    expect(stored!.mic!.gainDb, 9);
  });

  test(
    'reopening a recording restores ITS gain, not the last one used',
    () async {
      final a = await attach(projectA.path);
      a.setAudioGainDb(12);
      a.setAudioGainDbEnd(12);
      await PostStateStore.settled();

      // A second recording, opened after A was left at +12 dB. Before this fix
      // the prefs seed made B read 12 too.
      final b = await attach(projectB.path);
      expect(
        b.audioGainDb,
        12,
        reason: 'prefs still SEED a recording that has never stored audio',
      );
      b.setAudioGainDb(0);
      b.setAudioGainDbEnd(0);
      await PostStateStore.settled();

      // Now reopen A. Its own stored +12 must win over B's freshly-saved 0.
      final reopened = await attach(projectA.path);
      expect(
        reopened.audioGainDb,
        12,
        reason: 'A stored 12; editing B must not have reached into it',
      );
    },
  );

  test('master volume and voice cleanup persist per recording too', () async {
    final post = await attach(projectA.path);
    post.setAudioVolumePercent(60);
    post.setAudioVolumePercentEnd(60);
    post.setVoiceCleanup(
      const VoiceCleanup(enabled: true, mode: CleanupMode.light),
    );
    await PostStateStore.settled();

    final stored = PostStateStore.load(
      projectA.path,
    ).trackOfType<AudioTrack>()!;
    expect(stored.masterVolumePercent, 60);
    expect(stored.mic!.cleanup!.enabled, isTrue);
    expect(stored.mic!.cleanup!.mode, CleanupMode.light);

    final reopened = await attach(projectA.path);
    expect(reopened.audioVolumePercent, 60);
    expect(reopened.voiceCleanup.mode, CleanupMode.light);
  });

  group('undo/redo', () {
    test('undo steps a committed gain change back', () async {
      final post = await attach(projectA.path);
      post.setAudioGainDb(6);
      post.setAudioGainDbEnd(6);
      expect(post.canUndoAudio, isTrue);

      post.undoAudio();
      expect(post.audioGainDb, 0);

      post.redoAudio();
      expect(post.audioGainDb, 6);
    });

    /// A drag emits many ticks and one `...End`. All of it is one action to
    /// the user, so it must cost exactly one press of undo.
    test('a whole drag collapses into one history entry', () async {
      final post = await attach(projectA.path);
      for (final v in [2.0, 4.0, 6.0, 8.0]) {
        post.setAudioGainDb(v);
      }
      post.setAudioGainDbEnd(8);

      post.undoAudio();
      expect(post.audioGainDb, 0, reason: 'one undo must clear the whole drag');
      expect(post.canUndoAudio, isFalse);
    });

    /// A drag that lands back where it started changed nothing, so it must not
    /// occupy a slot in the history. This is the guard that needs
    /// `AudioTrack.operator==` to exist.
    test('a drag that returns to its start records nothing', () async {
      final post = await attach(projectA.path);
      post.setAudioGainDb(5);
      post.setAudioGainDb(0);
      post.setAudioGainDbEnd(0);
      expect(post.canUndoAudio, isFalse);
    });

    test('history does not follow the user to another recording', () async {
      final a = await attach(projectA.path);
      a.setAudioGainDb(7);
      a.setAudioGainDbEnd(7);
      expect(a.canUndoAudio, isTrue);
      await PostStateStore.settled();

      final b = await attach(projectB.path);
      expect(
        b.canUndoAudio,
        isFalse,
        reason: "undo must never reach into another recording's audio",
      );
    });
  });
}
