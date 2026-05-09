import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/theme/app_theme.dart';

class AppSidebarRailButton extends StatelessWidget {
  const AppSidebarRailButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.iconSize,
    this.buttonSize,
    this.semanticsLabel,
  });

  final Key? buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;
  final double? iconSize;
  final double? buttonSize;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = context.shellMetricsOrNull;
    final effectiveIconSize = iconSize ?? metrics?.railIconSize ?? 28;
    final effectiveButtonSize = buttonSize ?? metrics?.railButtonSize ?? 40;
    final activeColor = theme.colorScheme.onSurface;
    final inactiveColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.78,
    );

    return Semantics(
      button: true,
      label: semanticsLabel ?? tooltip,
      selected: selected,
      child: IconButton(
        key: buttonKey,
        onPressed: onTap,
        tooltip: tooltip,
        isSelected: selected,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: effectiveButtonSize,
          height: effectiveButtonSize,
        ),
        splashRadius: effectiveButtonSize / 2,
        iconSize: effectiveIconSize,
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected) ||
                states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused) ||
                states.contains(WidgetState.pressed)) {
              return activeColor;
            }
            return inactiveColor;
          }),
          overlayColor: WidgetStatePropertyAll(
            activeColor.withValues(alpha: 0.08),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                theme.appEditorChrome.controlRadius,
              ),
            ),
          ),
        ),
        icon: Icon(icon, semanticLabel: semanticsLabel ?? tooltip),
      ),
    );
  }
}
