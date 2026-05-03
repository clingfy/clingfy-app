import 'dart:async';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/core/zoom/zoom_focus_heuristic.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';

/// Inspector strip that exposes zoom-behavior controls for the
/// currently-selected zoom segment. Renders nothing when no segment is
/// selected or the editor cannot single-edit (multi-selection /
/// disabled).
///
/// Listens to [editor] directly — drop it anywhere a [ZoomEditorController]
/// is in scope.
class ZoomSegmentBehaviorInspector extends StatefulWidget {
  const ZoomSegmentBehaviorInspector({
    super.key,
    required this.editor,
    required this.nativeBridge,
    this.sessionId,
  });

  final ZoomEditorController? editor;
  final NativeBridge nativeBridge;
  final String? sessionId;

  @override
  State<ZoomSegmentBehaviorInspector> createState() =>
      _ZoomSegmentBehaviorInspectorState();
}

class _ZoomSegmentBehaviorInspectorState
    extends State<ZoomSegmentBehaviorInspector> {
  // Cached "motion is too small" answer per segment id. `null` while the
  // bridge query is in flight or has not run yet for that segment id.
  final Map<String, bool> _staticHintBySegmentId = <String, bool>{};
  String? _inFlightSegmentId;

  @override
  void initState() {
    super.initState();
    widget.editor?.addListener(_onEditorChanged);
    _maybeQueryHintForSelection();
  }

  @override
  void didUpdateWidget(covariant ZoomSegmentBehaviorInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) {
      oldWidget.editor?.removeListener(_onEditorChanged);
      widget.editor?.addListener(_onEditorChanged);
      _staticHintBySegmentId.clear();
      _inFlightSegmentId = null;
      _maybeQueryHintForSelection();
    }
  }

  @override
  void dispose() {
    widget.editor?.removeListener(_onEditorChanged);
    super.dispose();
  }

  void _onEditorChanged() {
    _maybeQueryHintForSelection();
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
      // Channel disappeared between the capabilities probe and this
      // call — bail out silently. The next selection will not retry.
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
    // Hide the whole behavior inspector when the native backend cannot
    // honor fixedTarget — exposing a toggle that silently does nothing
    // is worse UX than not showing it at all.
    if (!editor.capabilities.fixedTargetPreview) {
      return const SizedBox.shrink();
    }
    if (!editor.canSingleEdit) return const SizedBox.shrink();
    final segment = editor.primarySelectedSegment;
    if (segment == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isFollow = segment.focusMode == ZoomFocusMode.followCursor;
    final showHint =
        isFollow && (_staticHintBySegmentId[segment.id] ?? false);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                l10n.zoomBehavior,
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<ZoomFocusMode>(
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
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ],
          ),
          if (showHint) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.zoomCursorStaticHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
