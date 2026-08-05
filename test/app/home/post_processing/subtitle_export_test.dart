import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

/// What the export carries, and what lands next to the file afterwards.
///
/// Burn-in is native's job (it owns the frames); the sidecar is written here,
/// from the same cue list, once native reports where the video actually landed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<MethodCall> calls;
  late String exportedPath;

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = await Directory.systemTemp.createTemp('clingfy_subs_test');
    exportedPath = '${tempDir.path}/My Recording.mp4';
    calls = [];
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<PostProcessingController> createController({
    required SubtitleMode mode,
    List<Map<String, Object?>> transcript = const [
      {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
    ],
    String? exportReturns,
  }) async {
    SharedPreferences.setMockInitialValues({
      'postSubtitleMode': mode.wireValue,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return transcript;
        case 'exportVideo':
          return exportReturns ?? exportedPath;
        case 'processVideo':
          return '/tmp/preview.mov';
        default:
          return null;
      }
    });

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
    post.attachToRecording(
      sessionId: 'rec_export',
      projectPath: '/tmp/original.clingfyproj',
    );
    await pumpEventQueue();
    return post;
  }

  /// Runs the private sidecar step the way a completed export does, without a
  /// save dialog or a real render.
  Future<void> exportWith(
    PostProcessingController post,
    SubtitleMode mode, {
    String? outputPath,
  }) async {
    await post.writeSubtitleSidecars(outputPath ?? exportedPath, mode);
  }

  File srt([String? path]) =>
      File((path ?? exportedPath).replaceAll('.mp4', '.srt'));
  File vtt([String? path]) =>
      File((path ?? exportedPath).replaceAll('.mp4', '.vtt'));

  // ---- Sidecar output ---------------------------------------------------

  test('sidecar mode writes both formats beside the video', () async {
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().existsSync(), isTrue);
    expect(vtt().existsSync(), isTrue);
    expect(srt().readAsStringSync(), contains('hello there'));
    expect(vtt().readAsStringSync(), startsWith('WEBVTT'));
  });

  test('both mode also writes the sidecar', () async {
    final post = await createController(mode: SubtitleMode.both);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.both);

    expect(srt().existsSync(), isTrue);
  });

  test('burn-in alone writes no files', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.burnIn);

    expect(srt().existsSync(), isFalse);
    expect(vtt().existsSync(), isFalse);
  });

  test('off writes nothing even with a transcript in hand', () async {
    final post = await createController(mode: SubtitleMode.none);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.none);

    expect(srt().existsSync(), isFalse);
  });

  test('no cues means no empty sidecar files', () async {
    // An empty .srt beside a video looks like a broken subtitle track.
    final post = await createController(mode: SubtitleMode.sidecar);

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().existsSync(), isFalse);
    expect(vtt().existsSync(), isFalse);
  });

  test('edits are what get written, not the raw transcript', () async {
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();
    post.updateCaptionText('c1', 'Clingfy');

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().readAsStringSync(), contains('Clingfy'));
    expect(srt().readAsStringSync(), isNot(contains('hello there')));
  });

  test('the sidecar is written as UTF-8 with no BOM', () async {
    final post = await createController(
      mode: SubtitleMode.sidecar,
      transcript: const [
        {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'مرحبا'},
      ],
    );
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar);

    final bytes = srt().readAsBytesSync();
    // WebVTT requires UTF-8 and SubRip declares no encoding at all, so a BOM
    // is at best ignored and at worst parsed as part of the first cue number.
    expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
    expect(srt().readAsStringSync(), contains('مرحبا'));
  });

  // ---- Path handling ----------------------------------------------------

  test('a dot in a folder name does not move the sidecar', () async {
    // Cutting at the last dot in the whole path would write the sidecar as a
    // sibling of the directory instead of beside the video.
    final dotted = Directory('${tempDir.path}/My.Videos')
      ..createSync(recursive: true);
    final video = '${dotted.path}/clip';

    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();
    await exportWith(post, SubtitleMode.sidecar, outputPath: video);

    expect(File('$video.srt').existsSync(), isTrue);
    expect(File('${tempDir.path}/My.srt').existsSync(), isFalse);
  });

  test('an extensionless output still gets its sidecars', () async {
    final video = '${tempDir.path}/clip';
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar, outputPath: video);

    expect(File('$video.srt').existsSync(), isTrue);
  });

  test('a sidecar failure does not throw at the export', () async {
    // The video is already on disk. Re-running a whole render to retry two
    // small text files would be far worse than a missing subtitle track.
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await expectLater(
      exportWith(
        post,
        SubtitleMode.sidecar,
        outputPath: '${tempDir.path}/no such dir/clip.mp4',
      ),
      completes,
    );
  });

  // ---- Export payload ---------------------------------------------------

  test('the payload always states the destination', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    expect(post.captions, isNotEmpty);
    // The mode is read from settings at export time, so what the panel shows
    // and what native is told cannot drift.
    expect(post.exportSubtitleMode, SubtitleMode.burnIn);
  });

  test(
    'no transcript means the destination is off regardless of preference',
    () async {
      // A stored "burn in" must not put native into a caption path with an
      // empty track.
      final post = await createController(mode: SubtitleMode.burnIn);

      expect(post.captions, isEmpty);
      expect(post.exportSubtitleMode, SubtitleMode.none);
    },
  );
}
