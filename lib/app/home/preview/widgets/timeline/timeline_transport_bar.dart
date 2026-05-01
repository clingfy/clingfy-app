import 'dart:math' as math;

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class TimelineTransportBar extends StatelessWidget {
  const TimelineTransportBar({
    super.key,
    required this.isReady,
    required this.isPlaying,
    required this.currentTimeLabel,
    required this.totalTimeLabel,
    required this.modeText,
    required this.zoomLevel,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomLevelChanged,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onPlayPause,
  });

  final bool isReady;
  final bool isPlaying;
  final String currentTimeLabel;
  final String totalTimeLabel;
  final String? modeText;
  final double zoomLevel;
  final double minZoom;
  final double maxZoom;
  final ValueChanged<double> onZoomLevelChanged;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback? onPlayPause;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final padX = metrics?.timelineChromePaddingX ?? spacing.md;
    final padY = metrics?.timelineChromePaddingY ?? spacing.sm;
    final sectionGap = metrics?.timelineSectionGap ?? spacing.md;
    final controlGap = metrics?.timelineControlGap ?? spacing.xs;
    final minHeight = metrics?.timelineTransportMinHeight ?? 40;
    final timeScale = metrics?.timelineTimeTextScale ?? 1.0;
    final modeScale = metrics?.timelineModeTextScale ?? 1.0;
    final hideZoomLabelBelow =
        metrics?.timelineHideZoomLabelBelowWidth ?? 560;
    final compactBelow =
        metrics?.timelineCompactTransportBelowWidth ?? 640;
    final sliderMin = metrics?.timelineZoomSliderMinWidth ?? 120;
    final sliderMax = metrics?.timelineZoomSliderMaxWidth ?? 220;
    final sliderFactor = metrics?.timelineZoomSliderWidthFactor ?? 0.20;

    final timeStyle = typography.mono.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
      fontSize: (typography.mono.fontSize ?? 12) * timeScale,
    );
    final modeStyle = typography.bodyMuted.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
      fontSize: (typography.bodyMuted.fontSize ?? 12) * modeScale,
    );
    final zoomLabelStyle = typography.value.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
    );

    return Container(
      key: const Key('timeline_transport_bar'),
      constraints: BoxConstraints(minHeight: minHeight),
      padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
      decoration: BoxDecoration(
        color: tokens.timelineChromeSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sliderWidth = math.min(
            sliderMax,
            math.max(sliderMin, constraints.maxWidth * sliderFactor),
          );
          final isCompact = constraints.maxWidth < compactBelow;
          final showZoomLabel = constraints.maxWidth >= hideZoomLabelBelow;
          final innerSectionGap = isCompact ? controlGap : sectionGap;

          final children = <Widget>[
            AppButton(
              key: const Key('timeline_play_pause_button'),
              label: isPlaying ? l10n.pausePlayback : l10n.play,
              icon: isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: AppButtonSize.compact,
              variant: AppButtonVariant.secondary,
              onPressed: isReady ? onPlayPause : null,
            ),
            SizedBox(width: innerSectionGap),
            Text(
              '$currentTimeLabel / $totalTimeLabel',
              key: const Key('timeline_transport_time'),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: timeStyle,
            ),
            SizedBox(width: innerSectionGap),
            Expanded(
              child: Text(
                modeText ?? '',
                key: const Key('timeline_transport_mode_text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: modeStyle,
              ),
            ),
            SizedBox(width: innerSectionGap),
            if (showZoomLabel) ...[
              Text(l10n.zoom, style: zoomLabelStyle),
              SizedBox(width: controlGap),
            ],
            AppIconButton(
              key: const Key('timeline_zoom_out_button'),
              icon: Icons.remove_rounded,
              tooltip: l10n.zoom,
              onPressed: onZoomOut,
            ),
            SizedBox(width: controlGap),
            SizedBox(
              width: sliderWidth,
              child: AppSlider(
                key: const Key('timeline_zoom_slider'),
                variant: AppSliderVariant.compact,
                value: zoomLevel,
                min: minZoom,
                max: maxZoom,
                semanticLabel: l10n.zoom,
                onChanged: onZoomLevelChanged,
              ),
            ),
            SizedBox(width: controlGap),
            AppIconButton(
              key: const Key('timeline_zoom_in_button'),
              icon: Icons.add_rounded,
              tooltip: l10n.zoom,
              onPressed: onZoomIn,
            ),
            SizedBox(width: innerSectionGap),
            AppButton(
              key: const Key('timeline_transport_fit_button'),
              label: l10n.fit,
              icon: Icons.fit_screen_rounded,
              size: AppButtonSize.compact,
              variant: AppButtonVariant.secondary,
              onPressed: onFit,
            ),
          ];

          return Row(children: children);
        },
      ),
    );
  }
}
