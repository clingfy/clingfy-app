import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Where a project's subtitles go.
///
/// The destination is a sticky global on purpose — someone who always burns in
/// for social should not re-pick it every recording. What was missing was any
/// memory of a DEVIATION: switching recording B to sidecar silently changed
/// what recording A exported, because A had no opinion of its own to consult.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const screenRecorderChannel = MethodChannel('com.clingfy/screen_recorder');

  late Directory tempDir;

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = Directory.systemTemp.createTempSync('clingfy_dest_test');
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    await PostStateStore.settled();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// One controller, so switching projects goes through the real attach path
  /// rather than a fresh object that could not leak state even if we wanted it
  /// to.
  Future<PostProcessingController> controllerWith(SubtitleMode global) async {
    SharedPreferences.setMockInitialValues({
      'postSubtitleMode': global.wireValue,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return {
            'cues': [
              {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
            ],
            'language': null,
          };
        default:
          return null;
      }
    });

    final bridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: bridge);
    await settings.loadPreferences();
    final player = PlayerController(nativeBridge: bridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: bridge,
    );
    addTearDown(() {
      post.dispose();
      player.dispose();
      settings.dispose();
    });
    return post;
  }

  Future<void> open(PostProcessingController post, String name) async {
    final dir = Directory('${tempDir.path}/$name')..createSync();
    post.attachToRecording(sessionId: name, projectPath: dir.path);
    await pumpEventQueue();
  }

  SubtitleMode? storedDestination(String name) => PostStateStore.load(
    '${tempDir.path}/$name',
  ).trackOfType<CaptionTrack>()?.destination;

  test('switching one recording does not change another', () async {
    // The scenario from #455, start to finish.
    final post = await controllerWith(SubtitleMode.burnIn);

    // A is transcribed and left on the default.
    await open(post, 'A');
    await post.generateCaptions();
    await PostStateStore.settled();
    expect(post.exportSubtitleMode, SubtitleMode.burnIn);

    // B is transcribed and switched to sidecar, which also moves the global.
    await open(post, 'B');
    await post.generateCaptions();
    await PostStateStore.settled();
    post.setSubtitleMode(SubtitleMode.sidecar);
    await PostStateStore.settled();
    expect(post.exportSubtitleMode, SubtitleMode.sidecar);

    // Re-opening A must still burn in. Nothing about A changed.
    await open(post, 'A');
    expect(
      post.exportSubtitleMode,
      SubtitleMode.burnIn,
      reason:
          'A was transcribed while the default was burn-in and the user '
          'never changed it there; a switch made on B must not reach it',
    );
  });

  test('a transcript pins the preference it was made under', () async {
    final post = await controllerWith(SubtitleMode.both);
    await open(post, 'A');
    await post.generateCaptions();
    await PostStateStore.settled();

    expect(
      storedDestination('A'),
      SubtitleMode.both,
      reason:
          'seeded at generate time, which is the one moment the right '
          'value is unambiguous',
    );
  });

  test(
    'an explicit switch is written to the project, not just prefs',
    () async {
      final post = await controllerWith(SubtitleMode.burnIn);
      await open(post, 'A');
      await post.generateCaptions();
      await PostStateStore.settled();

      post.setSubtitleMode(SubtitleMode.sidecar);
      await PostStateStore.settled();

      expect(storedDestination('A'), SubtitleMode.sidecar);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getString('postSubtitleMode'),
        SubtitleMode.sidecar.wireValue,
        reason:
            'the global stays the sticky default that seeds the NEXT '
            'recording — only the per-project memory is new',
      );
    },
  );

  test('a project with no transcript still follows the preference', () async {
    final post = await controllerWith(SubtitleMode.sidecar);
    await open(post, 'A');

    expect(
      post.exportSubtitleMode,
      SubtitleMode.none,
      reason: 'no cues means no subtitles regardless of destination',
    );
    expect(
      storedDestination('A'),
      isNull,
      reason: 'nothing to pin a destination onto until a transcript exists',
    );
  });

  test('a project pinned away from the global can be set back to it', () async {
    // The guard used to compare the new value against the PREFERENCE. So when
    // a project was pinned to sidecar while the global said burn-in, choosing
    // burn-in here matched the preference, early-returned, and left the
    // project on sidecar — the control showed burn-in and the export did not
    // honour it. The comparison has to be against the effective mode.
    final post = await controllerWith(SubtitleMode.burnIn);
    await open(post, 'A');
    await post.generateCaptions();
    await PostStateStore.settled();

    // Pin A away from the global directly, so the preference stays burn-in.
    await PostStateStore.update('${tempDir.path}/A', (state) {
      final track = state.trackOfType<CaptionTrack>()!;
      return state.withTrack(track.copyWith(destination: SubtitleMode.sidecar));
    });
    await PostStateStore.settled();
    await open(post, 'A');
    expect(post.exportSubtitleMode, SubtitleMode.sidecar);

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(
      prefs.getString('postSubtitleMode'),
      SubtitleMode.burnIn.wireValue,
      reason: 'the setup only works if the global still disagrees',
    );

    post.setSubtitleMode(SubtitleMode.burnIn);
    await PostStateStore.settled();

    expect(post.exportSubtitleMode, SubtitleMode.burnIn);
    expect(
      storedDestination('A'),
      SubtitleMode.burnIn,
      reason:
          'the override has to move, not be skipped because the new value '
          'happens to equal the global',
    );
  });
}
