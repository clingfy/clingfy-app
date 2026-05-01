import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_control_box.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

/// Cross-platform text field wrapper.
///
/// - macOS: `MacosTextField`
/// - fallback: Material `TextFormField`
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.placeholder,
    this.keyboardType,
    this.onSubmitted,
    this.onChanged,
    this.minWidth,
    this.maxWidth,
    this.expand = false,
    this.heightMac,
    this.heightWin,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? placeholder;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final double? minWidth;
  final double? maxWidth;
  final bool expand;
  final double? heightMac;
  final double? heightWin;

  @override
  Widget build(BuildContext context) {
    final mac = isMac();
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final metrics = context.shellMetricsOrNull;
    final effectiveMinWidth = minWidth ??
        metrics?.sidebarControlMinWidth ??
        AppSidebarTokens.controlMinWidth;
    final effectiveMaxWidth = maxWidth ??
        metrics?.sidebarControlMaxWidth ??
        AppSidebarTokens.controlMaxWidth;
    final effectiveHeightMac = heightMac ??
        metrics?.sidebarControlHeightMac ??
        AppSidebarTokens.controlHeightMac;
    final effectiveHeightWin = heightWin ??
        metrics?.sidebarControlHeightDefault ??
        AppSidebarTokens.controlHeightDefault;
    final inputTheme = theme.inputDecorationTheme;
    final fillColor = inputTheme.fillColor ?? theme.colorScheme.surface;
    final enabledBorder =
        (inputTheme.enabledBorder ?? inputTheme.border)
            as OutlineInputBorder? ??
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: theme.dividerColor),
        );
    final focusedBorder =
        inputTheme.focusedBorder as OutlineInputBorder? ??
        enabledBorder.copyWith(
          borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.4),
        );
    final decoration = BoxDecoration(
      color: fillColor,
      borderRadius: enabledBorder.borderRadius.resolve(
        Directionality.of(context),
      ),
      border: Border.all(
        color: enabledBorder.borderSide.color,
        width: enabledBorder.borderSide.width,
      ),
    );
    final focusedDecoration = decoration.copyWith(
      border: Border.all(
        color: focusedBorder.borderSide.color,
        width: focusedBorder.borderSide.width,
      ),
    );
    if (mac) {
      return AppControlBox(
        minWidth: effectiveMinWidth,
        maxWidth: effectiveMaxWidth,
        expand: expand,
        height: effectiveHeightMac,
        child: MacosTextField(
          controller: controller,
          enabled: enabled,
          decoration: decoration,
          focusedDecoration: focusedDecoration,
          placeholder: placeholder,
          keyboardType: keyboardType,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      );
    }

    return AppControlBox(
      minWidth: effectiveMinWidth,
      maxWidth: effectiveMaxWidth,
      expand: expand,
      height: mac ? effectiveHeightMac : effectiveHeightWin,
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
        ).copyWith(hintText: placeholder),
        keyboardType: keyboardType,
        onFieldSubmitted: onSubmitted,
        onChanged: onChanged,
      ),
    );
  }
}
