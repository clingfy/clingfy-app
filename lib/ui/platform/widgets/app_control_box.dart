import 'dart:math' as math;

import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';

/// Shared control wrapper for sidebar fields.
///
/// It standardizes width and height across dropdowns, text fields, and other
/// field-like controls.
class AppControlBox extends StatelessWidget {
  const AppControlBox({
    super.key,
    required this.child,
    this.expand = false,
    this.minWidth = AppSidebarTokens.controlMinWidth,
    this.maxWidth = AppSidebarTokens.controlMaxWidth,
    this.height = AppSidebarTokens.controlHeightDefault,
    this.alignment = Alignment.centerRight,
  });

  final Widget child;
  final bool expand;
  final double minWidth;
  final double maxWidth;
  final double height;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : maxWidth;
        final effectiveMax = math.min(maxWidth, available);
        final effectiveMin = math.min(minWidth, effectiveMax);

        final box = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: expand ? effectiveMax : effectiveMin,
            // maxWidth: effectiveMax,
          ),
          child: SizedBox(width: double.infinity, height: height, child: child),
        );

        if (expand) {
          return box;
        }

        return Align(alignment: alignment, child: box);
      },
    );
  }
}
