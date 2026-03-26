import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_switch.dart';
import 'package:flutter/material.dart';

/// Standard row for boolean sidebar settings.
class AppToggleRow extends StatelessWidget {
  const AppToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.infoTooltip,
    this.helperText,
  });

  final String title;
  final String? infoTooltip;
  final String? helperText;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = AppSidebarTokens.rowTitleStyle(theme);
    final subtitleStyle = AppSidebarTokens.helperStyle(
      theme,
    ).copyWith(color: theme.colorScheme.secondary);
    final hasHelperText = helperText != null && helperText!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: hasHelperText
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: titleStyle)),
                    if (infoTooltip != null) ...[
                      const SizedBox(width: 8),
                      AppInlineInfoTooltip(
                        message: infoTooltip!,
                        color: subtitleStyle.color,
                      ),
                    ],
                  ],
                ),
                if (hasHelperText) ...[
                  const SizedBox(height: AppSidebarTokens.compactGap / 2),
                  Text(helperText!, style: subtitleStyle),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSidebarTokens.controlGap),
          Padding(
            padding: EdgeInsets.only(top: hasHelperText ? 2 : 0),
            child: PlatformSwitch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}
