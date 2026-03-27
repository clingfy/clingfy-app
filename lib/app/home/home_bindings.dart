import 'dart:async';

import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/services.dart';

class HomeBindings {
  HomeBindings({
    required this.scope,
    required this.onToggleRecording,
    required this.onRecordingFinalized,
    required this.onExportProgress,
    required this.onHandleNativeBarAction,
    required this.onHandleNativeSelectionChanged,
    required this.onUpdateNativeBarState,
  });

  final HomeScope scope;
  final Future<void> Function() onToggleRecording;
  final Future<void> Function(String path) onRecordingFinalized;
  final void Function(double progress) onExportProgress;
  final void Function(String type, Map<String, dynamic>? payload)
  onHandleNativeBarAction;
  final void Function(String type, dynamic id) onHandleNativeSelectionChanged;
  final void Function() onUpdateNativeBarState;

  bool _isBound = false;

  CountdownController get countdownController => scope.countdown;
  NativeBridge get nativeBridge => scope.app.nativeBridge;
  SettingsController get settingsController => scope.app.settings;
  RecordingController get recordingController => scope.recording;
  DeviceController get deviceController => scope.devices;
  OverlayController get overlayController => scope.overlay;
  PostProcessingController get postProcessingController => scope.post;

  bool? _lastRecordingActive;
  String? _attachedRecordingSessionId;

  bool _handleKeyDebug(KeyEvent event) {
    if (event is KeyDownEvent &&
        countdownController.isActive &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      countdownController.cancel();
      recordingController.cancelPendingStartIntent();
      return true;
    }
    return false;
  }

  void _handleWorkflowChanged() {
    final isRecording = recordingController.isActivelyRecording;
    if (_lastRecordingActive != isRecording) {
      overlayController.updateRecordingState(isRecording);
      _lastRecordingActive = isRecording;
    }

    final state = recordingController.state;
    if (state.phase == WorkflowPhase.openingPreview &&
        state.sessionId != null &&
        state.finalizedRecordingPath != null &&
        _attachedRecordingSessionId != state.sessionId) {
      _attachedRecordingSessionId = state.sessionId;
      postProcessingController.attachToRecording(
        sessionId: state.sessionId!,
        sourcePath: state.finalizedRecordingPath!,
      );
      unawaited(
        postProcessingController.prepareInitialPreview(
          sessionId: state.sessionId!,
        ),
      );
      unawaited(onRecordingFinalized(state.finalizedRecordingPath!));
    } else if (state.phase == WorkflowPhase.idle &&
        _attachedRecordingSessionId != null) {
      _attachedRecordingSessionId = null;
      postProcessingController.detachRecording();
    }

    onUpdateNativeBarState();
  }

  void bind() {
    if (_isBound) return;
    _isBound = true;

    HardwareKeyboard.instance.addHandler(_handleKeyDebug);

    nativeBridge.setOnIndicatorPauseTapped(() {
      unawaited(recordingController.pauseRecording());
    });
    nativeBridge.setOnIndicatorStopTapped(() {
      onToggleRecording();
    });
    nativeBridge.setOnIndicatorResumeTapped(() {
      unawaited(recordingController.resumeRecording());
    });
    nativeBridge.setOnMenuBarToggleRequest(() {
      onToggleRecording();
    });
    nativeBridge.setOnExportProgress(onExportProgress);
    nativeBridge.setOnPreRecordingBarAction(onHandleNativeBarAction);
    nativeBridge.setOnNativeSelectionChanged(onHandleNativeSelectionChanged);

    recordingController.addListener(_handleWorkflowChanged);
    deviceController.addListener(onUpdateNativeBarState);
    overlayController.addListener(onUpdateNativeBarState);
    countdownController.addListener(onUpdateNativeBarState);
    settingsController.addListener(onUpdateNativeBarState);
    nativeBridge.isUpdateAvailable.addListener(onUpdateNativeBarState);

    _handleWorkflowChanged();
  }

  void unbind() {
    if (!_isBound) return;
    _isBound = false;

    HardwareKeyboard.instance.removeHandler(_handleKeyDebug);

    recordingController.removeListener(_handleWorkflowChanged);
    deviceController.removeListener(onUpdateNativeBarState);
    overlayController.removeListener(onUpdateNativeBarState);
    countdownController.removeListener(onUpdateNativeBarState);
    settingsController.removeListener(onUpdateNativeBarState);
    nativeBridge.isUpdateAvailable.removeListener(onUpdateNativeBarState);

    nativeBridge.setOnIndicatorPauseTapped(null);
    nativeBridge.setOnIndicatorStopTapped(null);
    nativeBridge.setOnIndicatorResumeTapped(null);
    nativeBridge.setOnMenuBarToggleRequest(null);
    nativeBridge.setOnExportProgress(null);
    nativeBridge.setOnPreRecordingBarAction(null);
    nativeBridge.setOnNativeSelectionChanged(null);
  }
}
