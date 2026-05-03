import 'dart:async';

import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_desktop_pane_dimensions.dart';
import 'package:clingfy/app/home/guide/home_guide_anchors.dart';
import 'package:clingfy/app/home/guide/home_guide_controller.dart';
import 'package:clingfy/app/home/guide/home_guide_overlay.dart';
import 'package:clingfy/app/home/guide/home_guide_step.dart';
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
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

DesktopPaneSpec _railSpecFor(ShellResponsiveMetrics? metrics) {
  final defaultWidth =
      metrics?.railWidth ?? HomeDesktopPaneDimensions.railWidth;
  final minWidth = metrics?.leftRailExpandedMinWidth ?? defaultWidth;
  final maxWidth = metrics?.leftRailExpandedMaxWidth ?? defaultWidth;
  final compactWidth =
      metrics?.railCompactWidth ?? HomeDesktopPaneDimensions.compactRailWidth;
  // Clamp default into [min, max] so the spec invariant is satisfied even at
  // tiers where the metric defaults end up outside the clamp window.
  final clampedDefault = defaultWidth.clamp(minWidth, maxWidth).toDouble();
  return DesktopPaneSpec(
    id: DesktopPaneId.homeLeftSidebar,
    defaultWidth: clampedDefault,
    minWidth: minWidth,
    maxWidth: maxWidth,
    collapsedWidth: compactWidth,
    collapsible: true,
    autoCollapsePriority: 0,
  );
}

const DesktopPaneSpec _homeWorkspaceColumnSpec = DesktopPaneSpec(
  id: DesktopPaneId.homeWorkspaceColumn,
  defaultWidth: HomeDesktopPaneDimensions.innerExpandedMinWidth,
  minWidth: HomeDesktopPaneDimensions.innerCollapsedMinWidth,
  autoCollapseAllowed: false,
  flex: true,
);

DesktopPaneSpec _inspectorSpecForId(
  DesktopPaneId id,
  ShellResponsiveMetrics? metrics,
) {
  final defaultWidth =
      metrics?.optionsPanelDefaultWidth ??
      HomeDesktopPaneDimensions.inspectorDefault;
  final minWidth =
      metrics?.optionsPanelMinWidth ?? HomeDesktopPaneDimensions.inspectorMin;
  final maxWidth =
      metrics?.optionsPanelMaxWidth ?? HomeDesktopPaneDimensions.inspectorMax;
  return DesktopPaneSpec(
    id: id,
    defaultWidth: defaultWidth,
    minWidth: minWidth,
    maxWidth: maxWidth,
    collapsedWidth: HomeDesktopPaneDimensions.inspectorCollapsed,
    resizable: true,
    collapsible: true,
    snapCollapseAtMinWidthOnDragEnd: true,
    autoCollapsePriority: 1,
  );
}

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
    required this.actions,
    required this.uiState,
    required this.settingsController,
    required this.countdownController,
  });

  final HomeActions actions;
  final HomeUiState uiState;
  final SettingsController settingsController;
  final CountdownController countdownController;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final DesktopPaneController _paneController;
  late final HomeGuideController _guideController;
  late final HomeGuideAnchors _guideAnchors;

  DesktopPaneLayoutPrefs? _guideSavedPaneLayout;
  int? _guideSavedRecordingSidebarIndex;
  bool _lastObservedGuideVisible = false;
  HomeGuideStep _lastObservedGuideStep = HomeGuideStep.sidebar;
  int _guideSpotlightRefreshSequence = 0;
  ShellDensity? _lastDensity;
  ShellResponsiveMetrics? _currentMetrics;

  // Decoupled visibility model:
  //  - persisted pane collapsed state lives in _paneController
  //  - responsive inline availability lives in _lastCanShowInspectorInline
  //  - _compactForcedInlineInspectorId pins the active inspector pane inline
  //    in compact mode so that DesktopSplitLayout will not auto-collapse it,
  //    even when the resolver would normally squeeze it out. This is a
  //    transient (non-persisted) signal that follows user intent (toolbar
  //    toggle / sidebar tap / guide step).
  DesktopPaneId? _compactForcedInlineInspectorId;
  bool _lastCanShowInspectorInline = true;

  DesktopPaneSpec get _homeRailPaneSpec => _railSpecFor(_currentMetrics);

  DesktopPaneSpec get _recordingInspectorPaneSpec =>
      _inspectorSpecForId(DesktopPaneId.recordingSidebar, _currentMetrics);

  DesktopPaneSpec get _postProcessingInspectorPaneSpec =>
      _inspectorSpecForId(DesktopPaneId.postProcessingSidebar, _currentMetrics);

  @override
  void initState() {
    super.initState();
    _paneController = DesktopPaneController(
      initialLayout: widget.uiState.paneLayout,
    );
    _guideAnchors = HomeGuideAnchors();
    _guideController = HomeGuideController(
      prefsStore: widget.actions.prefsStore,
    )..addListener(_handleGuideStateChanged);
    _lastObservedGuideVisible = _guideController.isVisible;
    _lastObservedGuideStep = _guideController.currentStep;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      await _guideController.maybeStartAutomatically(canShow: _canStartGuide());
    });
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_paneController.layout != widget.uiState.paneLayout) {
      _paneController.applyPersistedLayout(widget.uiState.paneLayout);
    }
  }

  @override
  void dispose() {
    _guideController.removeListener(_handleGuideStateChanged);
    _guideController.dispose();
    super.dispose();
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

  void _toggleRecordingFromUi(BuildContext context) {
    unawaited(widget.actions.toggleRecording(context));
  }

  Future<void> _confirmClosePreview(BuildContext context) async {
    unawaited(widget.actions.closePreview(context));
  }

  bool _canStartGuide() {
    final recordingController = context.read<RecordingController>();
    return !recordingController.isRecording &&
        !recordingController.showPreviewShell &&
        !recordingController.isBusyTransitioning &&
        !widget.countdownController.isActive;
  }

  void _handleGuideStateChanged() {
    if (!mounted) {
      return;
    }

    final isVisible = _guideController.isVisible;
    final currentStep = _guideController.currentStep;
    final visibilityChanged = _lastObservedGuideVisible != isVisible;
    final stepChanged = _lastObservedGuideStep != currentStep;

    _lastObservedGuideVisible = isVisible;
    _lastObservedGuideStep = currentStep;

    if (!isVisible) {
      _guideSpotlightRefreshSequence += 1;
      _restoreGuideUiState();
      setState(() {});
      return;
    }

    if (!visibilityChanged && !stepChanged) {
      return;
    }

    _prepareGuideUiState();
    _applyGuideStepUiState(currentStep);
    setState(() {});
    _scheduleGuideSpotlightRefresh(currentStep);
  }

  void _prepareGuideUiState() {
    _guideSavedPaneLayout ??= _paneController.layout;
    _guideSavedRecordingSidebarIndex ??= widget.uiState.recordingSidebarIndex;
  }

  void _applyGuideStepUiState(HomeGuideStep step) {
    switch (step) {
      case HomeGuideStep.captureSource:
        widget.uiState.setRecordingSidebarIndex(0);
        _paneController.setPaneCollapsed(_recordingInspectorPaneSpec, false);
        _ensureOptionsVisibleForGuide();
        break;
      case HomeGuideStep.camera:
        widget.uiState.setRecordingSidebarIndex(1);
        _paneController.setPaneCollapsed(_recordingInspectorPaneSpec, false);
        _ensureOptionsVisibleForGuide();
        break;
      case HomeGuideStep.output:
        widget.uiState.setRecordingSidebarIndex(2);
        _paneController.setPaneCollapsed(_recordingInspectorPaneSpec, false);
        _ensureOptionsVisibleForGuide();
        break;
      case HomeGuideStep.sidebar:
      case HomeGuideStep.startRecording:
      case HomeGuideStep.help:
        break;
    }
  }

  void _ensureOptionsVisibleForGuide() {
    if (!_lastCanShowInspectorInline) {
      _compactForcedInlineInspectorId = _recordingInspectorPaneSpec.id;
    }
  }

  void _scheduleGuideSpotlightRefresh(HomeGuideStep step) {
    final requestSequence = ++_guideSpotlightRefreshSequence;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_isActiveGuideSpotlightRefresh(requestSequence, step)) {
        return;
      }

      if (step == HomeGuideStep.camera || step == HomeGuideStep.output) {
        final anchorContext = _guideAnchors.keyForStep(step).currentContext;
        if (anchorContext != null) {
          await Scrollable.ensureVisible(
            anchorContext,
            duration: Duration.zero,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isActiveGuideSpotlightRefresh(requestSequence, step)) {
            _guideController.requestSpotlightRefresh();
          }
        });
        return;
      }

      _guideController.requestSpotlightRefresh();
    });
  }

  bool _isActiveGuideSpotlightRefresh(int requestSequence, HomeGuideStep step) {
    return mounted &&
        requestSequence == _guideSpotlightRefreshSequence &&
        _guideController.isVisible &&
        _guideController.currentStep == step;
  }

  void _restoreGuideUiState() {
    final savedPaneLayout = _guideSavedPaneLayout;
    if (savedPaneLayout != null) {
      _paneController.applyPersistedLayout(savedPaneLayout);
      _guideSavedPaneLayout = null;
    }

    final savedRecordingSidebarIndex = _guideSavedRecordingSidebarIndex;
    if (savedRecordingSidebarIndex != null) {
      widget.uiState.setRecordingSidebarIndex(savedRecordingSidebarIndex);
      _guideSavedRecordingSidebarIndex = null;
    }
  }

  void _startGuideFromHelp(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_canStartGuide()) {
      widget.uiState.setNotice(
        HomeUiNotice(
          message: l10n.homeGuideReplayUnavailable,
          tone: HomeUiNoticeTone.warning,
          autoDismissAfter: const Duration(seconds: 5),
        ),
      );
      return;
    }

    widget.uiState.clearTransientNotice();
    _guideController.start();
  }

  void _selectRecordingSection(int index) {
    widget.uiState.setRecordingSidebarIndex(index);
    final spec = _recordingInspectorPaneSpec;
    if (_lastCanShowInspectorInline) {
      if (_paneController.stateFor(spec.id).isCollapsed) {
        _showPane(spec);
      }
      return;
    }
    _revealInlineInCompact(spec);
  }

  void _selectPostProcessingSection(int index) {
    widget.uiState.setPostProcessingSidebarIndex(index);
    final spec = _postProcessingInspectorPaneSpec;
    if (_lastCanShowInspectorInline) {
      if (_paneController.stateFor(spec.id).isCollapsed) {
        _showPane(spec);
      }
      return;
    }
    _revealInlineInCompact(spec);
  }

  /// In compact mode, "reveal" means: pin the active inspector pane id so the
  /// resolver does not auto-collapse it, and ensure the user-collapsed state
  /// is cleared. This brings the existing inline pane into view; if the
  /// available width is too small the layout will fall back to its existing
  /// horizontal scrolling behaviour.
  void _revealInlineInCompact(DesktopPaneSpec spec) {
    final wasCollapsed = _paneController.stateFor(spec.id).isCollapsed;
    if (_compactForcedInlineInspectorId != spec.id) {
      setState(() {
        _compactForcedInlineInspectorId = spec.id;
      });
    }
    if (wasCollapsed) {
      _setPaneCollapsed(spec, false);
    }
  }

  void _toggleActiveInspector({
    required DesktopPaneSpec activeInspectorSpec,
    required bool canShowInspectorInline,
  }) {
    if (canShowInspectorInline) {
      if (_compactForcedInlineInspectorId != null) {
        setState(() => _compactForcedInlineInspectorId = null);
      }
      _setPaneCollapsed(
        activeInspectorSpec,
        !_paneController.stateFor(activeInspectorSpec.id).isCollapsed,
      );
      return;
    }

    final isPinned = _compactForcedInlineInspectorId == activeInspectorSpec.id;
    if (isPinned) {
      setState(() => _compactForcedInlineInspectorId = null);
      _setPaneCollapsed(activeInspectorSpec, true);
    } else {
      _revealInlineInCompact(activeInspectorSpec);
    }
  }

  Widget _buildHomeOptionsPanel({
    required DesktopPanePresentation panePresentation,
    required bool isRecording,
    required bool showPreviewShell,
  }) {
    return HomeOptionsPanel(
      isRecording: isRecording,
      showPreviewShell: showPreviewShell,
      uiState: widget.uiState,
      actions: widget.actions,
      settingsController: widget.settingsController,
      panePresentation: panePresentation,
      captureSourceGuideAnchorKey: _guideAnchors.captureSourceSection,
      cameraGuideAnchorKey: _guideAnchors.cameraSection,
      outputGuideAnchorKey: _guideAnchors.outputSection,
    );
  }

  void _syncCompactInlineState(bool canShowInspectorInline) {
    if (_lastCanShowInspectorInline == canShowInspectorInline) {
      return;
    }
    _lastCanShowInspectorInline = canShowInspectorInline;
    // When the layout regains room for the inline inspector, drop the
    // compact "force inline" pin so the normal auto-collapse behaviour
    // resumes.
    if (canShowInspectorInline && _compactForcedInlineInspectorId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_compactForcedInlineInspectorId != null) {
          setState(() => _compactForcedInlineInspectorId = null);
        }
      });
    }
  }

  void _applyDensityAutoCollapse(
    ShellResponsiveMetrics metrics,
    DesktopPaneSpec railSpec,
  ) {
    if (_lastDensity == metrics.density) {
      return;
    }
    _lastDensity = metrics.density;
    if (metrics.autoCompactRail) {
      final railState = _paneController.stateFor(railSpec.id);
      if (!railState.isCollapsed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final current = _paneController.stateFor(railSpec.id);
          if (!current.isCollapsed) {
            _paneController.setPaneCollapsed(railSpec, true);
            _persistPaneLayout();
          }
        });
      }
    }
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
                          final shellSize = Size(
                            constraints.hasBoundedWidth
                                ? constraints.maxWidth
                                : MediaQuery.sizeOf(context).width,
                            constraints.hasBoundedHeight
                                ? constraints.maxHeight
                                : MediaQuery.sizeOf(context).height,
                          );
                          final metrics = ShellResponsiveMetrics.fromSize(
                            shellSize,
                          );
                          _currentMetrics = metrics;
                          _applyDensityAutoCollapse(metrics, _homeRailPaneSpec);
                          final activeInspectorSpec = showPreviewShell
                              ? _postProcessingInspectorPaneSpec
                              : _recordingInspectorPaneSpec;
                          final canShowInspectorInline =
                              !metrics.autoCollapseOptions &&
                              constraints.maxWidth >=
                                  HomeDesktopPaneDimensions
                                      .inspectorAutoHideThreshold;
                          _syncCompactInlineState(canShowInspectorInline);
                          final inspectorCollapsedByUser = _paneController
                              .stateFor(activeInspectorSpec.id)
                              .isCollapsed;
                          final inspectorVisibleInline =
                              canShowInspectorInline &&
                              !inspectorCollapsedByUser;
                          final compactForcedInlineActive =
                              !canShowInspectorInline &&
                              _compactForcedInlineInspectorId ==
                                  activeInspectorSpec.id &&
                              !inspectorCollapsedByUser;
                          final inspectorVisibleForToolbar =
                              inspectorVisibleInline ||
                              compactForcedInlineActive;
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
                              onLayoutCommitted: (_) => _persistPaneLayout(),
                              panes: [
                                DesktopPaneSlot(
                                  spec: _homeRailPaneSpec,
                                  builder: (context, panePresentation) {
                                    return HomeLeftSidebar(
                                      uiState: widget.uiState,
                                      panePresentation: panePresentation,
                                      guideShellKey: _guideAnchors.sidebarShell,
                                      helpButtonAnchorKey:
                                          _guideAnchors.helpButton,
                                      onRecordingSectionSelected:
                                          _selectRecordingSection,
                                      onPostProcessingSectionSelected:
                                          _selectPostProcessingSection,
                                      onOpenSettings: () {
                                        unawaited(
                                          widget.actions.openSettings(context),
                                        );
                                      },
                                      onStartQuickTour: () {
                                        _startGuideFromHelp(context);
                                      },
                                      onOpenAbout: () {
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
                                              inspectorVisibleForToolbar,
                                          onToggleInspector: () =>
                                              _toggleActiveInspector(
                                                activeInspectorSpec:
                                                    activeInspectorSpec,
                                                canShowInspectorInline:
                                                    canShowInspectorInline,
                                              ),
                                          showPreviewActions: showPreviewShell,
                                          onNewRecording: showPreviewShell
                                              ? () => unawaited(
                                                  _confirmClosePreview(context),
                                                )
                                              : null,
                                        ),
                                        const SizedBox(
                                          height: HomeDesktopPaneDimensions
                                              .innerGap,
                                        ),
                                        Expanded(
                                          child: DesktopSplitLayout(
                                            key: Key(
                                              'home_shell_inner_pane_layout_${activeInspectorSpec.id.name}',
                                            ),
                                            controller: _paneController,
                                            gap: HomeDesktopPaneDimensions
                                                .innerGap,
                                            minHeight: HomeDesktopPaneDimensions
                                                .workspaceMinHeight,
                                            onLayoutCommitted: (_) =>
                                                _persistPaneLayout(),
                                            preventAutoCollapsePaneIds:
                                                compactForcedInlineActive
                                                ? <DesktopPaneId>{
                                                    activeInspectorSpec.id,
                                                  }
                                                : const <DesktopPaneId>{},
                                            panes: [
                                              DesktopPaneSlot(
                                                spec: activeInspectorSpec,
                                                builder:
                                                    (
                                                      context,
                                                      panePresentation,
                                                    ) {
                                                      return _buildHomeOptionsPanel(
                                                        panePresentation:
                                                            panePresentation,
                                                        isRecording:
                                                            isRecording,
                                                        showPreviewShell:
                                                            showPreviewShell,
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
                                                      isRecording: isRecording,
                                                      isPaused: isPaused,
                                                      isBusy: isBusy,
                                                      canPause: canPause,
                                                      canResume: canResume,
                                                      onToggleRecording: () =>
                                                          _toggleRecordingFromUi(
                                                            context,
                                                          ),
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
                                                      startRecordingButtonKey:
                                                          _guideAnchors
                                                              .startRecordingButton,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (showTimelineBar) ...[
                                          const SizedBox(
                                            height: HomeDesktopPaneDimensions
                                                .innerGap,
                                          ),
                                          const TimelineBar(),
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

                          return ResponsiveShellScope(
                            metrics: metrics,
                            child: shell,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const ExportProgressDock(),
              HomeGuideOverlay(
                controller: _guideController,
                anchors: _guideAnchors,
              ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: CountdownOverlay(
          controller: widget.countdownController,
          onCancel: () => _toggleRecordingFromUi(context),
        ),
      ),
    );
  }
}
