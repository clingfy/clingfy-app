import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';

class AppSettingsGroup extends StatelessWidget {
  const AppSettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.description,
    this.infoTooltip,
    this.trailing,
    this.anchorKey,
    this.sectionKey,
  });

  final String title;
  final String? description;
  final String? infoTooltip;
  final Widget? trailing;
  final List<Widget> children;
  final Key? anchorKey;
  final Key? sectionKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = AppSidebarTokens.sectionHeaderStyle(
      theme,
    ).copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w700);
    final descriptionStyle = AppSidebarTokens.helperStyle(theme);

    final content = Padding(
      key: sectionKey,
      padding: const EdgeInsets.only(bottom: AppSidebarTokens.optionsGroupGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: titleStyle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (infoTooltip != null && infoTooltip!.isNotEmpty) ...[
                          const SizedBox(width: AppSidebarTokens.compactGap),
                          AppInlineInfoTooltip(message: infoTooltip!, size: 14),
                        ],
                      ],
                    ),
                    if (description != null && description!.isNotEmpty) ...[
                      const SizedBox(height: AppSidebarTokens.compactGap),
                      Text(description!, style: descriptionStyle),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSidebarTokens.controlGap),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: AppSidebarTokens.rowGap),
          ...children,
        ],
      ),
    );

    if (anchorKey == null) {
      return content;
    }

    return Container(key: anchorKey, child: content);
  }
}
