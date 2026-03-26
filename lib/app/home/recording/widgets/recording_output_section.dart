import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class RecordingOutputSection extends StatelessWidget {
  const RecordingOutputSection({
    super.key,
    required this.isRecording,
    required this.captureFrameRate,
    required this.autoStopEnabled,
    required this.autoStopAfter,
    required this.countdownEnabled,
    required this.countdownDuration,
    required this.onFrameRateChanged,
    required this.onAutoStopEnabledChanged,
    required this.onAutoStopAfterChanged,
    required this.onCountdownEnabledChanged,
    required this.onCountdownDurationChanged,
  });

  final bool isRecording;
  final int captureFrameRate;
  final bool autoStopEnabled;
  final Duration autoStopAfter;
  final bool countdownEnabled;
  final int countdownDuration;
  final ValueChanged<int> onFrameRateChanged;
  final ValueChanged<bool> onAutoStopEnabledChanged;
  final ValueChanged<Duration> onAutoStopAfterChanged;
  final ValueChanged<bool> onCountdownEnabledChanged;
  final ValueChanged<int> onCountdownDurationChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFormRow(
          label: l10n.frameRate,
          control: PlatformDropdown<int>(
            value: captureFrameRate,
            labelText: l10n.frameRate,
            items: [30, 60]
                .map(
                  (fps) => PlatformMenuItem(value: fps, label: l10n.fps(fps)),
                )
                .toList(),
            onChanged: isRecording
                ? null
                : (value) {
                    if (value != null) onFrameRateChanged(value);
                  },
          ),
        ),
        const SizedBox(
          key: Key('recording_output_frame_rate_duration_gap'),
          height: AppSidebarTokens.optionsGroupGap,
        ),
        const SizedBox(
          key: Key('recording_output_frame_rate_duration_gap2'),
          height: AppSidebarTokens.optionsGroupGap,
        ),
        AppSection(
          title: l10n.duration,
          titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppFormRow(
                label: l10n.autoStopAfter,
                control: PlatformDropdown<Duration>(
                  value: autoStopEnabled ? autoStopAfter : Duration.zero,
                  items: [
                    PlatformMenuItem(value: Duration.zero, label: l10n.none),
                    ...[
                      const Duration(minutes: 1),
                      const Duration(minutes: 5),
                      const Duration(minutes: 10),
                      const Duration(minutes: 30),
                      const Duration(hours: 1),
                    ].map((duration) {
                      final label = duration.inHours >= 1
                          ? l10n.hoursShort(duration.inHours)
                          : l10n.minutesShort(duration.inMinutes);
                      return PlatformMenuItem(value: duration, label: label);
                    }),
                  ],
                  onChanged: isRecording
                      ? null
                      : (duration) {
                          if (duration == null) return;
                          if (duration == Duration.zero) {
                            onAutoStopEnabledChanged(false);
                          } else {
                            onAutoStopEnabledChanged(true);
                            onAutoStopAfterChanged(duration);
                          }
                        },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(
          key: Key('recording_output_duration_countdown_gap'),
          height: AppSidebarTokens.optionsSubgroupGap,
        ),
        AppFormRow(
          label: l10n.countdown,
          control: PlatformDropdown<int>(
            value: countdownEnabled ? countdownDuration : 0,
            items: [
              PlatformMenuItem(value: 0, label: l10n.none),
              ...[3, 5, 10].map(
                (seconds) => PlatformMenuItem(
                  value: seconds,
                  label: l10n.seconds(seconds),
                ),
              ),
            ],
            onChanged: isRecording
                ? null
                : (value) {
                    if (value == null) return;
                    if (value == 0) {
                      onCountdownEnabledChanged(false);
                    } else {
                      onCountdownEnabledChanged(true);
                      onCountdownDurationChanged(value);
                    }
                  },
          ),
        ),
      ],
    );
  }
}
