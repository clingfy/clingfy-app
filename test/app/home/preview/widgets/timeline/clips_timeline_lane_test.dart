import 'package:clingfy/app/home/preview/widgets/timeline/clips_timeline_lane.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
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
}
