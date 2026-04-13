import 'dart:math' as math;

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
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

    return Container(
      key: const Key('timeline_transport_bar'),
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm,
      ),
      decoration: BoxDecoration(
        color: tokens.timelineChromeSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sliderWidth = math.min(
            220.0,
            math.max(120.0, constraints.maxWidth * 0.2),
          );

          return Row(
            children: [
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
              SizedBox(width: spacing.md),
              Text(
                '$currentTimeLabel / $totalTimeLabel',
                key: const Key('timeline_transport_time'),
                style: typography.mono.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                ),
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Text(
                  modeText ?? '',
                  key: const Key('timeline_transport_mode_text'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.bodyMuted.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              ),
              SizedBox(width: spacing.md),
              Text(
                l10n.zoom,
                style: typography.value.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                ),
              ),
              SizedBox(width: spacing.sm),
              AppIconButton(
                key: const Key('timeline_zoom_out_button'),
                icon: Icons.remove_rounded,
                tooltip: l10n.zoom,
                onPressed: onZoomOut,
              ),
              SizedBox(width: spacing.xs),
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
              SizedBox(width: spacing.xs),
              AppIconButton(
                key: const Key('timeline_zoom_in_button'),
                icon: Icons.add_rounded,
                tooltip: l10n.zoom,
                onPressed: onZoomIn,
              ),
              SizedBox(width: spacing.md),
              AppButton(
                key: const Key('timeline_transport_fit_button'),
                label: l10n.fit,
                icon: Icons.fit_screen_rounded,
                size: AppButtonSize.compact,
                variant: AppButtonVariant.secondary,
                onPressed: onFit,
              ),
            ],
          );
        },
      ),
    );
  }
}
