import 'dart:async';

import 'package:clingfy/app/infrastructure/analytics/analytics_events.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_service.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/core/bridges/native_bar_action.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/app/home/widgets/crash_reporting_notice.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/export/export_disk_full_message.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/startup_recovery_notice.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/app/permissions/widgets/start_recording_permission_dialog.dart';
import 'package:clingfy/app/permissions/widgets/start_recording_storage_dialog.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/settings/widgets/about_view.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:clingfy/app/home/preview/widgets/close_unexported_recording_dialog.dart';
import 'package:clingfy/commercial/licensing/widgets/paywall_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/core/bridges/job_progress.dart';

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
      uiState.applyPaneLayoutPrefs(prefs.paneLayout);
      await nativeBridge.setRecordingIndicatorPinned(prefs.indicatorPinned);
      await nativeBridge.setDisplayTargetMode(prefs.targetMode);
      await recordingController.refreshPauseResumeCapabilities();
    } finally {
      uiState.markHydrated();
    }
  }

  Future<void> applyInitialFileTemplate() async {
    await nativeBridge.setFileNameTemplate('{appname}_{date}_{time}');
  }

  /// Phase 10.4 (Windows-only): runs once after home is ready. Asks native
  /// for the startup crash-recovery report; surfaces a warning toast when
  /// recordings were interrupted (same HomeUiNotice pattern 10.2 uses for
  /// pending recording warnings). Temp-file cleanup alone is log-only.
  static bool _startupRecoveryAnnounced = false;

  @visibleForTesting
  static void debugResetStartupRecoveryAnnouncement() {
    _startupRecoveryAnnounced = false;
  }

  Future<void> announceStartupRecovery(BuildContext context) async {
    if (!isWindows() || _startupRecoveryAnnounced) return;
    _startupRecoveryAnnounced = true;

    final report = await nativeBridge.getStartupRecoveryReport();
    if (report == null) return;

    if (report.hasCleanedTempFiles || report.cleanedTempBytes > 0) {
      Log.i('HomeActions', 'Startup recovery cleaned temp files', null, null, {
        'cleanedTempFileCount': report.cleanedTempFileCount,
        'cleanedTempBytes': report.cleanedTempBytes,
      });
    }
    if (report.hasInterruptedProjects) {
      Log.i(
        'HomeActions',
        'Startup recovery found interrupted recordings',
        null,
        null,
        {
          'count': report.interruptedProjects.length,
          'projectPaths': report.interruptedProjects
              .map((p) => p.projectPath)
              .toList(),
        },
      );
    }

    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final notice = buildStartupRecoveryNotice(
      report,
      interruptedMessage: l10n.recordingInterruptedNotice,
    );
    if (notice != null) {
      uiState.setNotice(notice);
    }
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
    await recordingController.refreshPauseResumeCapabilities();

    if (mode == DisplayTargetMode.singleAppWindow) {
      await deviceController.reloadAppWindows();
    }
    await syncAppWindowWatch();
  }

  /// Starts the native window watcher only while the app-window picker is
  /// actually on screen, and stops it otherwise.
  ///
  /// The window list is the one picker macOS provides no notification for, so
  /// it has to be polled. Polling it in the background forever would be pure
  /// waste — nobody is looking — and polling during a take is worse, because
  /// the picker is unusable then. This is the gate that keeps the cost
  /// proportional to the benefit.
  Future<void> syncAppWindowWatch() async {
    final shouldWatch =
        uiState.targetMode == DisplayTargetMode.singleAppWindow &&
        !recordingController.isRecording;

    if (shouldWatch == _appWindowWatchActive) return;
    _appWindowWatchActive = shouldWatch;
    await nativeBridge.setAppWindowWatchActive(shouldWatch);
  }

  /// Mirrors the native ref-count so a repeated call is not double-counted.
  bool _appWindowWatchActive = false;

  Future<void> persistPaneLayout(DesktopPaneLayoutPrefs layout) async {
    uiState.applyPaneLayoutPrefs(layout);
    await prefsStore.savePaneLayout(layout);
  }

  Future<void> toggleRecording(BuildContext context) async {
    if (recordingController.showPreviewShell &&
        recordingController.canInteractWithPreview) {
      postProcessingController.togglePlayback();
      return;
    }
    if (countdownController.isActive) {
      countdownController.cancel();
      recordingController.cancelPendingStartIntent();
      return;
    }
    if (recordingController.isBusy || recordingController.isExporting) return;

    uiState.clearError();
    recordingController.clearError();

    try {
      if (!recordingController.isRecording) {
        if (!_hasValidRecordingTargetSelection()) {
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
      uiState.setError(_platformExceptionMessageOrCode(e));
    }
  }

  bool _hasValidRecordingTargetSelection() {
    switch (uiState.targetMode) {
      case DisplayTargetMode.singleAppWindow:
        if (deviceController.selectedAppWindowId == null) {
          uiState.setError(NativeErrorCode.noWindowSelected);
          return false;
        }
        return true;
      case DisplayTargetMode.areaRecording:
        if (overlayController.areaRect == null ||
            overlayController.areaDisplayId == null) {
          uiState.setError(NativeErrorCode.noAreaSelected);
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  String _platformExceptionMessageOrCode(PlatformException error) {
    final message = error.message;
    if (message == null || message.trim().isEmpty) {
      return error.code;
    }
    return message;
  }

  /// Routes a native job tick to whoever owns that job's UI.
  ///
  /// One channel now carries both export and transcription, so the job has to
  /// be dispatched on rather than assumed. An unrecognised job is dropped
  /// rather than shown as export progress — a transcription tick moving the
  /// export bar would be worse than no bar at all.
  void handleJobProgress(JobProgress progress) {
    switch (progress.job) {
      case ProgressJob.export:
        postProcessingController.updateProgress(progress.fraction);
      case ProgressJob.captions:
        postProcessingController.updateCaptionsProgress(progress);
      case ProgressJob.unknown:
        // Dropped rather than shown as export progress — a tick from a job this
        // build does not know about moving the export bar would be worse than
        // no bar at all.
        break;
    }
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

  Future<void> handleExternalProjectOpen(
    BuildContext context,
    String projectPath,
  ) async {
    if (projectPath.isEmpty) return;

    final l10n = AppLocalizations.of(context)!;

    if (_shouldBlockExternalProjectOpen()) {
      uiState.setNotice(
        HomeUiNotice(
          message: l10n.externalProjectOpenBlocked,
          tone: HomeUiNoticeTone.warning,
          autoDismissAfter: const Duration(seconds: 5),
        ),
      );
      return;
    }

    if (recordingController.projectPath == projectPath &&
        recordingController.canInteractWithPreview) {
      return;
    }

    if (recordingController.canInteractWithPreview &&
        recordingController.projectPath != null &&
        recordingController.projectPath != projectPath) {
      final shouldClose = await confirmCloseUnexportedRecordingIfNeeded(
        context,
        warningEnabled:
            settingsController.workspace.warnBeforeClosingUnexportedRecording,
        hasExportedCurrentRecording:
            postProcessingController.hasExportedCurrentRecording,
        disableFutureWarnings: () => settingsController.workspace
            .updateWarnBeforeClosingUnexportedRecording(false),
      );
      if (!shouldClose) {
        return;
      }

      playerController.clearError();
      uiState.clearTransientNotice();
      await recordingController.replacePreviewWithProject(projectPath);
      return;
    }

    playerController.clearError();
    uiState.clearTransientNotice();
    recordingController.clearError();
    recordingController.openExistingProject(projectPath);
  }

  void handleExternalProjectOpenFailed(
    BuildContext context,
    String projectPath,
  ) {
    if (projectPath.isEmpty) return;

    uiState.setNotice(
      HomeUiNotice(
        message: AppLocalizations.of(context)!.externalProjectOpenFailed,
        tone: HomeUiNoticeTone.error,
      ),
    );
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

    // The wider lock, not [isEditingLocked]: a transcription in flight must not
    // be able to start an export, but the sidebar it shares a getter with has
    // to stay live — the captions Stop button is in there.
    if (postProcessingController.isExportLocked ||
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

      ClingfyAnalytics.capture(
        AnalyticsEvents.billingPaywallView,
        properties: {
          'reason': 'export_blocked',
          'plan': licenseController.currentPlan,
          'trial_exports_remaining': licenseController.trialExportsRemaining,
        },
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

      // A burn-in that was asked for and failed leaves an export payload
      // byte-identical to a captionless one, so native renders happily and
      // everything downstream reports success. Saying "Export successful" here
      // is how someone publishes a video they believe is subtitled.
      _showSavedFileNotice(
        context,
        prefix: postProcessingController.lastExportBurnInFailed
            ? l10n.exportSavedWithoutSubtitles
            : l10n.exportSuccess,
        path: path,
        tone: postProcessingController.lastExportBurnInFailed
            ? HomeUiNoticeTone.warning
            : HomeUiNoticeTone.success,
      );
      // First successful export is when the crash-reporting disclosure fires.
      // At launch it is a modal about diagnostics in front of someone who has
      // not used the app yet, and the fastest way past it is to dismiss it
      // unread — which makes the disclosure worthless. Here the user has just
      // finished something and nothing else is competing for attention.
      if (context.mounted) {
        await maybeShowCrashReportingNotice(context);
      }
    } on PlatformException catch (e) {
      if (postProcessingController.lastExportWasCancelled) {
        return;
      }

      // Disk-full ranks above the generic export-error message: it tells the
      // user *exactly* why and what to do (free space / lower resolution).
      final message =
          ExportDiskFullMessage.forException(e, l10n) ??
          (e.code == 'EXPORT_INPUT_MISSING'
              ? l10n.errExportInputMissing
              : e.code == NativeErrorCode.advancedCameraExportFailed
              ? (e.message ??
                    'Advanced camera styling could not be rendered for export.')
              : l10n.errExportError(e.message ?? 'Unknown error'));

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

  bool _shouldBlockExternalProjectOpen() {
    if (countdownController.isActive) {
      return true;
    }

    return switch (recordingController.phase) {
      WorkflowPhase.idle || WorkflowPhase.previewReady => false,
      WorkflowPhase.openingPreview ||
      WorkflowPhase.previewLoading ||
      WorkflowPhase.closingPreview ||
      WorkflowPhase.startingRecording ||
      WorkflowPhase.recording ||
      WorkflowPhase.pausedRecording ||
      WorkflowPhase.stoppingRecording ||
      WorkflowPhase.finalizingRecording ||
      WorkflowPhase.exporting => true,
    };
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

  Future<void> openAbout(BuildContext context) async {
    await _openSettingsRoute(context, AboutView.routeName);
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

    // "No microphone" is a DEVICE choice, and it has to reach the recorder on
    // its own. It used to travel only as `needsMicrophone: false` on the
    // preflight intent, which merely skips the permission prompt — so
    // `disableMicrophone` stayed false, native took `want_mic = true`, and
    // opened the DEFAULT microphone (empty id) for the whole session. The user
    // asked for no mic and the app recorded from one: silent, but running, and
    // bundled as a real mic sidecar.
    //
    // Seeded here rather than only inside the permission branch below, because
    // that branch runs ONLY when something needs attention — on the ordinary
    // path it never executes and the flag stayed false.
    final micDeselected =
        deviceController.selectedAudioSourceId == DeviceController.noAudioId;
    var overrides = RecordingStartOverrides(disableMicrophone: micDeselected);

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
        // Either reason disables it: the user did not want a mic, or the OS
        // will not give us one.
        disableMicrophone:
            micDeselected ||
            preflight.missingOptional.contains(
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
    // Cheap: syncAppWindowWatch returns immediately unless the gate flipped.
    unawaited(syncAppWindowWatch());

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

    final micLive =
        deviceController.selectedAudioSourceId != DeviceController.noAudioId;

    final state = {
      'phase': recordingController.phase.wireValue,
      'sessionId': recordingController.sessionId,
      'countdownActive': countdownController.isActive,
      'targetMode': uiState.targetMode.index,
      'cameraEnabled': camSelected,
      'micEnabled': micLive,
      'systemAudioEnabled': settingsController.recording.systemAudioEnabled,
      'updateAvailable': nativeBridge.isUpdateAvailable.value,
      'canPauseResume': recordingController.canPauseResume,
      'pauseResumeInFlight': recordingController.pauseResumeInFlight,
      'selectedDisplayId': deviceController.selectedDisplayId,
      'selectedAppWindowId': deviceController.selectedAppWindowId,
      'selectedAudioSourceId': deviceController.selectedAudioSourceId,
      'selectedCamId': camSelected ? rawCamId : null,
      // Pre-record audio warnings. The bar is the surface a user actually
      // looks at before hitting record, so these cannot live only in the
      // sidebar. Both are gated on a live mic for the same reason the sidebar
      // gates them: with no microphone there is nothing to bleed INTO and no
      // level to be too low, and "No microphone" is the first-run default.
      'micInputTooLow': micLive && deviceController.micInputTooLow,
      'systemAudioBleedRisk':
          micLive && settingsController.recording.systemAudioBleedRisk,
    };

    // The mic level meter notifies on every level delta, and DeviceController
    // is a listener on this method — so without this guard a live microphone
    // pushed bar state to native dozens of times a second, and the native
    // updateState re-framed the floating panel (animated) on every one of
    // them. The bar renders none of that: it consumes only the fields below.
    if (_lastBarState != null && mapEquals(_lastBarState, state)) {
      return;
    }
    _lastBarState = state;

    nativeBridge.setPreRecordingBarState(state);
  }

  /// Last payload actually sent, so identical pushes are dropped.
  Map<String, dynamic>? _lastBarState;

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
      case NativeBarAction.pauseTapped:
        unawaited(recordingController.pauseRecording());
        break;
      case NativeBarAction.resumeTapped:
        unawaited(recordingController.resumeRecording());
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

    unawaited(recordingController.refreshPauseResumeCapabilities());
    updateNativeBarState();
  }

  void _showSavedFileNotice(
    BuildContext context, {
    required String prefix,
    required String path,
    HomeUiNoticeTone tone = HomeUiNoticeTone.success,
  }) {
    final l10n = AppLocalizations.of(context)!;
    uiState.setNotice(
      HomeUiNotice(
        message: '$prefix $path',
        tone: tone,
        action: HomeUiNoticeAction(
          label: l10n.revealInFinder,
          onPressed: () => settingsController.workspace.revealFile(path),
        ),
      ),
    );
  }
}
