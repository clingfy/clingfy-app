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
  autoCollapsePriority: 0,
);

const _inspectorSpec = DesktopPaneSpec(
  id: DesktopPaneId.recordingSidebar,
  defaultWidth: 220,
  minWidth: 200,
  maxWidth: 260,
  collapsedWidth: 32,
  resizable: true,
  collapsible: true,
  autoCollapsePriority: 1,
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
                spec: _inspectorSpec,
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
                            controller.togglePaneCollapsed(_inspectorSpec);
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
      tester.getRect(find.byKey(const Key('pane_recording_sidebar'))).width,
      moreOrLessEquals(32),
    );

    await tester.tap(find.byKey(const Key('toggle_recording_sidebar')));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('pane_recording_sidebar'))).width,
      moreOrLessEquals(240),
    );
  });

  testWidgets('auto-collapse prioritizes the left rail before the inspector', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final controller = DesktopPaneController();

    await tester.pumpWidget(
      _buildHarness(controller: controller, onCommit: (_) {}, width: 648),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(const Key('pane_home_left_sidebar'))).width,
      moreOrLessEquals(40),
    );
    expect(
      tester.getRect(find.byKey(const Key('pane_recording_sidebar'))).width,
      moreOrLessEquals(200),
    );
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
