import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class AppInlineInfoTooltip extends StatelessWidget {
  const AppInlineInfoTooltip({
    super.key,
    required this.message,
    this.size = 16,
    this.color,
  });

  final String message;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = Icon(
      CupertinoIcons.info_circle,
      size: size,
      color:
          color ??
          theme.textTheme.bodySmall?.color ??
          theme.colorScheme.outline,
      semanticLabel: message,
    );

    if (macos.MacosTheme.maybeOf(context) != null) {
      return macos.MacosTooltip(
        message: message,
        excludeFromSemantics: true,
        child: icon,
      );
    }

    return Tooltip(message: message, excludeFromSemantics: true, child: icon);
  }
}
