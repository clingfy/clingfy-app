import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
