import 'dart:io';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/clips/clip_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/wait_until.dart';

import '../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeChannel.screenRecorder);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> setClipsCalls;

  setUp(() async {
    await installCommonNativeMocks();
    setClipsCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'previewSetClips') setClipsCalls.add(call);
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await clearCommonNativeMocks();
  });

  ClipEditorController make({int durationMs = 10000}) => ClipEditorController(
    nativeBridge: NativeBridge.instance,
    durationMs: durationMs,
    sessionId: 'sess-1',
  );

  // The latest clips payload pushed to native, as a list of maps.
  List<Map> lastPushedClips() {
    final args = setClipsCalls.last.arguments as Map;
    return (args['clips'] as List).cast<Map>();
  }

  test('starts as a single whole-recording clip with no cuts', () {
    final c = make();
    addTearDown(c.dispose);

    expect(c.clips, hasLength(1));
    expect(c.hasCuts, isFalse);
    expect(c.editedDurationMs, 10000);
    expect(c.canUndo, isFalse);
    expect(c.canDeleteSelected, isFalse);
  });

  test('splitAtPlayhead creates two clips and pushes them to native', () async {
    final c = make();
    addTearDown(c.dispose);

    c.splitAtPlayhead(4000);
    await pumpEventQueue();

    expect(c.clips, hasLength(2));
    expect(c.hasCuts, isTrue);
    expect(c.canUndo, isTrue);
    expect(setClipsCalls, isNotEmpty);
    expect(lastPushedClips(), hasLength(2));
    expect(lastPushedClips().first['sourceOutMs'], 4000);
  });

  test('splitAtPlayhead on a boundary is a no-op (no history entry)', () {
    final c = make();
    addTearDown(c.dispose);

    c.splitAtPlayhead(0);

    expect(c.clips, hasLength(1));
    expect(c.canUndo, isFalse);
  });

  test('deleteSelected removes the clip and ripples; keeps at least one', () {
    final c = make();
    addTearDown(c.dispose);

    c.splitAtPlayhead(4000); // -> clip_0 [0..4000], clip_1 [4000..10000]
    c.selectClip('clip_0');
    expect(c.canDeleteSelected, isTrue);

    c.deleteSelected();
    expect(c.clips, hasLength(1));
    expect(c.clips.first.id, 'clip_1');
    expect(c.editedDurationMs, 6000);

    // Only one clip left — the floor protects it.
    c.selectClip('clip_1');
    expect(c.canDeleteSelected, isFalse);
    c.deleteSelected();
    expect(c.clips, hasLength(1));
  });

  test('moveClipToIndex reorders, records one undo, and skips no-ops', () {
    final c = make();
    addTearDown(c.dispose);

    c.splitAtPlayhead(4000); // clip_0 [0..4000], clip_1 [4000..10000]
    c.moveClipToIndex('clip_1', 0);
    expect(c.clips.map((e) => e.id), ['clip_1', 'clip_0']);
    expect(c.canUndo, isTrue);

    // The whole reorder is one undo step that restores the original order.
    c.undo();
    expect(c.clips.map((e) => e.id), ['clip_0', 'clip_1']);

    c.redo();
    expect(c.clips.map((e) => e.id), ['clip_1', 'clip_0']);

    // Moving a clip to where it already is changes nothing → no history entry.
    final canUndoBefore = c.canUndo;
    c.moveClipToIndex('clip_1', 0);
    expect(c.clips.map((e) => e.id), ['clip_1', 'clip_0']);
    expect(c.canUndo, canUndoBefore);
  });

  test(
    'trim drag lifecycle trims the clip and records one undo entry',
    () async {
      final c = make();
      addTearDown(c.dispose);

      c.beginTrim('clip_0', ClipTrimEdge.start);
      expect(c.isTrimming, isTrue);
      c.updateTrimTo(2000); // drag the start edge to timeline 2000
      expect(c.clips.first.sourceInMs, 2000);
      expect(c.isTrimming, isTrue);

      c.commitTrim();
      await pumpEventQueue();
      expect(c.isTrimming, isFalse);
      expect(c.clips.first.sourceInMs, 2000);
      expect(c.editedDurationMs, 8000);
      expect(c.canUndo, isTrue);

      // The whole drag is one undo.
      c.undo();
      expect(c.clips.first.sourceInMs, 0);
      expect(c.editedDurationMs, 10000);
    },
  );

  test('cancelTrim restores the pre-drag clips without history', () {
    final c = make();
    addTearDown(c.dispose);

    c.beginTrim('clip_0', ClipTrimEdge.end);
    c.updateTrimTo(6000);
    expect(c.clips.first.sourceOutMs, 6000);

    c.cancelTrim();
    expect(c.clips.first.sourceOutMs, 10000);
    expect(c.canUndo, isFalse);
  });

  test('commitTrim returns true on a real change and false on a no-op', () {
    final c = make();
    addTearDown(c.dispose);

    // Grabbed and released with no movement → no-op.
    c.beginTrim('clip_0', ClipTrimEdge.end);
    expect(c.commitTrim(), isFalse);
    expect(c.canUndo, isFalse);

    // A real edge move → committed as one undo entry.
    c.beginTrim('clip_0', ClipTrimEdge.end);
    c.updateTrimTo(6000);
    expect(c.commitTrim(), isTrue);
    expect(c.canUndo, isTrue);
  });

  test('beginTrim self-heals a stranded prior trim instead of baking it in', () {
    final c = make();
    addTearDown(c.dispose);

    // A trim that is live-mutated but never committed/cancelled (stranded).
    c.beginTrim('clip_0', ClipTrimEdge.end);
    c.updateTrimTo(6000);
    expect(c.clips.first.sourceOutMs, 6000);
    expect(c.canUndo, isFalse);

    // Starting a fresh trim must roll the stranded drag back first, not snapshot
    // the already-trimmed clips as the new baseline.
    c.beginTrim('clip_0', ClipTrimEdge.end);
    expect(c.clips.first.sourceOutMs, 10000);

    c.updateTrimTo(7000);
    c.commitTrim();
    // Undo restores the TRUE original (10000) — proving the stranded 6000 was
    // never silently folded into history.
    c.undo();
    expect(c.clips.first.sourceOutMs, 10000);
  });

  test(
    'undo/redo walks the clip history and pushes native each step',
    () async {
      final c = make();
      addTearDown(c.dispose);

      c.splitAtPlayhead(4000);
      await pumpEventQueue();
      expect(c.clips, hasLength(2));

      c.undo();
      await pumpEventQueue();
      expect(c.clips, hasLength(1));
      expect(c.hasCuts, isFalse);
      expect(lastPushedClips(), hasLength(1));

      c.redo();
      await pumpEventQueue();
      expect(c.clips, hasLength(2));
      expect(lastPushedClips(), hasLength(2));
    },
  );

  test('notifies listeners on edits', () {
    final c = make();
    addTearDown(c.dispose);
    var notifications = 0;
    c.addListener(() => notifications++);

    c.splitAtPlayhead(4000);
    c.selectClip('clip_0');

    expect(notifications, greaterThanOrEqualTo(2));
  });

  group('persistence', () {
    late Directory projectDir;

    setUp(() async {
      projectDir = await Directory.systemTemp.createTemp('clingfy_clipedit_');
    });

    tearDown(() async {
      if (await projectDir.exists()) {
        await projectDir.delete(recursive: true);
      }
    });

    ClipEditorController makeForProject({int durationMs = 10000}) =>
        ClipEditorController(
          nativeBridge: NativeBridge.instance,
          durationMs: durationMs,
          sessionId: 'sess-1',
          projectPath: projectDir.path,
        );

    Future<void> seedPersistedClips(List<Clip> clips) => ClipStateStore.save(
      projectDir.path,
      ClipPersistState(recordingDurationMs: 10000, clips: clips),
    );

    test(
      'with no persisted file, seeds the whole recording (no push)',
      () async {
        final c = makeForProject();
        addTearDown(c.dispose);
        await pumpEventQueue();

        expect(c.clips, hasLength(1));
        expect(c.hasCuts, isFalse);
        // A trivial (whole-recording) restore is native's starting state, so it
        // must not push on construction.
        expect(setClipsCalls, isEmpty);
      },
    );

    test('restores persisted cuts and pushes them to native on open', () async {
      await seedPersistedClips(const [
        Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 4000,
          timelineStartMs: 0,
        ),
        Clip(
          id: 'clip_1',
          sourceInMs: 6000,
          sourceOutMs: 10000,
          timelineStartMs: 4000,
        ),
      ]);

      final c = makeForProject();
      addTearDown(c.dispose);
      await pumpEventQueue();

      expect(c.clips, hasLength(2));
      expect(c.hasCuts, isTrue);
      expect(c.editedDurationMs, 8000);
      // Restored edit is pushed so the reopened preview plays its cuts.
      expect(setClipsCalls, isNotEmpty);
      expect(lastPushedClips(), hasLength(2));
      // Restore itself is not an undoable edit.
      expect(c.canUndo, isFalse);
    });

    test('advances the id counter past restored ids (no collision)', () async {
      await seedPersistedClips(const [
        Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 4000,
          timelineStartMs: 0,
        ),
        Clip(
          id: 'clip_1',
          sourceInMs: 4000,
          sourceOutMs: 10000,
          timelineStartMs: 4000,
        ),
      ]);

      final c = makeForProject();
      addTearDown(c.dispose);

      // Splitting the first restored clip must mint a fresh id, not reuse
      // clip_0 / clip_1.
      c.splitAtPlayhead(2000);
      final ids = c.clips.map((e) => e.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
      expect(ids, contains('clip_2'));
    });

    test('re-normalizes a stale timelineStartMs layout on restore', () async {
      // A corrupted/hand-edited file with a non-contiguous timeline: clip_1's
      // timelineStartMs (9999) does not follow clip_0's duration. Restore must
      // reflow it to the gap-free layout (4000) while preserving ids/source.
      await seedPersistedClips(const [
        Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 4000,
          timelineStartMs: 0,
        ),
        Clip(
          id: 'clip_1',
          sourceInMs: 6000,
          sourceOutMs: 10000,
          timelineStartMs: 9999,
        ),
      ]);

      final c = makeForProject();
      addTearDown(c.dispose);

      expect(c.clips.map((e) => e.id), ['clip_0', 'clip_1']);
      expect(c.clips[0].timelineStartMs, 0);
      expect(c.clips[1].timelineStartMs, 4000);
      expect(c.clips[1].sourceInMs, 6000);
      expect(c.editedDurationMs, 8000);
    });

    test(
      'rejects out-of-range persisted clips and seeds the whole recording',
      () async {
        // sourceOutMs well beyond the recording length → not from this recording.
        await seedPersistedClips(const [
          Clip(
            id: 'clip_0',
            sourceInMs: 0,
            sourceOutMs: 999999,
            timelineStartMs: 0,
          ),
        ]);

        final c = makeForProject();
        addTearDown(c.dispose);
        await pumpEventQueue();

        expect(c.clips, hasLength(1));
        expect(c.hasCuts, isFalse);
        expect(c.editedDurationMs, 10000);
        expect(setClipsCalls, isEmpty);
      },
    );

    test('persists the clip list on a committed edit', () async {
      final c = makeForProject();
      addTearDown(c.dispose);

      c.splitAtPlayhead(4000);

      // The save is fire-and-forget real file I/O (ClipEditorController wraps it
      // in `unawaited` so a save never blocks an edit), so pumpEventQueue is not
      // a guarantee it landed — it only drains microtasks. Poll instead.
      final persisted = await waitForValue(
        () => ClipStateStore.load(projectDir.path),
        reason: 'clips_state.json after a committed split',
      );
      expect(persisted.clips, hasLength(2));
      expect(persisted.recordingDurationMs, 10000);
    });

    test('persists undo back to the whole recording', () async {
      final c = makeForProject();
      addTearDown(c.dispose);

      c.splitAtPlayhead(4000);
      await waitUntil(
        () => ClipStateStore.load(projectDir.path)?.clips.length == 2,
        reason: 'the split must be on disk before undo is meaningful',
      );

      c.undo();
      // Polls on the VALUE, not just existence: the file already exists from the
      // split above, so waiting for non-null would pass on the pre-undo state.
      await waitUntil(
        () => ClipStateStore.load(projectDir.path)?.clips.length == 1,
        reason: 'clips_state.json after undo',
      );

      final persisted = ClipStateStore.load(projectDir.path);
      expect(persisted, isNotNull);
      expect(persisted!.clips, hasLength(1));
    });

    test('does not persist when no project path is set', () async {
      // The default `make()` has no project path — editing must not write.
      final c = make();
      addTearDown(c.dispose);

      c.splitAtPlayhead(4000);
      // A negative assertion, so the fire-and-forget race cannot turn this red:
      // with no project path the controller returns before issuing any write, so
      // there is nothing in flight to wait for.
      await pumpEventQueue();

      expect(
        await File('${projectDir.path}/clips_state.json').exists(),
        isFalse,
      );
    });
  });
}
