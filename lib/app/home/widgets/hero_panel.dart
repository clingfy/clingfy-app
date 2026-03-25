import 'package:flutter/material.dart';
import 'package:clingfy/app/home/widgets/grid_painter.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';

class HeroPanel extends StatelessWidget {
  const HeroPanel({
    super.key,
    required this.isRecording,
    required this.isBusy,
    required this.onToggle,
  });

  final bool isRecording;
  final bool isBusy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final chrome = context.appEditorChrome;
    final tokens = context.appTokens;
    final typography = context.appTypography;
    final colors = theme.colorScheme;

    return Container(
      key: const Key('hero_panel_shell'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: Stack(
        children: [
          // Grid pattern or placeholder
          Positioned.fill(
            child: Opacity(
              opacity: 0.1,
              child: CustomPaint(
                painter: GridPainter(color: theme.dividerColor),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isRecording ? Icons.circle : Icons.videocam,
                  size: 64,
                  color: isRecording ? colors.error : colors.primary,
                ),
                SizedBox(height: spacing.lg),
                Text(
                  isRecording
                      ? AppLocalizations.of(context)!.recordingInProgress
                      : AppLocalizations.of(context)!.readyToRecord,
                  textAlign: TextAlign.center,
                  style: typography.panelTitle.copyWith(
                    letterSpacing: 1.2,
                    color: colors.onSurface,
                  ),
                ),
                SizedBox(height: spacing.xxl),
                FilledButton.icon(
                  onPressed: isBusy ? null : onToggle,
                  icon: Icon(
                    isRecording ? Icons.stop : Icons.fiber_manual_record,
                    size: 18,
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(180, 48),
                    backgroundColor: isRecording
                        ? colors.error
                        : colors.primary,
                    foregroundColor: isRecording
                        ? colors.onError
                        : colors.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(chrome.controlRadius),
                    ),
                  ),
                  label: Text(
                    isRecording
                        ? AppLocalizations.of(context)!.stop
                        : AppLocalizations.of(context)!.startRecording,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          if (isBusy)
            Container(
              color: colors.scrim.withValues(alpha: 0.5),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
