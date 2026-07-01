import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/recording_warning_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter/widgets.dart';

class HomeErrorPresentation {
  const HomeErrorPresentation({required this.message, required this.action});

  final String? message;
  final ToolbarMessageAction? action;
}

class HomeErrorMapper {
  static HomeErrorPresentation map(
    BuildContext context,
    String? rawError, {
    required void Function(String pane) openSystemSettings,
    // Phase 10.3: native prose to render when [rawError] is an
    // unrecognized CODE (Windows feeds codes first so they localize; the
    // prose beats showing a raw token like "BAD_ARGS").
    String? verbatimFallback,
  }) {
    final l10n = AppLocalizations.of(context)!;

    String? message;
    ToolbarMessageAction? action;

    switch (rawError) {
      case null:
        message = null;
      case NativeErrorCode.alreadyRecording:
        message = l10n.errAlreadyRecording;
      case NativeErrorCode.noWindowSelected:
        message = l10n.errNoWindowSelected;
      case NativeErrorCode.windowNotAvailable:
        message = l10n.errWindowUnavailable;
      case NativeErrorCode.noAreaSelected:
        message = l10n.errNoAreaSelected;
      case NativeErrorCode.targetError:
        message = l10n.errTargetError;
      case NativeErrorCode.notRecording:
        message = l10n.errNotRecording;
      case NativeErrorCode.invalidRecordingState:
        message = l10n.errInvalidRecordingState;
      case NativeErrorCode.pauseResumeUnsupported:
        message = l10n.errPauseResumeUnsupported;
      case NativeErrorCode.unknownAudioDevice:
        message = l10n.errUnknownAudioDevice;
      case NativeErrorCode.badQuality:
        message = l10n.errBadQuality;
      case NativeErrorCode.screenRecordingPermission:
        message = l10n.errScreenRecordingPermission;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('screen'),
        );
      case NativeErrorCode.microphonePermissionRequired:
        // Windows variant points at "Windows Settings > Privacy & security"
        // — the macOS copy names System Settings panes that don't exist
        // there.
        message = isWindows()
            ? l10n.errMicrophonePermissionRequiredWindows
            : l10n.errMicrophonePermissionRequired;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('microphone'),
        );
      case NativeErrorCode.recordingError:
        message = l10n.errRecordingError('');
      case NativeErrorCode.outputUrlError:
        message = l10n.errOutputUrlError('');
      case NativeErrorCode.accessibilityPermissionRequired:
        message = l10n.errAccessibilityPermissionRequired;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('accessibility'),
        );
      case NativeErrorCode.exportError:
        message = l10n.errExportError('');
      case NativeErrorCode.cameraPermissionDenied:
        message = isWindows()
            ? l10n.errCameraPermissionDeniedWindows
            : l10n.errCameraPermissionDenied;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('camera'),
        );
      case NativeErrorCode.exportInputMissing:
        message = l10n.errExportInputMissing;
      case NativeErrorCode.advancedCameraExportFailed:
        message = l10n.errExportError(
          'Advanced camera styling could not be rendered for export.',
        );
      case NativeErrorCode.videoFileMissing:
        message = l10n.errVideoFileMissing;
      case NativeErrorCode.cursorFileMissing:
        message = l10n.errCursorFileMissing;
      case NativeErrorCode.assetInvalid:
        message = l10n.errAssetInvalid;

      // Phase 10.2 — recordingWarning codes (Windows-only emitters; see
      // RecordingWarningCode). Each maps to a localized toast and, where a
      // settings page can actually help, an Open Settings action. The
      // toolbar keeps the warning tone for these.
      case RecordingWarningCode.micOpenFailed:
        message = l10n.warnMicOpenFailed;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('microphone'),
        );
      case RecordingWarningCode.micDisconnected:
        message = l10n.warnMicDisconnected;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('sound'),
        );
      case RecordingWarningCode.systemAudioOpenFailed:
        message = l10n.warnSystemAudioOpenFailed;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('sound'),
        );
      case RecordingWarningCode.systemAudioStopped:
        message = l10n.warnSystemAudioStopped;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('sound'),
        );
      case RecordingWarningCode.cameraUnavailable:
        message = l10n.warnCameraUnavailable;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('camera'),
        );
      case RecordingWarningCode.cameraOpenFailed:
        message = l10n.warnCameraOpenFailed;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('camera'),
        );
      case RecordingWarningCode.cameraDisconnected:
        // Unplugged hardware — no settings page helps; message only.
        message = l10n.warnCameraDisconnected;
      case RecordingWarningCode.encoderVideoError:
        message = l10n.warnEncoderVideoError;
      case RecordingWarningCode.encoderAudioError:
        message = l10n.warnEncoderAudioError;
      case RecordingWarningCode.windowClosedPartialSaved:
        message = l10n.warnWindowClosedPartialSaved;
      case RecordingWarningCode.displayDisconnectedPartialSaved:
        message = l10n.warnDisplayDisconnectedPartialSaved;

      // Phase 10.3 — codes that previously fell through to the default
      // branch and rendered as raw tokens.
      case NativeErrorCode.badMode:
        message = l10n.errBadMode;
      case NativeErrorCode.noCamera:
        message = l10n.errNoCamera;
      case NativeErrorCode.cameraInputError:
        message = l10n.errCameraInputError;
      case NativeErrorCode.fileNotFound:
        message = l10n.errFileNotFound;
      case NativeErrorCode.windowsNotImplemented:
        message = l10n.errWindowsNotImplemented;
      case NativeErrorCode.exportDiskFull:
        message = l10n.errExportDiskFullFallback;
      case NativeErrorCode.previewInputMissing:
      case NativeErrorCode.sceneInputMissing:
        message = l10n.errExportInputMissing;

      // Phase 10.4 — crash/error mapping. Native codes first, then the
      // Dart-synthesized watchdog codes. EXPORT_CANCELLED deliberately has
      // NO case: a clean cancel is classified upstream
      // (PostProcessingController) and never reaches a toast.
      case NativeErrorCode.recordingDiskFull:
        message = l10n.errRecordingDiskFull;
        action = ToolbarMessageAction(
          label: l10n.openStorageSettings,
          onPressed: () => openSystemSettings('storage'),
        );
      case NativeErrorCode.previewOpenError:
        message = l10n.errPreviewOpenFailed;
      case NativeErrorCode.previewRenderError:
        message = l10n.errPreviewRenderFailed;
      case NativeErrorCode.internalError:
        message = l10n.errInternalError;
      case DartSynthesizedErrorCode.recordingStartTimeout:
        message = l10n.errRecordingStartTimeout;
      case DartSynthesizedErrorCode.recordingFinalizeTimeout:
        message = l10n.errRecordingFinalizeTimeout;
      case DartSynthesizedErrorCode.previewTimeout:
        message = l10n.errPreviewTimeout;
      default:
        message = verbatimFallback ?? rawError;
    }

    return HomeErrorPresentation(message: message, action: action);
  }
}
