import 'dart:async';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/job_progress.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';
import '../../../test_helpers/wait_until.dart';
import 'dart:io';
import 'package:clingfy/core/captions/caption_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Caption state on the controller: what it asks native, what it refuses to
/// ask twice, and what survives an edit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  late List<MethodCall> calls;
  late Map<String, Object?> capabilityReply;
  late List<Map<String, Object?>> transcriptReply;

  /// Set to throw from `generateCaptions` instead of returning cues.
  PlatformException? generateThrows;

  /// Held open so a transcription can be observed mid-flight.
  Completer<List<Map<String, Object?>>>? generateGate;

  Future<PostProcessingController> createController({
    bool attach = true,
  }) async {
    calls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'captionsCapability':
          return capabilityReply;
        case 'generateCaptions':
          if (generateGate != null) return await generateGate!.future;
          if (generateThrows != null) throw generateThrows!;
          return transcriptReply;
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

    if (attach) {
      post.attachToRecording(
        sessionId: 'rec_captions',
        projectPath: '/tmp/original.clingfyproj',
      );
      await pumpEventQueue();
    }
    return post;
  }

  setUp(() {
    capabilityReply = {
      'available': true,
      'hasMicAudio': true,
      'hasSystemAudio': true,
    };
    transcriptReply = [
      {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
      {'id': 'c2', 'startMs': 1500, 'endMs': 3000, 'text': 'second line'},
    ];
    generateThrows = null;
    generateGate = null;
  });

  List<MethodCall> callsNamed(String name) =>
      calls.where((c) => c.method == name).toList();

  // ---- Capability probe -------------------------------------------------

  test('attaching a recording probes native for what it can caption', () async {
    final post = await createController();

    expect(callsNamed('captionsCapability'), hasLength(1));
    expect(
      callsNamed('captionsCapability').single.arguments,
      containsPair('projectPath', '/tmp/original.clingfyproj'),
    );
    expect(post.captionsCapability?.available, isTrue);
  });

  test(
    'the source selection is seeded from what the recording holds',
    () async {
      // System audio only: offering a microphone toggle would let the user
      // select a source that does not exist on disk.
      capabilityReply = {
        'available': true,
        'hasMicAudio': false,
        'hasSystemAudio': true,
      };
      final post = await createController();

      expect(post.captionsUseMic, isFalse);
      expect(post.captionsUseSystem, isTrue);
      expect(post.captionsCapability?.shouldOfferSourcePicker, isFalse);
    },
  );

  test('both sources are on when both exist', () async {
    final post = await createController();
    expect(post.captionsUseMic, isTrue);
    expect(post.captionsUseSystem, isTrue);
  });

  test('a probe failure leaves captions off rather than crashing', () async {
    capabilityReply = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final post = await createController(attach: false);
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      if (call.method == 'captionsCapability') {
        throw PlatformException(code: 'BOOM');
      }
      return null;
    });

    post.attachToRecording(
      sessionId: 's',
      projectPath: '/tmp/original.clingfyproj',
    );
    await pumpEventQueue();

    expect(post.captionsCapability, isNull);
    expect(post.isGeneratingCaptions, isFalse);
  });

  // ---- Generating -------------------------------------------------------

  test('generation sends the selected sources and stores the cues', () async {
    final post = await createController();
    post.setCaptionsUseSystem(false);

    await post.generateCaptions();

    final call = callsNamed('generateCaptions').single;
    expect(call.arguments, containsPair('useMic', true));
    expect(call.arguments, containsPair('useSystem', false));
    expect(
      call.arguments,
      containsPair('projectPath', '/tmp/original.clingfyproj'),
    );
    expect(post.captions.map((c) => c.text), ['hello there', 'second line']);
    expect(post.captions.first.endMs, 1500);
    expect(post.isGeneratingCaptions, isFalse);
    expect(post.hasEverGeneratedCaptions, isTrue);
  });

  test('a second generate is refused while one is in flight', () async {
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();

    final first = post.generateCaptions();
    await pumpEventQueue();
    expect(post.isGeneratingCaptions, isTrue);

    await post.generateCaptions();
    expect(
      callsNamed('generateCaptions'),
      hasLength(1),
      reason: 'the engine is not re-entrant; two jobs is a crash, not a queue',
    );

    generateGate!.complete(transcriptReply);
    await first;
    expect(post.isGeneratingCaptions, isFalse);
  });

  test('generating with no source selected never reaches native', () async {
    final post = await createController();
    post.setCaptionsUseMic(false);
    post.setCaptionsUseSystem(false);

    await post.generateCaptions();

    expect(callsNamed('generateCaptions'), isEmpty);
    expect(post.isGeneratingCaptions, isFalse);
  });

  test(
    'a failure clears the in-flight flag so the button comes back',
    () async {
      final post = await createController();
      generateThrows = PlatformException(code: 'CAPTIONS_FAILED');

      await post.generateCaptions();

      expect(post.isGeneratingCaptions, isFalse);
      expect(post.captionsProgress, isNull);
      expect(post.captions, isEmpty);
      expect(
        post.hasEverGeneratedCaptions,
        isTrue,
        reason: 'a run happened and produced nothing — the panel may say so',
      );
    },
  );

  test('cancelling is not a run that found nothing', () async {
    final post = await createController();
    generateThrows = PlatformException(code: 'CAPTIONS_CANCELLED');

    await post.generateCaptions();

    expect(post.isGeneratingCaptions, isFalse);
    expect(
      post.hasEverGeneratedCaptions,
      isFalse,
      reason: '"no speech found" after a deliberate cancel is a lie',
    );
  });

  test('cancel reaches native only while something is running', () async {
    final post = await createController();

    await post.cancelCaptions();
    expect(callsNamed('cancelCaptions'), isEmpty);

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();
    await post.cancelCaptions();
    expect(callsNamed('cancelCaptions'), hasLength(1));

    generateGate!.complete([]);
    await run;
  });

  // ---- Cancelling --------------------------------------------------------

  test('cancelling is acknowledged before native answers', () async {
    // The engine cannot be interrupted mid-download, so the acknowledgement
    // cannot wait for it. This is the state the panel renders as "Stopping…".
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    final cancelling = post.cancelCaptions();

    expect(
      post.isCancellingCaptions,
      isTrue,
      reason: 'set synchronously, before the native round trip resolves',
    );
    expect(post.captionsProgress, isNull);

    await cancelling;
    generateGate!.complete([]);
    await run;
    expect(post.isCancellingCaptions, isFalse);
    expect(post.isGeneratingCaptions, isFalse);
  });

  test('a second stop press does not reach native', () async {
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    await post.cancelCaptions();
    await post.cancelCaptions();
    await post.cancelCaptions();

    expect(
      callsNamed('cancelCaptions'),
      hasLength(1),
      reason: 'the logs show eleven presses in four seconds; one is enough',
    );

    generateGate!.complete([]);
    await run;
  });

  test('progress from a cancelled job never moves the bar again', () async {
    // A cancelled job keeps emitting while it unwinds. Those ticks must not
    // advance a bar the user has already stopped.
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();
    await post.cancelCaptions();

    post.updateCaptionsProgress(
      const JobProgress(
        job: ProgressJob.captions,
        stage: ProgressStage.transcribing,
        fraction: 0.9,
      ),
    );

    expect(post.captionsProgress, isNull);

    generateGate!.complete([]);
    await run;
  });

  test('a fresh run clears the stopping state', () async {
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final first = post.generateCaptions();
    await pumpEventQueue();
    await post.cancelCaptions();
    generateGate!.complete([]);
    await first;

    generateGate = null;
    await post.generateCaptions();

    expect(post.isCancellingCaptions, isFalse);
  });

  // ---- Progress ---------------------------------------------------------

  test('progress ticks land only while a transcription runs', () async {
    final post = await createController();

    // A late tick from a job that already ended must not resurrect the bar.
    post.updateCaptionsProgress(
      const JobProgress(
        job: ProgressJob.captions,
        stage: ProgressStage.transcribing,
        fraction: 0.5,
      ),
    );
    expect(post.captionsProgress, isNull);

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.updateCaptionsProgress(
      const JobProgress(
        job: ProgressJob.captions,
        stage: ProgressStage.transcribing,
        fraction: 0.5,
      ),
    );
    expect(post.captionsProgress, 0.5);
    expect(post.captionsStage, ProgressStage.transcribing);

    generateGate!.complete(transcriptReply);
    await run;
    expect(
      post.captionsProgress,
      isNull,
      reason: 'a finished job leaves no half-full bar behind',
    );
  });

  test('a run starts indeterminate, not at zero', () async {
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();

    final run = post.generateCaptions();
    await pumpEventQueue();

    expect(post.captionsProgress, isNull);
    expect(post.captionsStage, ProgressStage.preparing);

    generateGate!.complete([]);
    await run;
  });

  // ---- Editing ----------------------------------------------------------

  test(
    'an edit replaces only the text, keeping the cue on the clock',
    () async {
      final post = await createController();
      await post.generateCaptions();

      post.updateCaptionText('c1', 'Clingfy');

      final edited = post.captions.firstWhere((c) => c.id == 'c1');
      expect(edited.text, 'Clingfy');
      expect(edited.startMs, 0);
      expect(edited.endMs, 1500);
      expect(
        post.captions[1].text,
        'second line',
        reason: 'siblings untouched',
      );
      expect(post.captions, hasLength(2));
    },
  );

  test('an edit is trimmed', () async {
    final post = await createController();
    await post.generateCaptions();

    post.updateCaptionText('c1', '  padded  ');
    expect(post.captions.first.text, 'padded');
  });

  test('an unknown cue id changes nothing', () async {
    final post = await createController();
    await post.generateCaptions();
    final before = post.captions;

    post.updateCaptionText('does-not-exist', 'ghost');

    expect(
      identical(post.captions, before),
      isTrue,
      reason: 'no new list means no rebuild for a no-op edit',
    );
  });

  test('re-committing the same text does not churn the list', () async {
    final post = await createController();
    await post.generateCaptions();
    final before = post.captions;

    post.updateCaptionText('c1', 'hello there');

    expect(identical(post.captions, before), isTrue);
  });

  test('an edit publishes a new list so the sidebar rebuilds', () async {
    final post = await createController();
    await post.generateCaptions();
    final before = post.captions;

    post.updateCaptionText('c1', 'changed');

    expect(
      identical(post.captions, before),
      isFalse,
      reason:
          'the selector compares by identity; mutating in place is invisible',
    );
  });

  test('word timings survive a text correction', () async {
    transcriptReply = [
      {
        'id': 'c1',
        'startMs': 0,
        'endMs': 1000,
        'text': 'hello wrld',
        'words': [
          {'startMs': 0, 'endMs': 400, 'text': 'hello'},
          {'startMs': 400, 'endMs': 1000, 'text': 'wrld'},
        ],
      },
    ];
    final post = await createController();
    await post.generateCaptions();
    expect(post.captions.first.words, hasLength(2));

    post.updateCaptionText('c1', 'hello world');

    expect(
      post.captions.first.words,
      hasLength(2),
      reason:
          'cut-reflow needs the timings; dropping them on an edit breaks it',
    );
    expect(post.captions.first.words.first.endMs, 400);
  });

  // ---- Persistence -------------------------------------------------------

  test('a generated transcript is written into the project bundle', () async {
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);
    await pumpEventQueue();

    await post.generateCaptions();

    // Persistence is fire-and-forget, so the write can outlast a fixed number
    // of event-loop pumps when the suite is contending for the disk. Poll for
    // the file instead of guessing how long it takes.
    final stored = await waitForValue(
      () => CaptionStateStore.load(project.path),
      reason: 'the transcript should have been written',
    );
    expect(stored.captions.map((c) => c.text), ['hello there', 'second line']);
  });

  test('a correction is persisted, not just held in memory', () async {
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);
    await pumpEventQueue();
    await post.generateCaptions();

    post.updateCaptionText('c1', 'Clingfy');

    await waitUntil(
      () =>
          CaptionStateStore.load(project.path)?.captions.first.text ==
          'Clingfy',
      reason: 'the correction should have been written',
    );
  });

  test('reopening a recording restores its transcript', () async {
    // The whole point of persisting: minutes of compute plus the user\'s own
    // corrections must not die with the window.
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(
        captions: const [
          Caption(id: 'old', startMs: 0, endMs: 900, text: 'from last time'),
        ],
      ),
    );

    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);

    expect(post.captions.map((c) => c.text), ['from last time']);
    expect(
      post.hasEverGeneratedCaptions,
      isTrue,
      reason: 'a restored transcript is not a recording that never ran',
    );
  });

  test('a recording with no stored transcript opens empty', () async {
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);

    expect(post.captions, isEmpty);
    expect(post.hasEverGeneratedCaptions, isFalse);
  });

  // ---- Project switching -------------------------------------------------

  test('a new recording does not inherit the last one\'s subtitles', () async {
    final post = await createController();
    await post.generateCaptions();
    expect(post.captions, isNotEmpty);

    post.attachToRecording(
      sessionId: 'rec_second',
      projectPath: '/tmp/second.clingfyproj',
    );

    // The second project has no stored transcript, so it opens empty rather
    // than showing the first recording's subtitles.
    expect(post.captions, isEmpty);
    expect(post.hasEverGeneratedCaptions, isFalse);
    // Cleared and re-probed rather than carried over: the new recording may
    // have entirely different audio on disk.
    await pumpEventQueue();
    expect(callsNamed('captionsCapability'), hasLength(2));
    expect(
      callsNamed('captionsCapability').last.arguments,
      containsPair('projectPath', '/tmp/second.clingfyproj'),
    );
  });
}
