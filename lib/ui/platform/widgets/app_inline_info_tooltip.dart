import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

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
    return Tooltip(
      message: message,
      excludeFromSemantics: true,
      child: Semantics(
        label: message,
        child: Icon(
          CupertinoIcons.info_circle,
          size: size,
          color:
              color ??
              theme.textTheme.bodySmall?.color ??
              theme.colorScheme.outline,
          semanticLabel: message,
        ),
      ),
    );
  }
}
