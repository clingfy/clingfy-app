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
}
