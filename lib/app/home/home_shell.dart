import 'dart:async';

import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/countdown_overlay.dart';
import 'package:clingfy/app/home/widgets/export_progress_dock.dart';
import 'package:clingfy/app/home/widgets/home_left_sidebar.dart';
import 'package:clingfy/app/home/widgets/home_options_panel.dart';
import 'package:clingfy/app/home/widgets/home_right_panel.dart';
import 'package:clingfy/app/home/widgets/home_toolbar.dart';
import 'package:clingfy/app/home/widgets/reset_preferences_action.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeShell extends StatelessWidget {
  const HomeShell({
    super.key,
    required this.title,
    required this.actions,
    required this.uiState,
    required this.settingsController,
    required this.countdownController,
  });

  final String title;
  final HomeActions actions;
  final HomeUiState uiState;
  final SettingsController settingsController;
  final CountdownController countdownController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = context.appEditorChrome;
    final tokens = theme.appTokens;
    final isRecording = context.select<RecordingController, bool>(
      (r) => r.isRecording,
    );
    final isPaused = context.select<RecordingController, bool>(
      (r) => r.isPaused,
    );
    final isBusy = context.select<RecordingController, bool>(
      (r) => r.isBusyTransitioning,
    );
    final canPause = context.select<RecordingController, bool>(
      (r) => r.canPause,
    );
    final canResume = context.select<RecordingController, bool>(
      (r) => r.canResume,
    );
    final showTimelineBar = context.select<RecordingController, bool>(
      (r) => r.showTimelineBar,
    );

    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.outerBackground),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(kEditorShellOuterPadding),
                child: Container(
                  key: const Key('editor_shell_frame'),
                  decoration: BoxDecoration(
                    color: tokens.outerBackground,
                    borderRadius: BorderRadius.circular(chrome.shellRadius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(kEditorShellInnerPadding),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        HomeLeftSidebar(
                          uiState: uiState,
                          onOpenSettings: () {
                            unawaited(actions.openSettings(context));
                          },
                          onOpenHelp: () {
                            unawaited(actions.openAbout(context));
                          },
                          onResetPreferences: () {
                            unawaited(confirmResetPreferences(context));
                          },
                        ),
                        const SizedBox(width: kEditorShellGap),
                        Expanded(
                          child: Column(
                            key: const Key('home_workspace_column'),
                            children: [
                              HomeToolbar(
                                title: title,
                                isRecording: isRecording,
                                isPaused: isPaused,
                                uiState: uiState,
                                onExport: () {
                                  unawaited(actions.exportFromUi(context));
                                },
                                onOpenSystemSettings:
                                    actions.openSystemSettings,
                                onClearMessage: actions.clearToolbarErrors,
                              ),
                              const SizedBox(height: kEditorShellGap),
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    HomeOptionsPanel(
                                      isRecording: isRecording,
                                      uiState: uiState,
                                      actions: actions,
                                      settingsController: settingsController,
                                    ),
                                    const SizedBox(width: kEditorShellGap),
                                    HomeRightPanel(
                                      isRecording: isRecording,
                                      isPaused: isPaused,
                                      isBusy: isBusy,
                                      canPause: canPause,
                                      canResume: canResume,
                                      onToggleRecording: () async {
                                        unawaited(
                                          actions.toggleRecording(context),
                                        );
                                      },
                                      onPauseRecording: () {
                                        unawaited(
                                          actions.recordingController
                                              .pauseRecording(),
                                        );
                                      },
                                      onResumeRecording: () {
                                        unawaited(
                                          actions.recordingController
                                              .resumeRecording(),
                                        );
                                      },
                                      onClosePreview: () {
                                        unawaited(
                                          actions.closePreview(context),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              if (showTimelineBar) ...[
                                const SizedBox(height: kEditorShellGap),
                                TimelineBar(
                                  onClose: () {
                                    unawaited(actions.closePreview(context));
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const ExportProgressDock(),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: CountdownOverlay(controller: countdownController),
      ),
    );
  }
}
