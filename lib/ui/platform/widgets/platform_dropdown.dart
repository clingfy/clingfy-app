import 'dart:math' as math;

import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class PlatformMenuItem<T> {
  final T value;
  final String label;
  const PlatformMenuItem({required this.value, required this.label});
}

class PlatformDropdown<T> extends StatefulWidget {
  const PlatformDropdown({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.labelText,
    this.minWidth,
    this.maxWidth,
    this.expand = true,
    this.heightMac,
    this.heightWin,
  });

  static const ValueKey<String> fieldKey = ValueKey<String>(
    'platform_dropdown_field',
  );
  static const ValueKey<String> labelKey = ValueKey<String>(
    'platform_dropdown_label',
  );
  static const ValueKey<String> arrowKey = ValueKey<String>(
    'platform_dropdown_arrow',
  );

  final List<PlatformMenuItem<T>> items;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final String? labelText;
  final double? minWidth;
  final double? maxWidth;
  final bool expand;
  final double? heightMac;
  final double? heightWin;

  @override
  State<PlatformDropdown<T>> createState() => _PlatformDropdownState<T>();
}

class _PlatformDropdownState<T> extends State<PlatformDropdown<T>> {
  bool _isHoveringField = false;
  bool _isMenuOpen = false;

  bool get _enabled => widget.onChanged != null && widget.items.isNotEmpty;

  String get _displayLabel {
    for (final item in widget.items) {
      if (item.value == widget.value) {
        return item.label;
      }
    }
    return widget.labelText ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.appTypography.body;
    final palette = _DropdownPalette.resolve(theme);
    final metrics = context.shellMetricsOrNull;
    final effectiveMaxWidth = widget.maxWidth ??
        metrics?.sidebarControlMaxWidth ??
        AppSidebarTokens.controlMaxWidth;
    final effectiveHeightMac = widget.heightMac ??
        metrics?.sidebarControlHeightMac ??
        AppSidebarTokens.controlHeightMac;
    final effectiveHeightWin = widget.heightWin ??
        metrics?.sidebarControlHeightDefault ??
        AppSidebarTokens.controlHeightDefault;
    final height = isMac() ? effectiveHeightMac : effectiveHeightWin;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (effectiveMaxWidth.isFinite
                  ? effectiveMaxWidth
                  : AppSidebarTokens.controlMaxWidth);

        final clampedWidth = effectiveMaxWidth.isFinite
            ? math.min(effectiveMaxWidth, availableWidth)
            : availableWidth;

        final fieldWidth = widget.expand ? availableWidth : clampedWidth;
        final labelWidth = math.max(0.0, fieldWidth - 48).toDouble();

        final popupTheme = theme.copyWith(
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
        );

        final dropdown = SizedBox(
          width: fieldWidth,
          height: height,
          child: Theme(
            data: popupTheme,
            child: PopupMenuButton<T>(
              enabled: _enabled,
              tooltip: '',
              padding: EdgeInsets.zero,
              position: PopupMenuPosition.under,
              color: palette.surface,
              surfaceTintColor: Colors.transparent,
              shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.22),
              elevation: 10,
              constraints: BoxConstraints.tightFor(width: fieldWidth),
              onOpened: () {
                if (!mounted) return;
                setState(() {
                  _isMenuOpen = true;
                });
              },
              onCanceled: () {
                if (!mounted) return;
                setState(() {
                  _isMenuOpen = false;
                });
              },
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: palette.border),
              ),
              onSelected: (selected) {
                if (mounted) {
                  setState(() {
                    _isMenuOpen = false;
                  });
                }
                widget.onChanged?.call(selected);
              },
              itemBuilder: (context) => [
                for (final entry in widget.items.indexed)
                  PopupMenuItem<T>(
                    value: entry.$2.value,
                    padding: EdgeInsets.zero,
                    height: 42,
                    child: SizedBox(
                      width: double.infinity,
                      child: _DropdownMenuRow(
                        rowKey: ValueKey(
                          'platform_dropdown_menu_row_${entry.$1}',
                        ),
                        label: entry.$2.label,
                        isSelected: entry.$2.value == widget.value,
                        palette: palette,
                        textStyle: textStyle,
                      ),
                    ),
                  ),
              ],
              child: MouseRegion(
                cursor: _enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onEnter: (_) {
                  if (!_enabled) return;
                  setState(() {
                    _isHoveringField = true;
                  });
                },
                onExit: (_) {
                  if (!_enabled) return;
                  setState(() {
                    _isHoveringField = false;
                  });
                },
                child: _DropdownField(
                  label: _displayLabel,
                  enabled: _enabled,
                  isHovered: _isHoveringField,
                  isOpen: _isMenuOpen,
                  palette: palette,
                  textStyle: textStyle,
                  buttonLabelWidth: labelWidth,
                ),
              ),
            ),
          ),
        );

        return Align(
          alignment: widget.expand
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: dropdown,
        );
      },
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.enabled,
    required this.isHovered,
    required this.isOpen,
    required this.palette,
    required this.textStyle,
    required this.buttonLabelWidth,
  });

  final String label;
  final bool enabled;
  final bool isHovered;
  final bool isOpen;
  final _DropdownPalette palette;
  final TextStyle textStyle;
  final double buttonLabelWidth;

  @override
  Widget build(BuildContext context) {
    final background = palette.fieldBackground(
      enabled: enabled,
      hovered: isHovered,
      open: isOpen,
    );
    final borderColor = palette.fieldBorder(
      enabled: enabled,
      hovered: isHovered,
      open: isOpen,
    );
    final textColor = palette.fieldText(
      enabled: enabled,
      hovered: isHovered,
      open: isOpen,
    );
    final arrowColor = palette.fieldArrow(
      enabled: enabled,
      hovered: isHovered,
      open: isOpen,
    );

    return AnimatedContainer(
      key: PlatformDropdown.fieldKey,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: buttonLabelWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  key: PlatformDropdown.labelKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle.copyWith(color: textColor),
                ),
              ),
            ),
            const Spacer(),
            AnimatedRotation(
              duration: const Duration(milliseconds: 160),
              turns: isOpen ? 0.5 : 0,
              child: Icon(
                Icons.keyboard_arrow_down,
                key: PlatformDropdown.arrowKey,
                size: 18,
                color: arrowColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropdownMenuRow extends StatefulWidget {
  const _DropdownMenuRow({
    required this.rowKey,
    required this.label,
    required this.isSelected,
    required this.palette,
    required this.textStyle,
  });

  final Key rowKey;
  final String label;
  final bool isSelected;
  final _DropdownPalette palette;
  final TextStyle textStyle;

  @override
  State<_DropdownMenuRow> createState() => _DropdownMenuRowState();
}

class _DropdownMenuRowState extends State<_DropdownMenuRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() {
          _isHovered = true;
        });
      },
      onExit: (_) {
        setState(() {
          _isHovered = false;
        });
      },
      child: AnimatedContainer(
        key: widget.rowKey,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: widget.palette.menuRowBackground(
            selected: widget.isSelected,
            hovered: _isHovered,
          ),
          borderRadius: BorderRadius.circular(8),
          border: widget.isSelected
              ? Border.all(color: widget.palette.selectedBorder)
              : null,
        ),
        child: Text(
          widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.textStyle.copyWith(
            color: widget.palette.menuRowText(selected: widget.isSelected),
            fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _DropdownPalette {
  const _DropdownPalette({
    required this.isDark,
    required this.surface,
    required this.disabledSurface,
    required this.text,
    required this.disabledText,
    required this.icon,
    required this.border,
    required this.hoverSurface,
    required this.selectedSurface,
    required this.selectedBorder,
    required this.activeBorder,
    required this.activeText,
    required this.activeArrow,
    required this.selectedText,
  });

  static _DropdownPalette resolve(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF232428) : const Color(0xFFF3F4F7);
    final text = isDark ? const Color(0xFF797A7E) : const Color(0xFF5F636B);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;
    final border = theme.colorScheme.outlineVariant.withValues(
      alpha: isDark ? 0.8 : 0.95,
    );

    return _DropdownPalette(
      isDark: isDark,
      surface: surface,
      disabledSurface: Color.alphaBlend(
        text.withValues(alpha: isDark ? 0.08 : 0.05),
        surface,
      ),
      text: text,
      disabledText: text.withValues(alpha: 0.55),
      icon: text,
      border: border,
      hoverSurface: Color.alphaBlend(
        onSurface.withValues(alpha: isDark ? 0.05 : 0.04),
        surface,
      ),
      selectedSurface: Color.alphaBlend(
        primary.withValues(alpha: isDark ? 0.14 : 0.10),
        surface,
      ),
      selectedBorder: primary.withValues(alpha: isDark ? 0.22 : 0.18),
      activeBorder: Color.alphaBlend(
        primary.withValues(alpha: isDark ? 0.38 : 0.24),
        border,
      ),
      activeText: Color.lerp(text, onSurface, isDark ? 0.30 : 0.24)!,
      activeArrow: Color.lerp(text, primary, isDark ? 0.48 : 0.34)!,
      selectedText: Color.lerp(text, onSurface, isDark ? 0.38 : 0.30)!,
    );
  }

  final bool isDark;
  final Color surface;
  final Color disabledSurface;
  final Color text;
  final Color disabledText;
  final Color icon;
  final Color border;
  final Color hoverSurface;
  final Color selectedSurface;
  final Color selectedBorder;
  final Color activeBorder;
  final Color activeText;
  final Color activeArrow;
  final Color selectedText;

  Color fieldBackground({
    required bool enabled,
    required bool hovered,
    required bool open,
  }) {
    if (!enabled) return disabledSurface;
    if (open) {
      return Color.alphaBlend(
        selectedSurface.withValues(alpha: isDark ? 0.88 : 0.78),
        surface,
      );
    }
    if (hovered) {
      return Color.alphaBlend(
        hoverSurface.withValues(alpha: isDark ? 0.95 : 0.88),
        surface,
      );
    }
    return surface;
  }

  Color fieldBorder({
    required bool enabled,
    required bool hovered,
    required bool open,
  }) {
    if (!enabled) return border.withValues(alpha: 0.55);
    if (open) return activeBorder;
    if (hovered) {
      return Color.lerp(border, activeBorder, 0.55)!;
    }
    return border;
  }

  Color fieldText({
    required bool enabled,
    required bool hovered,
    required bool open,
  }) {
    if (!enabled) return disabledText;
    if (open || hovered) return activeText;
    return text;
  }

  Color fieldArrow({
    required bool enabled,
    required bool hovered,
    required bool open,
  }) {
    if (!enabled) return disabledText;
    if (open || hovered) return activeArrow;
    return icon;
  }

  Color menuRowBackground({required bool selected, required bool hovered}) {
    final base = selected ? selectedSurface : Colors.transparent;
    if (!hovered) return base;
    return Color.alphaBlend(hoverSurface.withValues(alpha: 0.92), base);
  }

  Color menuRowText({required bool selected}) {
    return selected ? selectedText : text;
  }
}
