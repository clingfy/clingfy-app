import 'package:flutter/material.dart';

class PaneDividerHandle extends StatelessWidget {
  const PaneDividerHandle({
    super.key,
    required this.onHorizontalDragStart,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
    this.isActive = false,
  });

  static const double hitWidth = 12;
  static const double visibleThickness = 1.5;
  static const double visibleHeight = 34;

  final GestureDragStartCallback onHorizontalDragStart;
  final GestureDragUpdateCallback onHorizontalDragUpdate;
  final GestureDragEndCallback onHorizontalDragEnd;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.dividerColor.withValues(alpha: 0.28);
    final activeColor = theme.colorScheme.onSurface.withValues(alpha: 0.56);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: onHorizontalDragStart,
        onHorizontalDragUpdate: onHorizontalDragUpdate,
        onHorizontalDragEnd: onHorizontalDragEnd,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            width: visibleThickness,
            height: visibleHeight,
            decoration: BoxDecoration(
              color: isActive ? activeColor : baseColor,
              borderRadius: BorderRadius.circular(visibleThickness),
            ),
          ),
        ),
      ),
    );
  }
}
