import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/captions/captions_model.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

/// The chosen speech model, from the preference to the native call.
///
/// The arg keys on these payloads have no ratchet — PR-0d's test covers method
/// NAMES only — and native reads every argument with a default. So a misspelled
/// `variant` key is silent: native runs the default, the user picked Fast, and
/// the transcript takes the full-size model's minutes. These pin the key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.clingfy/screen_recorder');
  late Directory tempDir;
  late List<MethodCall> calls;

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = Directory.systemTemp.createTempSync('clingfy_model_wire');
    calls = [];
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    await PostStateStore.settled();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<PostProcessingController> controller({String? storedModel}) async {
    SharedPreferences.setMockInitialValues({
      if (storedModel != null) 'postCaptionsModel': storedModel,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'captionsCapability':
              return {
                'available': true,
                'hasMicAudio': true,
                'hasSystemAudio': true,
              };
            case 'generateCaptions':
              return {'cues': <dynamic>[], 'language': 'en'};
            // A real snapshot, not null. The storage refresh fetches it BEFORE
            // the model info and `getStorageSnapshot` throws on null, which
            // skips the model-info call entirely — so a null here would make
            // the Storage-card test pass or fail for the wrong reason.
            case 'getStorageSnapshot':
              return <String, dynamic>{
                'systemTotalBytes': 500 * 1024 * 1024 * 1024,
                'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
                'recordingsBytes': 0,
                'tempBytes': 0,
                'logsBytes': 0,
                'recordingsPath': '/tmp/r',
                'tempPath': '/tmp/t',
                'logsPath': '/tmp/l',
                'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
                'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
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
    final dir = Directory('${tempDir.path}/rec')..createSync();
    post.attachToRecording(sessionId: 'rec', projectPath: dir.path);
    await pumpEventQueue();
    return post;
  }

  Map<dynamic, dynamic> lastArgs(String method) =>
      calls.lastWhere((c) => c.method == method).arguments as Map;

  test(
    'generateCaptions sends the chosen model under the variant key',
    () async {
      final post = await controller(storedModel: CaptionsModel.fast.wire);
      await post.generateCaptions();
      expect(lastArgs('generateCaptions')['variant'], CaptionsModel.fast.wire);
    },
  );

  test('with no choice made, it sends the default', () async {
    final post = await controller();
    await post.generateCaptions();
    expect(
      lastArgs('generateCaptions')['variant'],
      CaptionsModel.best.wire,
      reason: 'the default is the model every user already has',
    );
  });

  /// The choice is persisted, unlike the language beside it: a model has no
  /// safe "Auto" to reset to.
  test('a choice persists and the next transcription uses it', () async {
    final post = await controller();
    post.setCaptionsModel(CaptionsModel.balanced);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('postCaptionsModel'), CaptionsModel.balanced.wire);
    expect(post.captionsModel, CaptionsModel.balanced);

    await post.generateCaptions();
    expect(
      lastArgs('generateCaptions')['variant'],
      CaptionsModel.balanced.wire,
    );
  });

  test('the language still travels beside it, unchanged', () async {
    final post = await controller(storedModel: CaptionsModel.fast.wire);
    post.setCaptionsLanguage('ar');
    await post.generateCaptions();
    final args = lastArgs('generateCaptions');
    expect(args['language'], 'ar');
    expect(args['variant'], CaptionsModel.fast.wire);
  });

  test('the Storage card asks about the chosen model', () async {
    final post = await controller(storedModel: CaptionsModel.fast.wire);
    calls.clear();
    post.setCaptionsModel(CaptionsModel.balanced);
    await pumpEventQueue();
    await pumpEventQueue();

    final infoCalls = calls.where((c) => c.method == 'getCaptionModelInfo');
    expect(infoCalls, isNotEmpty, reason: 'a switch refreshes the card');
    expect(
      (infoCalls.last.arguments as Map)['variant'],
      CaptionsModel.balanced.wire,
      reason: 'so the card marks the model the user chose as the one in use',
    );
  });

  test('bridge omits variant when none is given', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {'cues': <dynamic>[]};
        });
    await NativeBridge.instance.generateCaptions(projectPath: '/x');
    expect(
      lastArgs('generateCaptions').containsKey('variant'),
      isFalse,
      reason: 'an older native build must see exactly the arguments it did',
    );
  });
}
