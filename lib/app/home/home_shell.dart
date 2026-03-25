import 'dart:async';

import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/countdown_overlay.dart';
import 'package:clingfy/app/home/widgets/export_progress_dock.dart';
import 'package:clingfy/app/home/widgets/home_left_sidebar.dart';
import 'package:clingfy/app/home/widgets/home_right_panel.dart';
import 'package:clingfy/app/home/widgets/home_toolbar.dart';
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
    final backgroundGradient = context.appTokens.shellGradient;
    final spacing = context.appSpacing;
    final chrome = context.appEditorChrome;
    final tokens = theme.appTokens;
    final isRecording = context.select<RecordingController, bool>(
      (r) => r.isRecording,
    );
    final isBusy = context.select<RecordingController, bool>(
      (r) => r.isBusyTransitioning,
    );
    final showTimelineBar = context.select<RecordingController, bool>(
      (r) => r.showTimelineBar,
    );

    return DecoratedBox(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.all(spacing.page),
                child: Container(
                  key: const Key('editor_shell_frame'),
                  decoration: BoxDecoration(
                    color: tokens.panelBackground.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(chrome.shellRadius),
                    border: Border.all(color: tokens.panelBorder),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(spacing.lg),
                    child: Column(
                      children: [
                        HomeToolbar(
                          title: title,
                          isRecording: isRecording,
                          uiState: uiState,
                          onExport: () {
                            unawaited(actions.exportFromUi(context));
                          },
                          onOpenSettings: () {
                            unawaited(actions.openSettings(context));
                          },
                          onOpenSystemSettings: actions.openSystemSettings,
                          onClearMessage: actions.clearToolbarErrors,
                        ),
                        SizedBox(height: spacing.lg),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              HomeLeftSidebar(
                                isRecording: isRecording,
                                uiState: uiState,
                                actions: actions,
                                settingsController: settingsController,
                              ),
                              SizedBox(width: spacing.md),
                              HomeRightPanel(
                                isRecording: isRecording,
                                isBusy: isBusy,
                                onToggleRecording: () async {
                                  unawaited(actions.toggleRecording(context));
                                },
                                onClosePreview: () {
                                  unawaited(actions.closePreview(context));
                                },
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: spacing.md),
                        if (showTimelineBar)
                          TimelineBar(
                            onClose: () {
                              unawaited(actions.closePreview(context));
                            },
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
