import 'dart:async';

import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_desktop_pane_dimensions.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/countdown_overlay.dart';
import 'package:clingfy/app/home/widgets/export_progress_dock.dart';
import 'package:clingfy/app/home/widgets/home_left_sidebar.dart';
import 'package:clingfy/app/home/widgets/home_options_panel.dart';
import 'package:clingfy/app/home/widgets/home_right_panel.dart';
import 'package:clingfy/app/home/widgets/home_toolbar.dart';
import 'package:clingfy/app/home/widgets/reset_preferences_action.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

const DesktopPaneSpec _homeRailPaneSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeLeftSidebar,
  defaultWidth: HomeDesktopPaneDimensions.railWidth,
  minWidth: HomeDesktopPaneDimensions.compactRailWidth,
  maxWidth: HomeDesktopPaneDimensions.railWidth,
  collapsedWidth: HomeDesktopPaneDimensions.compactRailWidth,
  collapsible: true,
  autoCollapsePriority: 0,
);

const DesktopPaneSpec _homeWorkspaceColumnSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeWorkspaceColumn,
  defaultWidth: HomeDesktopPaneDimensions.innerExpandedMinWidth,
  minWidth: HomeDesktopPaneDimensions.innerCollapsedMinWidth,
  autoCollapseAllowed: false,
  flex: true,
);

const DesktopPaneSpec _recordingInspectorPaneSpec = DesktopPaneSpec(
  id: DesktopPaneId.recordingSidebar,
  defaultWidth: HomeDesktopPaneDimensions.inspectorDefault,
  minWidth: HomeDesktopPaneDimensions.inspectorMin,
  maxWidth: HomeDesktopPaneDimensions.inspectorMax,
  collapsedWidth: HomeDesktopPaneDimensions.inspectorCollapsed,
  resizable: true,
  collapsible: true,
  autoCollapsePriority: 1,
);

const DesktopPaneSpec _postProcessingInspectorPaneSpec = DesktopPaneSpec(
  id: DesktopPaneId.postProcessingSidebar,
  defaultWidth: HomeDesktopPaneDimensions.inspectorDefault,
  minWidth: HomeDesktopPaneDimensions.inspectorMin,
  maxWidth: HomeDesktopPaneDimensions.inspectorMax,
  collapsedWidth: HomeDesktopPaneDimensions.inspectorCollapsed,
  resizable: true,
  collapsible: true,
  autoCollapsePriority: 1,
);

const DesktopPaneSpec _homeRightWorkspacePaneSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeRightWorkspace,
  defaultWidth: HomeDesktopPaneDimensions.workspaceMinWidth,
  minWidth: HomeDesktopPaneDimensions.workspaceMinWidth,
  autoCollapseAllowed: false,
  flex: true,
);

class HomeShell extends StatefulWidget {
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
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final DesktopPaneController _paneController;

  @override
  void initState() {
    super.initState();
    _paneController = DesktopPaneController(
      initialLayout: widget.uiState.paneLayout,
    );
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_paneController.layout != widget.uiState.paneLayout) {
      _paneController.applyPersistedLayout(widget.uiState.paneLayout);
    }
  }

  void _persistPaneLayout() {
    unawaited(widget.actions.persistPaneLayout(_paneController.layout));
  }

  void _togglePane(DesktopPaneSpec spec) {
    _paneController.togglePaneCollapsed(spec);
    _persistPaneLayout();
  }

  void _setPaneCollapsed(DesktopPaneSpec spec, bool collapsed) {
    _paneController.setPaneCollapsed(spec, collapsed);
    _persistPaneLayout();
  }

  void _showPane(DesktopPaneSpec spec) => _setPaneCollapsed(spec, false);

  void _selectRecordingSection(int index) {
    widget.uiState.setRecordingSidebarIndex(index);
    if (_paneController.stateFor(_recordingInspectorPaneSpec.id).isCollapsed) {
      _showPane(_recordingInspectorPaneSpec);
    }
  }

  void _selectPostProcessingSection(int index) {
    widget.uiState.setPostProcessingSidebarIndex(index);
    if (_paneController
        .stateFor(_postProcessingInspectorPaneSpec.id)
        .isCollapsed) {
      _showPane(_postProcessingInspectorPaneSpec);
    }
  }

  bool _isInspectorHiddenForLayout({
    required BoxConstraints constraints,
    required DesktopPaneSpec spec,
  }) {
    if (_paneController.stateFor(spec.id).isCollapsed) {
      return true;
    }
    return constraints.maxWidth <
        HomeDesktopPaneDimensions.inspectorAutoHideThreshold;
  }

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
    final showPreviewShell = context.select<RecordingController, bool>(
      (r) => r.showPreviewShell,
    );

    final activeInspectorSpec = showPreviewShell
        ? _postProcessingInspectorPaneSpec
        : _recordingInspectorPaneSpec;

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
                    child: AnimatedBuilder(
                      animation: _paneController,
                      builder: (context, _) => LayoutBuilder(
                        builder: (context, constraints) {
                          final forceCompactRail =
                              constraints.maxWidth <
                              HomeDesktopPaneDimensions.autoCompactThreshold;
                          final inspectorHiddenForLayout =
                              _isInspectorHiddenForLayout(
                                constraints: constraints,
                                spec: activeInspectorSpec,
                              );
                          final inspectorGap = inspectorHiddenForLayout
                              ? 0.0
                              : HomeDesktopPaneDimensions.innerGap;
                          final needsVerticalScroll =
                              constraints.maxHeight <
                              HomeDesktopPaneDimensions.shellMinHeight;

                          Widget shell = SizedBox(
                            height: needsVerticalScroll
                                ? HomeDesktopPaneDimensions.shellMinHeight
                                : constraints.maxHeight,
                            child: DesktopSplitLayout(
                              key: const Key('home_shell_outer_pane_layout'),
                              controller: _paneController,
                              gap: HomeDesktopPaneDimensions.outerGap,
                              minHeight:
                                  HomeDesktopPaneDimensions.shellMinHeight,
                              forcedCollapsedPaneIds: forceCompactRail
                                  ? const <DesktopPaneId>{
                                      DesktopPaneId.homeLeftSidebar,
                                    }
                                  : const <DesktopPaneId>{},
                              onLayoutCommitted: (_) => _persistPaneLayout(),
                              panes: [
                                DesktopPaneSlot(
                                  spec: _homeRailPaneSpec,
                                  builder: (context, panePresentation) {
                                    return HomeLeftSidebar(
                                      uiState: widget.uiState,
                                      panePresentation: panePresentation,
                                      onRecordingSectionSelected:
                                          _selectRecordingSection,
                                      onPostProcessingSectionSelected:
                                          _selectPostProcessingSection,
                                      onOpenSettings: () {
                                        unawaited(
                                          widget.actions.openSettings(context),
                                        );
                                      },
                                      onOpenHelp: () {
                                        unawaited(
                                          widget.actions.openAbout(context),
                                        );
                                      },
                                      onResetPreferences: () {
                                        unawaited(
                                          confirmResetPreferences(context),
                                        );
                                      },
                                      onToggleRailMode: () =>
                                          _togglePane(_homeRailPaneSpec),
                                    );
                                  },
                                ),
                                DesktopPaneSlot(
                                  spec: _homeWorkspaceColumnSpec,
                                  builder: (context, _) {
                                    return Column(
                                      key: const Key('home_workspace_column'),
                                      children: [
                                        HomeToolbar(
                                          title: widget.title,
                                          isRecording: isRecording,
                                          isPaused: isPaused,
                                          uiState: widget.uiState,
                                          onExport: () {
                                            unawaited(
                                              widget.actions.exportFromUi(
                                                context,
                                              ),
                                            );
                                          },
                                          onOpenSystemSettings:
                                              widget.actions.openSystemSettings,
                                          onClearMessage:
                                              widget.actions.clearToolbarErrors,
                                          isInspectorVisible:
                                              !inspectorHiddenForLayout,
                                          onToggleInspector: () =>
                                              _setPaneCollapsed(
                                                activeInspectorSpec,
                                                !inspectorHiddenForLayout,
                                              ),
                                        ),
                                        const SizedBox(
                                          height: HomeDesktopPaneDimensions
                                              .innerGap,
                                        ),
                                        Expanded(
                                          child: Stack(
                                            children: [
                                              DesktopSplitLayout(
                                                key: Key(
                                                  'home_shell_inner_pane_layout_${activeInspectorSpec.id.name}',
                                                ),
                                                controller: _paneController,
                                                gap: inspectorGap,
                                                minHeight:
                                                    HomeDesktopPaneDimensions
                                                        .workspaceMinHeight,
                                                onLayoutCommitted: (_) =>
                                                    _persistPaneLayout(),
                                                panes: [
                                                  DesktopPaneSlot(
                                                    spec: activeInspectorSpec,
                                                    builder: (context, panePresentation) {
                                                      return HomeOptionsPanel(
                                                        isRecording:
                                                            isRecording,
                                                        showPreviewShell:
                                                            showPreviewShell,
                                                        uiState: widget.uiState,
                                                        actions: widget.actions,
                                                        settingsController: widget
                                                            .settingsController,
                                                        panePresentation:
                                                            panePresentation,
                                                      );
                                                    },
                                                  ),
                                                  DesktopPaneSlot(
                                                    spec:
                                                        _homeRightWorkspacePaneSpec,
                                                    builder: (context, _) {
                                                      return ConstrainedBox(
                                                        constraints: const BoxConstraints(
                                                          minWidth:
                                                              HomeDesktopPaneDimensions
                                                                  .workspaceMinWidth,
                                                          minHeight:
                                                              HomeDesktopPaneDimensions
                                                                  .workspaceMinHeight,
                                                        ),
                                                        child: HomeRightPanel(
                                                          isRecording:
                                                              isRecording,
                                                          isPaused: isPaused,
                                                          isBusy: isBusy,
                                                          canPause: canPause,
                                                          canResume: canResume,
                                                          onToggleRecording:
                                                              () async {
                                                                unawaited(
                                                                  widget.actions
                                                                      .toggleRecording(
                                                                        context,
                                                                      ),
                                                                );
                                                              },
                                                          onPauseRecording: () {
                                                            unawaited(
                                                              widget
                                                                  .actions
                                                                  .recordingController
                                                                  .pauseRecording(),
                                                            );
                                                          },
                                                          onResumeRecording: () {
                                                            unawaited(
                                                              widget
                                                                  .actions
                                                                  .recordingController
                                                                  .resumeRecording(),
                                                            );
                                                          },
                                                          onClosePreview: () {
                                                            unawaited(
                                                              widget.actions
                                                                  .closePreview(
                                                                    context,
                                                                  ),
                                                            );
                                                          },
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ),
                                              if (inspectorHiddenForLayout)
                                                Positioned.fill(
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: _InspectorRevealHandle(
                                                      onPressed: () =>
                                                          _showPane(
                                                            activeInspectorSpec,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        if (showTimelineBar) ...[
                                          const SizedBox(
                                            height: HomeDesktopPaneDimensions
                                                .innerGap,
                                          ),
                                          TimelineBar(
                                            onClose: () {
                                              unawaited(
                                                widget.actions.closePreview(
                                                  context,
                                                ),
                                              );
                                            },
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          );

                          if (needsVerticalScroll) {
                            shell = SingleChildScrollView(
                              key: const Key('home_shell_vertical_scroll_view'),
                              child: shell,
                            );
                          }

                          return shell;
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const ExportProgressDock(),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: CountdownOverlay(
          controller: widget.countdownController,
        ),
      ),
    );
  }
}

class _InspectorRevealHandle extends StatelessWidget {
  const _InspectorRevealHandle({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: l10n.showOptions,
        child: Semantics(
          button: true,
          label: l10n.showOptions,
          child: GestureDetector(
            key: const Key('home_options_panel_reveal_handle'),
            onTap: onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(chrome.controlRadius + 4),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.14),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 18),
                child: Icon(Icons.tune_rounded, size: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
