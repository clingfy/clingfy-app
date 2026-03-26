import 'dart:async';

import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_menu_button.dart';
import 'package:clingfy/app/home/post_processing/widgets/zoom_track.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:provider/provider.dart';

class TimelineBar extends StatelessWidget {
  const TimelineBar({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerController, (int durMs, int posMs, bool ready)>(
      selector: (_, p) => (p.durationMs, p.positionMs, p.isReady),
      builder: (context, t, _) {
        final player = context.read<PlayerController>();

        return VideoTimeline(
          durationMs: t.$1,
          positionMs: t.$2,
          isReady: t.$3,
          onSeek: (ms) => unawaited(player.seekTo(ms)),
          onHoverSeek: (ms) => unawaited(player.previewPeekTo(ms)),
          onHoverEnd: () => unawaited(player.previewPeekEnd()),
          onClose: onClose,
        );
      },
    );
  }
}

class VideoTimeline extends StatefulWidget {
  final int durationMs;
  final int positionMs;
  final bool isReady;
  final Function(int) onSeek;
  final Function(int)? onHoverSeek;
  final VoidCallback onClose;
  final VoidCallback? onHoverEnd;

  const VideoTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.isReady,
    required this.onSeek,
    required this.onClose,
    this.onHoverSeek,
    this.onHoverEnd,
  });

  @override
  State<VideoTimeline> createState() => _VideoTimelineState();
}

class DeleteSelectedZoomIntent extends Intent {
  const DeleteSelectedZoomIntent();
}

class ClearZoomSelectionIntent extends Intent {
  const ClearZoomSelectionIntent();
}

class SelectAllZoomIntent extends Intent {
  const SelectAllZoomIntent();
}

enum _SelectionMenuAction {
  selectAfterPlayhead,
  selectAllVisible,
  clearSelection,
}

class _VideoTimelineState extends State<VideoTimeline> {
  bool _scrubbing = false;
  int? _hoverPositionMs;
  late final FocusNode _zoomEditorFocusNode;

  // Gradient for the timeline progress
  // Gradient colors will be derived from Theme in build()

  @override
  void initState() {
    super.initState();
    _zoomEditorFocusNode = FocusNode(debugLabel: 'zoom-editor-timeline');
  }

  String fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void seekToPercent(double percent) {
    if (!widget.isReady) return;
    final totalMs = widget.durationMs > 0 ? widget.durationMs : 1;
    final clamped = percent.clamp(0.0, 1.0);
    final target = (clamped * totalMs).round();
    widget.onSeek(target);
  }

  void _requestTimelineFocus() {
    if (!_zoomEditorFocusNode.hasFocus) {
      _zoomEditorFocusNode.requestFocus();
    }
  }

  void _handleDeleteSelected(ZoomEditorController? editor) {
    if (editor == null || !editor.hasSelection) return;
    editor.deleteSelectedSegments();
  }

  void _handleClearOrEscape(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.handleEscapeAction();
  }

  void _handleSelectAll(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllVisible();
  }

  void _handleSelectAfterPlayhead(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllAfter(widget.positionMs);
  }

  @override
  void dispose() {
    _zoomEditorFocusNode.dispose();
    super.dispose();
  }

  Widget? _buildToolbarStatusChip(
    BuildContext context,
    ZoomEditorController? editor,
  ) {
    if (editor == null || !widget.isReady) return null;
    if (editor.stickyAddModeEnabled) {
      return _TimelineStatusChip(
        key: const Key('timeline_mode_chip'),
        icon: Icons.push_pin_rounded,
        label: AppLocalizations.of(context)!.zoomKeepAdding,
        accentColor: Theme.of(context).colorScheme.primary,
      );
    }
    if (editor.addMode == ZoomAddMode.oneShot) {
      return _TimelineStatusChip(
        key: const Key('timeline_mode_chip'),
        icon: Icons.add_circle_outline_rounded,
        label: AppLocalizations.of(context)!.zoomAddOne,
        accentColor: Theme.of(context).colorScheme.primary,
      );
    }
    return null;
  }

  _TimelineStatusLineData? _buildStatusLineData(
    BuildContext context,
    ZoomEditorController? editor,
  ) {
    if (editor == null || !widget.isReady) return null;
    final l10n = AppLocalizations.of(context)!;

    if (editor.stickyAddModeEnabled) {
      return _TimelineStatusLineData(
        icon: Icons.push_pin_rounded,
        message: l10n.zoomKeepAddingStatus,
      );
    }
    if (editor.addMode == ZoomAddMode.oneShot) {
      return _TimelineStatusLineData(
        icon: Icons.add_circle_outline_rounded,
        message: l10n.zoomAddOneStatus,
      );
    }
    if (editor.isTrimming) {
      return _TimelineStatusLineData(
        icon: editor.activeTrimHandle == TrimHandle.left
            ? Icons.keyboard_arrow_left_rounded
            : Icons.keyboard_arrow_right_rounded,
        message: editor.activeTrimHandle == TrimHandle.left
            ? l10n.zoomTrimStartStatus
            : l10n.zoomTrimEndStatus,
      );
    }
    if (editor.isMoving) {
      return _TimelineStatusLineData(
        icon: Icons.open_with_rounded,
        message: l10n.zoomMoveStatus,
      );
    }
    if (editor.isBandSelecting) {
      return _TimelineStatusLineData(
        icon: Icons.select_all_rounded,
        message: l10n.zoomBandSelectStatus,
      );
    }
    return null;
  }

  Widget _buildTimelineContent({
    required BuildContext context,
    required ThemeData theme,
    required Color accentColor,
    required Color foregroundColor,
    required Color secondaryTextColor,
    required AppLocalizations l10n,
    required bool ready,
    required int totalMs,
    required double fraction,
    required List<ZoomSegment> playerSegments,
    required ZoomEditorController? editor,
  }) {
    final hasEditor = ready && editor != null;
    final hasSelection = editor?.hasSelection ?? false;
    final selectedCount = editor?.selectedCount ?? 0;
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    final controlFill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.secondaryContainer;
    final subtleBorder = theme.dividerColor.withValues(alpha: 0.1);
    final timelineBandHeight = chrome.timelineRulerHeight;
    const timelineTrackTop = 31.0;
    const timelineTrackHeight = 20.0;
    final deleteTooltip = selectedCount <= 1
        ? l10n.zoomDeleteSelectedOne
        : l10n.zoomDeleteSelectedMany(selectedCount);
    final statusChip = _buildToolbarStatusChip(context, editor);
    final statusLineData = _buildStatusLineData(context, editor);

    final timelineTrack = (playerSegments.isEmpty && editor == null)
        ? const SizedBox.shrink()
        : ZoomTrack(
            segments: editor?.displaySegments ?? playerSegments,
            durationMs: totalMs,
            positionMs: widget.positionMs,
            onQuickSeek: widget.onSeek,
            editorController: editor,
            onFocusRequested: _requestTimelineFocus,
            selectedSegmentIds: editor?.selectedSegmentIds,
            primarySelectedSegmentId: editor?.primarySelectedSegmentId,
            canSingleEdit: editor?.canSingleEdit,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timeline_rounded,
                          size: 18,
                          color: foregroundColor,
                        ),
                        SizedBox(width: spacing.xs + 1),
                        Text(
                          l10n.timeline,
                          style: typography.button.copyWith(
                            color: foregroundColor,
                          ),
                        ),
                        if (statusChip != null) ...[
                          SizedBox(width: spacing.xs + 2),
                          statusChip,
                        ],
                      ],
                    ),
                    if (hasEditor) ...[
                      SizedBox(width: spacing.sm + 1),
                      _TimelineToolbarGroup(
                        key: const Key('timeline_toolbar_add_group'),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _TimelineToggleIconButton(
                              key: const Key('timeline_add_button'),
                              icon: Icons.add_rounded,
                              label: l10n.zoomAddOne,
                              tooltip: l10n.zoomAddOneTooltip,
                              isActive: editor.addModeEnabled,
                              accentColor: accentColor,
                              foregroundColor: foregroundColor,
                              onPressed: editor.toggleAddMode,
                            ),
                            SizedBox(width: spacing.xs + 1),
                            Container(
                              width: 1,
                              height: 18,
                              color: theme.dividerColor.withValues(alpha: 0.22),
                            ),
                            SizedBox(width: spacing.xs + 1),
                            _TimelineToggleIconButton(
                              key: const Key('timeline_sticky_add_button'),
                              icon: Icons.push_pin_rounded,
                              tooltip: l10n.zoomKeepAddingTooltip,
                              isActive: editor.stickyAddModeEnabled,
                              accentColor: accentColor,
                              foregroundColor: foregroundColor,
                              onPressed: editor.toggleStickyAddMode,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: spacing.xs + 2),
                      _TimelineToolbarGroup(
                        key: const Key('timeline_toolbar_selection_group'),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppMenuButton<_SelectionMenuAction>(
                              tooltip: l10n.zoomSelectionTools,
                              icon: Icons.select_all_rounded,
                              items: editor.displaySegments.isEmpty
                                  ? const []
                                  : [
                                      AppMenuItem(
                                        value: _SelectionMenuAction
                                            .selectAfterPlayhead,
                                        label: l10n.zoomSelectAfterPlayhead,
                                      ),
                                      AppMenuItem(
                                        value: _SelectionMenuAction
                                            .selectAllVisible,
                                        label: l10n.zoomSelectAllVisible,
                                      ),
                                      if (hasSelection)
                                        AppMenuItem(
                                          value: _SelectionMenuAction
                                              .clearSelection,
                                          label: l10n.zoomClearSelection,
                                        ),
                                    ],
                              onSelected: (action) {
                                switch (action) {
                                  case _SelectionMenuAction.selectAfterPlayhead:
                                    _handleSelectAfterPlayhead(editor);
                                    break;
                                  case _SelectionMenuAction.selectAllVisible:
                                    _handleSelectAll(editor);
                                    break;
                                  case _SelectionMenuAction.clearSelection:
                                    editor.clearSelection();
                                    break;
                                }
                              },
                            ),

                            SizedBox(width: spacing.xs),
                            AppIconButton(
                              onPressed: hasSelection
                                  ? () => _handleDeleteSelected(editor)
                                  : null,
                              icon: Icons.delete_outline_rounded,
                              color: hasSelection
                                  ? theme.colorScheme.error
                                  : foregroundColor.withValues(alpha: 0.32),
                              size: 19,
                              tooltip: deleteTooltip,
                            ),
                            SizedBox(width: spacing.xs),
                            AppIconButton(
                              onPressed: editor.canUndo ? editor.undo : null,
                              icon: Icons.undo_rounded,
                              color: editor.canUndo
                                  ? foregroundColor.withValues(alpha: 0.72)
                                  : foregroundColor.withValues(alpha: 0.32),
                              size: 19,
                              tooltip: l10n.zoomUndoLastAction,
                            ),
                            if (hasSelection) ...[
                              SizedBox(width: spacing.xs),
                              _TimelineStatusChip(
                                icon: Icons.layers_outlined,
                                label: l10n.zoomSelectedCount(selectedCount),
                                accentColor: accentColor,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(width: spacing.sm + 2),
            Container(
              key: const Key('timeline_time_chip'),
              padding: EdgeInsets.symmetric(
                horizontal: spacing.sm,
                vertical: spacing.xs,
              ),
              decoration: BoxDecoration(
                color: controlFill,
                borderRadius: BorderRadius.circular(chrome.pillRadius),
                border: Border.all(color: subtleBorder),
              ),
              child: Text(
                ready
                    ? '${fmt(widget.positionMs)} / ${fmt(widget.durationMs)}'
                    : '--:--',
                style: typography.mono.copyWith(
                  color: secondaryTextColor.withValues(alpha: 0.9),
                ),
              ),
            ),
            SizedBox(width: spacing.xs + 1),
            AppIconButton(
              key: const Key('timeline_close_button'),
              tooltip: l10n.closeTimelineTooltip,
              icon: CupertinoIcons.xmark,
              onPressed: widget.onClose,
              color: secondaryTextColor.withValues(alpha: 0.8),
              size: 17,
            ),
          ],
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: statusLineData == null
              ? const SizedBox.shrink()
              : Padding(
                  key: ValueKey<String>(statusLineData.message),
                  padding: EdgeInsets.only(top: spacing.xs + 2),
                  child: _TimelineStatusLine(
                    key: const Key('timeline_status_line'),
                    icon: statusLineData.icon,
                    message: statusLineData.message,
                    accentColor: accentColor,
                    textColor: secondaryTextColor,
                    backgroundColor: controlFill.withValues(alpha: 0.92),
                    borderColor: subtleBorder,
                  ),
                ),
        ),
        SizedBox(height: spacing.sm),
        timelineTrack,
        SizedBox(height: spacing.xs + 2),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 0.0;
            final safeWidth = (width.isFinite && width > 0) ? width : 1.0;
            double handleX = width * fraction;
            handleX = handleX.clamp(0, width);

            void updateFromDx(double dx) {
              final percent = (dx / safeWidth).clamp(0.0, 1.0);
              seekToPercent(percent);
            }

            return MouseRegion(
              onHover: ready
                  ? (event) {
                      if (_scrubbing) return;

                      final dx = event.localPosition.dx;
                      final percent = (dx / safeWidth).clamp(0.0, 1.0);
                      final hoverMs = (percent * totalMs).round();

                      setState(() => _hoverPositionMs = hoverMs);
                      widget.onHoverSeek?.call(hoverMs);
                    }
                  : null,
              onExit: (_) {
                setState(() => _hoverPositionMs = null);
                widget.onHoverEnd?.call();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: ready
                    ? (details) {
                        widget.onHoverEnd?.call();
                        setState(() {
                          _scrubbing = true;
                          _hoverPositionMs = null;
                        });

                        updateFromDx(details.localPosition.dx);

                        setState(() => _scrubbing = false);
                      }
                    : null,
                onHorizontalDragStart: ready
                    ? (_) {
                        widget.onHoverEnd?.call();
                        setState(() {
                          _scrubbing = true;
                          _hoverPositionMs = null;
                        });
                      }
                    : null,
                onHorizontalDragUpdate: ready
                    ? (details) => updateFromDx(details.localPosition.dx)
                    : null,
                onHorizontalDragEnd: ready
                    ? (_) {
                        setState(() {
                          _scrubbing = false;
                          _hoverPositionMs = null;
                        });
                        widget.onHoverEnd?.call();
                      }
                    : null,
                child: SizedBox(
                  key: const Key('timeline_ruler_band'),
                  height: timelineBandHeight,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: RulerPainter(
                            durationMs: totalMs,
                            tickColor: secondaryTextColor.withValues(
                              alpha: 0.28,
                            ),
                            textColor: secondaryTextColor.withValues(
                              alpha: 0.62,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.only(top: timelineTrackTop),
                        height: timelineTrackHeight,
                        decoration: BoxDecoration(
                          color: controlFill.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(
                            chrome.controlRadius,
                          ),
                          border: Border.all(color: subtleBorder),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: ready ? fraction : 0,
                        child: Container(
                          margin: const EdgeInsets.only(top: timelineTrackTop),
                          height: timelineTrackHeight,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                accentColor.withValues(alpha: 0.76),
                                accentColor.withValues(alpha: 0.94),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(
                              chrome.controlRadius,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withValues(alpha: 0.14),
                                blurRadius: 5,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_hoverPositionMs != null) ...[
                        Positioned(
                          left:
                              (width *
                                      (_hoverPositionMs! / totalMs).clamp(
                                        0.0,
                                        1.0,
                                      ))
                                  .clamp(0, width) -
                              0.75,
                          top: 2,
                          bottom: 4,
                          child: Container(
                            width: 1.5,
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.42),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                        Positioned(
                          left:
                              (width *
                                      (_hoverPositionMs! / totalMs).clamp(
                                        0.0,
                                        1.0,
                                      ))
                                  .clamp(0, width) -
                              5,
                          top: 1,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                      Positioned(
                        left: handleX - 1,
                        top: 0,
                        bottom: 4,
                        child: Container(
                          width: 2,
                          decoration: BoxDecoration(
                            color: accentColor,
                            borderRadius: BorderRadius.circular(1),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withValues(alpha: 0.22),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: handleX - 5.5,
                        top: 0,
                        child: Container(
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            color: accentColor,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.isReady;
    final totalMsRaw = ready ? widget.durationMs : 1;
    final totalMs = totalMsRaw > 0 ? totalMsRaw : 1;
    final fraction = ready
        ? (widget.positionMs.clamp(0, totalMs) / totalMs).clamp(0.0, 1.0)
        : 0.0;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final l10n = AppLocalizations.of(context)!;
    final accentColor = theme.primaryColor;
    final foregroundColor =
        theme.textTheme.bodyMedium?.color ?? colorScheme.onSurface;
    final secondaryTextColor =
        theme.textTheme.bodySmall?.color ?? colorScheme.onSurfaceVariant;
    final editor = context.select<PlayerController, ZoomEditorController?>(
      (player) => player.zoomEditor,
    );
    final playerSegments = context.select<PlayerController, List<ZoomSegment>>(
      (player) => player.zoomSegments,
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.delete): DeleteSelectedZoomIntent(),
        SingleActivator(LogicalKeyboardKey.backspace):
            DeleteSelectedZoomIntent(),
        SingleActivator(LogicalKeyboardKey.escape): ClearZoomSelectionIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            SelectAllZoomIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, control: true):
            SelectAllZoomIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DeleteSelectedZoomIntent: CallbackAction<DeleteSelectedZoomIntent>(
            onInvoke: (_) {
              _handleDeleteSelected(editor);
              return null;
            },
          ),
          ClearZoomSelectionIntent: CallbackAction<ClearZoomSelectionIntent>(
            onInvoke: (_) {
              _handleClearOrEscape(editor);
              return null;
            },
          ),
          SelectAllZoomIntent: CallbackAction<SelectAllZoomIntent>(
            onInvoke: (_) {
              _handleSelectAll(editor);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _zoomEditorFocusNode,
          canRequestFocus: true,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _requestTimelineFocus(),
            child: Container(
              key: const Key('timeline_shell'),
              padding: EdgeInsets.symmetric(
                horizontal: chrome.timelineHorizontalPadding,
                vertical: chrome.timelineVerticalPadding,
              ),
              decoration: BoxDecoration(
                color: tokens.timelineBackground,
                borderRadius: BorderRadius.circular(chrome.panelRadius),
              ),
              child: editor == null
                  ? _buildTimelineContent(
                      context: context,
                      theme: theme,
                      accentColor: accentColor,
                      foregroundColor: foregroundColor,
                      secondaryTextColor: secondaryTextColor,
                      l10n: l10n,
                      ready: ready,
                      totalMs: totalMs,
                      fraction: fraction,
                      playerSegments: playerSegments,
                      editor: null,
                    )
                  : ListenableBuilder(
                      listenable: editor,
                      builder: (context, _) {
                        return _buildTimelineContent(
                          context: context,
                          theme: theme,
                          accentColor: accentColor,
                          foregroundColor: foregroundColor,
                          secondaryTextColor: secondaryTextColor,
                          l10n: l10n,
                          ready: ready,
                          totalMs: totalMs,
                          fraction: fraction,
                          playerSegments: playerSegments,
                          editor: editor,
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineStatusLineData {
  const _TimelineStatusLineData({required this.icon, required this.message});

  final IconData icon;
  final String message;
}

class _TimelineToolbarGroup extends StatelessWidget {
  const _TimelineToolbarGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final controlFill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.secondaryContainer;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.xs + 1,
        vertical: spacing.xs - 1,
      ),
      decoration: BoxDecoration(
        color: controlFill,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
      ),
      child: child,
    );
  }
}

class _TimelineToggleIconButton extends StatelessWidget {
  const _TimelineToggleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.accentColor,
    required this.foregroundColor,
    required this.onPressed,
    this.label,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color accentColor;
  final Color foregroundColor;
  final VoidCallback onPressed;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    final child = DecoratedBox(
      decoration: BoxDecoration(
        color: isActive
            ? accentColor.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(
          color: isActive
              ? accentColor.withValues(alpha: 0.28)
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: label == null ? spacing.xs + 1 : spacing.sm,
            vertical: spacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: isActive
                    ? accentColor
                    : foregroundColor.withValues(alpha: 0.8),
              ),
              if (label != null) ...[
                SizedBox(width: spacing.xs + 1),
                Text(
                  label!,
                  style: typography.value.copyWith(
                    color: isActive
                        ? accentColor
                        : foregroundColor.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Tooltip(message: tooltip, child: child);
  }
}

class _TimelineStatusChip extends StatelessWidget {
  const _TimelineStatusChip({
    super.key,
    required this.icon,
    required this.label,
    required this.accentColor,
  });

  final IconData icon;
  final String label;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.xs + 2,
        vertical: spacing.xs - 1,
      ),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(chrome.pillRadius),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accentColor),
          SizedBox(width: spacing.xs + 1),
          Text(
            label,
            style: typography.caption.copyWith(
              color: accentColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineStatusLine extends StatelessWidget {
  const _TimelineStatusLine({
    super.key,
    required this.icon,
    required this.message,
    required this.accentColor,
    required this.textColor,
    required this.backgroundColor,
    required this.borderColor,
  });

  final IconData icon;
  final String message;
  final Color accentColor;
  final Color textColor;
  final Color backgroundColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md - 2,
        vertical: spacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Icon(icon, size: 14, color: accentColor),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.bodyMuted.copyWith(
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RulerPainter extends CustomPainter {
  final int durationMs;
  final Color tickColor;
  final Color textColor;

  RulerPainter({
    required this.durationMs,
    required this.tickColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;

    final Paint tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1;

    final TextPainter textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    // We want roughly one major tick every 100 pixels
    final double width = size.width;
    final int majorTicks = (width / 100).floor();
    if (majorTicks == 0) return;

    // Determine raw step in ms
    final double rawStepMs = durationMs / majorTicks;

    // Find a nice interval >= 1000ms
    // Candidates in ms: 1s, 2s, 5s, 10s, 15s, 30s, 60s, 2m, 5m, 10m...
    final List<int> intervals = [
      1000,
      2000,
      5000,
      10000,
      15000,
      30000,
      60000,
      120000,
      300000,
      600000,
      900000,
      1800000,
      3600000,
    ];

    int stepMs = intervals.first;
    for (final interval in intervals) {
      if (interval >= rawStepMs) {
        stepMs = interval;
        break;
      }
    }
    // If larger than max interval, just round rawStepMs to nearest second
    if (rawStepMs > intervals.last) {
      stepMs = ((rawStepMs / 1000).ceil() * 1000);
    }

    // Calculate actual number of ticks based on nice step
    // We iterate by time, not by tick count
    for (int ms = 0; ms <= durationMs; ms += stepMs) {
      final double x = (ms / durationMs) * width;

      // Draw major tick
      canvas.drawLine(Offset(x, 0), Offset(x, 10), tickPaint);

      // Draw time text
      final Duration d = Duration(milliseconds: ms);
      final String text =
          '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

      textPainter.text = TextSpan(
        text: text,
        style: TextStyle(color: textColor, fontSize: 10),
      );
      textPainter.layout();

      // Fix clipping: clamp the x position for text
      // Default center: x - textPainter.width / 2
      // Left edge (x=0): must be at least 0
      // Right edge (x=width): must be at most width - textPainter.width
      double textX = x - textPainter.width / 2;
      textX = textX.clamp(0.0, width - textPainter.width);

      textPainter.paint(canvas, Offset(textX, 12));

      // Draw minor ticks
      final double minorStepPx = (stepMs / durationMs) * width / 5;
      for (int j = 1; j < 5; j++) {
        final double minorX = x + j * minorStepPx;
        if (minorX > width) break;
        canvas.drawLine(Offset(minorX, 0), Offset(minorX, 5), tickPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant RulerPainter oldDelegate) {
    return oldDelegate.durationMs != durationMs ||
        oldDelegate.tickColor != tickColor ||
        oldDelegate.textColor != textColor;
  }
}
