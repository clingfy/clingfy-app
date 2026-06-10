import 'dart:async';

import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_error_mapper.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

/// Decides which toolbar notice presentation wins (Phase 10.2). Pure —
/// extracted from the build method so the precedence is unit-testable
/// without the widget tree:
///
/// 1. A notice carrying BOTH a message and a code is a coded warning
///    (Windows recordingWarning). When the mapper RECOGNIZED the code
///    (its message differs from the raw-code passthrough), render the
///    localized mapped message + the mapper's settings action, keeping
///    the notice's (warning) tone.
/// 2. An unrecognized code — or a plain message notice (macOS warnings,
///    success toasts) — renders the verbatim message with the notice's
///    own tone/action.
/// 3. No message notice: a mapped raw error (recording/device/overlay)
///    renders as an error-tone presentation dismissed via
///    [onClearMessage].
@visibleForTesting
ToolbarNoticePresentation? resolveToolbarNotice({
  required HomeUiNotice? notice,
  required HomeErrorPresentation mapped,
  required VoidCallback onDismissNotice,
  required VoidCallback onClearMessage,
}) {
  ToolbarMessageTone toneOf(HomeUiNoticeTone tone) => switch (tone) {
    HomeUiNoticeTone.info => ToolbarMessageTone.info,
    HomeUiNoticeTone.success => ToolbarMessageTone.success,
    HomeUiNoticeTone.warning => ToolbarMessageTone.warning,
    HomeUiNoticeTone.error => ToolbarMessageTone.error,
  };

  if (notice != null &&
      notice.message != null &&
      notice.rawErrorCode != null &&
      mapped.message != null &&
      mapped.message != notice.rawErrorCode) {
    return ToolbarNoticePresentation(
      message: mapped.message!,
      tone: toneOf(notice.tone),
      action: mapped.action,
      onDismiss: onDismissNotice,
    );
  }
  if (notice?.message != null) {
    return ToolbarNoticePresentation(
      message: notice!.message!,
      tone: toneOf(notice.tone),
      action: notice.action == null
          ? null
          : ToolbarMessageAction(
              label: notice.action!.label,
              semanticLabel: notice.action!.semanticLabel,
              onPressed: notice.action!.onPressed,
            ),
      onDismiss: onDismissNotice,
    );
  }
  if (mapped.message != null) {
    return ToolbarNoticePresentation(
      message: mapped.message!,
      tone: ToolbarMessageTone.error,
      action: mapped.action,
      onDismiss: onClearMessage,
    );
  }
  return null;
}

class HomeToolbar extends StatelessWidget {
  const HomeToolbar({
    super.key,
    required this.isRecording,
    required this.isPaused,
    required this.uiState,
    required this.onExport,
    required this.onOpenSystemSettings,
    required this.onClearMessage,
    this.isInspectorVisible = true,
    this.onToggleInspector,
    this.showPreviewActions = false,
    this.onNewRecording,
  });

  final bool isRecording;
  final bool isPaused;
  final HomeUiState uiState;
  final VoidCallback onExport;
  final Future<void> Function(String pane) onOpenSystemSettings;
  final VoidCallback onClearMessage;
  final bool isInspectorVisible;
  final VoidCallback? onToggleInspector;
  final bool showPreviewActions;
  final VoidCallback? onNewRecording;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: uiState,
      builder: (context, _) {
        final deviceError = context.select<DeviceController, String?>(
          (d) => d.errorMessage,
        );
        final overlayError = context.select<OverlayController, String?>(
          (o) => o.errorMessage,
        );
        final postHasError = context.select<PostProcessingController, bool>(
          (p) => p.hasError,
        );
        final postEditingLocked = context
            .select<PostProcessingController, bool>((p) => p.isEditingLocked);
        final previewReady = context.select<RecordingController, bool>(
          (r) => r.canInteractWithPreview,
        );
        final exportToolbarState = context
            .select<
              PostProcessingController,
              ({
                bool exporting,
                bool inBackground,
                bool cancelRequested,
                double? progress,
              })
            >(
              (p) => (
                exporting: p.isExporting,
                inBackground: p.isExportInBackground,
                cancelRequested: p.isExportCancelRequested,
                progress: p.exportProgress,
              ),
            );

        return Selector<
          RecordingController,
          (
            String? elapsed,
            String? countdown,
            String? recError,
            String? recErrorFallback,
          )
        >(
          selector: (_, r) => (
            r.isRecording ? r.formattedElapsed : null,
            r.countdownText,
            r.displayError,
            r.displayErrorFallback,
          ),
          builder: (context, d, _) {
            final notice = uiState.notice;
            final rawError =
                notice?.rawErrorCode ?? d.$3 ?? deviceError ?? overlayError;
            // The prose fallback belongs ONLY to the recording error it
            // came with — when rawError is a warning-notice code or a
            // device/overlay code, passing it would break the mapper's
            // raw-echo default (which resolveToolbarNotice uses as its
            // "code recognized?" sentinel) and show unrelated prose.
            final recordingErrorShown =
                notice?.rawErrorCode == null && d.$3 != null;
            final mapped = HomeErrorMapper.map(
              context,
              rawError,
              verbatimFallback: recordingErrorShown ? d.$4 : null,
              openSystemSettings: (pane) {
                unawaited(onOpenSystemSettings(pane));
              },
            );
            final resolvedNotice = resolveToolbarNotice(
              notice: notice,
              mapped: mapped,
              onDismissNotice: uiState.clearNotice,
              onClearMessage: onClearMessage,
            );
            final exportStatus =
                exportToolbarState.exporting && exportToolbarState.inBackground
                ? ToolbarExportStatusPresentation(
                    progress: exportToolbarState.progress,
                    cancelRequested: exportToolbarState.cancelRequested,
                    onShowDetails: () {
                      unawaited(
                        ClingfyTelemetry.addUiBreadcrumb(
                          category: 'ui.export',
                          message: 'export_progress_modal_restored',
                        ),
                      );
                      context
                          .read<PostProcessingController>()
                          .showExportProgressModal();
                    },
                    // onCancel: exportToolbarState.cancelRequested
                    //     ? null
                    //     : () {
                    //         context
                    //             .read<PostProcessingController>()
                    //             .cancelExport();
                    //       },
                  )
                : null;

            return DesktopToolbar(
              isRecording: isRecording,
              isPaused: isPaused,
              elapsedText: d.$1,
              countdownText: d.$2,
              notice: resolvedNotice,
              onExport:
                  (previewReady &&
                      !isRecording &&
                      !postEditingLocked &&
                      !postHasError)
                  ? onExport
                  : null,
              exportStatus: exportStatus,
              isProcessing: postEditingLocked,
              isInspectorVisible: isInspectorVisible,
              onToggleInspector: onToggleInspector,
              showPreviewActions: showPreviewActions,
              onNewRecording: onNewRecording,
            );
          },
        );
      },
    );
  }
}
