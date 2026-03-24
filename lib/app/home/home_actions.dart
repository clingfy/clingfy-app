import 'dart:async';

import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/core/bridges/native_bar_action.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/app/permissions/widgets/start_recording_permission_dialog.dart';
import 'package:clingfy/app/permissions/widgets/start_recording_storage_dialog.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:clingfy/app/home/preview/widgets/close_unexported_recording_dialog.dart';
import 'package:clingfy/commercial/licensing/widgets/paywall_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomeActions {
  HomeActions({required this.scope});

  final HomeScope scope;

  CountdownController get countdownController => scope.countdown;
  DeviceController get deviceController => scope.devices;
  LicenseController get licenseController => scope.license;
  OverlayController get overlayController => scope.overlay;
  PermissionsController get permissionsController => scope.permissions;
  PlayerController get playerController => scope.player;
  PostProcessingController get postProcessingController => scope.post;
  RecordingController get recordingController => scope.recording;
  HomeUiState get uiState => scope.uiState;
  HomePrefsStore get prefsStore => scope.prefsStore;
  NativeBridge get nativeBridge => scope.app.nativeBridge;
  SettingsController get settingsController => scope.app.settings;

  Future<void> hydrateStartupPrefs() async {
    try {
      final prefs = await prefsStore.load();
      uiState.setIndicatorPinned(prefs.indicatorPinned);
      uiState.setTargetMode(prefs.targetMode);
      await nativeBridge.setRecordingIndicatorPinned(prefs.indicatorPinned);
      await nativeBridge.setDisplayTargetMode(prefs.targetMode);
    } finally {
      uiState.markHydrated();
    }
  }

  Future<void> applyInitialFileTemplate() async {
    await nativeBridge.setFileNameTemplate('{appname}_{date}_{time}');
  }

  void clearToolbarErrors() {
    uiState.clearError();
    recordingController.clearError();
    deviceController.clearError();
    overlayController.clearError();
  }

  Future<void> setIndicatorPinned(bool value) async {
    uiState.setIndicatorPinned(value);
    await prefsStore.saveIndicatorPinned(value);
    await nativeBridge.setRecordingIndicatorPinned(value);
  }

  Future<void> setDisplayTargetMode(DisplayTargetMode mode) async {
    uiState.setTargetMode(mode);
    await prefsStore.saveDisplayTargetMode(mode);
    await nativeBridge.setDisplayTargetMode(mode);

    if (mode == DisplayTargetMode.singleAppWindow) {
      await deviceController.reloadAppWindows();
    }
  }

  Future<void> toggleRecording(BuildContext context) async {
    if (recordingController.showPreviewShell &&
        recordingController.canInteractWithPreview) {
      postProcessingController.togglePlayback();
      return;
    }
    if (recordingController.isBusy || recordingController.isExporting) return;

    uiState.clearError();
    recordingController.clearError();

    try {
      if (!recordingController.isRecording) {
        if (countdownController.isActive) {
          countdownController.cancel();
          recordingController.cancelPendingStartIntent();
          return;
        }
        final overrides = await _resolveRecordingStartOverrides(context);
        if (overrides == null) {
          return;
        }
        if (settingsController.recording.countdownEnabled &&
            settingsController.recording.countdownDuration > 0) {
          recordingController.beginRecordingStartIntent();
          countdownController.start(
            durationSeconds: settingsController.recording.countdownDuration,
            onFinished: () {
              unawaited(
                recordingController.startRecording(overrides: overrides),
              );
            },
          );
        } else {
          await recordingController.startRecording(overrides: overrides);
        }
      } else {
        await recordingController.stopRecording();
      }
    } on PlatformException catch (e) {
      Log.e('HomeActions', 'toggleRecording failed: $e');
      uiState.setError(e.message ?? e.code);
    }
  }

  void handleExportProgress(double progress) {
    postProcessingController.updateProgress(progress);
  }

  Future<void> handleRecordingFinalized(
    BuildContext context,
    String path,
  ) async {
    if (path.isEmpty) return;

    if (settingsController.workspace.openFolderAfterStop) {
      final didOpen = await settingsController.workspace
          .openSaveFolderOncePerSession();
      if (!didOpen && context.mounted) {
        _showSavedFileNotice(
          context,
          prefix: AppLocalizations.of(context)!.recordingSaved,
          path: path,
        );
      }
    }
  }

  Future<void> exportFromUi(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;

    if (recordingController.previewPath == null ||
        recordingController.isRecording ||
        !recordingController.canInteractWithPreview) {
      return;
    }

    if (postProcessingController.isExporting) {
      unawaited(
        ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.export',
          message: 'export_duplicate_start_blocked',
        ),
      );
      uiState.setNotice(
        HomeUiNotice(
          message: l10n.exportAlreadyInProgress,
          tone: HomeUiNoticeTone.warning,
        ),
      );
      return;
    }

    if (postProcessingController.isEditingLocked ||
        postProcessingController.hasError) {
      return;
    }

    uiState.clearTransientNotice();

    if (licenseController.isLoading) {
      await licenseController.refreshEntitlement();
      if (!context.mounted) return;
    }

    if (!licenseController.canExport) {
      unawaited(
        ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.license',
          message: 'license_export_blocked',
          data: {
            'plan': licenseController.currentPlan,
            'trialExportsRemaining': licenseController.trialExportsRemaining,
          },
        ),
      );

      await PaywallDialog.show(context);
      if (!context.mounted) return;

      if (!licenseController.canExport) {
        uiState.setNotice(
          HomeUiNotice(
            message: l10n.paywallExportBlocked,
            tone: HomeUiNoticeTone.warning,
          ),
        );
        return;
      }
    }

    try {
      recordingController.enterExporting();
      final path = await postProcessingController.exportCurrentRecording(
        context,
      );
      if (!context.mounted) return;

      if (path == null) {
        return;
      }

      final consumeOk = await licenseController.consumeExport();
      if (!context.mounted) return;
      if (!consumeOk) {
        uiState.setNotice(
          HomeUiNotice(
            message: l10n.paywallConsumeFailed,
            tone: HomeUiNoticeTone.warning,
          ),
        );
      }

      if (settingsController.workspace.openFolderAfterExport) {
        await settingsController.workspace.openSaveFolderOncePerSession();
        if (!context.mounted) return;
      }

      _showSavedFileNotice(context, prefix: l10n.exportSuccess, path: path);
    } on PlatformException catch (e) {
      if (postProcessingController.lastExportWasCancelled) {
        return;
      }

      final message = e.code == 'EXPORT_INPUT_MISSING'
          ? l10n.errExportInputMissing
          : l10n.errExportError(e.message ?? 'Unknown error');

      uiState.setNotice(
        HomeUiNotice(message: message, tone: HomeUiNoticeTone.error),
      );
    } catch (e) {
      if (postProcessingController.lastExportWasCancelled) {
        return;
      }

      uiState.setNotice(
        HomeUiNotice(
          message: l10n.errExportError(e.toString()),
          tone: HomeUiNoticeTone.error,
        ),
      );
    } finally {
      recordingController.finishExporting();
    }
  }

  Future<void> closePreview(BuildContext context) async {
    final shouldClose = await confirmCloseUnexportedRecordingIfNeeded(
      context,
      warningEnabled:
          settingsController.workspace.warnBeforeClosingUnexportedRecording,
      hasExportedCurrentRecording:
          postProcessingController.hasExportedCurrentRecording,
      disableFutureWarnings: () => settingsController.workspace
          .updateWarnBeforeClosingUnexportedRecording(false),
    );
    if (!shouldClose) return;

    await recordingController.closePreview();
    playerController.clearError();
  }

  Future<void> openSettings(BuildContext context) async {
    await _openSettingsRoute(context, AppSettingsView.routeName);
  }

  Future<void> openStorageSettings(BuildContext context) async {
    await _openSettingsRoute(context, AppSettingsView.storageRouteName);
  }

  Future<void> _openSettingsRoute(
    BuildContext context,
    String routeName,
  ) async {
    if (uiState.isSettingsOpen) return;

    uiState.setSettingsOpen(true);
    try {
      await Navigator.of(context).pushNamed(routeName);
    } finally {
      uiState.setSettingsOpen(false);
    }
  }

  Future<void> openSystemSettings(String pane) async {
    try {
      await nativeBridge.openSystemSettings(pane);
    } catch (e) {
      Log.e('HomeActions', 'Failed to open system settings: $e');
    }
  }

  Future<RecordingStartOverrides?> _resolveRecordingStartOverrides(
    BuildContext context,
  ) async {
    final intent = RecordingStartIntent(
      needsScreenRecording: true,
      needsMicrophone:
          deviceController.selectedAudioSourceId != DeviceController.noAudioId,
      needsCamera: overlayController.cameraOverlayEnabled,
      needsAccessibility: overlayController.cursorEnabled,
    );

    final preflight = await permissionsController
        .prepareRecordingStartPreflight(intent: intent);
    var overrides = const RecordingStartOverrides();

    if (preflight.hasPermissionAttention) {
      if (!context.mounted) {
        return null;
      }

      final decision = await StartRecordingPermissionDialog.show(
        context,
        preflight: preflight,
      );
      if (decision == null ||
          decision == StartRecordingPermissionDecision.cancel) {
        return null;
      }

      if (decision == StartRecordingPermissionDecision.grantPermissions) {
        await _grantMissingRecordingPermissions(preflight);
        await permissionsController.refresh();
        return null;
      }

      overrides = RecordingStartOverrides(
        disableMicrophone: preflight.missingOptional.contains(
          MissingPermissionKind.microphone,
        ),
        disableCameraOverlay: preflight.missingOptional.contains(
          MissingPermissionKind.camera,
        ),
        disableCursorHighlight: preflight.missingOptional.contains(
          MissingPermissionKind.accessibility,
        ),
      );
    }

    final storage = preflight.storage;
    if (storage != null && storage.needsAttention) {
      if (!context.mounted) {
        return null;
      }

      final decision = await StartRecordingStorageDialog.show(
        context,
        storage: storage,
      );
      if (decision == null ||
          decision == StartRecordingStorageDecision.cancel) {
        return null;
      }
      if (!context.mounted) {
        return null;
      }
      if (decision == StartRecordingStorageDecision.openStorageSettings) {
        await openStorageSettings(context);
        return null;
      }
      if (decision == StartRecordingStorageDecision.bypassAndRecord) {
        overrides = RecordingStartOverrides(
          disableMicrophone: overrides.disableMicrophone,
          disableCameraOverlay: overrides.disableCameraOverlay,
          disableCursorHighlight: overrides.disableCursorHighlight,
          allowLowStorageBypass: true,
        );
      }
    }

    return overrides;
  }

  Future<void> _grantMissingRecordingPermissions(
    RecordingStartPreflight preflight,
  ) async {
    if (preflight.missingHard.contains(MissingPermissionKind.screenRecording)) {
      await permissionsController.requestScreen();
      if (!permissionsController.screenRecording) {
        await permissionsController.openScreenSettings();
      }
    }

    if (preflight.missingOptional.contains(MissingPermissionKind.camera)) {
      await permissionsController.requestCam();
    }

    if (preflight.missingOptional.contains(MissingPermissionKind.microphone)) {
      await permissionsController.requestMic();
    }

    if (preflight.missingOptional.contains(
      MissingPermissionKind.accessibility,
    )) {
      await permissionsController.openAccessibility();
    }
  }

  void updateNativeBarState() {
    if (!uiState.uiPrefsHydrated ||
        !deviceController.isHydrated ||
        !overlayController.isHydrated) {
      return;
    }

    final rawCamId = deviceController.selectedCamId;
    final camSelected =
        rawCamId != null &&
        rawCamId.isNotEmpty &&
        rawCamId != 'none' &&
        rawCamId != DeviceController.noAudioId;

    final state = {
      'phase': recordingController.phase.wireValue,
      'sessionId': recordingController.sessionId,
      'countdownActive': countdownController.isActive,
      'targetMode': uiState.targetMode.index,
      'cameraEnabled': camSelected,
      'micEnabled':
          deviceController.selectedAudioSourceId != DeviceController.noAudioId,
      'systemAudioEnabled': settingsController.recording.systemAudioEnabled,
      'updateAvailable': nativeBridge.isUpdateAvailable.value,
      'selectedDisplayId': deviceController.selectedDisplayId,
      'selectedAppWindowId': deviceController.selectedAppWindowId,
      'selectedAudioSourceId': deviceController.selectedAudioSourceId,
      'selectedCamId': camSelected ? rawCamId : null,
    };

    nativeBridge.setPreRecordingBarState(state);
  }

  void handleNativeBarAction(
    BuildContext context,
    String type,
    Map<String, dynamic>? payload,
  ) {
    Log.i('HomeActions', 'NativeBar action: $type, payload: $payload');

    switch (type) {
      case NativeBarAction.closeTapped:
        break;
      case NativeBarAction.displayTapped:
        unawaited(setDisplayTargetMode(DisplayTargetMode.explicitId));
        break;
      case NativeBarAction.windowTapped:
        unawaited(setDisplayTargetMode(DisplayTargetMode.singleAppWindow));
        break;
      case NativeBarAction.areaTapped:
        unawaited(setDisplayTargetMode(DisplayTargetMode.areaRecording));
        unawaited(overlayController.pickAreaRecordingRegion());
        break;
      case NativeBarAction.cameraTapped:
        unawaited(overlayController.cycleOverlayMode());
        break;
      case NativeBarAction.micTapped:
        if (deviceController.selectedAudioSourceId ==
            DeviceController.noAudioId) {
          if (deviceController.audioSources.isNotEmpty) {
            unawaited(
              deviceController.setAudioSource(
                deviceController.audioSources.first.id,
              ),
            );
          }
        } else {
          unawaited(
            deviceController.setAudioSource(DeviceController.noAudioId),
          );
        }
        break;
      case NativeBarAction.systemAudioTapped:
        unawaited(
          settingsController.recording.updateSystemAudioEnabled(
            !settingsController.recording.systemAudioEnabled,
          ),
        );
        break;
      case NativeBarAction.updateTapped:
        nativeBridge.checkForUpdates();
        break;
      case NativeBarAction.recordTapped:
        unawaited(toggleRecording(context));
        break;
    }
  }

  void handleNativeSelectionChanged(String type, dynamic id) {
    Log.i('HomeActions', 'Native selection changed: $type, id: $id');
    unawaited(
      ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.selection',
        message: 'Native selection changed',
        data: {'type': type, 'id': id?.toString()},
      ),
    );

    switch (type) {
      case NativeSelectionType.display:
        if (id is int) {
          uiState.setTargetMode(DisplayTargetMode.explicitId);
          unawaited(
            nativeBridge.setDisplayTargetMode(DisplayTargetMode.explicitId),
          );
          unawaited(deviceController.setDisplay(id));
        }
        break;
      case NativeSelectionType.window:
        uiState.setTargetMode(DisplayTargetMode.singleAppWindow);
        unawaited(
          nativeBridge.setDisplayTargetMode(DisplayTargetMode.singleAppWindow),
        );
        unawaited(deviceController.setAppWindow(id as int?));
        break;
      case NativeSelectionType.mic:
        unawaited(deviceController.setAudioSource(id as String?));
        break;
      case NativeSelectionType.camera:
        final camId = id as String?;
        unawaited(deviceController.setCamSource(camId));
        if (camId != null && camId != 'none' && camId.isNotEmpty) {
          if (overlayController.overlayMode == OverlayMode.off) {
            unawaited(
              overlayController.setOverlayMode(OverlayMode.whileRecording),
            );
          }
        }
        break;
      case NativeSelectionType.mode:
        if (id is int && id >= 0 && id < DisplayTargetMode.values.length) {
          final mode = DisplayTargetMode.values[id];
          uiState.setTargetMode(mode);
          unawaited(nativeBridge.setDisplayTargetMode(mode));
        }
        break;
    }

    updateNativeBarState();
  }

  void _showSavedFileNotice(
    BuildContext context, {
    required String prefix,
    required String path,
  }) {
    final l10n = AppLocalizations.of(context)!;
    uiState.setNotice(
      HomeUiNotice(
        message: '$prefix $path',
        tone: HomeUiNoticeTone.success,
        action: HomeUiNoticeAction(
          label: l10n.revealInFinder,
          onPressed: () => settingsController.workspace.revealFile(path),
        ),
      ),
    );
  }
}
