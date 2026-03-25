import 'dart:math' as math;

import 'package:clingfy/ui/platform/widgets/app_control_box.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:fluent_ui/fluent_ui.dart' as fluent;

class PlatformMenuItem<T> {
  final T value;
  final String label;
  const PlatformMenuItem({required this.value, required this.label});
}

class PlatformDropdown<T> extends StatelessWidget {
  const PlatformDropdown({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.labelText,

    // Layout tuning (for AppFormRow alignment)
    this.minWidth = AppSidebarTokens.controlMinWidth,
    this.maxWidth = AppSidebarTokens.controlMaxWidth,
    this.expand = false,

    // Heights
    this.heightMac = AppSidebarTokens.controlHeightMac,
    this.heightWin =
        AppSidebarTokens.controlHeightDefault, // avoid fluent overflow
  });

  final List<PlatformMenuItem<T>> items;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final String? labelText;

  final double minWidth;
  final double maxWidth;
  final bool expand;
  final double heightMac;
  final double heightWin;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).appTypography.body;
    final bool mac = isMac();
    final double h = mac ? heightMac : heightWin;

    // Clamp min/max based on available width before handing layout to
    // AppControlBox so all field-like controls follow the same sizing system.
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : maxWidth;
        final effectiveMax = math.min(maxWidth, available);
        final effectiveMin = math.min(minWidth, effectiveMax);
        final buttonLabelWidth = math.max(0.0, effectiveMax - 40);

        Widget labelWidget(String label, {double? width}) {
          final text = Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          );
          if (width == null) {
            return text;
          }
          return SizedBox(
            width: width,
            child: Align(alignment: Alignment.centerLeft, child: text),
          );
        }

        final Widget control = mac
            ? macos.MacosPopupButton<T>(
                value: value,
                selectedItemBuilder: (context) => items
                    .map((e) => labelWidget(e.label, width: buttonLabelWidth))
                    .toList(),
                onChanged: onChanged,
                items: items
                    .map(
                      (e) => macos.MacosPopupMenuItem<T>(
                        value: e.value,
                        child: labelWidget(e.label),
                      ),
                    )
                    .toList(),
                hint: labelText == null
                    ? null
                    : labelWidget(labelText!, width: buttonLabelWidth),
              )
            : fluent.ComboBox<T>(
                isExpanded: true,
                value: value,
                onChanged: onChanged,
                items: items
                    .map(
                      (e) => fluent.ComboBoxItem<T>(
                        value: e.value,
                        child: labelWidget(e.label),
                      ),
                    )
                    .toList(),
                placeholder: labelText == null ? null : labelWidget(labelText!),
              );

        return AppControlBox(
          minWidth: effectiveMin,
          maxWidth: effectiveMax,
          height: h,
          expand: expand,
          alignment: Alignment.centerLeft,
          child: SizedBox(width: double.infinity, child: control),
        );
      },
    );
  }
}
