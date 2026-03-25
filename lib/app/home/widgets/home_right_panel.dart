import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/hero_panel.dart';
import 'package:clingfy/app/home/preview/widgets/inline_preview_panel.dart';
import 'package:clingfy/app/home/preview/widgets/preview_overlay_controls.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeRightPanel extends StatelessWidget {
  const HomeRightPanel({
    super.key,
    required this.isRecording,
    required this.isBusy,
    required this.onToggleRecording,
    required this.onClosePreview,
    this.previewHostBuilder,
  });

  final bool isRecording;
  final bool isBusy;
  final VoidCallback onToggleRecording;
  final VoidCallback onClosePreview;
  final InlinePreviewHostBuilder? previewHostBuilder;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final previewUiState = context
        .select<
          RecordingController,
          ({
            bool showPreviewShell,
            bool showPreviewControls,
            bool showPreviewLoadingOverlay,
            bool showPreviewSurface,
            String? previewPath,
            String? sessionId,
          })
        >(
          (r) => (
            showPreviewShell: r.showPreviewShell,
            showPreviewControls: r.showPreviewControls,
            showPreviewLoadingOverlay: r.showPreviewLoadingOverlay,
            showPreviewSurface: r.showPreviewSurface,
            previewPath: r.previewPath,
            sessionId: r.sessionId,
          ),
        );
    final postHasError = context.select<PostProcessingController, bool>(
      (p) => p.hasError,
    );
    final recordingController = context.read<RecordingController>();
    final isPlaying = context.select<PlayerController, bool>(
      (p) => p.isPlaying,
    );

    return Expanded(
      child: Container(
        key: const Key('home_right_panel_shell'),
        decoration: BoxDecoration(
          color: tokens.panelBackground,
          borderRadius: BorderRadius.circular(chrome.panelRadius),
          border: Border.all(color: tokens.panelBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.all(chrome.stagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: previewUiState.showPreviewShell
                    ? Builder(
                        builder: (context) {
                          final player = context.read<PlayerController>();
                          return PreviewWithOverlayControls(
                            preview: KeyedSubtree(
                              key: ValueKey(
                                'preview-shell-${previewUiState.sessionId ?? 'none'}',
                              ),
                              child: InlinePreviewPanel(
                                path: previewUiState.previewPath ?? '',
                                onToggleRecord: onToggleRecording,
                                onClose: onClosePreview,
                                onPreviewHostMounted: recordingController
                                    .handlePreviewHostMounted,
                                showLoadingOverlay:
                                    previewUiState.showPreviewLoadingOverlay,
                                showSurface: previewUiState.showPreviewSurface,
                                previewHostBuilder: previewHostBuilder,
                              ),
                            ),
                            isPlaying: isPlaying,
                            controlsEnabled:
                                previewUiState.showPreviewControls &&
                                !postHasError,
                            onPlayPause: (playing) {
                              if (playing) {
                                player.play();
                              } else {
                                player.pause();
                              }
                            },
                          );
                        },
                      )
                    : HeroPanel(
                        isRecording: isRecording,
                        isBusy: isBusy,
                        onToggle: onToggleRecording,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
