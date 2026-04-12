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
    required this.cameraPlacementCalls,
  });

  final _TestPlayerController player;
  final PostProcessingController post;
  final SettingsController settings;
  final List<MethodCall> processCalls;
  final List<MethodCall> cameraPlacementCalls;

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
    final cameraPlacementCalls = <MethodCall>[];
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
        case 'previewSetCameraPlacement':
          cameraPlacementCalls.add(call);
          return null;
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
      projectPath: '/tmp/original.clingfyproj',
    );
    await Future<void>.delayed(Duration.zero);
    processCalls.clear();

    final harness = _Harness(
      player: player,
      post: post,
      settings: settings,
      processCalls: processCalls,
      cameraPlacementCalls: cameraPlacementCalls,
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
      expect(args['projectPath'], '/tmp/original.clingfyproj');
      expect(args['layoutPreset'], harness.settings.post.layoutPreset.name);
      expect(
        args['resolutionPreset'],
        harness.settings.post.resolutionPreset.name,
      );
      expect(args['audioGainDb'], harness.post.audioGainDb);
      expect(args['audioVolumePercent'], harness.post.audioVolumePercent);
      expect(args['cameraPreviewChangeKind'], 'none');
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
      expect(args['projectPath'], '/tmp/original.clingfyproj');
      expect(args['layoutPreset'], harness.settings.post.layoutPreset.name);
      expect(
        args['resolutionPreset'],
        harness.settings.post.resolutionPreset.name,
      );
      expect(args['cameraPreviewChangeKind'], 'none');
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
      expect(args['cameraPreviewChangeKind'], 'none');
    },
  );

  test(
    'repeated preview composition requests keep the latest pre-open state',
    () async {
      final harness = await createHarness();

      harness.post.setResolutionPreset(ResolutionPreset.p2160);
      await Future<void>.delayed(Duration.zero);
      harness.post.setResolutionPreset(ResolutionPreset.p1080);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls.length, greaterThanOrEqualTo(2));
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(args['sessionId'], 'rec_test_session');
      expect(args['projectPath'], '/tmp/original.clingfyproj');
      expect(args['resolutionPreset'], ResolutionPreset.p1080.name);
      expect(args['cameraPreviewChangeKind'], 'none');
    },
  );

  test(
    'camera layout preset changes mark preview payload as placementJump',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.processCalls.clear();

      harness.post.setCameraLayoutPreset(CameraLayoutPreset.overlayTopLeft);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(args['cameraLayoutPreset'], 'overlayTopLeft');
      expect(args['cameraPreviewChangeKind'], 'placementJump');
    },
  );

  test(
    'snapped manual camera centers mark preview payload as placementJump',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.processCalls.clear();

      harness.post.setCameraManualCenterSnap(const Offset(0.5, 0.14));
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], {'x': 0.5, 'y': 0.86});
    },
  );

  test(
    'manual camera drag preview stays dragPreview and end commits as placementJump',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.processCalls.clear();
      harness.cameraPlacementCalls.clear();

      harness.post.setCameraManualCenterPreview(const Offset(0.2, 0.3));
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isEmpty);
      expect(harness.post.isEditingLocked, isFalse);
      expect(harness.cameraPlacementCalls, isNotEmpty);
      var args = Map<String, dynamic>.from(
        harness.cameraPlacementCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'dragPreview');
      expect(args['projectPath'], '/tmp/original.clingfyproj');
      expect(args['cameraNormalizedCenter'], {'x': 0.2, 'y': 0.7});

      harness.processCalls.clear();
      harness.cameraPlacementCalls.clear();
      harness.post.setCameraManualCenterPreviewEnd(const Offset(0.4, 0.6));
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      expect(harness.cameraPlacementCalls, isEmpty);
      args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], {'x': 0.4, 'y': 0.4});
    },
  );

  test(
    'manual camera center commits mark preview payload as placementJump',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.processCalls.clear();

      harness.post.setCameraManualCenter(const Offset(0.3, 0.7));
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      var args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], {'x': 0.3, 'y': 0.7});

      harness.processCalls.clear();
      harness.post.resetCameraManualPosition();
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], isNull);
    },
  );

  test(
    'manual camera axis end updates mark preview payload as placementJump',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      harness.post.setCameraManualCenter(const Offset(0.25, 0.75));
      await Future<void>.delayed(Duration.zero);
      harness.processCalls.clear();

      harness.post.setCameraManualCenterXEnd(0.6);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      var args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], {'x': 0.6, 'y': 0.75});

      harness.processCalls.clear();
      harness.post.setCameraManualCenterYEnd(0.2);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['cameraPreviewChangeKind'], 'placementJump');
      expect(args['cameraNormalizedCenter'], {'x': 0.6, 'y': 0.2});
    },
  );

  test(
    'default camera motion settings are included in preview payloads',
    () async {
      final harness = await createHarness();

      harness.post.setCameraVisible(true);
      await Future<void>.delayed(Duration.zero);

      expect(harness.processCalls, isNotEmpty);
      final args = Map<String, dynamic>.from(
        harness.processCalls.last.arguments! as Map<dynamic, dynamic>,
      );

      expect(
        args['cameraZoomBehavior'],
        CameraCompositionState.defaultZoomBehavior.name,
      );
      expect(
        args['cameraZoomScaleMultiplier'],
        CameraCompositionState.defaultZoomScaleMultiplier,
      );
      expect(
        args['cameraIntroPreset'],
        CameraCompositionState.defaultIntroPreset.name,
      );
      expect(
        args['cameraOutroPreset'],
        CameraCompositionState.defaultOutroPreset.name,
      );
      expect(
        args['cameraIntroDurationMs'],
        CameraCompositionState.defaultIntroDurationMs,
      );
      expect(
        args['cameraOutroDurationMs'],
        CameraCompositionState.defaultOutroDurationMs,
      );
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
