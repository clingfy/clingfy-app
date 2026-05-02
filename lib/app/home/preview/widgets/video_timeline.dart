import 'dart:async';

import 'package:clingfy/app/home/preview/widgets/timeline/timeline_editor_viewport.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_header_bar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_transport_bar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  final int durationMs;
  final int positionMs;
  final bool isReady;
  final ValueChanged<int> onSeek;
  final ValueChanged<int>? onHoverSeek;
  final VoidCallback onClose;
  final VoidCallback? onHoverEnd;

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

class _VideoTimelineState extends State<VideoTimeline> {
  late final FocusNode _zoomEditorFocusNode;
  late final TimelineViewportController _viewportController;

  int? _hoverPositionMs;
  bool _showZoomLane = true;
  bool _showMarkersLane = false;
  bool _panModeEnabled = false;

  @override
  void initState() {
    super.initState();
    _zoomEditorFocusNode = FocusNode(debugLabel: 'zoom-editor-timeline');
    _viewportController = TimelineViewportController(
      durationMs: widget.durationMs > 0 ? widget.durationMs : 1,
    );
  }

  @override
  void didUpdateWidget(covariant VideoTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationMs != oldWidget.durationMs) {
      _viewportController.setDurationMs(
        widget.durationMs > 0 ? widget.durationMs : 1,
      );
    }
    if (!oldWidget.isReady && widget.isReady) {
      _viewportController.fitToDuration(centerMs: widget.positionMs);
    }
  }

  @override
  void dispose() {
    _zoomEditorFocusNode.dispose();
    _viewportController.dispose();
    super.dispose();
  }

  String _fmt(int ms) {
    final duration = Duration(milliseconds: ms);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }

  void _requestTimelineFocus() {
    if (!_zoomEditorFocusNode.hasFocus) {
      _zoomEditorFocusNode.requestFocus();
    }
  }

  void _clearHoverPreview() {
    if (_hoverPositionMs != null) {
      setState(() => _hoverPositionMs = null);
    }
    widget.onHoverEnd?.call();
  }

  void _setPanModeEnabled(bool enabled) {
    if (_panModeEnabled == enabled) return;
    if (enabled) {
      _clearHoverPreview();
    }
    setState(() => _panModeEnabled = enabled);
  }

  KeyEventResult _handleTimelineKeyEvent(FocusNode node, KeyEvent event) {
    final isSpace = event.logicalKey == LogicalKeyboardKey.space;
    final isAltSpace = isSpace && HardwareKeyboard.instance.isAltPressed;

    if (!isAltSpace) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _setPanModeEnabled(true);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _setPanModeEnabled(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleDeleteSelected(ZoomEditorController? editor) {
    if (editor == null || !editor.hasSelection) return;
    editor.deleteSelectedSegments();
  }

  void _handleClearOrEscape(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.handleEscapeAction();
  }

  void _handleSelectAllVisible(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllInRange(
      _viewportController.visibleStartMs,
      _viewportController.visibleEndMs,
    );
  }

  void _handleSelectAfterPlayhead(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllAfter(widget.positionMs);
  }

  void _toggleSnap(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.setSnappingEnabled(!editor.snappingEnabled);
  }

  void _toggleZoomLaneVisibility() {
    if (_showZoomLane && !_showMarkersLane) return;
    setState(() => _showZoomLane = !_showZoomLane);
  }

  void _toggleMarkersLaneVisibility() {
    if (_showMarkersLane && !_showZoomLane) return;
    setState(() => _showMarkersLane = !_showMarkersLane);
  }

  String? _buildModeText(AppLocalizations l10n, ZoomEditorController? editor) {
    if (!widget.isReady || editor == null) return null;
    if (editor.addMode == ZoomAddMode.sticky) return l10n.zoomKeepAddingStatus;
    if (editor.addMode == ZoomAddMode.oneShot) return l10n.zoomAddOneStatus;
    if (editor.isTrimming) {
      return editor.activeTrimHandle == TrimHandle.left
          ? l10n.zoomTrimStartStatus
          : l10n.zoomTrimEndStatus;
    }
    if (editor.isMoving) return l10n.zoomMoveStatus;
    if (editor.isBandSelecting) return l10n.zoomBandSelectStatus;
    return null;
  }

  Future<void> _togglePlayback(PlayerController player) async {
    if (!widget.isReady) return;
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.isReady;
    final totalMs = ready && widget.durationMs > 0 ? widget.durationMs : 1;
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final l10n = AppLocalizations.of(context)!;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final shellGap = metrics?.timelineShellGap ?? (theme.appSpacing.xs + 2);
    final editor = context.select<PlayerController, ZoomEditorController?>(
      (player) => player.zoomEditor,
    );
    final playerSegments = context.select<PlayerController, List<ZoomSegment>>(
      (player) => player.zoomSegments,
    );
    final isPlaying = context.select<PlayerController, bool>(
      (player) => player.isPlaying,
    );

    final dockContent = ListenableBuilder(
      listenable: Listenable.merge([
        _viewportController,
        if (editor != null) editor,
      ]),
      builder: (context, _) {
        final canEditZoom = ready && editor != null && _showZoomLane;
        final activeEditor = canEditZoom ? editor : null;
        final modeText = _buildModeText(l10n, editor);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TimelineHeaderBar(
              snappingEnabled: editor?.snappingEnabled ?? false,
              canEditZoom: canEditZoom,
              canDelete: activeEditor?.hasSelection ?? false,
              canUndo: activeEditor?.canUndo ?? false,
              showZoomLane: _showZoomLane,
              showMarkersLane: _showMarkersLane,
              onToggleSnap: canEditZoom ? () => _toggleSnap(editor) : null,
              onSelectAllVisible: canEditZoom
                  ? () => _handleSelectAllVisible(editor)
                  : null,
              onSelectAfterPlayhead: canEditZoom
                  ? () => _handleSelectAfterPlayhead(editor)
                  : null,
              onDeleteSelected: canEditZoom
                  ? () => _handleDeleteSelected(editor)
                  : null,
              onUndo: activeEditor?.undo,
              onToggleZoomLaneVisibility: _toggleZoomLaneVisibility,
              onToggleMarkersLaneVisibility: _toggleMarkersLaneVisibility,
              onClose: widget.onClose,
            ),
            SizedBox(height: shellGap),
            TimelineTransportBar(
              isReady: ready,
              isPlaying: isPlaying,
              currentTimeLabel: ready ? _fmt(widget.positionMs) : '--:--',
              totalTimeLabel: ready ? _fmt(widget.durationMs) : '--:--',
              modeText: modeText,
              zoomLevel: _viewportController.zoomLevel,
              minZoom: _viewportController.minZoom,
              maxZoom: _viewportController.maxZoom,
              onZoomLevelChanged: (value) =>
                  _viewportController.setZoomLevel(value),
              onZoomIn: _viewportController.zoomIn,
              onZoomOut: _viewportController.zoomOut,
              onFit: () => _viewportController.fitToDuration(
                centerMs: widget.positionMs,
              ),
              onPlayPause: ready
                  ? () => unawaited(
                      _togglePlayback(context.read<PlayerController>()),
                    )
                  : null,
            ),
            SizedBox(height: shellGap),
            TimelineEditorViewport(
              durationMs: totalMs,
              positionMs: widget.positionMs,
              viewportController: _viewportController,
              segments: playerSegments,
              editorController: editor,
              showZoomLane: _showZoomLane,
              showMarkersLane: _showMarkersLane,
              panModeEnabled: _panModeEnabled,
              onSeek: widget.onSeek,
              onHoverSeek: widget.onHoverSeek,
              onHoverEnd: widget.onHoverEnd,
              onHoverChanged: (value) =>
                  setState(() => _hoverPositionMs = value),
              hoverPositionMs: _hoverPositionMs,
              onFocusRequested: _requestTimelineFocus,
            ),
          ],
        );
      },
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
              _handleSelectAllVisible(editor);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _zoomEditorFocusNode,
          canRequestFocus: true,
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              _setPanModeEnabled(false);
            }
          },
          onKeyEvent: _handleTimelineKeyEvent,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _requestTimelineFocus(),
            child: Container(
              key: const Key('timeline_shell'),
              padding: EdgeInsets.zero,
              decoration: BoxDecoration(
                color: tokens.timelineBackground,
                borderRadius: BorderRadius.circular(chrome.panelRadius),
              ),
              child: RepaintBoundary(child: dockContent),
            ),
          ),
        ),
      ),
    );
  }
}
