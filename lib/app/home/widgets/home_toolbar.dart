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
  });

  final bool isRecording;
  final bool isPaused;
  final HomeUiState uiState;
  final VoidCallback onExport;
  final Future<void> Function(String pane) onOpenSystemSettings;
  final VoidCallback onClearMessage;
  final bool isInspectorVisible;
  final VoidCallback? onToggleInspector;

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
          (String? elapsed, String? countdown, String? recError)
        >(
          selector: (_, r) => (
            r.isRecording ? r.formattedElapsed : null,
            r.countdownText,
            r.errorMessage,
          ),
          builder: (context, d, _) {
            final notice = uiState.notice;
            final rawError =
                notice?.rawErrorCode ?? d.$3 ?? deviceError ?? overlayError;
            final mapped = HomeErrorMapper.map(
              context,
              rawError,
              openSystemSettings: (pane) {
                unawaited(onOpenSystemSettings(pane));
              },
            );
            final explicitNotice = notice?.message != null
                ? ToolbarNoticePresentation(
                    message: notice!.message!,
                    tone: switch (notice.tone) {
                      HomeUiNoticeTone.info => ToolbarMessageTone.info,
                      HomeUiNoticeTone.success => ToolbarMessageTone.success,
                      HomeUiNoticeTone.warning => ToolbarMessageTone.warning,
                      HomeUiNoticeTone.error => ToolbarMessageTone.error,
                    },
                    action: notice.action == null
                        ? null
                        : ToolbarMessageAction(
                            label: notice.action!.label,
                            semanticLabel: notice.action!.semanticLabel,
                            onPressed: notice.action!.onPressed,
                          ),
                    onDismiss: uiState.clearNotice,
                  )
                : null;
            final mappedNotice =
                explicitNotice == null && mapped.message != null
                ? ToolbarNoticePresentation(
                    message: mapped.message!,
                    tone: ToolbarMessageTone.error,
                    action: mapped.action,
                    onDismiss: onClearMessage,
                  )
                : null;
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
              notice: explicitNotice ?? mappedNotice,
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
            );
          },
        );
      },
    );
  }
}
