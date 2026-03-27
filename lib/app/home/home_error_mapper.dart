import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
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
        message = l10n.errMicrophonePermissionRequired;
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
        message = l10n.errCameraPermissionDenied;
        action = ToolbarMessageAction(
          label: l10n.openSettings,
          onPressed: () => openSystemSettings('camera'),
        );
      case NativeErrorCode.exportInputMissing:
        message = l10n.errExportInputMissing;
      case NativeErrorCode.videoFileMissing:
        message = l10n.errVideoFileMissing;
      case NativeErrorCode.cursorFileMissing:
        message = l10n.errCursorFileMissing;
      case NativeErrorCode.assetInvalid:
        message = l10n.errAssetInvalid;
      default:
        message = rawError;
    }

    return HomeErrorPresentation(message: message, action: action);
  }
}
