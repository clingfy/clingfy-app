import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';

class _TestPlayerController extends PlayerController {
  _TestPlayerController({
    required super.nativeBridge,
    this.compositionZoomSegments,
  });

  List<ZoomSegment>? compositionZoomSegments;

  @override
  List<ZoomSegment>? get previewCompositionZoomSegments =>
      compositionZoomSegments;
}

class _Harness {
  _Harness({
    required this.player,
    required this.post,
    required this.settings,
    required this.processCalls,
  });

  final _TestPlayerController player;
  final PostProcessingController post;
  final SettingsController settings;
  final List<MethodCall> processCalls;

  void dispose() {
    post.dispose();
    player.dispose();
    settings.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<_Harness> createHarness({List<ZoomSegment>? zoomSegments}) async {
    final processCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'processVideo':
          processCalls.add(call);
          return '/tmp/preview.mov';
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();

    final player = _TestPlayerController(
      nativeBridge: nativeBridge,
      compositionZoomSegments: zoomSegments,
    );
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    post.attachToRecording(
      sessionId: 'rec_test_session',
      sourcePath: '/tmp/original.mov',
    );
    await Future<void>.delayed(Duration.zero);
    processCalls.clear();

    final harness = _Harness(
      player: player,
      post: post,
      settings: settings,
      processCalls: processCalls,
    );
    addTearDown(harness.dispose);
    return harness;
  }

  test(
    'applyProcessing includes zoomSegments when preview composition segments are available',
    () async {
      final harness = await createHarness(
        zoomSegments: const [
          ZoomSegment(
            id: 'effective_0',
            startMs: 120,
            endMs: 340,
            source: 'effective',
          ),
        ],
      );

      await harness.post.applyProcessing();

      expect(harness.processCalls, hasLength(1));
      final args = Map<String, dynamic>.from(
        harness.processCalls.single.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['path'], '/tmp/original.mov');
      expect(args['layoutPreset'], harness.settings.post.layoutPreset.name);
      expect(
        args['resolutionPreset'],
        harness.settings.post.resolutionPreset.name,
      );
      expect(args['audioGainDb'], harness.post.audioGainDb);
      expect(args['audioVolumePercent'], harness.post.audioVolumePercent);
      expect(args['zoomSegments'], [
        {'startMs': 120, 'endMs': 340},
      ]);
    },
  );

  test(
    'applyProcessing omits zoomSegments when preview composition segments are not ready',
    () async {
      final harness = await createHarness();

      await harness.post.applyProcessing();

      expect(harness.processCalls, hasLength(1));
      final args = Map<String, dynamic>.from(
        harness.processCalls.single.arguments! as Map<dynamic, dynamic>,
      );
      expect(args.containsKey('zoomSegments'), isFalse);
      expect(args['path'], '/tmp/original.mov');
      expect(args['layoutPreset'], harness.settings.post.layoutPreset.name);
      expect(
        args['resolutionPreset'],
        harness.settings.post.resolutionPreset.name,
      );
    },
  );

  test(
    'setLayoutPreset triggers processVideo with the updated layout preset',
    () async {
      final harness = await createHarness();

      harness.post.setLayoutPreset(LayoutPreset.youtube169);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(harness.settings.post.layoutPreset, LayoutPreset.youtube169);
      expect(args['layoutPreset'], 'youtube169');
    },
  );

  test(
    'camera zoom behavior and multiplier are included in preview payloads',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.post.setCameraZoomBehavior(
        CameraZoomBehavior.scaleWithScreenZoom,
      );
      harness.post.setCameraZoomScaleMultiplierEnd(0.6);

      expect(harness.processCalls, isNotEmpty);
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(args['cameraZoomBehavior'], 'scaleWithScreenZoom');
      expect(args['cameraZoomScaleMultiplier'], 0.6);
    },
  );

  test('camera animation settings are included in preview payloads', () async {
    final harness = await createHarness();

    harness.post.setCameraVisible(true);
    harness.post.setCameraIntroPreset(CameraIntroPreset.pop);
    harness.post.setCameraOutroPreset(CameraOutroPreset.slide);
    harness.post.setCameraZoomEmphasisPreset(CameraZoomEmphasisPreset.pulse);
    harness.post.setCameraIntroDurationMsEnd(300);
    harness.post.setCameraOutroDurationMsEnd(260);
    harness.post.setCameraZoomEmphasisStrengthEnd(0.12);

    expect(harness.processCalls, isNotEmpty);
    final args = Map<String, dynamic>.from(
      harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
    );

    expect(args['cameraIntroPreset'], 'pop');
    expect(args['cameraOutroPreset'], 'slide');
    expect(args['cameraZoomEmphasisPreset'], 'pulse');
    expect(args['cameraIntroDurationMs'], 300);
    expect(args['cameraOutroDurationMs'], 260);
    expect(args['cameraZoomEmphasisStrength'], 0.12);
  });
}
