import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
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
    this.showHeader = true,
  });

  final String title;
  final String? description;
  final String? infoTooltip;
  final Widget? trailing;
  final List<Widget> children;
  final Key? anchorKey;
  final Key? sectionKey;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = context.shellMetricsOrNull;
    final optionsGroupGap =
        metrics?.sidebarOptionsGroupGap ?? AppSidebarTokens.optionsGroupGap;
    final compactGap =
        metrics?.sidebarCompactGap ?? AppSidebarTokens.compactGap;
    final controlGap =
        metrics?.sidebarControlGap ?? AppSidebarTokens.controlGap;
    final rowGap = metrics?.sidebarRowGap ?? AppSidebarTokens.rowGap;
    final infoIconSize = metrics?.sidebarIconSmall ?? 14;
    final titleStyle = AppSidebarTokens.sectionHeaderStyle(
      theme,
    ).copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w700);
    final descriptionStyle = AppSidebarTokens.helperStyle(theme);

    final content = Padding(
      key: sectionKey,
      padding: EdgeInsets.only(bottom: optionsGroupGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
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
                          if (infoTooltip != null &&
                              infoTooltip!.isNotEmpty) ...[
                            SizedBox(width: compactGap),
                            AppInlineInfoTooltip(
                              message: infoTooltip!,
                              size: infoIconSize,
                            ),
                          ],
                        ],
                      ),
                      if (description != null && description!.isNotEmpty) ...[
                        SizedBox(height: compactGap),
                        Text(description!, style: descriptionStyle),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  SizedBox(width: controlGap),
                  trailing!,
                ],
              ],
            ),
            SizedBox(height: rowGap),
          ],
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
