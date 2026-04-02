import 'dart:async';

import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/keyboard_shortcuts_controller.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_bindings.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_shell.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/home_loading_view.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/app/infrastructure/native/native_strings_bridge.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.appScope});

  final AppScope appScope;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CountdownController _countdownController;
  late final HomeUiState _uiState;
  late final HomePrefsStore _prefsStore;
  late final PermissionsController _permissionsController;

  HomeActions? _actions;
  HomeBindings? _bindings;
  KeyboardShortcutsController? _keyboardShortcutsController;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _countdownController = CountdownController();
    _uiState = HomeUiState();
    _prefsStore = HomePrefsStore();
    _permissionsController = PermissionsController(
      bridge: widget.appScope.nativeBridge,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NativeStringsBridge().onLocaleChanged(context);

    if (_initialized) return;
    _initialized = true;

    final recordingController = context.read<RecordingController>();
    final playerController = context.read<PlayerController>();
    final deviceController = context.read<DeviceController>();
    final overlayController = context.read<OverlayController>();
    final postProcessingController = context.read<PostProcessingController>();
    final licenseController = context.read<LicenseController>();
    final homeScope = HomeScope(
      app: widget.appScope,
      recording: recordingController,
      player: playerController,
      devices: deviceController,
      overlay: overlayController,
      permissions: _permissionsController,
      post: postProcessingController,
      license: licenseController,
      countdown: _countdownController,
      uiState: _uiState,
      prefsStore: _prefsStore,
    );

    final actions = HomeActions(scope: homeScope);

    _actions = actions;
    _bindings = HomeBindings(
      scope: homeScope,
      onToggleRecording: () => actions.toggleRecording(context),
      onRecordingFinalized: (path) =>
          actions.handleRecordingFinalized(context, path),
      onExportProgress: actions.handleExportProgress,
      onHandleNativeBarAction: (type, payload) =>
          actions.handleNativeBarAction(context, type, payload),
      onHandleNativeSelectionChanged: actions.handleNativeSelectionChanged,
      onUpdateNativeBarState: actions.updateNativeBarState,
    )..bind();

    _keyboardShortcutsController = KeyboardShortcutsController(
      settings: widget.appScope.settings,
      onToggleRecording: () {
        unawaited(actions.toggleRecording(context));
      },
      onRefreshDevices: () {
        deviceController.reloadAudioSources();
        deviceController.reloadCameras();
      },
      onToggleActionBar: widget.appScope.nativeBridge.togglePreRecordingBar,
      onCycleOverlayMode: overlayController.cycleOverlayMode,
      onExportVideo: () => actions.exportFromUi(context),
      onShowActionBar: widget.appScope.nativeBridge.showPreRecordingBar,
      onOpenSettings: () {
        unawaited(actions.openSettings(context));
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await actions.hydrateStartupPrefs();
      } catch (e, st) {
        Log.e('HomePage', 'Failed to hydrate startup UI prefs', e, st);
      }
      if (!mounted) return;

      NativeStringsBridge().attachContext(context);
      await widget.appScope.nativeBridge.setPreRecordingBarEnabled(
        widget.appScope.settings.workspace.showPreRecordingActionBar,
      );
      await actions.applyInitialFileTemplate();
      actions.updateNativeBarState();
    });
  }

  @override
  void dispose() {
    _bindings?.unbind();
    _countdownController.dispose();
    _permissionsController.dispose();
    _uiState.dispose();
    super.dispose();
  }

  Widget _bindActions({required Widget child}) {
    final keyboardShortcutsController = _keyboardShortcutsController;
    if (keyboardShortcutsController == null) return child;

    return Actions(
      actions: keyboardShortcutsController.buildActions(context),
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: widget.appScope.settings,
          builder: (context, _) {
            return PlatformMenuBar(
              menus: keyboardShortcutsController.buildMenus(context),
              child: Shortcuts(
                shortcuts: keyboardShortcutsController.shortcuts,
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    if (actions == null || _keyboardShortcutsController == null) {
      return const HomeLoadingView();
    }

    final deviceHydrated = context.select<DeviceController, bool>(
      (d) => d.isHydrated,
    );
    final overlayHydrated = context.select<OverlayController, bool>(
      (o) => o.isHydrated,
    );

    return _bindActions(
      child: AnimatedBuilder(
        animation: _uiState,
        builder: (context, _) {
          final isStartupHydrated =
              _uiState.uiPrefsHydrated && deviceHydrated && overlayHydrated;
          if (!isStartupHydrated) {
            return const HomeLoadingView();
          }

          return ChangeNotifierProvider<HomeUiState>.value(
            value: _uiState,
            child: HomeShell(
              actions: actions,
              uiState: _uiState,
              settingsController: widget.appScope.settings,
              countdownController: _countdownController,
            ),
          );
        },
      ),
    );
  }
}
