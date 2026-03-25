import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ZoomTrack extends StatefulWidget {
  final List<ZoomSegment> segments;
  final int durationMs;
  final int positionMs;
  final ValueChanged<int>? onQuickSeek;
  final ZoomEditorController? editorController;
  final VoidCallback? onFocusRequested;

  // Optional externally provided selection state. Falls back to editor state.
  final Set<String>? selectedSegmentIds;
  final String? primarySelectedSegmentId;
  final bool? canSingleEdit;

  const ZoomTrack({
    super.key,
    required this.segments,
    required this.durationMs,
    required this.positionMs,
    this.onQuickSeek,
    this.editorController,
    this.onFocusRequested,
    this.selectedSegmentIds,
    this.primarySelectedSegmentId,
    this.canSingleEdit,
  });

  @override
  State<ZoomTrack> createState() => _ZoomTrackState();
}

enum _TrackDragMode { none, addDraft, move, trimLeft, trimRight, bandSelect }

class _ZoomTrackState extends State<ZoomTrack> {
  MouseCursor _cursor = SystemMouseCursors.click;
  static const double _handleTolerancePx = 10.0;

  _TrackDragMode _dragMode = _TrackDragMode.none;
  bool _dragConsumed = false;
  double? _bandStartDx;
  double? _bandCurrentDx;
  Offset? _lastHoverLocalPosition;

  bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  bool get _isToggleModifierPressed {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return _isMacOS
        ? (keys.contains(LogicalKeyboardKey.metaLeft) ||
              keys.contains(LogicalKeyboardKey.metaRight))
        : (keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight));
  }

  bool get _isRangeModifierPressed {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  Set<String> get _selectedIds {
    if (widget.selectedSegmentIds != null) {
      return widget.selectedSegmentIds!;
    }
    return widget.editorController?.selectedSegmentIds ?? const <String>{};
  }

  String? get _primarySelectedId {
    return widget.primarySelectedSegmentId ??
        widget.editorController?.primarySelectedSegmentId;
  }

  bool get _canSingleEdit {
    return widget.canSingleEdit ??
        (widget.editorController?.canSingleEdit ?? false);
  }

  void _requestFocus() {
    widget.onFocusRequested?.call();
  }

  int _localXToMs(double localX, double totalWidth) {
    final percent = (localX / totalWidth).clamp(0.0, 1.0);
    return (percent * widget.durationMs).round();
  }

  int _handleToleranceMs(double totalWidth) {
    final toleranceMs = ((_handleTolerancePx / totalWidth) * widget.durationMs)
        .round();
    return toleranceMs < 1 ? 1 : toleranceMs;
  }

  void _resetBandSelectionState() {
    _bandStartDx = null;
    _bandCurrentDx = null;
  }

  TrimHandle? _hitHandleForSelectedSegment({
    required ZoomSegment segment,
    required double localX,
    required double totalWidth,
    required ZoomEditorController editor,
  }) {
    if (!editor.canSingleEdit) return null;
    if (editor.primarySelectedSegment?.id != segment.id) return null;

    final x1 = (segment.startMs / widget.durationMs) * totalWidth;
    final x2 = (segment.endMs / widget.durationMs) * totalWidth;

    if ((localX - x1).abs() <= _handleTolerancePx) return TrimHandle.left;
    if ((localX - x2).abs() <= _handleTolerancePx) return TrimHandle.right;
    return null;
  }

  int? _selectionBandStartMs(double totalWidth) {
    if (_dragMode != _TrackDragMode.bandSelect || _bandStartDx == null) {
      return null;
    }
    return _localXToMs(_bandStartDx!, totalWidth);
  }

  int? _selectionBandEndMs(double totalWidth) {
    if (_dragMode != _TrackDragMode.bandSelect || _bandCurrentDx == null) {
      return null;
    }
    return _localXToMs(_bandCurrentDx!, totalWidth);
  }

  void _applyCursor(MouseCursor nextCursor) {
    if (_cursor != nextCursor) {
      setState(() => _cursor = nextCursor);
    }
  }

  void _restoreCursorAfterGesture() {
    final lastHoverLocalPosition = _lastHoverLocalPosition;
    if (lastHoverLocalPosition == null) {
      _applyCursor(SystemMouseCursors.click);
      return;
    }
    _updateCursorForLocalPosition(lastHoverLocalPosition.dx);
  }

  void _updateCursor(PointerEvent event) {
    _lastHoverLocalPosition = event.localPosition;
    _updateCursorForLocalPosition(event.localPosition.dx);
  }

  void _updateCursorForLocalPosition(double localX) {
    final editor = widget.editorController;
    if (editor == null) {
      _applyCursor(SystemMouseCursors.click);
      return;
    }

    if (_dragMode == _TrackDragMode.bandSelect) {
      _applyCursor(SystemMouseCursors.precise);
      return;
    }

    if (_dragMode == _TrackDragMode.move) {
      _applyCursor(SystemMouseCursors.grabbing);
      return;
    }

    if (_dragMode == _TrackDragMode.trimLeft ||
        _dragMode == _TrackDragMode.trimRight) {
      _applyCursor(SystemMouseCursors.resizeLeftRight);
      return;
    }

    if (editor.addModeEnabled) {
      _applyCursor(SystemMouseCursors.precise);
      return;
    }

    final box = context.findRenderObject() as RenderBox;
    final totalWidth = box.size.width;
    final ms = _localXToMs(localX, totalWidth);
    final toleranceMs = _handleToleranceMs(totalWidth);
    final hit = editor.hitTest(ms, toleranceMs: toleranceMs);

    MouseCursor nextCursor = SystemMouseCursors.click;
    if (hit != null) {
      final isPrimary = _primarySelectedId == hit.id;
      if (!_canSingleEdit) {
        nextCursor = SystemMouseCursors.click;
      } else {
        if (isPrimary) {
          final handle = _hitHandleForSelectedSegment(
            segment: hit,
            localX: localX,
            totalWidth: totalWidth,
            editor: editor,
          );
          if (handle != null) {
            nextCursor = SystemMouseCursors.resizeLeftRight;
          } else {
            nextCursor = SystemMouseCursors.grab;
          }
        } else {
          nextCursor = SystemMouseCursors.click;
        }
      }
    }

    _applyCursor(nextCursor);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.durationMs <= 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final controlFill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.secondaryContainer;
    final accentColor = theme.colorScheme.primary;
    final editor = widget.editorController;
    final isAddMode = editor?.addModeEnabled ?? false;

    return MouseRegion(
      cursor: _cursor,
      onHover: _updateCursor,
      onExit: (_) {
        _lastHoverLocalPosition = null;
        _applyCursor(SystemMouseCursors.click);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: isAddMode || editor == null
            ? null
            : (details) {
                if (_dragConsumed) {
                  _dragConsumed = false;
                  return;
                }

                _requestFocus();

                final box = context.findRenderObject() as RenderBox;
                final tapMs = _localXToMs(
                  details.localPosition.dx,
                  box.size.width,
                );
                final toleranceMs = _handleToleranceMs(box.size.width);
                final hit = editor.hitTest(tapMs, toleranceMs: toleranceMs);
                final isRangeSelection = _isRangeModifierPressed;
                final isToggleSelection = _isToggleModifierPressed;

                if (hit == null) {
                  if (!isRangeSelection && !isToggleSelection) {
                    editor.clearSelection();
                  }
                  return;
                }

                if (isRangeSelection) {
                  editor.selectRangeTo(hit);
                } else if (isToggleSelection) {
                  editor.toggleSelection(hit);
                } else {
                  editor.selectOnly(hit);
                }
              },
        onDoubleTapDown: isAddMode || editor == null
            ? null
            : (details) {
                _requestFocus();
                final box = context.findRenderObject() as RenderBox;
                final tapMs = _localXToMs(
                  details.localPosition.dx,
                  box.size.width,
                );
                final toleranceMs = _handleToleranceMs(box.size.width);
                final hit = editor.hitTest(tapMs, toleranceMs: toleranceMs);
                if (hit == null) return;
                editor.selectOnly(hit);
                widget.onQuickSeek?.call(hit.startMs);
              },
        onPanStart: (details) {
          final box = context.findRenderObject() as RenderBox;
          final localX = details.localPosition.dx;
          final totalWidth = box.size.width;
          final ms = _localXToMs(localX, totalWidth);
          final toleranceMs = _handleToleranceMs(totalWidth);

          _dragMode = _TrackDragMode.none;
          _dragConsumed = false;

          final isRangeSelection = _isRangeModifierPressed;
          final isToggleSelection = _isToggleModifierPressed;

          _requestFocus();

          if (isAddMode) {
            _dragMode = _TrackDragMode.addDraft;
            _dragConsumed = true;
            _applyCursor(SystemMouseCursors.precise);
            editor?.updateDraft(ms, ms);
            return;
          }

          if (editor == null) return;
          final hit = editor.hitTest(ms, toleranceMs: toleranceMs);

          if (hit != null) {
            if (isRangeSelection) {
              editor.selectRangeTo(hit);
              return;
            }
            if (isToggleSelection) {
              editor.toggleSelection(hit);
              return;
            }

            if (editor.hasMultiSelection) {
              return;
            }

            if (editor.primarySelectedSegment?.id != hit.id) {
              editor.selectOnly(hit);
            }

            if (!editor.canSingleEdit) return;

            final handle = _hitHandleForSelectedSegment(
              segment: hit,
              localX: localX,
              totalWidth: totalWidth,
              editor: editor,
            );

            _dragConsumed = true;
            if (handle == TrimHandle.left) {
              _dragMode = _TrackDragMode.trimLeft;
              _applyCursor(SystemMouseCursors.resizeLeftRight);
              editor.beginTrimAt(ms, hit, TrimHandle.left);
            } else if (handle == TrimHandle.right) {
              _dragMode = _TrackDragMode.trimRight;
              _applyCursor(SystemMouseCursors.resizeLeftRight);
              editor.beginTrimAt(ms, hit, TrimHandle.right);
            } else {
              _dragMode = _TrackDragMode.move;
              _applyCursor(SystemMouseCursors.grabbing);
              editor.beginMoveAt(ms, hit);
            }
            return;
          }

          _dragMode = _TrackDragMode.bandSelect;
          _dragConsumed = true;
          _bandStartDx = localX;
          _bandCurrentDx = localX;
          _applyCursor(SystemMouseCursors.precise);
          editor.beginBandSelection(additive: isToggleSelection);

          setState(() {
            // Trigger band paint
          });
        },
        onPanUpdate: (details) {
          final editor = widget.editorController;
          if (editor == null) return;

          final box = context.findRenderObject() as RenderBox;
          final localX = details.localPosition.dx;
          final totalWidth = box.size.width;
          final currentMs = _localXToMs(localX, totalWidth);

          switch (_dragMode) {
            case _TrackDragMode.addDraft:
              final startMs = editor.draftSegment?.startMs ?? currentMs;
              editor.updateDraft(startMs, currentMs);
              break;
            case _TrackDragMode.trimLeft:
            case _TrackDragMode.trimRight:
              editor.updateTrimTo(currentMs);
              break;
            case _TrackDragMode.move:
              editor.updateMoveTo(currentMs);
              break;
            case _TrackDragMode.bandSelect:
              _bandCurrentDx = localX;
              final startDx = _bandStartDx ?? localX;
              final startMs = _localXToMs(startDx, totalWidth);
              editor.updateBandSelection(startMs, currentMs);
              setState(() {
                // Trigger band paint
              });
              break;
            case _TrackDragMode.none:
              break;
          }
        },
        onPanEnd: (_) {
          switch (_dragMode) {
            case _TrackDragMode.addDraft:
              editor?.commitDraft();
              break;
            case _TrackDragMode.trimLeft:
            case _TrackDragMode.trimRight:
              editor?.commitTrim();
              break;
            case _TrackDragMode.move:
              editor?.commitMove();
              break;
            case _TrackDragMode.bandSelect:
              final localStart = _bandStartDx;
              final localEnd = _bandCurrentDx;
              if (editor != null &&
                  localStart != null &&
                  localEnd != null &&
                  context.mounted) {
                final box = context.findRenderObject() as RenderBox;
                final startMs = _localXToMs(localStart, box.size.width);
                final endMs = _localXToMs(localEnd, box.size.width);
                editor.updateBandSelection(startMs, endMs);
              }
              editor?.endBandSelection();
              break;
            case _TrackDragMode.none:
              break;
          }

          final shouldRepaintBand = _dragMode == _TrackDragMode.bandSelect;
          _dragMode = _TrackDragMode.none;
          _dragConsumed = false;
          _resetBandSelectionState();
          _restoreCursorAfterGesture();
          if (shouldRepaintBand) {
            setState(() {
              // Clear band paint
            });
          }
        },
        onPanCancel: () {
          final shouldRepaintBand = _dragMode == _TrackDragMode.bandSelect;
          if (_dragMode == _TrackDragMode.trimLeft ||
              _dragMode == _TrackDragMode.trimRight) {
            editor?.cancelTrim();
          } else if (_dragMode == _TrackDragMode.move) {
            editor?.cancelMove();
          } else if (_dragMode == _TrackDragMode.bandSelect) {
            editor?.endBandSelection();
          }
          _dragMode = _TrackDragMode.none;
          _dragConsumed = false;
          _resetBandSelectionState();
          _restoreCursorAfterGesture();
          if (shouldRepaintBand) {
            setState(() {
              // Clear band paint
            });
          }
        },
        child: Container(
          key: const Key('zoom_track_shell'),
          height: chrome.inspectorTabHeight,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: controlFill,
            borderRadius: BorderRadius.circular(chrome.controlRadius),
            border: Border.all(color: tokens.panelBorder),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(chrome.controlRadius),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  painter: ZoomTrackPainter(
                    segments: widget.segments,
                    draftSegment: editor?.draftSegment,
                    durationMs: widget.durationMs,
                    positionMs: widget.positionMs,
                    accentColor: accentColor,
                    trackColor: tokens.timelineTrack,
                    tickColor: tokens.timelineTick,
                    selectedSegmentIds: _selectedIds,
                    primarySelectedSegmentId: _primarySelectedId,
                    selectionBandStartMs: _selectionBandStartMs(
                      constraints.maxWidth,
                    ),
                    selectionBandEndMs: _selectionBandEndMs(
                      constraints.maxWidth,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class ZoomTrackPainter extends CustomPainter {
  final List<ZoomSegment> segments;
  final ZoomSegment? draftSegment;
  final int durationMs;
  final int positionMs;
  final Color accentColor;
  final Color trackColor;
  final Color tickColor;
  final Set<String> selectedSegmentIds;
  final String? primarySelectedSegmentId;
  final int? selectionBandStartMs;
  final int? selectionBandEndMs;

  ZoomTrackPainter({
    required this.segments,
    this.draftSegment,
    required this.durationMs,
    required this.positionMs,
    required this.accentColor,
    required this.trackColor,
    required this.tickColor,
    required this.selectedSegmentIds,
    required this.primarySelectedSegmentId,
    required this.selectionBandStartMs,
    required this.selectionBandEndMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;

    const laneVerticalInset = 2.0;
    final laneRect = Rect.fromLTWH(
      0,
      laneVerticalInset,
      size.width,
      size.height - (laneVerticalInset * 2),
    );
    final paint = Paint()..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(laneRect, const Radius.circular(5)),
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.fill,
    );

    if (selectionBandStartMs != null && selectionBandEndMs != null) {
      final lower = selectionBandStartMs! < selectionBandEndMs!
          ? selectionBandStartMs!
          : selectionBandEndMs!;
      final upper = selectionBandStartMs! > selectionBandEndMs!
          ? selectionBandStartMs!
          : selectionBandEndMs!;
      final x1 = (lower / durationMs) * size.width;
      final x2 = (upper / durationMs) * size.width;
      final bandRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x1, 2, x2, size.height - 2),
        const Radius.circular(6),
      );
      canvas.drawRRect(
        bandRect,
        Paint()
          ..color = accentColor.withValues(alpha: 0.1)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        bandRect,
        Paint()
          ..color = accentColor.withValues(alpha: 0.58)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }

    for (final seg in segments) {
      final isManual = seg.source == 'manual';
      final isActive = positionMs >= seg.startMs && positionMs < seg.endMs;
      final isSelected = selectedSegmentIds.contains(seg.id);
      final isPrimary = primarySelectedSegmentId == seg.id;

      if (isPrimary) {
        paint.color = accentColor.withValues(alpha: 0.9);
      } else if (isSelected) {
        paint.color = accentColor.withValues(alpha: 0.74);
      } else if (isManual) {
        paint.color = isActive
            ? accentColor.withValues(alpha: 0.7)
            : accentColor.withValues(alpha: 0.52);
      } else {
        paint.color = isActive
            ? accentColor.withValues(alpha: 0.42)
            : accentColor.withValues(alpha: 0.2);
      }

      final x1 = (seg.startMs / durationMs) * size.width;
      final x2 = (seg.endMs / durationMs) * size.width;
      final visualHeight = isPrimary
          ? laneRect.height
          : isSelected
          ? laneRect.height - 2
          : isManual
          ? laneRect.height - 4
          : laneRect.height - 8;
      final segmentTop = laneRect.center.dy - (visualHeight / 2);
      final segmentRight = x2 <= x1 ? x1 + 2 : x2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x1, segmentTop, segmentRight, segmentTop + visualHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, paint);

      if (isActive) {
        final glowPaint = Paint()
          ..color = paint.color.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
        canvas.drawRRect(rect, glowPaint);
      }

      if (isPrimary) {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = tickColor.withValues(alpha: 0.92)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
        final gripPaint = Paint()..color = tickColor.withValues(alpha: 0.88);
        final gripHeight = rect.height - 6;
        final gripTop = rect.top + 3;
        final leftGrip = RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + 3, gripTop, 2.5, gripHeight),
          const Radius.circular(999),
        );
        final rightGrip = RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.right - 5.5, gripTop, 2.5, gripHeight),
          const Radius.circular(999),
        );
        canvas.drawRRect(leftGrip, gripPaint);
        canvas.drawRRect(rightGrip, gripPaint);
      } else if (isSelected) {
        final outlinePaint = Paint()
          ..color = tickColor.withValues(alpha: 0.62)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1;
        canvas.drawRRect(rect, outlinePaint);
      } else if (isManual) {
        final handlePaint = Paint()..color = tickColor.withValues(alpha: 0.28);
        final gripHeight = rect.height - 8;
        final gripTop = rect.top + 4;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.left + 2.5, gripTop, 1.8, gripHeight),
            const Radius.circular(999),
          ),
          handlePaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.right - 4.3, gripTop, 1.8, gripHeight),
            const Radius.circular(999),
          ),
          handlePaint,
        );
      }
    }

    if (draftSegment != null) {
      final x1 = (draftSegment!.startMs / durationMs) * size.width;
      final x2 = (draftSegment!.endMs / durationMs) * size.width;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          x1,
          laneRect.center.dy - ((laneRect.height - 2) / 2),
          x2 <= x1 ? x1 + 2 : x2,
          laneRect.center.dy + ((laneRect.height - 2) / 2),
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accentColor.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accentColor.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ZoomTrackPainter oldDelegate) {
    return oldDelegate.segments != segments ||
        oldDelegate.draftSegment != draftSegment ||
        oldDelegate.durationMs != durationMs ||
        oldDelegate.positionMs != positionMs ||
        oldDelegate.primarySelectedSegmentId != primarySelectedSegmentId ||
        oldDelegate.selectionBandStartMs != selectionBandStartMs ||
        oldDelegate.selectionBandEndMs != selectionBandEndMs ||
        !setEquals(oldDelegate.selectedSegmentIds, selectedSegmentIds);
  }
}
