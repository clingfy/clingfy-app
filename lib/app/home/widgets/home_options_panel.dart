import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/post_processing_sidebar_container.dart';
import 'package:clingfy/app/home/widgets/recording_sidebar_container.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeOptionsPanel extends StatelessWidget {
  const HomeOptionsPanel({
    super.key,
    required this.isRecording,
    required this.uiState,
    required this.actions,
    required this.settingsController,
  });

  final bool isRecording;
  final HomeUiState uiState;
  final HomeActions actions;
  final SettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final showPreviewShell = context.select<RecordingController, bool>(
      (r) => r.showPreviewShell,
    );
    final totalWidth = showPreviewShell
        ? kPostProcessingOptionsSidebarWidth
        : kRecordingOptionsSidebarWidth;
    final optionsWidth = totalWidth - chrome.editorRailWidth - kEditorShellGap;

    return SizedBox(
      width: optionsWidth,
      child: Container(
        key: const Key('home_options_panel_shell'),
        decoration: BoxDecoration(
          color: tokens.previewPanelBackground,
          borderRadius: BorderRadius.circular(chrome.panelRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: showPreviewShell
            ? PostProcessingSidebarContainer(
                settingsController: settingsController,
                isRecording: isRecording,
                selectedIndex: uiState.postProcessingSidebarIndex,
              )
            : RecordingSidebarContainer(
                isRecording: isRecording,
                uiState: uiState,
                actions: actions,
                settingsController: settingsController,
                selectedIndex: uiState.recordingSidebarIndex,
              ),
      ),
    );
  }
}
