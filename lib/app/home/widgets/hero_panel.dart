import 'package:flutter/material.dart';
import 'package:clingfy/app/home/widgets/grid_painter.dart';
import 'package:clingfy/app/home/widgets/live_camera_preview.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
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
    this.cameraOverlayEnabled = false,
    this.cameraFloatingPreview = false,
    this.cameraOverlayStyle = const CameraOverlayPreviewStyle(),
    this.onToggleCameraPreviewMode,
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
  final bool cameraOverlayEnabled;
  // Phase 9.3.2/9.3.3: true = floating native bubble (in-app texture hidden);
  // false = in-app texture preview (the default — floating is opt-in). The
  // toggle callback flips it (null hides the toggle).
  final bool cameraFloatingPreview;
  final CameraOverlayPreviewStyle cameraOverlayStyle;
  final VoidCallback? onToggleCameraPreviewMode;
  final Key? startRecordingButtonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final chrome = context.appEditorChrome;
    final tokens = context.appTokens;
    final typography = context.appTypography;
    final colors = theme.colorScheme;
    final metrics = context.shellMetricsOrNull;
    final scale = metrics?.scale ?? 1.0;
    final heroIconSize = metrics?.heroIconSize ?? 64;
    final primaryButtonHeight = metrics?.heroButtonHeight ?? 48;
    final primaryButtonMinWidth = metrics?.heroButtonMinWidth ?? 180;
    final secondaryButtonMinWidth = primaryButtonMinWidth * (160 / 180);
    final titleScale = metrics?.heroTitleScale ?? 1.0;
    final paddingScale = scale.clamp(0.78, 1.0);
    final lgGap = spacing.lg * paddingScale;
    final xxlGap = spacing.xxl * paddingScale;
    final outerPad = spacing.xl * paddingScale;
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
                painter: GridPainter(
                  color: theme.dividerColor,
                  step: metrics?.gridStep ?? 40,
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(outerPad),
            child: Align(
              alignment: Alignment.center,
              child: SingleChildScrollView(
                child: Column(
                  key: const Key('hero_panel_body'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isPaused
                          ? Icons.pause_circle_filled
                          : (isRecording ? Icons.circle : Icons.videocam),
                      size: heroIconSize,
                      color: isRecording ? recordingAccent : colors.primary,
                    ),
                    SizedBox(height: lgGap),
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
                        fontSize:
                            (typography.panelTitle.fontSize ?? 18) * titleScale,
                      ),
                    ),
                    SizedBox(height: xxlGap),
                    // Phase 9.3.1/9.3.2: in-app camera texture — shown only in
                    // in-app preview mode (in floating mode the native bubble
                    // shows it instead).
                    LiveCameraPreview(
                      isRecording: isRecording,
                      cameraEnabled:
                          cameraOverlayEnabled && !cameraFloatingPreview,
                      overlayStyle: cameraOverlayStyle,
                    ),
                    // Phase 9.3.2: 1-click switch between floating + in-app, for
                    // GPUs where the floating bubble is invisible.
                    if (isRecording &&
                        cameraOverlayEnabled &&
                        onToggleCameraPreviewMode != null) ...[
                      TextButton.icon(
                        onPressed: onToggleCameraPreviewMode,
                        icon: Icon(
                          cameraFloatingPreview
                              ? Icons.picture_in_picture_alt
                              : Icons.open_in_new,
                          size: 16,
                        ),
                        label: Text(
                          cameraFloatingPreview
                              ? AppLocalizations.of(
                                  context,
                                )!.cameraPreviewUseInApp
                              : AppLocalizations.of(
                                  context,
                                )!.cameraPreviewUseFloating,
                        ),
                      ),
                      SizedBox(height: lgGap),
                    ],
                    if (!isRecording)
                      FilledButton.icon(
                        key: startRecordingButtonKey,
                        onPressed: isBusy ? null : onToggle,
                        icon: const Icon(Icons.fiber_manual_record, size: 18),
                        style: FilledButton.styleFrom(
                          minimumSize: Size(
                            primaryButtonMinWidth,
                            primaryButtonHeight,
                          ),
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
                              minimumSize: Size(
                                secondaryButtonMinWidth,
                                primaryButtonHeight,
                              ),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: isBusy ? null : onToggle,
                            icon: const Icon(Icons.stop, size: 18),
                            style: FilledButton.styleFrom(
                              minimumSize: Size(
                                secondaryButtonMinWidth,
                                primaryButtonHeight,
                              ),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
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
