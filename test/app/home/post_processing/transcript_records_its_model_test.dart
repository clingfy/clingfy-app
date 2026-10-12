import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Which model produced a transcript.
///
/// Recorded because translation needs it and cannot recover it later: Whisper
/// translates only to English and `large-v3-turbo` cannot translate at all, so
/// "can this transcript be translated" is a question about the model that made
/// it. A transcript from last month has no other record of that.
///
/// Reported by NATIVE rather than chosen by Dart, which is the part worth
/// getting right. Dart sends no variant, so this side does not know what the
/// engine loaded — and once the variant is selectable, "what was asked for" and
/// "what was used" can differ. The useful fact is what was used.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const screenRecorderChannel = MethodChannel('com.clingfy/screen_recorder');
  const variant = 'openai_whisper-large-v3-v20240930_626MB';

  late Directory tempDir;

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = Directory.systemTemp.createTempSync('clingfy_model_record');
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    await PostStateStore.settled();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// [reportedModel] null means native answered without the key, which is what
  /// an older binary and a platform without the engine both do.
  Future<PostProcessingController> controllerReporting(
    String? reportedModel,
  ) async {
    SharedPreferences.setMockInitialValues({});
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
            'language': 'en',
            if (reportedModel != null) 'transcribedBy': reportedModel,
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

  CaptionTrack? storedTrack(String name) =>
      PostStateStore.load('${tempDir.path}/$name').trackOfType<CaptionTrack>();

  test('a transcription records the model native reported', () async {
    final post = await controllerReporting(variant);
    await open(post, 'A');
    await post.generateCaptions();
    await PostStateStore.settled();

    expect(storedTrack('A')?.transcribedBy, variant);
  });

  /// Absent is a real state, not a placeholder. Every transcript made before
  /// this field existed genuinely has no record, and writing today's default
  /// into them would be the same lie `language` already had to be fixed for.
  test('a platform that reports no model records none', () async {
    final post = await controllerReporting(null);
    await open(post, 'B');
    await post.generateCaptions();
    await PostStateStore.settled();

    final track = storedTrack('B');
    expect(track, isNotNull, reason: 'the cues are still stored');
    expect(track!.captions, isNotEmpty);
    expect(
      track.transcribedBy,
      isNull,
      reason: 'unknown must stay unknown rather than be guessed',
    );
  });

  /// THE ONE THAT MATTERS for correctness over time. A correction re-persists
  /// the same track and knows nothing about the model; if that blanked the
  /// field, a user editing one word would erase the only record of what
  /// produced the transcript, and translation would lose its input.
  test('correcting a cue does not erase the recorded model', () async {
    final post = await controllerReporting(variant);
    await open(post, 'C');
    await post.generateCaptions();
    await PostStateStore.settled();
    expect(storedTrack('C')?.transcribedBy, variant);

    final cueId = post.captions.first.id;
    post.updateCaptionText(cueId, 'corrected text');
    await PostStateStore.settled();

    final track = storedTrack('C');
    expect(
      track?.captions.first.text,
      'corrected text',
      reason: 'the correction landed',
    );
    expect(
      track?.transcribedBy,
      variant,
      reason: 'and it did not take the model record with it',
    );
  });

  group('serialization', () {
    test('round-trips through the codec', () {
      const track = CaptionTrack(
        captions: [Caption(id: 'a', startMs: 0, endMs: 10, text: 'x')],
        transcribedBy: variant,
      );
      expect(CaptionTrack.fromMap(track.toMap()).transcribedBy, variant);
    });

    /// Additive: a bundle written before this field existed has no key, and
    /// must decode to null rather than fail or invent a value. That is why
    /// this needed no schema bump.
    test('a track written before the field existed decodes to null', () {
      final decoded = CaptionTrack.fromMap({
        'kind': 'caption',
        'id': 'caption',
        'enabled': true,
        'language': 'en',
        'captions': [
          {'id': 'a', 'startMs': 0, 'endMs': 10, 'text': 'x'},
        ],
      });
      expect(decoded.transcribedBy, isNull);
      expect(decoded.captions, hasLength(1), reason: 'the rest still decodes');
    });

    test('absent is written as absent, not as an empty string', () {
      const track = CaptionTrack(captions: []);
      expect(track.toMap().containsKey('transcribedBy'), isFalse);
    });

    test('copyWith leaves it alone when nothing supplies one', () {
      const track = CaptionTrack(transcribedBy: variant);
      expect(track.copyWith(language: 'ro').transcribedBy, variant);
    });
  });
}
