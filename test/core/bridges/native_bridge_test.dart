import 'dart:async';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/recording/models/audio_output_route.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

Future<void> _emitNativeMethod(String method, [Object? arguments]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.screenRecorder,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) => completer.complete(),
  );
  await completer.future;
}

Future<void> _emitWorkflowEvent(Map<String, Object?> event) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.workflowEvents,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) => completer.complete(),
  );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    final bridge = NativeBridge.instance;
    bridge.setOnIndicatorPauseTapped(null);
    bridge.setOnIndicatorStopTapped(null);
    bridge.setOnIndicatorResumeTapped(null);
    bridge.setOnProjectOpenRequested(null);
    await clearCommonNativeMocks();
  });

  test('indicatorPauseTapped dispatches through NativeBridge', () async {
    final bridge = NativeBridge.instance;
    var pauseTapped = 0;

    bridge.setOnIndicatorPauseTapped(() {
      pauseTapped += 1;
    });

    await _emitNativeMethod(NativeToFlutterMethod.indicatorPauseTapped);

    expect(pauseTapped, 1);
  });

  test(
    'Finder project open requests buffer until callback is attached',
    () async {
      final bridge = NativeBridge.instance;
      final openedProjects = <String>[];

      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/first.clingfyproj',
      });
      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/first.clingfyproj',
      });
      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/second.clingfyproj',
      });

      bridge.setOnProjectOpenRequested(openedProjects.add);
      await Future<void>.delayed(Duration.zero);

      expect(openedProjects, [
        '/tmp/first.clingfyproj',
        '/tmp/second.clingfyproj',
      ]);
    },
  );

  group('camera preview bridge (Phase 9.3.1/9.3.2)', () {
    void overrideScreenRecorder(
      Future<Object?> Function(MethodCall call) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, handler);
    }

    void clearScreenRecorder() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, null);
    }

    test(
      'setCameraPreviewMode forwards floating + parses resulting true',
      () async {
        MethodCall? captured;
        overrideScreenRecorder((call) async {
          captured = call;
          return <String, Object?>{'floating': true};
        });

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isTrue);
        expect(captured?.method, 'setCameraPreviewMode');
        expect((captured?.arguments as Map)['floating'], isTrue);
      },
    );

    test(
      'setCameraPreviewMode parses resulting false (floating refused)',
      () async {
        overrideScreenRecorder(
          (call) async => <String, Object?>{'floating': false},
        );

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isFalse);
      },
    );

    test(
      'setCameraPreviewMode returns false on MissingPluginException',
      () async {
        // No handler registered → channel throws MissingPluginException (macOS /
        // builds without the Windows handler). Must degrade to false, not throw.
        clearScreenRecorder();

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isFalse);
      },
    );
  });

  group('startup recovery report (Phase 10.4)', () {
    void overrideScreenRecorder(
      Future<Object?> Function(MethodCall call) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, handler);
    }

    void clearScreenRecorder() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, null);
    }

    test('getStartupRecoveryReport parses a well-formed report', () async {
      overrideScreenRecorder((call) async {
        expect(call.method, NativeMethod.getStartupRecoveryReport);
        return <String, Object?>{
          'interruptedProjects': [
            {'projectPath': r'C:\rec\one.clingfyproj', 'sessionId': 'rec_1'},
            {'projectPath': r'C:\rec\two.clingfyproj', 'sessionId': 'rec_2'},
          ],
          'cleanedTempFileCount': 3,
          'cleanedTempBytes': 1024,
        };
      });

      final report = await NativeBridge.instance.getStartupRecoveryReport();

      expect(report, isNotNull);
      expect(report!.interruptedProjects, hasLength(2));
      expect(
        report.interruptedProjects.first.projectPath,
        r'C:\rec\one.clingfyproj',
      );
      expect(report.interruptedProjects.first.sessionId, 'rec_1');
      expect(report.cleanedTempFileCount, 3);
      expect(report.cleanedTempBytes, 1024);
      expect(report.hasInterruptedProjects, isTrue);
      expect(report.hasCleanedTempFiles, isTrue);
    });

    test('getStartupRecoveryReport degrades malformed payloads to '
        'empty/zero instead of throwing', () async {
      overrideScreenRecorder(
        (call) async => <String, Object?>{
          'interruptedProjects': [
            'not-a-map',
            {'sessionId': 'rec_no_path'},
            {'projectPath': ''},
            {'projectPath': r'C:\rec\ok.clingfyproj', 'sessionId': 42},
          ],
          'cleanedTempFileCount': 'three',
          'cleanedTempBytes': 2.5,
        },
      );

      final report = await NativeBridge.instance.getStartupRecoveryReport();

      expect(report, isNotNull);
      // Only the entry with a usable projectPath survives; its non-string
      // sessionId degrades to ''.
      expect(report!.interruptedProjects, hasLength(1));
      expect(
        report.interruptedProjects.single.projectPath,
        r'C:\rec\ok.clingfyproj',
      );
      expect(report.interruptedProjects.single.sessionId, '');
      expect(report.cleanedTempFileCount, 0);
      expect(report.cleanedTempBytes, 2);
    });

    test('getStartupRecoveryReport returns null on MissingPluginException '
        '(macOS has no handler)', () async {
      clearScreenRecorder();

      final report = await NativeBridge.instance.getStartupRecoveryReport();

      expect(report, isNull);
    });

    test(
      'getStartupRecoveryReport returns null on PlatformException',
      () async {
        overrideScreenRecorder((call) async {
          throw PlatformException(code: 'INTERNAL_ERROR', message: 'boom');
        });

        final report = await NativeBridge.instance.getStartupRecoveryReport();

        expect(report, isNull);
      },
    );

    test(
      'getStartupRecoveryReport returns null when native replies null',
      () async {
        overrideScreenRecorder((call) async => null);

        final report = await NativeBridge.instance.getStartupRecoveryReport();

        expect(report, isNull);
      },
    );

    test('debugForceNativeCrash swallows native refusal errors', () async {
      overrideScreenRecorder((call) async {
        expect(call.method, NativeMethod.debugForceNativeCrash);
        throw PlatformException(
          code: 'BAD_ARGS',
          message: 'CLINGFY_CRASH_TEST is not set',
        );
      });

      // Must not throw — fire-and-forget by contract.
      await NativeBridge.instance.debugForceNativeCrash();
    });

    test(
      'debugForceNativeCrash swallows MissingPluginException (macOS)',
      () async {
        clearScreenRecorder();

        await NativeBridge.instance.debugForceNativeCrash();
      },
    );
  });

  group('color grade bridge', () {
    const channel = MethodChannel(NativeChannel.screenRecorder);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('previewSetColorGrade forwards the grade map and sessionId', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeBridge.instance.previewSetColorGrade(
        colorGrade: const ColorGrade(
          autoEnabled: true,
          exposure: 0.2,
          contrast: -0.1,
          saturation: 0.3,
          temperature: 0.05,
          tint: -0.02,
        ),
        sessionId: 'sess-1',
      );

      expect(captured?.method, 'previewSetColorGrade');
      final args = captured?.arguments as Map;
      expect(args['sessionId'], 'sess-1');
      final grade = args['colorGrade'] as Map;
      expect(grade['autoEnabled'], isTrue);
      expect(grade['exposure'], 0.2);
      expect(grade['contrast'], -0.1);
      expect(grade['saturation'], 0.3);
    });

    test('previewSetColorGrade omits sessionId when null', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeBridge.instance.previewSetColorGrade(
        colorGrade: const ColorGrade(exposure: 0.5),
        sessionId: null,
      );

      final args = captured?.arguments as Map;
      expect(args.containsKey('sessionId'), isFalse);
      expect((args['colorGrade'] as Map)['exposure'], 0.5);
    });
  });

  group('clip bridge', () {
    const channel = MethodChannel(NativeChannel.screenRecorder);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('previewSetClips forwards the clip maps and sessionId', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeBridge.instance.previewSetClips(
        clips: const [
          Clip(id: 'a', sourceInMs: 0, sourceOutMs: 3000, timelineStartMs: 0),
          Clip(
            id: 'b',
            sourceInMs: 7000,
            sourceOutMs: 9000,
            timelineStartMs: 3000,
          ),
        ],
        sessionId: 'sess-1',
      );

      expect(captured?.method, 'previewSetClips');
      final args = captured?.arguments as Map;
      expect(args['sessionId'], 'sess-1');
      final clips = args['clips'] as List;
      expect(clips, hasLength(2));
      expect((clips.first as Map)['sourceInMs'], 0);
      expect((clips.first as Map)['sourceOutMs'], 3000);
      expect((clips.last as Map)['sourceInMs'], 7000);
    });

    test('previewSetClips omits sessionId when null', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeBridge.instance.previewSetClips(
        clips: const [
          Clip(id: 'a', sourceInMs: 0, sourceOutMs: 5000, timelineStartMs: 0),
        ],
        sessionId: null,
      );

      final args = captured?.arguments as Map;
      expect(args.containsKey('sessionId'), isFalse);
      expect((args['clips'] as List), hasLength(1));
    });
  });

  group('getAudioOutputRoute', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        null,
      );
    });

    void respond(Object? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        (call) async => handler(call),
      );
    }

    test('parses each route the native side can report', () async {
      for (final entry in {
        'speakers': AudioOutputRoute.speakers,
        'headphones': AudioOutputRoute.headphones,
        'unknown': AudioOutputRoute.unknown,
      }.entries) {
        respond((call) {
          expect(call.method, NativeMethod.getAudioOutputRoute);
          return {'route': entry.key};
        });
        expect(await NativeBridge.instance.getAudioOutputRoute(), entry.value);
      }
    });

    test('an unrecognized route resolves to unknown, not a warning', () async {
      respond((_) => {'route': 'teleporter'});
      expect(
        await NativeBridge.instance.getAudioOutputRoute(),
        AudioOutputRoute.unknown,
      );
    });

    test('a missing route key resolves to unknown', () async {
      respond((_) => <String, Object?>{});
      expect(
        await NativeBridge.instance.getAudioOutputRoute(),
        AudioOutputRoute.unknown,
      );
    });

    test('a native build without the method resolves to unknown', () async {
      // Windows has no implementation; it must not throw into the settings
      // load path.
      respond((call) => throw MissingPluginException('no impl'));
      expect(
        await NativeBridge.instance.getAudioOutputRoute(),
        AudioOutputRoute.unknown,
      );
    });

    test('a platform error resolves to unknown', () async {
      respond((call) => throw PlatformException(code: 'BOOM'));
      expect(
        await NativeBridge.instance.getAudioOutputRoute(),
        AudioOutputRoute.unknown,
      );
    });
  });

  group('canvasPresetThumbnail', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        null,
      );
    });

    void respond(Object? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        (call) async => handler(call),
      );
    }

    test('sends every parameter the renderer keys its cache on', () async {
      MethodCall? seen;
      respond((call) {
        seen = call;
        return 'C:/cache/thumb.png';
      });

      final path = await NativeBridge.instance.canvasPresetThumbnail(
        presetId: 'graphicMesh',
        palette: 'sunset',
        intensity: 0.7,
        blur: 0.35,
        seed: 1,
        width: 72,
        height: 48,
      );

      expect(path, 'C:/cache/thumb.png');
      expect(seen?.method, 'canvasPresetThumbnail');
      final args = (seen!.arguments as Map).cast<String, dynamic>();
      // Every one of these changes the pixels, so every one must cross the
      // boundary — a dropped argument would silently serve another preset's
      // cached art.
      expect(args['presetId'], 'graphicMesh');
      expect(args['palette'], 'sunset');
      expect(args['intensity'], 0.7);
      expect(args['blur'], 0.35);
      expect(args['seed'], 1);
      expect(args['width'], 72);
      expect(args['height'], 48);
    });

    // A picker with no thumbnails is still a usable picker, so a platform
    // without the handler must degrade to the palette swatch rather than throw
    // into the sidebar build.
    test('a native build without the method resolves to null', () async {
      respond((_) => throw MissingPluginException('no impl'));
      expect(
        await NativeBridge.instance.canvasPresetThumbnail(
          presetId: 'abstractWaves',
          palette: 'bluePurple',
          intensity: 0.7,
          blur: 0.35,
          seed: 1,
          width: 72,
          height: 48,
        ),
        isNull,
      );
    });

    test('a render failure resolves to null rather than throwing', () async {
      respond((_) => throw PlatformException(code: 'BOOM'));
      expect(
        await NativeBridge.instance.canvasPresetThumbnail(
          presetId: 'abstractWaves',
          palette: 'bluePurple',
          intensity: 0.7,
          blur: 0.35,
          seed: 1,
          width: 72,
          height: 48,
        ),
        isNull,
      );
    });

    // Native answers null when it cannot render; that must arrive as null, not
    // as a crash decoding the reply.
    test('a null reply is a valid answer', () async {
      respond((_) => null);
      expect(
        await NativeBridge.instance.canvasPresetThumbnail(
          presetId: 'abstractWaves',
          palette: 'bluePurple',
          intensity: 0.7,
          blur: 0.35,
          seed: 1,
          width: 72,
          height: 48,
        ),
        isNull,
      );
    });
  });

  group('identifyDisplays bridge', () {
    void overrideScreenRecorder(
      Future<Object?> Function(MethodCall call) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, handler);
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, null);
    });

    test('forwards its arguments and returns the snapshot', () async {
      MethodCall? captured;
      overrideScreenRecorder((call) async {
        captured = call;
        return <Object?>[
          <String, Object?>{'id': 1, 'ordinal': 1},
          <String, Object?>{'id': 2, 'ordinal': 2},
        ];
      });

      final result = await NativeBridge.instance.identifyDisplays(
        durationMs: 1600,
        only: false,
        labels: {'1': '1. A', '2': '2. B'},
      );

      expect(result.supported, isTrue);
      expect(result.snapshot!.length, 2);
      expect(captured!.method, NativeMethod.identifyDisplays);
      expect(captured!.arguments, {
        'durationMs': 1600,
        'only': false,
        'onlyDisplayId': null,
        'labels': {'1': '1. A', '2': '2. B'},
      });
    });

    test('a MissingPluginException maps to unsupported', () async {
      overrideScreenRecorder((call) async {
        throw MissingPluginException('no handler');
      });

      final result = await NativeBridge.instance.identifyDisplays(
        durationMs: 900,
        only: true,
        onlyDisplayId: 2,
        labels: const {},
      );

      expect(result.supported, isFalse);
      expect(result.snapshot, isNull);
    });

    test('a PlatformException keeps the feature supported', () async {
      // A transient failure must not permanently hide a working button.
      overrideScreenRecorder((call) async {
        throw PlatformException(code: 'BOOM');
      });

      final result = await NativeBridge.instance.identifyDisplays(
        durationMs: 900,
        only: false,
        labels: const {},
      );

      expect(result.supported, isTrue);
      expect(result.snapshot, isNull);
    });
  });
}
