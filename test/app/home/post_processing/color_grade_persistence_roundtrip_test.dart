import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';
import '../../../test_helpers/wait_until.dart';

/// End-to-end color-grade persistence round-trip through the real
/// [PostProcessingController] wiring (load-on-open, push-to-preview,
/// save-on-commit). The pure serialization is covered by
/// canvas_appearance_store_test.dart and the native bake by the ColorGrade
/// golden / previewSetColorGrade pixel tests; this closes the live seam that
/// only the running controller exercises — the same one Windows uses, since
/// the store is platform-agnostic `dart:io`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory projectDir;
  late List<MethodCall> colorGradeCalls;

  // A deliberately non-identity grade with every field distinct, so a dropped
  // or swapped field fails the assertion.
  const persistedGrade = ColorGrade(
    autoEnabled: true,
    exposure: 0.4,
    contrast: -0.25,
    saturation: 0.15,
    temperature: -0.3,
    tint: 0.05,
  );

  setUp(() async {
    await installCommonNativeMocks();
    projectDir = await Directory.systemTemp.createTemp('clingfy_grade_rt_');
    colorGradeCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Replace the screen-recorder handler so we can capture the color-grade
    // push and return a preview path (mirrors post_processing_controller_test).
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'previewSetColorGrade':
          colorGradeCalls.add(call);
          return null;
        case 'processVideo':
          return '${projectDir.path}${Platform.pathSeparator}preview.mov';
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
    // Editor writes are fire-and-forget; deleting the tree while one recreates
    // post/ inside it fails with ENOTEMPTY.
    await PostStateStore.settled();
    if (await projectDir.exists()) {
      await projectDir.delete(recursive: true);
    }
  });

  Future<PostProcessingController> attachController(String projectPath) async {
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
    post.attachToRecording(sessionId: 'rec_grade_rt', projectPath: projectPath);
    // Flush the async scene-load chain (getRecordingSceneInfo →
    // _loadCanvasAppearance → _pushPreviewColorGrade → applyProcessing).
    await _settle();
    return post;
  }

  // Writes a v2 editor_state.json by hand — proves we parse an externally
  // authored file, not just one this process wrote.
  Future<void> writeEditorStateJson(ColorGrade grade) async {
    final json = const JsonEncoder.withIndent('  ').convert({
      'version': 2,
      'padding': 32.0,
      'cornerRadius': 12.0,
      'background': {
        'kind': 'color',
        'colorArgb': null,
        'imagePath': null,
        'preset': null,
      },
      'colorGrade': grade.toMap(),
    });
    await File(
      '${projectDir.path}${Platform.pathSeparator}editor_state.json',
    ).writeAsString(json);
  }

  test('load-on-open restores a persisted non-identity grade', () async {
    await writeEditorStateJson(persistedGrade);

    final post = await attachController(projectDir.path);

    expect(post.colorGrade.isIdentity, isFalse);
    expect(post.colorGrade, persistedGrade);
  });

  test('open pushes the restored grade to the native preview', () async {
    await writeEditorStateJson(persistedGrade);

    await attachController(projectDir.path);

    expect(colorGradeCalls, isNotEmpty);
    final args = Map<String, dynamic>.from(
      colorGradeCalls.last.arguments as Map<dynamic, dynamic>,
    );
    final grade = Map<String, dynamic>.from(
      args['colorGrade'] as Map<dynamic, dynamic>,
    );
    expect(grade['autoEnabled'], isTrue);
    expect(grade['exposure'], 0.4);
    expect(grade['contrast'], -0.25);
    expect(grade['saturation'], 0.15);
    expect(grade['temperature'], -0.3);
    expect(grade['tint'], 0.05);
  });

  test('editing + commit writes the grade to editor_state.json', () async {
    // Start with no persisted file — the grade begins neutral.
    final post = await attachController(projectDir.path);
    expect(post.colorGrade.isIdentity, isTrue);

    post.setColorGradeExposure(0.5);
    post.setColorGradeContrast(-0.2);
    post.setColorGradeSaturation(0.1);
    post.commitColorGrade();

    // The persist is fire-and-forget real file I/O, so a fixed sleep is a race
    // the CI runner can lose. Poll on the VALUE, not just the file's existence:
    // the bundle may already hold an earlier grade.
    await waitUntil(
      () => PostStateStore.load(projectDir.path).grade.exposure == 0.5,
      reason: 'post/state.json after a color commit',
    );

    final loaded = PostStateStore.load(projectDir.path);
    expect(loaded.grade.exposure, 0.5);
    expect(loaded.grade.contrast, -0.2);
    expect(loaded.grade.saturation, 0.1);
  });

  test(
    'full restart: a second open restores what the first one saved',
    () async {
      // Session 1: edit + commit, then tear down.
      final first = await attachController(projectDir.path);
      first.setColorGradeExposure(0.35);
      first.setColorGradeTemperature(-0.4);
      first.commitColorGrade();
      // Session 2 reads this file synchronously on open, so the write must be
      // confirmed on disk before the first controller is torn down — otherwise
      // the "restart" reads whatever happened to be there.
      await waitUntil(
        () => PostStateStore.load(projectDir.path).grade.exposure == 0.35,
        reason: 'session 1 must be on disk before the restart',
      );
      first.detachRecording();

      // Session 2: a brand-new controller opening the same bundle (the restart).
      final second = await attachController(projectDir.path);

      expect(second.colorGrade.isIdentity, isFalse);
      expect(second.colorGrade.exposure, 0.35);
      expect(second.colorGrade.temperature, -0.4);
    },
  );
}

/// Pump the event queue enough to flush the controller's chained awaits plus
/// the fire-and-forget file write (real async I/O — a single microtask hop is
/// not enough).
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
