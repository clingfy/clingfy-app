import 'dart:async';

import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_desktop_pane_dimensions.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_shell.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/app/settings/sections/about_settings_section.dart';
import 'package:clingfy/app/settings/sections/workspace_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/settings/widgets/about_view.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/native_test_setup.dart';

Future<void> _emitWorkflowEvent(Map<String, Object?> event) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.workflowEvents,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) => completer.complete(),
  );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<
    ({
      HomeActions actions,
      CountdownController countdown,
      DeviceController device,
      LicenseController license,
      OverlayController overlay,
      PermissionsController permissions,
      PlayerController player,
      PostProcessingController post,
      RecordingController recording,
      SettingsController settings,
      HomeUiState uiState,
    })
  >
  createHarness() async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final player = PlayerController(nativeBridge: nativeBridge)
      ..bindWorkflow(recording);
    final device = DeviceController(nativeBridge: nativeBridge);
    final overlay = OverlayController(bridge: nativeBridge);
    final permissions = PermissionsController(bridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    final license = LicenseController();
    final countdown = CountdownController();
    final uiState = HomeUiState();
    final actions = HomeActions(
      scope: HomeScope(
        app: AppScope(nativeBridge: nativeBridge, settings: settings),
        recording: recording,
        player: player,
        devices: device,
        overlay: overlay,
        permissions: permissions,
        post: post,
        license: license,
        countdown: countdown,
        uiState: uiState,
        prefsStore: HomePrefsStore(),
      ),
    );

    return (
      actions: actions,
      countdown: countdown,
      device: device,
      license: license,
      overlay: overlay,
      permissions: permissions,
      player: player,
      post: post,
      recording: recording,
      settings: settings,
      uiState: uiState,
    );
  }

  Widget buildShell({
    required HomeActions actions,
    required CountdownController countdown,
    required DeviceController device,
    required LicenseController license,
    required OverlayController overlay,
    required PlayerController player,
    required PostProcessingController post,
    required RecordingController recording,
    required SettingsController settings,
    required HomeUiState uiState,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingController>.value(value: recording),
        ChangeNotifierProvider<DeviceController>.value(value: device),
        ChangeNotifierProvider<LicenseController>.value(value: license),
        ChangeNotifierProvider<OverlayController>.value(value: overlay),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<PostProcessingController>.value(value: post),
        ChangeNotifierProvider<HomeUiState>.value(value: uiState),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        builder: (context, child) =>
            MacosTheme(data: buildMacosTheme(Brightness.dark), child: child!),
        routes: {
          AppSettingsView.routeName: (_) =>
              AppSettingsView(controller: settings),
          AppSettingsView.storageRouteName: (_) => AppSettingsView(
            controller: settings,
            initialSection: SettingsSection.storage,
          ),
          AboutView.routeName: (_) => AppSettingsView(
            controller: settings,
            initialSection: SettingsSection.about,
          ),
        },
        home: HomeShell(
          title: 'Clingfy',
          actions: actions,
          uiState: uiState,
          settingsController: settings,
          countdownController: countdown,
        ),
      ),
    );
  }

  testWidgets('recording shell keeps rail separate from the workspace column', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final harness = await createHarness();
    final theme = buildDarkTheme();
    harness.uiState.setRecordingSidebarIndex(2);

    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.device.dispose);
    addTearDown(harness.overlay.dispose);
    addTearDown(harness.permissions.dispose);
    addTearDown(harness.post.dispose);
    addTearDown(harness.license.dispose);
    addTearDown(harness.countdown.dispose);
    addTearDown(harness.uiState.dispose);
    addTearDown(harness.settings.dispose);

    await tester.pumpWidget(
      buildShell(
        actions: harness.actions,
        countdown: harness.countdown,
        device: harness.device,
        license: harness.license,
        overlay: harness.overlay,
        player: harness.player,
        post: harness.post,
        recording: harness.recording,
        settings: harness.settings,
        uiState: harness.uiState,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_left_sidebar_shell')), findsOneWidget);
    expect(find.byKey(const Key('home_options_panel_shell')), findsOneWidget);
    expect(find.byKey(const Key('desktop_toolbar_surface')), findsOneWidget);
    expect(find.byKey(const Key('home_sidebar_logo')), findsOneWidget);
    expect(find.byKey(const Key('timeline_shell')), findsNothing);
    expect(
      find.byKey(const Key('home_sidebar_settings_button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home_sidebar_help_button')), findsOneWidget);
    expect(find.byKey(const Key('home_sidebar_reset_button')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('recording_sidebar_header')),
        matching: find.text('Output'),
      ),
      findsOneWidget,
    );

    final railRect = tester.getRect(
      find.byKey(const Key('home_left_sidebar_shell')),
    );
    final toolbarRect = tester.getRect(
      find.byKey(const Key('desktop_toolbar_surface')),
    );
    final optionsRect = tester.getRect(
      find.byKey(const Key('home_options_panel_shell')),
    );
    final logoRect = tester.getRect(find.byKey(const Key('home_sidebar_logo')));
    final firstRailTileRect = tester.getRect(
      find.byKey(const ValueKey('recording_sidebar_rail_tile_0')),
    );
    final resetRect = tester.getRect(
      find.byKey(const Key('home_sidebar_reset_button')),
    );
    final helpRect = tester.getRect(
      find.byKey(const Key('home_sidebar_help_button')),
    );
    final settingsRect = tester.getRect(
      find.byKey(const Key('home_sidebar_settings_button')),
    );
    final frameRect = tester.getRect(
      find.byKey(const Key('editor_shell_frame')),
    );
    final viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    final settingsButton = tester.widget<IconButton>(
      find.byKey(const Key('home_sidebar_settings_button')),
    );
    final helpButton = tester.widget<IconButton>(
      find.byKey(const Key('home_sidebar_help_button')),
    );
    final resetButton = tester.widget<IconButton>(
      find.byKey(const Key('home_sidebar_reset_button')),
    );
    final utilityInactiveColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.78,
    );

    expect(toolbarRect.left, greaterThan(railRect.right));
    expect(toolbarRect.left, moreOrLessEquals(optionsRect.left));
    expect(
      logoRect.top - railRect.top,
      moreOrLessEquals(AppSidebarTokens.sectionGap),
    );
    expect(firstRailTileRect.top, greaterThan(logoRect.bottom));
    expect(resetRect.top, lessThan(helpRect.top));
    expect(helpRect.top, lessThan(settingsRect.top));
    expect(
      helpRect.top - resetRect.bottom,
      moreOrLessEquals(AppSidebarTokens.railItemGap),
    );
    expect(
      settingsRect.top - helpRect.bottom,
      moreOrLessEquals(AppSidebarTokens.railItemGap),
    );
    expect(frameRect.left, kEditorShellOuterPadding);
    expect(frameRect.top, kEditorShellOuterPadding);
    expect(frameRect.right, viewSize.width - kEditorShellOuterPadding);
    expect(frameRect.bottom, viewSize.height - kEditorShellOuterPadding);
    expect(settingsButton.iconSize, 28);
    expect(helpButton.iconSize, 28);
    expect(resetButton.iconSize, 28);
    expect(
      settingsButton.style?.backgroundColor?.resolve({}),
      Colors.transparent,
    );
    expect(helpButton.style?.backgroundColor?.resolve({}), Colors.transparent);
    expect(resetButton.style?.backgroundColor?.resolve({}), Colors.transparent);
    expect(
      settingsButton.style?.foregroundColor?.resolve({}),
      utilityInactiveColor,
    );
    expect(
      helpButton.style?.foregroundColor?.resolve({}),
      utilityInactiveColor,
    );
    expect(
      resetButton.style?.foregroundColor?.resolve({}),
      utilityInactiveColor,
    );
    expect(
      settingsButton.style?.foregroundColor?.resolve({WidgetState.hovered}),
      theme.colorScheme.onSurface,
    );

    expect(
      _decorationFor(
        tester,
        find.byKey(const Key('editor_shell_frame')),
      ).border,
      isNull,
    );
    expect(
      _decorationFor(tester, find.byKey(const Key('home_left_sidebar_shell'))),
      predicate<BoxDecoration>(
        (decoration) =>
            decoration.border == null &&
            decoration.color == theme.appTokens.editorChromeBackground,
      ),
    );
    expect(
      _decorationFor(tester, find.byKey(const Key('home_options_panel_shell'))),
      predicate<BoxDecoration>(
        (decoration) =>
            decoration.border == null &&
            decoration.color == theme.appTokens.previewPanelBackground,
      ),
    );
    expect(
      _decorationFor(tester, find.byKey(const Key('desktop_toolbar_surface'))),
      predicate<BoxDecoration>(
        (decoration) =>
            decoration.border == null &&
            decoration.color == theme.appTokens.editorChromeBackground,
      ),
    );
    expect(
      _decorationFor(
        tester,
        find.byKey(const Key('home_right_panel_shell')),
      ).border,
      isNull,
    );
  });

  testWidgets(
    'preview shell keeps the rail separate and aligns timeline with the workspace column',
    (tester) async {
      _setDesktopWindow(tester);
      final harness = await createHarness();
      harness.uiState.setRecordingSidebarIndex(2);
      harness.uiState.setPostProcessingSidebarIndex(1);

      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.device.dispose);
      addTearDown(harness.overlay.dispose);
      addTearDown(harness.permissions.dispose);
      addTearDown(harness.post.dispose);
      addTearDown(harness.license.dispose);
      addTearDown(harness.countdown.dispose);
      addTearDown(harness.uiState.dispose);
      addTearDown(harness.settings.dispose);

      await tester.pumpWidget(
        buildShell(
          actions: harness.actions,
          countdown: harness.countdown,
          device: harness.device,
          license: harness.license,
          overlay: harness.overlay,
          player: harness.player,
          post: harness.post,
          recording: harness.recording,
          settings: harness.settings,
          uiState: harness.uiState,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('recording_sidebar_header')),
          matching: find.text('Output'),
        ),
        findsOneWidget,
      );

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      await harness.recording.stopRecording();
      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'path': '/tmp/test.mov',
      });
      await _emitWorkflowEvent({
        'type': 'previewReady',
        'sessionId': sessionId,
        'path': '/tmp/test.mov',
        'token': 'preview_token',
      });

      await tester.pumpAndSettle();

      expect(find.byKey(const Key('timeline_shell')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('post_sidebar_header')),
          matching: find.text('Effects Settings'),
        ),
        findsOneWidget,
      );

      final railRect = tester.getRect(
        find.byKey(const Key('home_left_sidebar_shell')),
      );
      final toolbarRect = tester.getRect(
        find.byKey(const Key('desktop_toolbar_surface')),
      );
      final optionsRect = tester.getRect(
        find.byKey(const Key('home_options_panel_shell')),
      );
      final timelineRect = tester.getRect(
        find.byKey(const Key('timeline_shell')),
      );

      expect(toolbarRect.left, greaterThan(railRect.right));
      expect(toolbarRect.left, moreOrLessEquals(optionsRect.left));
      expect(toolbarRect.left, moreOrLessEquals(timelineRect.left));
      expect(
        _decorationFor(tester, find.byKey(const Key('timeline_shell'))).border,
        isNull,
      );
    },
  );

  testWidgets('sidebar settings button opens the workspace settings route', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final harness = await createHarness();

    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.device.dispose);
    addTearDown(harness.overlay.dispose);
    addTearDown(harness.permissions.dispose);
    addTearDown(harness.post.dispose);
    addTearDown(harness.license.dispose);
    addTearDown(harness.countdown.dispose);
    addTearDown(harness.uiState.dispose);
    addTearDown(harness.settings.dispose);

    await tester.pumpWidget(
      buildShell(
        actions: harness.actions,
        countdown: harness.countdown,
        device: harness.device,
        license: harness.license,
        overlay: harness.overlay,
        player: harness.player,
        post: harness.post,
        recording: harness.recording,
        settings: harness.settings,
        uiState: harness.uiState,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home_sidebar_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceSettingsSection), findsOneWidget);
  });

  testWidgets('sidebar help button opens the about settings route', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final harness = await createHarness();

    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.device.dispose);
    addTearDown(harness.overlay.dispose);
    addTearDown(harness.permissions.dispose);
    addTearDown(harness.post.dispose);
    addTearDown(harness.license.dispose);
    addTearDown(harness.countdown.dispose);
    addTearDown(harness.uiState.dispose);
    addTearDown(harness.settings.dispose);

    await tester.pumpWidget(
      buildShell(
        actions: harness.actions,
        countdown: harness.countdown,
        device: harness.device,
        license: harness.license,
        overlay: harness.overlay,
        player: harness.player,
        post: harness.post,
        recording: harness.recording,
        settings: harness.settings,
        uiState: harness.uiState,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home_sidebar_help_button')));
    await tester.pumpAndSettle();

    expect(find.byType(AboutSettingsSection), findsOneWidget);
  });

  testWidgets(
    'debug reset action stays in the sidebar and shows confirmation',
    (tester) async {
      _setDesktopWindow(tester);
      final harness = await createHarness();

      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.device.dispose);
      addTearDown(harness.overlay.dispose);
      addTearDown(harness.permissions.dispose);
      addTearDown(harness.post.dispose);
      addTearDown(harness.license.dispose);
      addTearDown(harness.countdown.dispose);
      addTearDown(harness.uiState.dispose);
      addTearDown(harness.settings.dispose);

      await tester.pumpWidget(
        buildShell(
          actions: harness.actions,
          countdown: harness.countdown,
          device: harness.device,
          license: harness.license,
          overlay: harness.overlay,
          player: harness.player,
          post: harness.post,
          recording: harness.recording,
          settings: harness.settings,
          uiState: harness.uiState,
        ),
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(tester.element(find.byType(HomeShell)))!;

      await tester.tap(find.byKey(const Key('home_sidebar_reset_button')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.debugResetPreferencesTitle), findsOneWidget);
      expect(find.text(l10n.debugResetPreferencesMessage), findsOneWidget);
    },
  );

  testWidgets(
    'persisted pane layout restores pane widths and collapsed state',
    (tester) async {
      _setDesktopWindow(tester);
      final harness = await createHarness();
      harness.uiState.applyPaneLayoutPrefs(
        const DesktopPaneLayoutPrefs(
          paneStates: {
            DesktopPaneId.homeLeftSidebar: DesktopPaneState(isCollapsed: true),
            DesktopPaneId.recordingSidebar: DesktopPaneState(
              width: 320,
              lastExpandedWidth: 320,
              userResized: true,
            ),
          },
        ),
      );

      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.device.dispose);
      addTearDown(harness.overlay.dispose);
      addTearDown(harness.permissions.dispose);
      addTearDown(harness.post.dispose);
      addTearDown(harness.license.dispose);
      addTearDown(harness.countdown.dispose);
      addTearDown(harness.uiState.dispose);
      addTearDown(harness.settings.dispose);

      await tester.pumpWidget(
        buildShell(
          actions: harness.actions,
          countdown: harness.countdown,
          device: harness.device,
          license: harness.license,
          overlay: harness.overlay,
          player: harness.player,
          post: harness.post,
          recording: harness.recording,
          settings: harness.settings,
          uiState: harness.uiState,
        ),
      );
      await tester.pumpAndSettle();

      final railRect = tester.getRect(
        find.byKey(const Key('home_left_sidebar_shell')),
      );
      final optionsRect = tester.getRect(
        find.byKey(const Key('home_options_panel_shell')),
      );

      expect(
        railRect.width,
        moreOrLessEquals(HomeDesktopPaneDimensions.leftCollapsed),
      );
      expect(optionsRect.width, moreOrLessEquals(320));
    },
  );

  testWidgets('options pane collapse and expand restore the last width', (
    tester,
  ) async {
    _setDesktopWindow(tester);
    final harness = await createHarness();
    harness.uiState.applyPaneLayoutPrefs(
      const DesktopPaneLayoutPrefs(
        paneStates: {
          DesktopPaneId.recordingSidebar: DesktopPaneState(
            width: 356,
            lastExpandedWidth: 356,
            userResized: true,
          ),
        },
      ),
    );

    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.device.dispose);
    addTearDown(harness.overlay.dispose);
    addTearDown(harness.permissions.dispose);
    addTearDown(harness.post.dispose);
    addTearDown(harness.license.dispose);
    addTearDown(harness.countdown.dispose);
    addTearDown(harness.uiState.dispose);
    addTearDown(harness.settings.dispose);

    await tester.pumpWidget(
      buildShell(
        actions: harness.actions,
        countdown: harness.countdown,
        device: harness.device,
        license: harness.license,
        overlay: harness.overlay,
        player: harness.player,
        post: harness.post,
        recording: harness.recording,
        settings: harness.settings,
        uiState: harness.uiState,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('home_options_panel_collapse_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home_options_panel_expand_button')),
      findsOneWidget,
    );
    expect(
      harness.uiState.paneStateFor(DesktopPaneId.recordingSidebar).isCollapsed,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('home_options_panel_expand_button')));
    await tester.pumpAndSettle();

    final optionsRect = tester.getRect(
      find.byKey(const Key('home_options_panel_shell')),
    );
    expect(
      harness.uiState.paneStateFor(DesktopPaneId.recordingSidebar).isCollapsed,
      isFalse,
    );
    expect(optionsRect.width, moreOrLessEquals(356));
  });

  testWidgets(
    'narrow shell auto-collapses panes and scrolls without overflow',
    (tester) async {
      final harness = await createHarness();

      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.device.dispose);
      addTearDown(harness.overlay.dispose);
      addTearDown(harness.permissions.dispose);
      addTearDown(harness.post.dispose);
      addTearDown(harness.license.dispose);
      addTearDown(harness.countdown.dispose);
      addTearDown(harness.uiState.dispose);
      addTearDown(harness.settings.dispose);

      tester.view.physicalSize = const Size(820, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        buildShell(
          actions: harness.actions,
          countdown: harness.countdown,
          device: harness.device,
          license: harness.license,
          overlay: harness.overlay,
          player: harness.player,
          post: harness.post,
          recording: harness.recording,
          settings: harness.settings,
          uiState: harness.uiState,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('desktop_split_layout_scroll_view')),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('home_options_panel_expand_button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

void _setDesktopWindow(
  WidgetTester tester, {
  Size size = const Size(1440, 960),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

BoxDecoration _decorationFor(WidgetTester tester, Finder finder) {
  final container = tester.widget<Container>(finder);
  return container.decoration! as BoxDecoration;
}
