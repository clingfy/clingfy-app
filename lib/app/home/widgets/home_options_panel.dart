import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/post_processing_sidebar_container.dart';
import 'package:clingfy/app/home/widgets/recording_sidebar_container.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/material.dart';

class HomeOptionsPanel extends StatelessWidget {
  const HomeOptionsPanel({
    super.key,
    required this.isRecording,
    required this.showPreviewShell,
    required this.uiState,
    required this.actions,
    required this.settingsController,
    required this.panePresentation,
    required this.onToggleCollapsed,
  });

  final bool isRecording;
  final bool showPreviewShell;
  final HomeUiState uiState;
  final HomeActions actions;
  final SettingsController settingsController;
  final DesktopPanePresentation panePresentation;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;

    return Container(
      key: const Key('home_options_panel_shell'),
      decoration: BoxDecoration(
        color: tokens.previewPanelBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: panePresentation.effectiveCollapsed
          ? _CollapsedOptionsPane(onExpand: onToggleCollapsed)
          : Stack(
              children: [
                Positioned.fill(
                  child: showPreviewShell
                      ? PostProcessingSidebarContainer(
                          settingsController: settingsController,
                          isRecording: isRecording,
                          selectedIndex: uiState.postProcessingSidebarIndex,
                          availableWidth: panePresentation.effectiveWidth,
                          isCompact: panePresentation.isCompact,
                        )
                      : RecordingSidebarContainer(
                          isRecording: isRecording,
                          uiState: uiState,
                          actions: actions,
                          settingsController: settingsController,
                          selectedIndex: uiState.recordingSidebarIndex,
                          availableWidth: panePresentation.effectiveWidth,
                          isCompact: panePresentation.isCompact,
                        ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    key: const Key('home_options_panel_collapse_button'),
                    onPressed: onToggleCollapsed,
                    tooltip: 'Collapse pane',
                    visualDensity: VisualDensity.compact,
                    splashRadius: 16,
                    iconSize: 18,
                    style: IconButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      backgroundColor: tokens.previewPanelBackground.withValues(
                        alpha: 0.92,
                      ),
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ),
              ],
            ),
    );
  }
}

class _CollapsedOptionsPane extends StatelessWidget {
  const _CollapsedOptionsPane({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;

    return ColoredBox(
      color: tokens.previewPanelBackground,
      child: Center(
        child: IconButton(
          key: const Key('home_options_panel_expand_button'),
          onPressed: onExpand,
          tooltip: 'Expand pane',
          splashRadius: 16,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
      ),
    );
  }
}
