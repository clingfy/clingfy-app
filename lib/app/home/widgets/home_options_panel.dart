import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/post_processing_sidebar_container.dart';
import 'package:clingfy/app/home/widgets/recording_sidebar_container.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_pane_header.dart';
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
    final l10n = AppLocalizations.of(context)!;
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final title = _resolvedTitle(l10n);
    final headerKey = _resolvedHeaderKey();
    final body = showPreviewShell
        ? PostProcessingSidebarContainer(
            settingsController: settingsController,
            isRecording: isRecording,
            selectedIndex: uiState.postProcessingSidebarIndex,
            availableWidth: panePresentation.effectiveWidth,
            isCompact: panePresentation.isCompact,
            showHeader: false,
          )
        : RecordingSidebarContainer(
            isRecording: isRecording,
            uiState: uiState,
            actions: actions,
            settingsController: settingsController,
            selectedIndex: uiState.recordingSidebarIndex,
            availableWidth: panePresentation.effectiveWidth,
            isCompact: panePresentation.isCompact,
            showHeader: false,
          );

    return Container(
      key: const Key('home_options_panel_shell'),
      decoration: BoxDecoration(
        color: tokens.previewPanelBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: panePresentation.effectiveCollapsed
          ? _CollapsedOptionsPane(
              title: title,
              expandTooltip: l10n.expandPane,
              onExpand: onToggleCollapsed,
            )
          : Column(
              children: [
                AppPaneHeader(
                  headerKey: headerKey,
                  title: title,
                  trailingKey: const Key('home_options_panel_collapse_button'),
                  trailingTooltip: l10n.collapsePane,
                  trailingIcon: Icons.chevron_right_rounded,
                  onTrailingPressed: onToggleCollapsed,
                  isCompact: panePresentation.isCompact,
                ),
                Expanded(child: body),
              ],
            ),
    );
  }

  String _resolvedTitle(AppLocalizations l10n) {
    if (showPreviewShell) {
      return switch (uiState.postProcessingSidebarIndex) {
        0 => l10n.layoutSettings,
        1 => l10n.effectsSettings,
        _ => l10n.exportSettings,
      };
    }

    return switch (uiState.recordingSidebarIndex) {
      0 => l10n.tabScreenAudio,
      1 => l10n.tabFaceCam,
      _ => l10n.output,
    };
  }

  Key _resolvedHeaderKey() {
    return showPreviewShell
        ? const Key('post_sidebar_header')
        : const Key('recording_sidebar_header');
  }
}

class _CollapsedOptionsPane extends StatelessWidget {
  const _CollapsedOptionsPane({
    required this.title,
    required this.expandTooltip,
    required this.onExpand,
  });

  final String title;
  final String expandTooltip;
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
          tooltip: '$expandTooltip: $title',
          splashRadius: 16,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
      ),
    );
  }
}
