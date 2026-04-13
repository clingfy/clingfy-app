import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';

/// Desktop-style settings row: label on the left, control on the right.
///
/// If the available width is small, it stacks into a column (label above control).
class AppFormRow extends StatelessWidget {
  const AppFormRow({
    super.key,
    required this.control,
    this.label,
    this.infoTooltip,
    this.labelTrailing,
    this.helperText,
    this.labelWidth = AppSidebarTokens.labelWidth,
    this.stackBreakpoint = AppSidebarTokens.stackBreakpoint,
    this.gap = AppSidebarTokens.controlGap,
  });

  final String? label;
  final String? infoTooltip;
  final Widget? labelTrailing;
  final String? helperText;
  final Widget control;

  /// Fixed width of the label column when not stacked.
  final double labelWidth;

  /// Below this width, the row becomes a column.
  final double stackBreakpoint;

  /// Horizontal spacing between label and control when not stacked.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final labelStyle = AppSidebarTokens.rowTitleStyle(theme);
    final helperStyle = AppSidebarTokens.helperStyle(theme);
    final hasHelperText = helperText != null && helperText!.isNotEmpty;
    final hasInfoTooltip = infoTooltip != null && infoTooltip!.isNotEmpty;

    Widget buildLabelLine() {
      final labelCluster = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: Text(label!, style: labelStyle)),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: hasInfoTooltip
                ? Row(
                    key: ValueKey(infoTooltip),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: spacing.xs),
                      AppInlineInfoTooltip(message: infoTooltip!),
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('no_info_tooltip')),
          ),
        ],
      );

      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: labelCluster),
          if (labelTrailing != null) ...[
            SizedBox(width: spacing.xs),
            labelTrailing!,
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final stacked = c.maxWidth < stackBreakpoint;

        // Control-only row.
        if (label == null) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
            child: Align(
              alignment: stacked ? Alignment.centerLeft : Alignment.centerRight,
              child: control,
            ),
          );
        }

        if (stacked) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildLabelLine(),
                if (hasHelperText) ...[
                  SizedBox(height: spacing.xs),
                  Text(helperText!, style: helperStyle),
                ],
                SizedBox(height: spacing.sm),
                control,
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: labelWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    buildLabelLine(),
                    if (hasHelperText) ...[
                      SizedBox(height: spacing.xs),
                      Text(helperText!, style: helperStyle),
                    ],
                  ],
                ),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: control),
              ),
            ],
          ),
        );
      },
    );
  }
}
