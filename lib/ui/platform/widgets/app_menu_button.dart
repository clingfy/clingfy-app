import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class AppMenuItem<T> {
  const AppMenuItem({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
  });

  final IconData icon;
  final String? tooltip;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    if (isMac() && macos.MacosTheme.maybeOf(context) != null) {
      final button = macos.MacosPulldownButton(
        icon: icon,
        items: items
            .map(
              (item) => macos.MacosPulldownMenuItem(
                label: item.label,
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.icon != null) ...[
                      Icon(item.icon, size: 14),
                      const SizedBox(width: 8),
                    ],
                    Text(item.label),
                  ],
                ),
                onTap: () => onSelected(item.value),
              ),
            )
            .toList(),
      );

      return tooltip == null
          ? button
          : macos.MacosTooltip(message: tooltip!, child: button);
    }

    if (isWindows()) {
      final button = fluent.DropDownButton(
        title: Icon(icon, size: 16),
        items: items
            .map(
              (item) => fluent.MenuFlyoutItem(
                leading: item.icon == null ? null : Icon(item.icon, size: 14),
                text: Text(item.label),
                onPressed: () => onSelected(item.value),
              ),
            )
            .toList(),
      );

      return tooltip == null
          ? button
          : fluent.Tooltip(message: tooltip!, child: button);
    }

    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      onSelected: onSelected,
      itemBuilder: (context) => items
          .map(
            (item) => PopupMenuItem<T>(
              value: item.value,
              child: Row(
                children: [
                  if (item.icon != null) ...[
                    Icon(item.icon, size: 16),
                    const SizedBox(width: 8),
                  ],
                  Text(item.label),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}
