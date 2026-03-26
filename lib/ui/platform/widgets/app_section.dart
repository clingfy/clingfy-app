import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';

/// Lightweight settings section used across platforms.
///
/// Renders an optional title row with trailing content above the section body.
class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    this.title,
    required this.child,
    this.infoTooltip,
    this.trailing,
    this.titleUppercase = true,
    this.titleSpacing = AppSidebarTokens.rowGap,
  });

  final String? title;
  final Widget child;
  final String? infoTooltip;
  final Widget? trailing;

  /// Uppercase section titles match macOS/desktop preferences for sidebar panels.
  final bool titleUppercase;

  /// Vertical spacing between the title row and content.
  final double titleSpacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final headerStyle = AppSidebarTokens.sectionHeaderStyle(theme);
    if (title == null || title!.isEmpty) {
      return child;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      titleUppercase ? title!.toUpperCase() : title!,
                      style: headerStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (infoTooltip != null && infoTooltip!.isNotEmpty) ...[
                    SizedBox(width: spacing.xs),
                    AppInlineInfoTooltip(
                      message: infoTooltip!,
                      color: headerStyle.color,
                      size: 14,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[SizedBox(width: spacing.sm), trailing!],
          ],
        ),
        SizedBox(height: titleSpacing),
        child,
      ],
    );
  }
}
