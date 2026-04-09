import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

class PostCursorSection extends StatelessWidget {
  const PostCursorSection({
    super.key,
    required this.cursorAvailable,
    required this.showCursor,
    required this.cursorSize,
    required this.onCursorShowChanged,
    required this.onCursorSizeChanged,
    required this.onCursorSizeChangeEnd,
  });

  final bool cursorAvailable;
  final bool showCursor;
  final double cursorSize;
  final ValueChanged<bool> onCursorShowChanged;
  final ValueChanged<double> onCursorSizeChanged;
  final ValueChanged<double> onCursorSizeChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.cursor,
          children: [
            AppToggleRow(
              title: l10n.showCursor,
              infoTooltip: l10n.toggleCursorVisibility,
              value: showCursor && cursorAvailable,
              onChanged: cursorAvailable ? onCursorShowChanged : null,
            ),
            if (!cursorAvailable) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(
                message: l10n.cursorDataMissing,
                variant: AppInlineNoticeVariant.warning,
              ),
            ],
            if (showCursor && cursorAvailable) ...[
              const SizedBox(
                key: Key('post_cursor_size_gap'),
                height: AppSidebarTokens.optionsSubgroupGap,
              ),
              AppInsetGroup(
                children: [
                  AppSliderRow(
                    label: l10n.cursorSize,
                    valueText: '${cursorSize.toStringAsFixed(1)}x',
                    slider: _buildSidebarSlider(
                      context,
                      value: cursorSize,
                      min: 0.5,
                      max: 3.0,
                      divisions: 25,
                      onChanged: onCursorSizeChanged,
                      onChangeEnd: onCursorSizeChangeEnd,
                      accentColor: accentColor,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSidebarSlider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    required Color accentColor,
    int? divisions,
  }) {
    final slider = AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );

    if (isMac()) return slider;

    return SliderTheme(
      data: Theme.of(
        context,
      ).sliderTheme.copyWith(activeTrackColor: accentColor),
      child: slider,
    );
  }
}
