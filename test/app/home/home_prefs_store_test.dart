import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load reads persisted indicator and target mode', () async {
    SharedPreferences.setMockInitialValues({
      HomePrefsStore.indicatorPinnedKey: true,
      HomePrefsStore.displayTargetModeKey:
          DisplayTargetMode.singleAppWindow.index,
    });

    final prefsStore = HomePrefsStore();
    final prefs = await prefsStore.load();

    expect(prefs.indicatorPinned, isTrue);
    expect(prefs.targetMode, DisplayTargetMode.singleAppWindow);
  });

  test('load reads persisted pane layout JSON', () async {
    const paneLayout = DesktopPaneLayoutPrefs(
      paneStates: {
        DesktopPaneId.homeLeftSidebar: DesktopPaneState(isCollapsed: true),
        DesktopPaneId.recordingSidebar: DesktopPaneState(
          width: 364,
          lastExpandedWidth: 364,
          userResized: true,
        ),
      },
    );
    SharedPreferences.setMockInitialValues({
      HomePrefsStore.homePaneLayoutKey:
          '{"homeLeftSidebar":{"isCollapsed":true,"autoCollapseAllowed":true,"userResized":false},"recordingSidebar":{"width":364.0,"lastExpandedWidth":364.0,"isCollapsed":false,"autoCollapseAllowed":true,"userResized":true}}',
    });

    final prefsStore = HomePrefsStore();
    final prefs = await prefsStore.load();

    expect(prefs.paneLayout, paneLayout);
  });

  test('load falls back safely for malformed pane layout JSON', () async {
    SharedPreferences.setMockInitialValues({
      HomePrefsStore.homePaneLayoutKey: '{broken-json',
    });

    final prefsStore = HomePrefsStore();
    final prefs = await prefsStore.load();

    expect(prefs.paneLayout, const DesktopPaneLayoutPrefs());
  });

  test('save methods persist values', () async {
    SharedPreferences.setMockInitialValues({});
    final prefsStore = HomePrefsStore();

    await prefsStore.saveIndicatorPinned(true);
    await prefsStore.saveDisplayTargetMode(DisplayTargetMode.areaRecording);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(HomePrefsStore.indicatorPinnedKey), isTrue);
    expect(
      prefs.getInt(HomePrefsStore.displayTargetModeKey),
      DisplayTargetMode.areaRecording.index,
    );
  });

  test('savePaneLayout persists pane layout JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final prefsStore = HomePrefsStore();
    const paneLayout = DesktopPaneLayoutPrefs(
      paneStates: {
        DesktopPaneId.postProcessingSidebar: DesktopPaneState(
          width: 340,
          lastExpandedWidth: 340,
          userResized: true,
        ),
      },
    );

    await prefsStore.savePaneLayout(paneLayout);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(HomePrefsStore.homePaneLayoutKey),
      '{"postProcessingSidebar":{"width":340.0,"lastExpandedWidth":340.0,"isCollapsed":false,"autoCollapseAllowed":true,"userResized":true}}',
    );
  });
}
