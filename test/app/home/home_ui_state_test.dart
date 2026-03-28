import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('setters update state and notify listeners', () {
    final state = HomeUiState();
    var notifications = 0;
    state.addListener(() {
      notifications += 1;
    });

    state.setError('boom');
    state.setTargetMode(DisplayTargetMode.singleAppWindow);
    state.setIndicatorPinned(true);
    state.setSettingsOpen(true);
    state.applyPaneLayoutPrefs(
      const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.homeLeftSidebar: DesktopPaneState(isCollapsed: true),
        },
      ),
    );
    state.markHydrated();

    expect(state.errorMessage, 'boom');
    expect(state.targetMode, DisplayTargetMode.singleAppWindow);
    expect(state.indicatorPinned, isTrue);
    expect(state.isSettingsOpen, isTrue);
    expect(
      state.paneStateFor(DesktopPaneId.homeLeftSidebar).isCollapsed,
      isTrue,
    );
    expect(state.uiPrefsHydrated, isTrue);
    expect(notifications, 6);
  });

  test('duplicate values do not notify again', () {
    final state = HomeUiState();
    var notifications = 0;
    state.addListener(() {
      notifications += 1;
    });

    state.setIndicatorPinned(false);
    state.setTargetMode(DisplayTargetMode.explicitId);
    state.setSettingsOpen(false);
    state.setError(null);
    state.applyPaneLayoutPrefs(const DesktopPaneLayoutPrefs());
    state.markHydrated();
    state.markHydrated();

    expect(notifications, 1);
  });

  test('pane layout hydration and updates notify once per change', () {
    final state = HomeUiState();
    addTearDown(state.dispose);
    var notifications = 0;
    state.addListener(() => notifications += 1);

    state.applyPaneLayoutPrefs(
      const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.recordingSidebar: DesktopPaneState(
            width: 360,
            lastExpandedWidth: 360,
            userResized: true,
          ),
        },
      ),
    );
    state.applyPaneLayoutPrefs(
      const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.recordingSidebar: DesktopPaneState(
            width: 320,
            lastExpandedWidth: 320,
            isCollapsed: true,
            userResized: true,
          ),
        },
      ),
    );

    expect(
      state.paneStateFor(DesktopPaneId.recordingSidebar),
      const DesktopPaneState(
        width: 320,
        lastExpandedWidth: 320,
        isCollapsed: true,
        userResized: true,
      ),
    );
    expect(notifications, 2);
  });

  testWidgets('success notice auto dismisses after 5 seconds', (tester) async {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      const HomeUiNotice(message: 'Saved', tone: HomeUiNoticeTone.success),
    );

    await tester.pump(const Duration(seconds: 4, milliseconds: 999));
    expect(state.notice?.message, 'Saved');

    await tester.pump(const Duration(milliseconds: 1));
    expect(state.notice, isNull);
  });

  testWidgets('success notice with action auto dismisses after 6 seconds', (
    tester,
  ) async {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      HomeUiNotice(
        message: 'Saved',
        tone: HomeUiNoticeTone.success,
        action: HomeUiNoticeAction(label: 'Reveal', onPressed: () {}),
      ),
    );

    await tester.pump(const Duration(seconds: 5, milliseconds: 999));
    expect(state.notice?.message, 'Saved');

    await tester.pump(const Duration(milliseconds: 1));
    expect(state.notice, isNull);
  });

  testWidgets('info notice auto dismisses after 4 seconds', (tester) async {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      const HomeUiNotice(message: 'Heads up', tone: HomeUiNoticeTone.info),
    );

    await tester.pump(const Duration(seconds: 3, milliseconds: 999));
    expect(state.notice?.message, 'Heads up');

    await tester.pump(const Duration(milliseconds: 1));
    expect(state.notice, isNull);
  });

  testWidgets('warning and error notices stay persistent', (tester) async {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      const HomeUiNotice(message: 'Watch out', tone: HomeUiNoticeTone.warning),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(state.notice?.message, 'Watch out');

    state.setNotice(
      const HomeUiNotice(message: 'Broken', tone: HomeUiNoticeTone.error),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(state.notice?.message, 'Broken');
  });

  testWidgets('setting a second notice cancels the prior timer', (
    tester,
  ) async {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      const HomeUiNotice(message: 'Saved', tone: HomeUiNoticeTone.success),
    );

    await tester.pump(const Duration(seconds: 3));

    state.setNotice(
      const HomeUiNotice(message: 'Info', tone: HomeUiNoticeTone.info),
    );

    await tester.pump(const Duration(seconds: 2));
    expect(state.notice?.message, 'Info');

    await tester.pump(const Duration(seconds: 2));
    expect(state.notice, isNull);
  });

  test('clearTransientNotice only clears auto dismiss notices', () {
    final state = HomeUiState();
    addTearDown(state.dispose);

    state.setNotice(
      const HomeUiNotice(message: 'Saved', tone: HomeUiNoticeTone.success),
    );
    state.clearTransientNotice();
    expect(state.notice, isNull);

    state.setNotice(
      const HomeUiNotice(message: 'Warning', tone: HomeUiNoticeTone.warning),
    );
    state.clearTransientNotice();
    expect(state.notice?.message, 'Warning');

    state.setNotice(
      const HomeUiNotice(message: 'Error', tone: HomeUiNoticeTone.error),
    );
    state.clearTransientNotice();
    expect(state.notice?.message, 'Error');
  });
}
