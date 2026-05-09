import 'dart:async';

import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/core/zoom/zoom_focus_heuristic.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Floating contextual toolbar that exposes zoom-behavior controls for
/// the currently-selected zoom segment without taking part in the
/// timeline's vertical layout.
///
/// Renders as a compact pill on top of the timeline shell via a parent
/// `Stack` + `Positioned`. Returns `SizedBox.shrink()` when no segment
/// is selected, the editor cannot single-edit, or the native backend
/// does not support fixed-target preview — so the slot collapses
/// without nudging anything around it.
class ZoomSegmentBehaviorFloatingToolbar extends StatefulWidget {
  const ZoomSegmentBehaviorFloatingToolbar({
    super.key,
    required this.editor,
    required this.nativeBridge,
    required this.viewportController,
    required this.durationMs,
    this.sessionId,
  });

  final ZoomEditorController? editor;
  final NativeBridge nativeBridge;
  final TimelineViewportController viewportController;
  final int durationMs;
  final String? sessionId;

  @override
  State<ZoomSegmentBehaviorFloatingToolbar> createState() =>
      _ZoomSegmentBehaviorFloatingToolbarState();
}

class _ZoomSegmentBehaviorFloatingToolbarState
    extends State<ZoomSegmentBehaviorFloatingToolbar> {
  final Map<String, bool> _staticHintBySegmentId = <String, bool>{};
  String? _inFlightSegmentId;
  // Segment id the user dismissed the pill for. Cleared whenever the
  // primary selection changes — re-selecting (or selecting another
  // segment) brings the pill back without a separate "show" toggle.
  String? _dismissedForSegmentId;
  String? _lastPrimarySelectionId;

  @override
  void initState() {
    super.initState();
    widget.editor?.addListener(_onEditorChanged);
    _lastPrimarySelectionId = widget.editor?.primarySelectedSegmentId;
    _maybeQueryHintForSelection();
  }

  @override
  void didUpdateWidget(covariant ZoomSegmentBehaviorFloatingToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) {
      oldWidget.editor?.removeListener(_onEditorChanged);
      widget.editor?.addListener(_onEditorChanged);
      _staticHintBySegmentId.clear();
      _inFlightSegmentId = null;
      _dismissedForSegmentId = null;
      _lastPrimarySelectionId = widget.editor?.primarySelectedSegmentId;
      _maybeQueryHintForSelection();
    }
  }

  @override
  void dispose() {
    widget.editor?.removeListener(_onEditorChanged);
    super.dispose();
  }

  void _onEditorChanged() {
    final currentPrimary = widget.editor?.primarySelectedSegmentId;
    if (currentPrimary != _lastPrimarySelectionId) {
      _lastPrimarySelectionId = currentPrimary;
      _dismissedForSegmentId = null;
    }
    _maybeQueryHintForSelection();
    if (mounted) setState(() {});
  }

  void _maybeQueryHintForSelection() {
    final editor = widget.editor;
    if (editor == null) return;
    if (!editor.capabilities.supportsSmartFixedTarget) return;
    if (!editor.canSingleEdit) return;
    final segment = editor.primarySelectedSegment;
    if (segment == null) return;
    if (segment.focusMode != ZoomFocusMode.followCursor) return;
    if (_staticHintBySegmentId.containsKey(segment.id)) return;
    if (_inFlightSegmentId == segment.id) return;
    _inFlightSegmentId = segment.id;

    unawaited(_runHintQuery(segment));
  }

  Future<void> _runHintQuery(ZoomSegment segment) async {
    final CursorSamplesResult samples;
    try {
      samples = await widget.nativeBridge.previewGetCursorSamples(
        startMs: segment.startMs,
        endMs: segment.endMs,
        playheadMs: segment.startMs,
        sessionId: widget.sessionId,
      );
    } on ZoomNativeCapabilityMissing {
      if (!mounted) return;
      setState(() {
        _staticHintBySegmentId[segment.id] = false;
        if (_inFlightSegmentId == segment.id) {
          _inFlightSegmentId = null;
        }
      });
      return;
    }
    if (!mounted) return;
    final decision = chooseZoomFocusModeForRange(
      startMs: segment.startMs,
      endMs: segment.endMs,
      playheadMs: segment.startMs,
      samples: samples,
    );
    setState(() {
      _staticHintBySegmentId[segment.id] =
          decision.mode == ZoomFocusMode.fixedTarget;
      if (_inFlightSegmentId == segment.id) {
        _inFlightSegmentId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    if (editor == null) return const SizedBox.shrink();
    if (!editor.capabilities.fixedTargetPreview) {
      return const SizedBox.shrink();
    }
    if (!editor.canSingleEdit) return const SizedBox.shrink();
    final segment = editor.primarySelectedSegment;
    if (segment == null) return const SizedBox.shrink();
    if (_dismissedForSegmentId == segment.id) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = theme.appTokens;
    final isFollow = segment.focusMode == ZoomFocusMode.followCursor;
    final showHint = isFollow && (_staticHintBySegmentId[segment.id] ?? false);

    return Material(
      color: tokens.timelineChromeSurface,
      elevation: 2,
      shape: StadiumBorder(side: BorderSide(color: tokens.panelBorder)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: l10n.zoomBehaviorTooltip,
              child: Text(
                l10n.zoomBehavior,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: 10),
            SegmentedButton<ZoomFocusMode>(
              segments: <ButtonSegment<ZoomFocusMode>>[
                ButtonSegment(
                  value: ZoomFocusMode.followCursor,
                  icon: const Icon(Icons.mouse_outlined, size: 16),
                  label: Text(l10n.zoomFollowCursor),
                ),
                ButtonSegment(
                  value: ZoomFocusMode.fixedTarget,
                  icon: const Icon(
                    Icons.center_focus_strong_outlined,
                    size: 16,
                  ),
                  label: Text(l10n.zoomFixedTarget),
                ),
              ],
              selected: <ZoomFocusMode>{segment.focusMode},
              onSelectionChanged: (next) {
                if (next.isEmpty) return;
                editor.setSegmentFocusMode(segment, mode: next.first);
              },
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            if (showHint) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: l10n.zoomCursorStaticHint,
                child: Icon(
                  Icons.info_outline,
                  size: 16,
                  color: theme.colorScheme.outline,
                  key: const Key('zoom_behavior_floating_toolbar_static_hint'),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.zoomBehaviorDismissTooltip,
              child: InkWell(
                key: const Key('zoom_behavior_floating_toolbar_close'),
                customBorder: const CircleBorder(),
                onTap: () {
                  setState(() {
                    _dismissedForSegmentId = segment.id;
                  });
                  editor.clearSelection();
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
