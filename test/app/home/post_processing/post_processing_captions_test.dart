import 'dart:async';
import 'package:clingfy/core/timeline/post_state_store.dart';
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

  /// The bundle [createController] attached to, for tests that assert the
  /// project path reaches native.
  late String attachedProjectPath;

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
      // A temp bundle per controller, not a shared '/tmp/original.clingfyproj'.
      // Editor state is real file I/O, so a fixed path lets one test's saved
      // transcript reappear in the next one — and it persisted between whole
      // runs of the suite, which made failures depend on what ran last.
      final bundle = await Directory.systemTemp.createTemp('clingfy_caps_ctl');
      addTearDown(() async {
        await PostStateStore.settled();
        if (bundle.existsSync()) bundle.deleteSync(recursive: true);
      });
      attachedProjectPath = bundle.path;
      post.attachToRecording(
        sessionId: 'rec_captions',
        projectPath: bundle.path,
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
      containsPair('projectPath', attachedProjectPath),
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

    final bundle = await Directory.systemTemp.createTemp('clingfy_caps_probe');
    addTearDown(() {
      if (bundle.existsSync()) bundle.deleteSync(recursive: true);
    });
    post.attachToRecording(sessionId: 's', projectPath: bundle.path);
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
    expect(call.arguments, containsPair('projectPath', attachedProjectPath));
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
    addTearDown(() async {
      await PostStateStore.settled();
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
      () => PostStateStore.load(project.path).trackOfType<CaptionTrack>(),
      reason: 'the transcript should have been written',
    );
    expect(stored.captions.map((c) => c.text), ['hello there', 'second line']);
  });

  test('a correction is persisted, not just held in memory', () async {
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() async {
      await PostStateStore.settled();
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);
    await pumpEventQueue();
    await post.generateCaptions();

    post.updateCaptionText('c1', 'Clingfy');

    await waitUntil(
      () =>
          PostStateStore.load(
            project.path,
          ).trackOfType<CaptionTrack>()?.captions.first.text ==
          'Clingfy',
      reason: 'the correction should have been written',
    );
  });

  test('reopening a recording restores its transcript', () async {
    // The whole point of persisting: minutes of compute plus the user\'s own
    // corrections must not die with the window.
    final project = await Directory.systemTemp.createTemp('clingfy_persist');
    addTearDown(() async {
      await PostStateStore.settled();
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
    addTearDown(() async {
      await PostStateStore.settled();
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

  /// Two real bundles, so a transcription started on one can be observed
  /// landing after the controller has moved to the other.
  Future<(Directory, Directory)> twoProjects() async {
    final a = await Directory.systemTemp.createTemp('clingfy_caps_a');
    final b = await Directory.systemTemp.createTemp('clingfy_caps_b');
    addTearDown(() async {
      await PostStateStore.settled();
      if (a.existsSync()) a.deleteSync(recursive: true);
      if (b.existsSync()) b.deleteSync(recursive: true);
    });
    return (a, b);
  }

  test('a transcript that lands after the user moved on is saved to its own '
      'recording', () async {
    // Minutes of compute used to be dropped on the floor here: the "is this
    // still the open project" guard sat BEFORE the assignment and the
    // persist, so a job that finished after the user opened the next
    // recording was neither applied nor written, with no message. Reopening
    // that recording then showed it as never transcribed.
    //
    // Project A has no transcript of its own, which is what makes this write
    // safe to do behind the user's back: it destroys nothing. The companion
    // case — A already holding hand-corrected cues — is pinned below, and there
    // the same run must NOT write.
    final (projectA, projectB) = await twoProjects();
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();

    generateGate!.complete(transcriptReply);
    await run;

    final stored = await waitForValue(
      () => PostStateStore.load(projectA.path).trackOfType<CaptionTrack>(),
      reason: 'the cues belong to the recording they were transcribed from',
    );
    expect(stored.captions.map((c) => c.text), ['hello there', 'second line']);
    expect(
      post.captions,
      isEmpty,
      reason: 'and must not surface on the recording now open',
    );
    expect(
      PostStateStore.load(projectB.path).trackOfType<CaptionTrack>(),
      isNull,
      reason: 'nor be written into it',
    );
  });

  test(
    'opening another recording does not hand it the running transcription',
    () async {
      // Recording B used to show A's progress bar and A's Stop button, and A's
      // ticks moved B's bar.
      final (projectA, projectB) = await twoProjects();
      final post = await createController(attach: false);
      post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
      await pumpEventQueue();

      generateGate = Completer<List<Map<String, Object?>>>();
      final run = post.generateCaptions();
      await pumpEventQueue();
      post.updateCaptionsProgress(
        const JobProgress(
          job: ProgressJob.captions,
          stage: ProgressStage.transcribing,
          fraction: 0.4,
        ),
      );
      expect(post.captionsProgress, 0.4, reason: 'A owns the job');

      post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
      await pumpEventQueue();

      expect(post.isGeneratingCaptions, isFalse);
      expect(post.captionsProgress, isNull);
      expect(post.captionsStage, ProgressStage.preparing);

      post.updateCaptionsProgress(
        const JobProgress(
          job: ProgressJob.captions,
          stage: ProgressStage.transcribing,
          fraction: 0.9,
        ),
      );
      expect(
        post.captionsProgress,
        isNull,
        reason: "a tick from A's job must not move B's bar",
      );

      generateGate!.complete(transcriptReply);
      await run;
      expect(post.captions, isEmpty);
    },
  );

  test('switching recordings frees the caption engine', () async {
    // The engine takes one job at a time. Left running, it makes Generate on
    // the newly-opened recording do nothing at all — so the job is cancelled,
    // and until it unwinds no second native job is started.
    final (projectA, projectB) = await twoProjects();
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();

    expect(callsNamed('cancelCaptions'), hasLength(1));

    // Deliberately not awaited: without the engine-busy guard this reaches
    // native and blocks on the same gate, and a hung test is a far worse signal
    // than a failed assertion.
    final second = post.generateCaptions();
    await pumpEventQueue();
    expect(
      callsNamed('generateCaptions'),
      hasLength(1),
      reason: 'two concurrent native jobs is a crash, not a queue',
    );

    generateGate!.complete(transcriptReply);
    await run;
    await second;
  });

  // ---- Export interlock --------------------------------------------------

  test('export is unavailable while a transcription runs', () async {
    // Export stayed enabled throughout a "Generate again", so pressing it let
    // the transcription land mid-render and sweep away the caption bitmaps the
    // export was still reading — a video with subtitles for the first part and
    // none after, reported as a success.
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    expect(post.isExportLocked, isTrue);

    generateGate!.complete(transcriptReply);
    await run;
    expect(post.isExportLocked, isFalse);
  });

  test('the editor is NOT locked while a transcription runs', () async {
    // The two locks are separate for one reason: the editing lock dims the
    // whole post-processing sidebar behind an IgnorePointer, and the captions
    // Stop button lives in there with no other route to cancelCaptions(). Fold
    // them back together and a 626 MB model download becomes unstoppable —
    // strictly worse than the export race the wide lock was added for.
    final post = await createController();
    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    expect(post.isGeneratingCaptions, isTrue);
    expect(
      post.isEditingLocked,
      isFalse,
      reason: 'the panel holding Stop must stay interactive',
    );

    generateGate!.complete(transcriptReply);
    await run;
  });

  // ---- An abandoned run must not destroy a transcript --------------------

  test('a stopped run that finishes anyway leaves the stored cues alone', () async {
    // Native cancellation is POLLED: a job already past its last check returns
    // a full transcript no matter how firmly it was stopped. Writing that over
    // the project's stored track is how hand corrections disappeared — the user
    // pressed Stop and lost work by doing so.
    final project = await Directory.systemTemp.createTemp('clingfy_caps_stop');
    addTearDown(() async {
      await PostStateStore.settled();
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    await PostStateStore.update(
      project.path,
      (state) => state.withTrack(
        const CaptionTrack(
          captions: [
            Caption(id: 'c1', startMs: 0, endMs: 1500, text: 'Clingfy'),
          ],
        ),
      ),
    );

    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);
    await pumpEventQueue();
    expect(post.captions.single.text, 'Clingfy');

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();
    await post.cancelCaptions();

    // The engine was already past its last cancel check: it completes.
    generateGate!.complete(transcriptReply);
    await run;
    await PostStateStore.settled();

    expect(
      PostStateStore.load(
        project.path,
      ).trackOfType<CaptionTrack>()?.captions.map((c) => c.text),
      ['Clingfy'],
      reason: 'the correction the user typed outranks a run they stopped',
    );
    expect(
      post.captions.single.text,
      'Clingfy',
      reason: 'nor may it appear on screen — Stop meant stop',
    );
  });

  test('a run the user stopped is not stored, even where nothing is at '
      'risk', () async {
    // The salvage write exists for cues NOBODY refused — a job the controller
    // cancelled to free the engine. A Stop the user pressed is a refusal, and
    // "the project has no transcript, so writing costs nothing" is not a reason
    // to keep one: it comes back on the next open, and with burn-in the default
    // destination it can end up rendered into a published video.
    final project = await Directory.systemTemp.createTemp('clingfy_caps_stop2');
    addTearDown(() async {
      await PostStateStore.settled();
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 's', projectPath: project.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();
    await post.cancelCaptions();

    // Past its last cancel poll — native completes and returns everything.
    generateGate!.complete(transcriptReply);
    await run;
    await PostStateStore.settled();

    expect(
      PostStateStore.load(project.path).trackOfType<CaptionTrack>(),
      isNull,
      reason: 'Stop means the transcript is gone, not filed away',
    );
    expect(post.captions, isEmpty, reason: 'and nothing appears on screen');
  });

  test(
    'opening another recording does not resurrect a stopped transcript',
    () async {
      // The reported sequence: Stop pressed during the model download, then the
      // next recording opened while the engine is still unwinding. The switch
      // cancels too — and when both cancels were the same flag, the switch
      // relabelled the user's refusal as "the controller moved on", which made the
      // salvage write legal and put the abandoned transcript on disk.
      final (projectA, projectB) = await twoProjects();
      final post = await createController(attach: false);
      post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
      await pumpEventQueue();

      generateGate = Completer<List<Map<String, Object?>>>();
      final run = post.generateCaptions();
      await pumpEventQueue();
      await post.cancelCaptions();

      post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
      await pumpEventQueue();

      generateGate!.complete(transcriptReply);
      await run;
      await PostStateStore.settled();

      expect(
        PostStateStore.load(projectA.path).trackOfType<CaptionTrack>(),
        isNull,
        reason: 'walking away does not un-press Stop',
      );
      expect(
        PostStateStore.load(projectB.path).trackOfType<CaptionTrack>(),
        isNull,
        reason: 'nor does it belong to the recording now open',
      );
    },
  );

  test('a salvaged transcript is never written behind the recording on '
      'screen', () async {
    // A leaves the screen (which cancels), then comes back before the job has
    // unwound. The panel in front of the user says "not transcribed"; a write it
    // cannot see is the same surprise on the next open that the salvage rule
    // exists to avoid. The cues are simply let go — the user is right there and
    // can press Generate again.
    final (projectA, projectB) = await twoProjects();
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();
    post.attachToRecording(sessionId: 'a2', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate!.complete(transcriptReply);
    await run;
    await PostStateStore.settled();

    expect(
      PostStateStore.load(projectA.path).trackOfType<CaptionTrack>(),
      isNull,
      reason: 'the screen and the bundle must not disagree about A',
    );
    expect(post.captions, isEmpty);
  });

  // ---- The engine is busy with someone else ------------------------------

  test('the newly-opened recording says the engine is still busy', () async {
    // The cancel that frees the engine is best-effort against a download that
    // cannot be interrupted, so the wait can be minutes. Throughout it,
    // recording B showed a live "Generate subtitles" whose press the
    // engine-busy guard silently dropped — a button that does nothing is
    // indistinguishable from a broken feature.
    final (projectA, projectB) = await twoProjects();
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();
    expect(
      post.isCaptionsEngineBusyOffScreen,
      isFalse,
      reason: 'A owns this job: it gets the progress row, not the notice',
    );

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();

    expect(post.isCaptionsEngineBusyOffScreen, isTrue);
    // Proof that the button had to be dead: the press cannot reach native.
    final refused = post.generateCaptions();
    await pumpEventQueue();
    expect(callsNamed('generateCaptions'), hasLength(1));

    generateGate!.complete(transcriptReply);
    await run;
    await refused;

    expect(
      post.isCaptionsEngineBusyOffScreen,
      isFalse,
      reason: 'the engine came free; Generate has to come back with it',
    );
  });

  test('coming back to the recording whose job is still unwinding does not '
      'offer a dead button either', () async {
    // The corner a "is the job on another project" test misses: the user
    // returns to A. The job that is still occupying the engine IS A's, so a
    // project comparison calls the engine free — and hands back exactly the
    // enabled Generate that does nothing. The progress row is gone (the switch
    // tore it down), so there would be nothing on screen at all.
    final (projectA, projectB) = await twoProjects();
    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();
    post.attachToRecording(sessionId: 'a2', projectPath: projectA.path);
    await pumpEventQueue();

    expect(
      post.isGeneratingCaptions,
      isFalse,
      reason: 'no progress row: this run was cancelled on the way out',
    );
    expect(post.isCaptionsEngineBusyOffScreen, isTrue);
    final refused = post.generateCaptions();
    await pumpEventQueue();
    expect(callsNamed('generateCaptions'), hasLength(1));

    generateGate!.complete(transcriptReply);
    await run;
    await refused;
    expect(post.isCaptionsEngineBusyOffScreen, isFalse);
  });

  test('an abandoned regeneration does not overwrite corrections on the '
      'recording left behind', () async {
    // The reported sequence: recording A holds hand-corrected cues, the user
    // presses Regenerate and opens recording B before it finishes. The switch
    // cancels, but the job is past its last poll and completes — and used to
    // write its machine transcript straight over A's corrections.
    final (projectA, projectB) = await twoProjects();
    await PostStateStore.update(
      projectA.path,
      (state) => state.withTrack(
        const CaptionTrack(
          captions: [
            Caption(id: 'c1', startMs: 0, endMs: 1500, text: 'Clingfy'),
          ],
        ),
      ),
    );

    final post = await createController(attach: false);
    post.attachToRecording(sessionId: 'a', projectPath: projectA.path);
    await pumpEventQueue();
    expect(post.captions.single.text, 'Clingfy');

    generateGate = Completer<List<Map<String, Object?>>>();
    final run = post.generateCaptions();
    await pumpEventQueue();

    post.attachToRecording(sessionId: 'b', projectPath: projectB.path);
    await pumpEventQueue();

    generateGate!.complete(transcriptReply);
    await run;
    await PostStateStore.settled();

    expect(
      PostStateStore.load(
        projectA.path,
      ).trackOfType<CaptionTrack>()?.captions.map((c) => c.text),
      ['Clingfy'],
      reason: 'minutes of compute are worth less than typed corrections',
    );
  });
}
