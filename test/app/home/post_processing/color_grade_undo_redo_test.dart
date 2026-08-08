import 'dart:async';
import 'dart:io';

import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';
import '../../../test_helpers/wait_until.dart';

/// Color-grade undo/redo through the real [PostProcessingController] wiring.
///
/// The command itself is unit-tested in
/// `test/core/timeline/set_color_grade_command_test.dart`; what only the live
/// controller can prove is the *gesture* contract — a slider drag emits many
/// ticks but must collapse into exactly one history entry — plus the fact that
/// stepping through history re-pushes the grade to the native preview and
/// re-persists it, the same two side effects a normal commit has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory projectDir;
  late List<MethodCall> colorGradeCalls;
  // When non-null, getRecordingSceneInfo parks until this completes, so a test
  // controls exactly when the async restore lands relative to its own edits.
  Completer<void>? sceneLoadGate;

  setUp(() async {
    await installCommonNativeMocks();
    projectDir = await Directory.systemTemp.createTemp('clingfy_grade_undo_');
    colorGradeCalls = <MethodCall>[];
    sceneLoadGate = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
        case 'getRecordingSceneInfo':
          if (sceneLoadGate != null) {
            await sceneLoadGate!.future;
          }
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    // Let any fire-and-forget PostStateStore write drain before the
    // directory is removed, so the delete never races a file being recreated.
    await _settle();
    await PostStateStore.settled();
    if (await projectDir.exists()) {
      try {
        await projectDir.delete(recursive: true);
      } on FileSystemException {
        // A late write recreated the bundle mid-delete; harmless in a temp dir.
      }
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
    post.attachToRecording(
      sessionId: 'rec_grade_undo',
      projectPath: projectPath,
    );
    await _settle();
    return post;
  }

  /// One slider gesture: several live ticks, then the release.
  void dragExposureTo(PostProcessingController post, double target) {
    for (final v in [target / 3, target * 2 / 3, target]) {
      post.setColorGradeExposure(v);
    }
    post.commitColorGrade();
  }

  test('drag ticks notify listeners without recording history', () async {
    final post = await attachController(projectDir.path);

    var notifications = 0;
    void listener() => notifications++;
    post.addListener(listener);
    addTearDown(() => post.removeListener(listener));

    post.setColorGradeExposure(0.1);
    post.setColorGradeExposure(0.2);
    post.setColorGradeExposure(0.3);

    // Every tick notifies so the sliders and preview track the drag, but the
    // gesture is still open — nothing is committed.
    expect(notifications, 3);
    expect(post.canUndoColorGrade, isFalse);
  });

  test('the pre-gesture rewind is never visible to listeners', () async {
    // commitColorGrade sets _colorGrade back to the baseline so the command
    // snapshots an honest "previous", then execute() immediately re-applies
    // the final value. If a notify ever landed in between, every slider would
    // snap to neutral on release — and no other test would catch it.
    final post = await attachController(projectDir.path);

    final seen = <double>[];
    void listener() => seen.add(post.colorGrade.exposure);
    post.addListener(listener);
    addTearDown(() => post.removeListener(listener));

    post.setColorGradeExposure(0.2);
    post.setColorGradeExposure(0.4);
    post.setColorGradeExposure(0.6);
    post.commitColorGrade();

    expect(seen, [0.2, 0.4, 0.6, 0.6]);
    expect(seen, isNot(contains(0.0)), reason: 'the baseline never resurfaces');
  });

  test(
    'every slider feeds one gesture and clamps to the legal range',
    () async {
      final post = await attachController(projectDir.path);

      post.setColorGradeTint(5.0);
      post.setColorGradeTemperature(-3.0);
      expect(post.colorGrade.tint, 1.0);
      expect(post.colorGrade.temperature, -1.0);

      post.commitColorGrade();

      // Both sliders moved inside one gesture, so they collapse into one entry.
      post.undoColorGrade();
      expect(post.colorGrade.tint, 0);
      expect(post.colorGrade.temperature, 0);
      expect(post.canUndoColorGrade, isFalse);
    },
  );

  test('a whole slider drag collapses into one undoable entry', () async {
    final post = await attachController(projectDir.path);
    expect(post.canUndoColorGrade, isFalse);
    expect(post.canRedoColorGrade, isFalse);

    dragExposureTo(post, 0.6);

    expect(post.colorGrade.exposure, 0.6);
    expect(post.canUndoColorGrade, isTrue);

    // One entry, not one per tick: a single undo returns to neutral.
    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0);
    expect(post.colorGrade.isIdentity, isTrue);
    expect(post.canUndoColorGrade, isFalse);
    expect(post.canRedoColorGrade, isTrue);

    post.redoColorGrade();
    expect(post.colorGrade.exposure, 0.6);
    expect(post.canRedoColorGrade, isFalse);
  });

  test('ticks before the release are not yet undoable', () async {
    final post = await attachController(projectDir.path);

    post.setColorGradeExposure(0.2);
    post.setColorGradeExposure(0.4);

    // The preview already tracks the drag, but nothing is committed.
    expect(post.colorGrade.exposure, 0.4);
    expect(post.canUndoColorGrade, isFalse);

    post.commitColorGrade();
    expect(post.canUndoColorGrade, isTrue);
  });

  test('a commit with no net change records no entry', () async {
    final post = await attachController(projectDir.path);

    // Release with no movement at all (tap on the slider track).
    post.commitColorGrade();
    expect(post.canUndoColorGrade, isFalse);

    // Drag out and back to where it started.
    post.setColorGradeContrast(0.3);
    post.setColorGradeContrast(0);
    post.commitColorGrade();
    expect(post.canUndoColorGrade, isFalse);
    expect(post.colorGrade.isIdentity, isTrue);
  });

  test('separate gestures undo one at a time, newest first', () async {
    final post = await attachController(projectDir.path);

    dragExposureTo(post, 0.5);
    post.setColorGradeSaturation(-0.4);
    post.commitColorGrade();

    expect(post.colorGrade.exposure, 0.5);
    expect(post.colorGrade.saturation, -0.4);

    post.undoColorGrade();
    expect(post.colorGrade.saturation, 0);
    expect(post.colorGrade.exposure, 0.5, reason: 'older edit survives');

    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0);
    expect(post.canUndoColorGrade, isFalse);

    post.redoColorGrade();
    post.redoColorGrade();
    expect(post.colorGrade.exposure, 0.5);
    expect(post.colorGrade.saturation, -0.4);
  });

  test('auto-enhance is its own undoable entry', () async {
    final post = await attachController(projectDir.path);

    dragExposureTo(post, 0.25);
    final beforeAuto = post.colorGrade;

    post.setColorGradeAutoEnhance(true);
    expect(post.colorGrade.autoEnabled, isTrue);
    expect(post.colorGrade, isNot(beforeAuto));

    post.undoColorGrade();
    expect(post.colorGrade, beforeAuto);
    expect(post.colorGrade.autoEnabled, isFalse);

    post.redoColorGrade();
    expect(post.colorGrade.autoEnabled, isTrue);
  });

  test('an ordinary auto click pushes the new grade once, not twice', () async {
    // The Auto toggle closes any open slider gesture first. When none is open
    // — the normal case, since Auto is a different widget from the sliders —
    // that must not run a second commit pass for the PRE-toggle grade: it
    // would push a stale grade to the preview and race a stale editor_state
    // write against the real one.
    final post = await attachController(projectDir.path);
    colorGradeCalls.clear();

    post.setColorGradeAutoEnhance(true);

    expect(colorGradeCalls, hasLength(1));
    final args = Map<String, dynamic>.from(
      colorGradeCalls.single.arguments as Map<dynamic, dynamic>,
    );
    final grade = Map<String, dynamic>.from(
      args['colorGrade'] as Map<dynamic, dynamic>,
    );
    expect(grade['autoEnabled'], isTrue);

    await _waitUntil(
      () => PostStateStore.load(projectDir.path).grade == post.colorGrade,
    );
  });

  test('auto pressed mid-drag keeps the drag as its own entry', () async {
    final post = await attachController(projectDir.path);

    // Drag the exposure slider but click Auto before releasing it.
    post.setColorGradeExposure(0.3);
    post.setColorGradeExposure(0.6);
    post.setColorGradeAutoEnhance(true);

    expect(post.colorGrade.autoEnabled, isTrue);

    // Two entries, not one: Auto first, then the drag underneath it.
    post.undoColorGrade();
    expect(post.colorGrade.autoEnabled, isFalse);
    expect(post.colorGrade.exposure, 0.6, reason: 'the drag survives');

    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0);
    expect(post.canUndoColorGrade, isFalse);
  });

  test('toggling auto off is undoable back to the enhanced grade', () async {
    final post = await attachController(projectDir.path);

    post.setColorGradeAutoEnhance(true);
    final enhanced = post.colorGrade;
    expect(enhanced.autoEnabled, isTrue);

    post.setColorGradeAutoEnhance(false);
    expect(post.colorGrade.isIdentity, isTrue);

    post.undoColorGrade();
    expect(post.colorGrade, enhanced);
  });

  test('a new edit after an undo drops the redo stack', () async {
    final post = await attachController(projectDir.path);

    dragExposureTo(post, 0.5);
    post.undoColorGrade();
    expect(post.canRedoColorGrade, isTrue);

    dragExposureTo(post, -0.2);
    expect(post.canRedoColorGrade, isFalse);
    expect(post.colorGrade.exposure, -0.2);
  });

  test('undo pushes the restored grade to the native preview', () async {
    final post = await attachController(projectDir.path);

    dragExposureTo(post, 0.7);
    colorGradeCalls.clear();

    post.undoColorGrade();

    expect(colorGradeCalls, isNotEmpty);
    final args = Map<String, dynamic>.from(
      colorGradeCalls.last.arguments as Map<dynamic, dynamic>,
    );
    final grade = Map<String, dynamic>.from(
      args['colorGrade'] as Map<dynamic, dynamic>,
    );
    expect(grade['exposure'], 0);
  });

  test('undo re-persists the restored grade to post/state.json', () async {
    final post = await attachController(projectDir.path);

    dragExposureTo(post, 0.45);
    await _waitUntil(
      () => PostStateStore.load(projectDir.path).grade.exposure == 0.45,
    );

    post.undoColorGrade();
    await _waitUntil(
      () => PostStateStore.load(projectDir.path).grade.isIdentity == true,
    );

    final loaded = PostStateStore.load(projectDir.path);
    expect(loaded.grade.exposure, 0);
    expect(loaded.grade.isIdentity, isTrue);
  });

  test('undo notifies listeners so the sliders rebuild', () async {
    final post = await attachController(projectDir.path);
    dragExposureTo(post, 0.3);

    var notifications = 0;
    void listener() => notifications++;
    post.addListener(listener);
    addTearDown(() => post.removeListener(listener));

    post.undoColorGrade();
    expect(notifications, greaterThan(0));

    notifications = 0;
    post.redoColorGrade();
    expect(notifications, greaterThan(0));
  });

  test('history does not leak across recordings', () async {
    final post = await attachController(projectDir.path);
    dragExposureTo(post, 0.5);
    expect(post.canUndoColorGrade, isTrue);

    final other = await Directory.systemTemp.createTemp('clingfy_grade_undo2_');
    addTearDown(() async {
      if (await other.exists()) await other.delete(recursive: true);
    });

    post.attachToRecording(sessionId: 'rec_other', projectPath: other.path);
    await _settle();

    expect(post.canUndoColorGrade, isFalse);
    expect(post.canRedoColorGrade, isFalse);
    expect(post.colorGrade.isIdentity, isTrue);
  });

  test('detaching the recording clears the history', () async {
    final post = await attachController(projectDir.path);
    dragExposureTo(post, 0.5);

    post.detachRecording();

    expect(post.canUndoColorGrade, isFalse);
    expect(post.canRedoColorGrade, isFalse);
  });

  test('auto with no net change records no entry', () async {
    final post = await attachController(projectDir.path);
    colorGradeCalls.clear();

    // Toggling Auto off on an already-neutral grade: next == current, so the
    // early return fires — it still syncs, but records nothing.
    post.setColorGradeAutoEnhance(false);
    expect(post.canUndoColorGrade, isFalse);
    expect(colorGradeCalls, hasLength(1));

    // Turning it on twice records exactly one entry, for the same reason.
    post.setColorGradeAutoEnhance(true);
    post.setColorGradeAutoEnhance(true);
    post.undoColorGrade();
    expect(post.colorGrade.isIdentity, isTrue);
    expect(post.canUndoColorGrade, isFalse);
  });

  test('auto after a zero-net gesture still pushes only once', () async {
    // A gesture that ends where it started must not make the Auto toggle emit
    // a stale pre-toggle push ahead of the real one.
    final post = await attachController(projectDir.path);

    post.setColorGradeExposure(0.3);
    post.setColorGradeExposure(0);
    colorGradeCalls.clear();

    post.setColorGradeAutoEnhance(true);

    expect(colorGradeCalls, hasLength(1));
    final args = Map<String, dynamic>.from(
      colorGradeCalls.single.arguments as Map<dynamic, dynamic>,
    );
    final grade = Map<String, dynamic>.from(
      args['colorGrade'] as Map<dynamic, dynamic>,
    );
    expect(grade['autoEnabled'], isTrue);

    // And it is one entry: undo goes straight back to neutral.
    post.undoColorGrade();
    expect(post.colorGrade.isIdentity, isTrue);
    expect(post.canUndoColorGrade, isFalse);
  });

  test('undo and redo are inert with an empty history', () async {
    final post = await attachController(projectDir.path);

    var notifications = 0;
    void listener() => notifications++;
    post.addListener(listener);
    addTearDown(() => post.removeListener(listener));

    // A drag is open but nothing is committed, so both stacks are empty.
    post.setColorGradeExposure(0.5);
    notifications = 0;
    colorGradeCalls.clear();

    post.undoColorGrade();
    post.redoColorGrade();

    expect(notifications, 0);
    expect(colorGradeCalls, isEmpty);
    expect(post.colorGrade.exposure, 0.5, reason: 'the open drag is untouched');

    // The early return skips the baseline clear, so the gesture still commits.
    post.commitColorGrade();
    expect(post.canUndoColorGrade, isTrue);
    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0);
  });

  test('redo mid-drag abandons the uncommitted ticks', () async {
    // The untested twin of the undo case below: redoColorGrade carries the
    // same baseline-clearing line.
    final post = await attachController(projectDir.path);
    dragExposureTo(post, 0.5);
    post.undoColorGrade();
    expect(post.canRedoColorGrade, isTrue);

    // Start a drag that is never released, then hit redo.
    post.setColorGradeExposure(0.9);
    post.redoColorGrade();

    expect(post.colorGrade.exposure, 0.5, reason: 'the redo won');
    expect(post.canRedoColorGrade, isFalse);
    expect(post.canUndoColorGrade, isTrue);

    // The loose tick must not surface as a phantom entry on the next commit.
    post.commitColorGrade();
    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0);
    expect(post.canUndoColorGrade, isFalse);
  });

  test(
    'opening a recording with no saved state leaves history alone',
    () async {
      // The bundle has no editor_state.json when the scene load reads it, so
      // the restore early-returns BEFORE clearing the session — the opposite
      // branch from the restore test below. A real edit afterwards must still
      // be undoable. (The file does exist by the end: the attach persists the
      // defaults on its way through applyProcessing.)
      final post = await attachController(projectDir.path);

      dragExposureTo(post, 0.4);
      expect(post.canUndoColorGrade, isTrue);

      post.undoColorGrade();
      expect(post.colorGrade.isIdentity, isTrue);
    },
  );

  test('undo mid-drag abandons the uncommitted ticks', () async {
    final post = await attachController(projectDir.path);
    dragExposureTo(post, 0.5);

    // Start a second drag but never release it, then hit undo.
    post.setColorGradeExposure(0.9);
    post.undoColorGrade();

    // The committed 0.5 edit is what got undone; the loose 0.9 tick is gone
    // and must not reappear as a phantom history entry on the next commit.
    expect(post.colorGrade.exposure, 0);
    expect(post.canUndoColorGrade, isFalse);

    post.commitColorGrade();
    expect(post.canUndoColorGrade, isFalse);
    expect(post.colorGrade.exposure, 0);
  });

  test('an edit inside the scene-load window leaves no stale history', () async {
    // The window: attachToRecording returns immediately and kicks off the scene
    // load, which later calls _loadCanvasAppearance and clears the colour
    // session. An edit committed inside that window has its grade replaced by
    // the restore. The invariant to pin is that no HISTORY entry survives
    // pointing at a grade the restore threw away — otherwise undo would jump to
    // a value the recording never had.
    //
    // A first attempt at this test was dropped as flaky because the outcome
    // depended on whether the edit's fire-and-forget write beat the restore's
    // read. Gating the scene load on a Completer removes that race entirely:
    // the test decides both the file contents AND the moment the restore reads
    // them.
    const savedGrade = ColorGrade(exposure: 0.2);
    final gate = Completer<void>();
    sceneLoadGate = gate;

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
      if (!gate.isCompleted) gate.complete();
      post.dispose();
      player.dispose();
      settings.dispose();
    });

    // The scene load parks on the gate, so we are inside the window.
    post.attachToRecording(
      sessionId: 'rec_window',
      projectPath: projectDir.path,
    );
    dragExposureTo(post, 0.8);
    expect(post.canUndoColorGrade, isTrue, reason: 'the edit was committed');

    // Let the edit's own persist land first, then plant the "already saved"
    // grade, so the restore is guaranteed to read 0.2 and not the edit.
    await waitUntil(
      () => PostStateStore.load(projectDir.path).grade.exposure == 0.8,
      reason: "the edit's own write must land before we overwrite it",
    );
    // Plant through the unified store: the edit above has already written
    // post/state.json, and that file outranks the legacy one this used to use.
    await PostStateStore.update(
      projectDir.path,
      (state) => state.copyWith(grade: savedGrade),
    );
    await waitUntil(
      () => PostStateStore.load(projectDir.path).grade.exposure == 0.2,
    );

    // Release the restore.
    gate.complete();
    await waitUntil(
      () => post.colorGrade.exposure == 0.2,
      reason: 'the restore should replace the in-window edit',
    );

    expect(post.colorGrade, savedGrade, reason: 'restore wins');
    expect(
      post.canUndoColorGrade,
      isFalse,
      reason: 'no history may survive pointing at the discarded grade',
    );
    expect(post.canRedoColorGrade, isFalse);

    // And a fresh edit after the window is undoable back to the RESTORED grade,
    // never to the value the restore discarded.
    dragExposureTo(post, 0.5);
    post.undoColorGrade();
    expect(post.colorGrade.exposure, 0.2);
  });

  test('a restored grade is the baseline for the first edit', () async {
    // Reopening a recording with a persisted grade must not make that grade
    // undoable — there is no edit to step back to, only saved state.
    await PostStateStore.save(
      projectDir.path,
      const Timeline(grade: ColorGrade(exposure: 0.2)),
    );

    final post = await attachController(projectDir.path);
    expect(post.colorGrade.exposure, 0.2);
    expect(post.canUndoColorGrade, isFalse);

    dragExposureTo(post, 0.8);
    post.undoColorGrade();

    expect(post.colorGrade.exposure, 0.2, reason: 'back to the saved grade');
  });
}

/// Pump the event queue enough to flush the controller's chained awaits plus
/// the fire-and-forget file write (real async I/O — a single microtask hop is
/// not enough). Bounded rather than a fixed sleep so a loaded machine does not
/// read a half-written bundle.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Polls until [done] holds, so disk assertions never race the fire-and-forget
/// `PostStateStore.save` (serialized per project path, so two
/// queued writes drain one after the other rather than concurrently).
Future<void> _waitUntil(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = timeout.inMilliseconds ~/ 5;
  for (var i = 0; i < deadline; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!done()) {
    throw StateError('condition still false after ${timeout.inMilliseconds}ms');
  }
}
