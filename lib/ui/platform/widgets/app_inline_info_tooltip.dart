import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

const _lightInfoTooltipColor = Color(0xFF6E6E73);
const _darkInfoTooltipColor = Color(0xFF8E8E93);

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
    final defaultColor = theme.brightness == Brightness.dark
        ? _darkInfoTooltipColor
        : _lightInfoTooltipColor;
    return Tooltip(
      message: message,
      excludeFromSemantics: true,
      child: Semantics(
        label: message,
        child: Icon(
          CupertinoIcons.info_circle,
          size: size,
          color: color ?? defaultColor,
          semanticLabel: message,
        ),
      ),
    );
  }
}
