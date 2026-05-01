import 'dart:math' as math;

import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
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
    this.minWidth,
    this.maxWidth,
    this.height,
    this.alignment = Alignment.centerRight,
  });

  final Widget child;
  final bool expand;
  final double? minWidth;
  final double? maxWidth;
  final double? height;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final metrics = context.shellMetricsOrNull;
    final effectiveMinFallback = minWidth ??
        metrics?.sidebarControlMinWidth ??
        AppSidebarTokens.controlMinWidth;
    final effectiveMaxFallback = maxWidth ??
        metrics?.sidebarControlMaxWidth ??
        AppSidebarTokens.controlMaxWidth;
    final effectiveHeight = height ??
        metrics?.sidebarControlHeightDefault ??
        AppSidebarTokens.controlHeightDefault;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : effectiveMaxFallback;
        final effectiveMax = math.min(effectiveMaxFallback, available);
        final effectiveMin = math.min(effectiveMinFallback, effectiveMax);

        final box = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: expand ? effectiveMax : effectiveMin,
            // maxWidth: effectiveMax,
          ),
          child: SizedBox(
            width: double.infinity,
            height: effectiveHeight,
            child: child,
          ),
        );

        if (expand) {
          return box;
        }

        return Align(alignment: alignment, child: box);
      },
    );
  }
}
