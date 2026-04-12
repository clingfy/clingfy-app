import 'package:flutter/material.dart';
import 'package:clingfy/app/home/widgets/grid_painter.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';

class HeroPanel extends StatelessWidget {
  static const _darkRecordingAccent = Color(0xFFFF4D5D);

  const HeroPanel({
    super.key,
    required this.isRecording,
    required this.isPaused,
    required this.isBusy,
    required this.canPause,
    required this.canResume,
    required this.onToggle,
    required this.onPause,
    required this.onResume,
    this.startRecordingButtonKey,
  });

  final bool isRecording;
  final bool isPaused;
  final bool isBusy;
  final bool canPause;
  final bool canResume;
  final VoidCallback onToggle;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final Key? startRecordingButtonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final chrome = context.appEditorChrome;
    final tokens = context.appTokens;
    final typography = context.appTypography;
    final colors = theme.colorScheme;
    final recordingAccent = theme.brightness == Brightness.dark
        ? _darkRecordingAccent
        : colors.error;

    return Container(
      key: const Key('hero_panel_shell'),
      decoration: BoxDecoration(
        color: tokens.previewPanelBackground,
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
          Padding(
            padding: EdgeInsets.all(spacing.xl),
            child: Align(
              alignment: Alignment.center,
              child: Column(
                key: const Key('hero_panel_body'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPaused
                        ? Icons.pause_circle_filled
                        : (isRecording ? Icons.circle : Icons.videocam),
                    size: 64,
                    color: isRecording ? recordingAccent : colors.primary,
                  ),
                  SizedBox(height: spacing.lg),
                  Text(
                    isPaused
                        ? AppLocalizations.of(context)!.recordingPaused
                        : isRecording
                        ? AppLocalizations.of(context)!.recordingInProgress
                        : AppLocalizations.of(context)!.readyToRecord,
                    textAlign: TextAlign.center,
                    style: typography.panelTitle.copyWith(
                      letterSpacing: 1.2,
                      color: colors.onSurface,
                    ),
                  ),
                  SizedBox(height: spacing.xxl),
                  if (!isRecording)
                    FilledButton.icon(
                      key: startRecordingButtonKey,
                      onPressed: isBusy ? null : onToggle,
                      icon: const Icon(Icons.fiber_manual_record, size: 18),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(180, 48),
                        backgroundColor: colors.primary,
                        foregroundColor: colors.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            chrome.controlRadius,
                          ),
                        ),
                      ),
                      label: Text(
                        AppLocalizations.of(context)!.startRecording,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    )
                  else
                    Wrap(
                      spacing: spacing.md,
                      runSpacing: spacing.md,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: isBusy
                              ? null
                              : (isPaused
                                    ? (canResume ? onResume : null)
                                    : (canPause ? onPause : null)),
                          icon: Icon(
                            isPaused ? Icons.play_arrow : Icons.pause,
                            size: 18,
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(160, 48),
                            foregroundColor: colors.onSurface,
                            side: BorderSide(color: tokens.panelBorder),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                chrome.controlRadius,
                              ),
                            ),
                          ),
                          label: Text(
                            isPaused
                                ? AppLocalizations.of(context)!.resume
                                : AppLocalizations.of(context)!.pause,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: isBusy ? null : onToggle,
                          icon: const Icon(Icons.stop, size: 18),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(160, 48),
                            backgroundColor: recordingAccent,
                            foregroundColor: colors.onError,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                chrome.controlRadius,
                              ),
                            ),
                          ),
                          label: Text(
                            AppLocalizations.of(context)!.stop,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
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
