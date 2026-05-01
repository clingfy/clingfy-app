import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

enum AppButtonVariant { primary, secondary }

enum AppButtonSize { regular, compact }

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    this.label,
    required this.onPressed,
    this.icon,
    this.child,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.regular,
    this.expand = false,
    this.minWidth,
  }) : assert(label != null || child != null);

  final String? label;
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final bool expand;
  final double? minWidth;

  static PushButton macos({
    Key? key,
    required Widget child,
    required VoidCallback? onPressed,
    AppButtonVariant variant = AppButtonVariant.primary,
    AppButtonSize size = AppButtonSize.regular,
  }) {
    final isCompact = size == AppButtonSize.compact;
    return PushButton(
      key: key,
      controlSize: isCompact ? ControlSize.regular : ControlSize.large,
      secondary: variant == AppButtonVariant.secondary,
      onPressed: onPressed,
      child: child,
    );
  }

  Widget _buildChild() {
    if (child != null) {
      return child!;
    }

    final resolvedLabel = label!;
    // if (icon == null) {
    //   return Text(resolvedLabel, maxLines: 1, overflow: TextOverflow.ellipsis);
    // }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) Icon(icon, size: 16),
        if (icon != null) const SizedBox(width: 8),
        Flexible(child: Text(resolvedLabel, overflow: TextOverflow.ellipsis)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = size == AppButtonSize.compact;
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final metrics = context.shellMetricsOrNull;
    final minHeight = isCompact
        ? metrics?.sidebarCompactButtonHeight ??
            AppSidebarTokens.compactButtonHeight
        : 40.0;
    final horizontalPadding = isCompact ? spacing.md : spacing.lg;
    final resolvedChild = _buildChild();
    // final hasMacosTheme = MacosTheme.maybeOf(context) != null;

    Widget button;

    final theme = Theme.of(context);
    // final hasMacosTheme = MacosTheme.maybeOf(context) != null;
    // final accentColor = theme.colorScheme.primary;
    // if (isMac() && hasMacosTheme) {
    //   button = PushButton(
    //     color: accentColor,
    //     controlSize: isCompact ? ControlSize.regular : ControlSize.large,
    //     secondary: variant == AppButtonVariant.secondary,
    //     onPressed: onPressed,
    //     child: child,
    //   );
    // } else
    {
      final style =
          (variant == AppButtonVariant.primary
                  ? ElevatedButton.styleFrom()
                  : OutlinedButton.styleFrom())
              .copyWith(
                minimumSize: WidgetStatePropertyAll(
                  Size(minWidth ?? 0, minHeight),
                ),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: isCompact ? spacing.sm : spacing.sm + 2,
                  ),
                ),
                visualDensity: const VisualDensity(
                  horizontal: -1,
                  vertical: -1,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll(typography.button),
                backgroundColor: WidgetStatePropertyAll(
                  (variant == AppButtonVariant.primary
                      ? theme.primaryColor
                      : theme.colorScheme.surfaceContainerHighest),
                ),
              );

      button = variant == AppButtonVariant.primary
          ? ElevatedButton(
              onPressed: onPressed,
              style: style,
              child: resolvedChild,
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: style,
              child: resolvedChild,
            );
    }

    if (minWidth != null) {
      button = ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth!),
        child: button,
      );
    }

    if (expand) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }
}
