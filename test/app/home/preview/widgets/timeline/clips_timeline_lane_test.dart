import 'package:clingfy/app/home/preview/widgets/timeline/clips_timeline_lane.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const laneWidth = 600.0;
  const editedDurationMs = 10000;

  // Two contiguous clips on the edited timeline: [0..4000] then [4000..10000].
  final twoClips = <Clip>[
    const Clip(
      id: 'clip_0',
      sourceInMs: 0,
      sourceOutMs: 4000,
      timelineStartMs: 0,
    ),
    const Clip(
      id: 'clip_1',
      sourceInMs: 4000,
      sourceOutMs: 10000,
      timelineStartMs: 4000,
    ),
  ];

  // Three contiguous clips, so reorder has neighbours to cross. On a 600px lane
  // their centres sit at ~90 (clip_0), ~270 (clip_1), ~480 (clip_2) px.
  final threeClips = <Clip>[
    const Clip(
      id: 'clip_0',
      sourceInMs: 0,
      sourceOutMs: 3000,
      timelineStartMs: 0,
    ),
    const Clip(
      id: 'clip_1',
      sourceInMs: 3000,
      sourceOutMs: 6000,
      timelineStartMs: 3000,
    ),
    const Clip(
      id: 'clip_2',
      sourceInMs: 6000,
      sourceOutMs: 10000,
      timelineStartMs: 6000,
    ),
  ];

  TimelineViewportController makeController() {
    final controller = TimelineViewportController(durationMs: editedDurationMs);
    // The lane does not configure the controller itself; the parent viewport
    // does. Configure it here so ms→px mapping has a real viewport width.
    controller.setViewportWidth(laneWidth);
    return controller;
  }

  Future<void> pumpLane(
    WidgetTester tester, {
    required List<Clip> clips,
    String? selectedClipId,
    required TimelineViewportController controller,
    required ValueChanged<String?> onSelectClip,
    ClipTrimCallbacks? trimCallbacks,
    ClipReorderCallbacks? reorderCallbacks,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: laneWidth,
              child: ClipsTimelineLane(
                clips: clips,
                selectedClipId: selectedClipId,
                viewportController: controller,
                onSelectClip: onSelectClip,
                trimCallbacks: trimCallbacks,
                reorderCallbacks: reorderCallbacks,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders one box per enabled clip', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await pumpLane(
      tester,
      clips: twoClips,
      controller: controller,
      onSelectClip: (_) {},
    );

    expect(find.byKey(const Key('clips_timeline_lane')), findsOneWidget);
    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      findsOneWidget,
    );
  });

  testWidgets('disabled clips are not rendered', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await pumpLane(
      tester,
      clips: [twoClips.first, twoClips.last.copyWith(enabled: false)],
      controller: controller,
      onSelectClip: (_) {},
    );

    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      findsNothing,
    );
  });

  testWidgets('tapping a clip box selects it by id', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);
    String? selected = 'unset';

    await pumpLane(
      tester,
      clips: twoClips,
      controller: controller,
      onSelectClip: (id) => selected = id,
    );

    await tester.tap(find.byKey(const Key('clips_timeline_lane_clip_clip_1')));
    await tester.pump();

    expect(selected, 'clip_1');
  });

  testWidgets('tapping the empty lane clears the selection (null)', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);
    String? selected = 'clip_0';

    // No clips → the whole lane is the background tap target.
    await pumpLane(
      tester,
      clips: const [],
      selectedClipId: 'clip_0',
      controller: controller,
      onSelectClip: (id) => selected = id,
    );

    await tester.tap(find.byKey(const Key('clips_timeline_lane_background')));
    await tester.pump();

    expect(selected, isNull);
  });

  testWidgets('the selected clip box draws a thicker accent border', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: 'clip_1',
      controller: controller,
      onSelectClip: (_) {},
    );

    BoxDecoration decorationOf(Key key) {
      final container = tester.widget<Container>(
        find.descendant(of: find.byKey(key), matching: find.byType(Container)),
      );
      return container.decoration! as BoxDecoration;
    }

    final selectedBorder =
        decorationOf(const Key('clips_timeline_lane_clip_clip_1')).border!
            as Border;
    final unselectedBorder =
        decorationOf(const Key('clips_timeline_lane_clip_clip_0')).border!
            as Border;

    expect(selectedBorder.top.width, 2);
    expect(unselectedBorder.top.width, 1);
  });

  testWidgets(
    'a near-minimum-duration clip on a long recording stays visible and '
    'tappable (selects, not clears)',
    (tester) async {
      // 10-minute recording: a 40ms clip is sub-pixel at zoom 1 and would
      // otherwise floor to zero width — invisible and untappable.
      final controller = TimelineViewportController(durationMs: 600000);
      controller.setViewportWidth(laneWidth);
      addTearDown(controller.dispose);

      String? selected = 'unset';
      final clips = <Clip>[
        const Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 40,
          timelineStartMs: 0,
        ),
        const Clip(
          id: 'clip_1',
          sourceInMs: 40,
          sourceOutMs: 600000,
          timelineStartMs: 40,
        ),
      ];

      await pumpLane(
        tester,
        clips: clips,
        controller: controller,
        onSelectClip: (id) => selected = id,
      );

      final shortBox = find.byKey(const Key('clips_timeline_lane_clip_clip_0'));
      expect(shortBox, findsOneWidget);
      // Floored to a real, hit-testable width rather than collapsing to 0.
      expect(tester.getSize(shortBox).width, greaterThanOrEqualTo(8));

      await tester.tap(shortBox);
      await tester.pump();

      // The tap selects the short clip rather than falling through to the
      // background (which would clear the selection to null).
      expect(selected, 'clip_0');
    },
  );

  ClipTrimCallbacks noopTrimCallbacks() => ClipTrimCallbacks(
    onBegin: (_, _) {},
    onUpdate: (_) {},
    onCommit: () {},
    onCancel: () {},
  );

  testWidgets(
    'only the selected clip gets an end handle, and no start handle',
    (tester) async {
      final controller = makeController();
      addTearDown(controller.dispose);

      await pumpLane(
        tester,
        clips: twoClips,
        selectedClipId: 'clip_0',
        controller: controller,
        onSelectClip: (_) {},
        trimCallbacks: noopTrimCallbacks(),
      );

      expect(
        find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
        findsOneWidget,
      );
      // Start-edge trim is intentionally not a drag handle on this gapless
      // timeline.
      expect(
        find.byKey(const Key('clips_timeline_lane_trim_start_clip_0')),
        findsNothing,
      );
      // The unselected clip has no handle.
      expect(
        find.byKey(const Key('clips_timeline_lane_trim_end_clip_1')),
        findsNothing,
      );
    },
  );

  testWidgets('no trim handles render without trim callbacks', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: 'clip_0',
      controller: controller,
      onSelectClip: (_) {},
      // trimCallbacks omitted → trim disabled.
    );

    expect(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      findsNothing,
    );
  });

  testWidgets('the end handle disappears when the selection clears', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: 'clip_0',
      controller: controller,
      onSelectClip: (_) {},
      trimCallbacks: noopTrimCallbacks(),
    );
    expect(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      findsOneWidget,
    );

    // Clear the selection → the previously selected clip's handle is gone.
    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: null,
      controller: controller,
      onSelectClip: (_) {},
      trimCallbacks: noopTrimCallbacks(),
    );
    expect(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      findsNothing,
    );
  });

  testWidgets(
    'the last clip end handle (at the clipped lane edge) is grabbable',
    (tester) async {
      final controller = makeController();
      addTearDown(controller.dispose);

      String? begunClip;
      var updates = 0;

      // Select clip_1, whose end sits at the very right edge of the lane.
      await pumpLane(
        tester,
        clips: twoClips,
        selectedClipId: 'clip_1',
        controller: controller,
        onSelectClip: (_) {},
        trimCallbacks: ClipTrimCallbacks(
          onBegin: (id, _) => begunClip = id,
          onUpdate: (_) => updates += 1,
          onCommit: () {},
          onCancel: () {},
        ),
      );

      // Drag from the handle's centre — it must be fully inside the clipped
      // lane, not half-dead past the right edge.
      await tester.drag(
        find.byKey(const Key('clips_timeline_lane_trim_end_clip_1')),
        const Offset(-80, 0),
      );
      await tester.pump();

      expect(begunClip, 'clip_1');
      expect(updates, greaterThan(0));
    },
  );

  testWidgets('dragging a clip edge handle drives the trim lifecycle', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? begunClip;
    ClipTrimEdge? begunEdge;
    var updates = 0;
    int? lastMs;
    var commits = 0;

    // Select clip_0 (spans 0..4000ms → its end handle sits mid-lane at ~240px,
    // safely clear of the clipped right edge).
    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: 'clip_0',
      controller: controller,
      onSelectClip: (_) {},
      trimCallbacks: ClipTrimCallbacks(
        onBegin: (id, edge) {
          begunClip = id;
          begunEdge = edge;
        },
        onUpdate: (ms) {
          updates += 1;
          lastMs = ms;
        },
        onCommit: () => commits += 1,
        onCancel: () {},
      ),
    );

    // Drag the end handle left by 120px.
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      const Offset(-120, 0),
    );
    await tester.pump();

    expect(begunClip, 'clip_0');
    expect(begunEdge, ClipTrimEdge.end);
    expect(updates, greaterThan(0));
    expect(commits, 1);
    // The end edge moved left → the reported ms is below the original 4000ms
    // end and still within the timeline.
    expect(lastMs, isNotNull);
    expect(lastMs, lessThan(4000));
    expect(lastMs, greaterThanOrEqualTo(0));
  });

  testWidgets('a cancelled gesture fires onCancel, not onCommit', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    var commits = 0;
    var cancels = 0;

    await pumpLane(
      tester,
      clips: twoClips,
      selectedClipId: 'clip_0',
      controller: controller,
      onSelectClip: (_) {},
      trimCallbacks: ClipTrimCallbacks(
        onBegin: (_, _) {},
        onUpdate: (_) {},
        onCommit: () => commits += 1,
        onCancel: () => cancels += 1,
      ),
    );

    // Press the handle then cancel the pointer before a drag is recognized —
    // the down-without-drag path routes to onHorizontalDragCancel.
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      ),
    );
    await gesture.cancel();
    await tester.pump();

    expect(cancels, 1);
    expect(commits, 0);
  });

  // --- Reorder ---

  testWidgets(
    'dragging a clip right past a neighbour reorders it to a higher index',
    (tester) async {
      final controller = makeController();
      addTearDown(controller.dispose);

      String? begun;
      (String, int)? committed;
      var cancels = 0;

      await pumpLane(
        tester,
        clips: threeClips,
        controller: controller,
        onSelectClip: (_) {},
        reorderCallbacks: ClipReorderCallbacks(
          onBegin: (id) => begun = id,
          onCommit: (id, index) => committed = (id, index),
          onCancel: () => cancels += 1,
        ),
      );

      // Drag the middle clip (centre ~270) right past clip_2's centre (~480).
      await tester.drag(
        find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
        const Offset(300, 0),
      );
      await tester.pump();

      expect(begun, 'clip_1');
      // Lands after both neighbours → [clip_0, clip_2, clip_1].
      expect(committed, ('clip_1', 2));
      expect(cancels, 0);
    },
  );

  testWidgets('dragging a clip left past a neighbour reorders it to index 0', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? begun;
    (String, int)? committed;

    await pumpLane(
      tester,
      clips: threeClips,
      controller: controller,
      onSelectClip: (_) {},
      reorderCallbacks: ClipReorderCallbacks(
        onBegin: (id) => begun = id,
        onCommit: (id, index) => committed = (id, index),
        onCancel: () {},
      ),
    );

    // Drag the middle clip (centre ~270) left past clip_0's centre (~90).
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      const Offset(-300, 0),
    );
    await tester.pump();

    expect(begun, 'clip_1');
    // Lands before both neighbours → [clip_1, clip_0, clip_2].
    expect(committed, ('clip_1', 0));
  });

  testWidgets('a tap selects the clip and does not reorder', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? selected = 'unset';
    String? begun;
    (String, int)? committed;

    await pumpLane(
      tester,
      clips: threeClips,
      controller: controller,
      onSelectClip: (id) => selected = id,
      reorderCallbacks: ClipReorderCallbacks(
        onBegin: (id) => begun = id,
        onCommit: (id, index) => committed = (id, index),
        onCancel: () {},
      ),
    );

    await tester.tap(find.byKey(const Key('clips_timeline_lane_clip_clip_1')));
    await tester.pump();

    expect(selected, 'clip_1');
    expect(begun, isNull);
    expect(committed, isNull);
  });

  testWidgets('a drag that stays within the clip fires no commit', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? begun;
    (String, int)? committed;

    await pumpLane(
      tester,
      clips: threeClips,
      controller: controller,
      onSelectClip: (_) {},
      reorderCallbacks: ClipReorderCallbacks(
        onBegin: (id) => begun = id,
        onCommit: (id, index) => committed = (id, index),
        onCancel: () {},
      ),
    );

    // A small drag that never crosses a neighbour's centre keeps the target at
    // the original index → an in-place drop, which commits nothing.
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      const Offset(20, 0),
    );
    await tester.pump();

    // The drag is recognized (begin fires) but resolves to no move.
    expect(begun, 'clip_1');
    expect(committed, isNull);
  });

  testWidgets('with a single clip, dragging does not reorder', (tester) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? begun;
    (String, int)? committed;

    await pumpLane(
      tester,
      clips: const [
        Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 10000,
          timelineStartMs: 0,
        ),
      ],
      controller: controller,
      onSelectClip: (_) {},
      reorderCallbacks: ClipReorderCallbacks(
        onBegin: (id) => begun = id,
        onCommit: (id, index) => committed = (id, index),
        onCancel: () {},
      ),
    );

    // Only one clip → reorder is disabled (no drag handlers wired), so the
    // horizontal drag is never claimed by the clip box.
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_clip_clip_0')),
      const Offset(200, 0),
    );
    await tester.pump();

    expect(begun, isNull);
    expect(committed, isNull);
  });

  testWidgets('without reorder callbacks, dragging a clip does not reorder', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    String? selected = 'unset';

    await pumpLane(
      tester,
      clips: threeClips,
      controller: controller,
      onSelectClip: (id) => selected = id,
      // reorderCallbacks omitted → drag-to-reorder disabled.
    );

    // A horizontal drag is not claimed by the box (no handlers) and is not a
    // tap, so nothing changes and no indicator appears.
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      const Offset(300, 0),
    );
    await tester.pump();

    expect(selected, 'unset');
    expect(
      find.byKey(const Key('clips_timeline_lane_reorder_indicator')),
      findsNothing,
    );
  });

  testWidgets(
    'a selected narrow clip still reorders from its body (trim handle does not '
    'swallow the whole box)',
    (tester) async {
      final controller = makeController();
      addTearDown(controller.dispose);

      // A 300ms clip renders ~16px wide on the 600px lane — narrow enough that
      // the full 22px end-trim handle would otherwise blanket its body and trap
      // a reorder drag. Capping the handle hit width keeps a body grab strip.
      final narrowFirst = <Clip>[
        const Clip(
          id: 'clip_0',
          sourceInMs: 0,
          sourceOutMs: 300,
          timelineStartMs: 0,
        ),
        const Clip(
          id: 'clip_1',
          sourceInMs: 300,
          sourceOutMs: 10000,
          timelineStartMs: 300,
        ),
      ];

      String? trimBegun;
      String? reorderBegun;
      (String, int)? reorderCommitted;

      await pumpLane(
        tester,
        clips: narrowFirst,
        selectedClipId: 'clip_0',
        controller: controller,
        onSelectClip: (_) {},
        trimCallbacks: ClipTrimCallbacks(
          onBegin: (id, _) => trimBegun = id,
          onUpdate: (_) {},
          onCommit: () {},
          onCancel: () {},
        ),
        reorderCallbacks: ClipReorderCallbacks(
          onBegin: (id) => reorderBegun = id,
          onCommit: (id, index) => reorderCommitted = (id, index),
          onCancel: () {},
        ),
      );

      // Drag the narrow selected clip's body right, past clip_1's centre.
      await tester.drag(
        find.byKey(const Key('clips_timeline_lane_clip_clip_0')),
        const Offset(400, 0),
      );
      await tester.pump();

      // The body drag reordered the clip; the trim handle never claimed it.
      expect(trimBegun, isNull);
      expect(reorderBegun, 'clip_0');
      expect(reorderCommitted, ('clip_0', 1));
    },
  );
}
