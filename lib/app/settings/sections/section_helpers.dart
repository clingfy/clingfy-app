import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

Widget buildSectionPage(
  BuildContext context, {
  required List<Widget> children,
}) {
  return ListView(
    padding: const EdgeInsets.all(16),
    children: [...children, const SizedBox(height: 24)],
  );
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    this.infoTooltip,
    required this.child,
  });

  final String title;
  final String? infoTooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      color: isDark ? theme.appTokens.editorChromeBackground : null,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.appTokens.panelBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (infoTooltip != null) ...[
                  const SizedBox(width: 8),
                  AppInlineInfoTooltip(message: infoTooltip!),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [Expanded(child: child)],
            ),
          ],
        ),
      ),
    );
  }
}
