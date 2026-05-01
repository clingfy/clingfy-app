import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/material.dart';

class AppPaneHeader extends StatelessWidget {
  const AppPaneHeader({
    super.key,
    required this.title,
    this.headerKey,
    this.leading,
    this.trailingKey,
    this.trailingTooltip,
    this.trailingIcon,
    this.onTrailingPressed,
    this.isCompact = false,
  });

  final String title;
  final Key? headerKey;
  final Widget? leading;
  final Key? trailingKey;
  final String? trailingTooltip;
  final IconData? trailingIcon;
  final VoidCallback? onTrailingPressed;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final metrics = context.shellMetricsOrNull;
    final defaultTop = metrics?.paneHeaderTopPadding ??
        AppSidebarTokens.headerTopPadding;
    final defaultBottom = metrics?.paneHeaderBottomPadding ??
        AppSidebarTokens.headerBottomPadding;
    final headerTopPadding = isCompact ? 10.0 : defaultTop;
    final headerBottomPadding = isCompact ? 8.0 : defaultBottom;
    final horizontalPadding = metrics?.sidebarContentHorizontalPadding ??
        AppSidebarTokens.contentHorizontalPadding;
    final titleFontSize = metrics?.paneHeaderTitleSize ?? 16;
    final titleStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: titleFontSize,
        );

    return Container(
      key: headerKey,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        headerTopPadding,
        horizontalPadding,
        headerBottomPadding,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          if (onTrailingPressed != null && trailingIcon != null)
            IconButton(
              key: trailingKey,
              onPressed: onTrailingPressed,
              tooltip: trailingTooltip,
              visualDensity: VisualDensity.compact,
              splashRadius: 16,
              iconSize: 18,
              style: IconButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
              icon: Icon(trailingIcon),
            ),
        ],
      ),
    );
  }
}
