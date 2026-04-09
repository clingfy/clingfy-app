import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _leftSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeLeftSidebar,
  defaultWidth: 60,
  minWidth: 40,
  maxWidth: 60,
  collapsedWidth: 40,
  collapsible: true,
  autoCollapsePriority: 1,
);

const _inspectorSpec = DesktopPaneSpec(
  id: DesktopPaneId.recordingSidebar,
  defaultWidth: 220,
  minWidth: 200,
  maxWidth: 260,
  collapsedWidth: 32,
  resizable: true,
  collapsible: true,
  autoCollapsePriority: 0,
);

const _zeroWidthInspectorSpec = DesktopPaneSpec(
  id: DesktopPaneId.recordingSidebar,
  defaultWidth: 220,
  minWidth: 200,
  maxWidth: 260,
  collapsedWidth: 0,
  resizable: true,
  collapsible: true,
  autoCollapsePriority: 0,
);

const _snapZeroWidthInspectorSpec = DesktopPaneSpec(
  id: DesktopPaneId.recordingSidebar,
  defaultWidth: 220,
  minWidth: 200,
  maxWidth: 260,
  collapsedWidth: 0,
  resizable: true,
  collapsible: true,
  snapCollapseAtMinWidthOnDragEnd: true,
  autoCollapsePriority: 0,
);

const _workspaceSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeRightWorkspace,
  defaultWidth: 400,
  minWidth: 400,
  autoCollapseAllowed: false,
  flex: true,
);

Widget _buildHarness({
  required DesktopPaneController controller,
  required ValueChanged<DesktopPaneLayoutPrefs> onCommit,
  DesktopPaneSpec inspectorSpec = _inspectorSpec,
  double width = 900,
  double height = 500,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: DesktopSplitLayout(
            controller: controller,
            gap: 4,
            minHeight: height,
            onLayoutCommitted: onCommit,
            panes: [
              DesktopPaneSlot(
                spec: _leftSpec,
                builder: (context, presentation) {
                  return ColoredBox(
                    key: const Key('pane_home_left_sidebar'),
                    color: Colors.blueGrey,
                    child: Center(
                      child: Text(
                        presentation.effectiveCollapsed
                            ? 'left-collapsed'
                            : 'left',
                      ),
                    ),
                  );
                },
              ),
              DesktopPaneSlot(
                spec: inspectorSpec,
                builder: (context, presentation) {
                  return Stack(
                    children: [
                      ColoredBox(
                        key: const Key('pane_recording_sidebar'),
                        color: Colors.teal,
                        child: Center(
                          child: Text(
                            presentation.effectiveCollapsed
                                ? 'inspector-collapsed'
                                : 'inspector',
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          key: const Key('toggle_recording_sidebar'),
                          onPressed: () {
                            controller.togglePaneCollapsed(inspectorSpec);
                            onCommit(controller.layout);
                          },
                          icon: Icon(
                            presentation.effectiveCollapsed
                                ? Icons.chevron_left_rounded
                                : Icons.chevron_right_rounded,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              DesktopPaneSlot(
                spec: _workspaceSpec,
                builder: (context, presentation) {
                  return ColoredBox(
                    key: const Key('pane_workspace'),
                    color: Colors.black12,
                    child: Center(
                      child: Text(
                        presentation.effectiveWidth.toStringAsFixed(0),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'drag resize clamps width to pane max and commits only on drag end',
    (tester) async {
      _setDesktopWindow(tester);
      final controller = DesktopPaneController();
      DesktopPaneLayoutPrefs? committedLayout;
      var commitCount = 0;

      await tester.pumpWidget(
        _buildHarness(
          controller: controller,
          onCommit: (layout) {
            commitCount += 1;
            committedLayout = layout;
          },
        ),
      );
      await tester.pumpAndSettle();

      final handle = find.byKey(
        const ValueKey('desktop_pane_handle_recordingSidebar'),
      );
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();

      expect(commitCount, 0);

      await gesture.up();
      await tester.pumpAndSettle();

      final inspectorRect = tester.getRect(
        find.byKey(const Key('pane_recording_sidebar')),
      );
      expect(inspectorRect.width, moreOrLessEquals(260));
      expect(commitCount, 1);
      expect(
        committedLayout?.stateFor(DesktopPaneId.recordingSidebar).width,
        260,
      );
    },
  );

  testWidgets(
    'dragging an opted-in zero-width inspector to min width snaps it closed on release',
    (tester) async {
      _setDesktopWindow(tester);
      final controller = DesktopPaneController(
        initialLayout: const DesktopPaneLayoutPrefs(
          paneStates: {
            DesktopPaneId.recordingSidebar: DesktopPaneState(
              width: 240,
              lastExpandedWidth: 240,
              userResized: true,
            ),
          },
        ),
      );

      await tester.pumpWidget(
        _buildHarness(
          controller: controller,
          inspectorSpec: _snapZeroWidthInspectorSpec,
          onCommit: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      final handle = find.byKey(
        const ValueKey('desktop_pane_handle_recordingSidebar'),
      );
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();

      expect(
        _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
        moreOrLessEquals(200),
      );

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final midCollapseWidth = _paneSlotWidth(
        tester,
        DesktopPaneId.recordingSidebar,
      );
      expect(midCollapseWidth, greaterThan(0));
      expect(midCollapseWidth, lessThan(200));

      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pane_recording_sidebar')), findsOneWidget);
      expect(
        controller.stateFor(DesktopPaneId.recordingSidebar).isCollapsed,
        isTrue,
      );
      expect(
        controller.stateFor(DesktopPaneId.recordingSidebar).width,
        moreOrLessEquals(240),
      );
      expect(
        controller.stateFor(DesktopPaneId.recordingSidebar).lastExpandedWidth,
        moreOrLessEquals(240),
      );
      expect(
        _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
        moreOrLessEquals(0),
      );

      controller.togglePaneCollapsed(_snapZeroWidthInspectorSpec);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final midExpandWidth = _paneSlotWidth(
        tester,
        DesktopPaneId.recordingSidebar,
      );
      expect(midExpandWidth, greaterThan(0));
      expect(midExpandWidth, lessThan(240));

      await tester.pumpAndSettle();

      expect(
        _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
        moreOrLessEquals(240),
      );
    },
  );

  testWidgets(
    'dragging slightly above min width keeps an opted-in inspector visible',
    (tester) async {
      _setDesktopWindow(tester);
      final controller = DesktopPaneController();

      await tester.pumpWidget(
        _buildHarness(
          controller: controller,
          inspectorSpec: _snapZeroWidthInspectorSpec,
          onCommit: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      final handle = find.byKey(
        const ValueKey('desktop_pane_handle_recordingSidebar'),
      );
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(-18, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pane_recording_sidebar')), findsOneWidget);
      expect(
        controller.stateFor(DesktopPaneId.recordingSidebar).isCollapsed,
        isFalse,
      );
      expect(
        _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
        moreOrLessEquals(202),
      );
    },
  );

  testWidgets('collapse and re-expand restore the last expanded width', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController(
      initialLayout: const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.recordingSidebar: DesktopPaneState(
            width: 240,
            lastExpandedWidth: 240,
            userResized: true,
          ),
        },
      ),
    );

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle_recording_sidebar')));
    await tester.pumpAndSettle();
    expect(
      _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
      moreOrLessEquals(32),
    );

    await tester.tap(find.byKey(const Key('toggle_recording_sidebar')));
    await tester.pumpAndSettle();
    expect(
      _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
      moreOrLessEquals(240),
    );
  });

  testWidgets('nonzero collapsed panes animate snapped width changes', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(
      _paneSlotWidth(tester, DesktopPaneId.homeLeftSidebar),
      moreOrLessEquals(60),
    );

    controller.togglePaneCollapsed(_leftSpec);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final midCollapseWidth = _paneSlotWidth(
      tester,
      DesktopPaneId.homeLeftSidebar,
    );
    expect(midCollapseWidth, greaterThan(40));
    expect(midCollapseWidth, lessThan(60));

    await tester.pumpAndSettle();

    expect(
      _paneSlotWidth(tester, DesktopPaneId.homeLeftSidebar),
      moreOrLessEquals(40),
    );

    controller.togglePaneCollapsed(_leftSpec);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final midExpandWidth = _paneSlotWidth(
      tester,
      DesktopPaneId.homeLeftSidebar,
    );
    expect(midExpandWidth, greaterThan(40));
    expect(midExpandWidth, lessThan(60));

    await tester.pumpAndSettle();

    expect(
      _paneSlotWidth(tester, DesktopPaneId.homeLeftSidebar),
      moreOrLessEquals(60),
    );
  });

  testWidgets('auto-collapse prioritizes the inspector before the left rail', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}, width: 648),
    );
    await tester.pumpAndSettle();

    expect(
      _paneSlotWidth(tester, DesktopPaneId.homeLeftSidebar),
      moreOrLessEquals(60),
    );
    expect(
      _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
      moreOrLessEquals(32),
    );
  });

  testWidgets('zero-width collapsed panes remove their extra gap and divider', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController(
      initialLayout: const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.recordingSidebar: DesktopPaneState(
            isCollapsed: true,
            width: 240,
            lastExpandedWidth: 240,
            userResized: true,
          ),
        },
      ),
    );

    await tester.pumpWidget(
      _buildHarness(
        controller: controller,
        inspectorSpec: _zeroWidthInspectorSpec,
        onCommit: (_) {},
      ),
    );
    await tester.pumpAndSettle();

    final leftRect = tester.getRect(
      find.byKey(const Key('pane_home_left_sidebar')),
    );
    final workspaceRect = tester.getRect(
      find.byKey(const Key('pane_workspace')),
    );

    expect(find.byKey(const Key('pane_recording_sidebar')), findsOneWidget);
    expect(
      _paneSlotWidth(tester, DesktopPaneId.recordingSidebar),
      moreOrLessEquals(0),
    );
    expect(
      find.byKey(const ValueKey('desktop_pane_handle_recordingSidebar')),
      findsNothing,
    );
    expect(workspaceRect.left, moreOrLessEquals(leftRect.right + 4));
  });

  testWidgets('auto-collapse is temporary and does not persist user state', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}, width: 648),
    );
    await tester.pumpAndSettle();

    expect(
      controller.stateFor(DesktopPaneId.homeLeftSidebar).isCollapsed,
      isFalse,
    );
    expect(
      controller.stateFor(DesktopPaneId.recordingSidebar).isCollapsed,
      isFalse,
    );
  });

  testWidgets('fully constrained layouts fall back to horizontal scrolling', (
    tester,
  ) async {
    _setDesktopWindow(tester, size: const Size(600, 600));
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}, width: 450),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('desktop_split_layout_scroll_view')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('asserts when configured with more than one flex pane', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 900,
          height: 400,
          child: DesktopSplitLayout(
            controller: controller,
            gap: 4,
            panes: [
              DesktopPaneSlot(
                spec: const DesktopPaneSpec(
                  id: DesktopPaneId.homeLeftSidebar,
                  defaultWidth: 200,
                  minWidth: 200,
                  flex: true,
                ),
                builder: (_, __) => const SizedBox(),
              ),
              DesktopPaneSlot(
                spec: const DesktopPaneSpec(
                  id: DesktopPaneId.homeRightWorkspace,
                  defaultWidth: 200,
                  minWidth: 200,
                  flex: true,
                ),
                builder: (_, __) => const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isA<AssertionError>());
  });
}

double _paneSlotWidth(WidgetTester tester, DesktopPaneId id) {
  return tester
      .getRect(find.byKey(ValueKey('desktop_pane_slot_${id.name}')))
      .width;
}

void _setDesktopWindow(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
