import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_segmented.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

class PostAudioSection extends StatelessWidget {
  const PostAudioSection({
    super.key,
    required this.hasAudio,
    this.gainAvailable,
    required this.audioVolume,
    required this.audioGainDb,
    required this.voiceCleanup,
    required this.onAudioVolumeChanged,
    required this.onAudioVolumeChangeEnd,
    required this.onAudioGainChanged,
    required this.onAudioGainChangeEnd,
    required this.onVoiceCleanupChanged,
  });

  final bool hasAudio;

  /// Audio separation (Windows D10): whether the GAIN slider will have an
  /// audible effect. On a separated recording gain targets the mic track
  /// only, so a mic-less-but-system-audio recording has working volume but
  /// inert gain — the gain row disables and the "no mic audio" notice shows
  /// while volume stays live. Null (macOS / unknown) falls back to
  /// [hasAudio], the pre-separation behavior.
  final bool? gainAvailable;
  final double audioVolume;
  final double audioGainDb;
  final VoiceCleanup voiceCleanup;
  final ValueChanged<double> onAudioVolumeChanged;
  final ValueChanged<double> onAudioVolumeChangeEnd;
  final ValueChanged<double> onAudioGainChanged;
  final ValueChanged<double> onAudioGainChangeEnd;
  final ValueChanged<VoiceCleanup> onVoiceCleanupChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final gainEnabled = gainAvailable ?? hasAudio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.audio,
          showHeader: false,
          children: [
            AppSliderRow(
              label: l10n.volume,
              slider: _buildSidebarSlider(
                value: audioVolume,
                min: 0,
                max: 100,
                divisions: 100,
                valueLabel: '${audioVolume.toInt()}%',
                semanticLabel: l10n.volume,
                onChanged: hasAudio ? onAudioVolumeChanged : null,
                onChangeEnd: onAudioVolumeChangeEnd,
              ),
            ),
            const SizedBox(height: AppSidebarTokens.rowGap),
            AppSliderRow(
              label: l10n.audioGain,
              slider: _buildSidebarSlider(
                value: audioGainDb,
                min: 0,
                max: 24,
                divisions: 24,
                valueLabel: audioGainDb == 0
                    ? l10n.off
                    : '+${audioGainDb.toInt()}dB',
                semanticLabel: l10n.audioGain,
                onChanged: gainEnabled ? onAudioGainChanged : null,
                onChangeEnd: onAudioGainChangeEnd,
              ),
            ),
            // Voice cleanup denoises the MIC track alone, so it needs the same
            // mic-present condition the gain slider does — a system-audio-only
            // recording has nothing for it to act on. Hidden on Windows until
            // the RNNoise engine is built there (its bridge method is a no-op
            // today), so the control never promises a cleanup that won't happen.
            if (gainEnabled && !isWindows()) ...[
              const SizedBox(height: AppSidebarTokens.rowGap),
              AppToggleRow(
                key: const ValueKey('post_audio_voice_cleanup_toggle'),
                title: l10n.voiceCleanup,
                helperText: l10n.voiceCleanupHelp,
                value: voiceCleanup.enabled,
                onChanged: (enabled) => onVoiceCleanupChanged(
                  voiceCleanup.copyWith(enabled: enabled),
                ),
              ),
              if (voiceCleanup.enabled) ...[
                const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
                AppSegmented<CleanupMode>(
                  key: const ValueKey('post_audio_voice_cleanup_mode'),
                  value: voiceCleanup.mode,
                  compact: true,
                  onChanged: (mode) =>
                      onVoiceCleanupChanged(voiceCleanup.copyWith(mode: mode)),
                  items: [
                    AppSegmentedItem(
                      value: CleanupMode.light,
                      label: l10n.voiceCleanupLight,
                    ),
                    AppSegmentedItem(
                      value: CleanupMode.balanced,
                      label: l10n.voiceCleanupBalanced,
                    ),
                    // CleanupMode.highQuality is deliberately absent: it is
                    // reserved for a future full-band engine and would behave
                    // identically to Balanced today.
                  ],
                ),
              ],
            ],
            // "No mic audio track found": shown when the recording has no
            // audio at all (the pre-separation case) AND when it has system
            // audio but no mic track (gain disabled above, volume live).
            if (!gainEnabled) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(message: l10n.noMicAudioFound),
            ],
            // Editing 4-7d (Windows): the mix is LIVE in the preview now —
            // gain+volume on edited (cut/reordered) sessions, volume-only on
            // an uncut one (MediaPlayer.Volume can't amplify; gain there
            // applies on export). The notice narrates that remaining gap.
            // Suppressed when gain is inert — it must not promise audible
            // gain a mic-less separated recording can't deliver.
            if (hasAudio && gainEnabled && isWindows()) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(
                key: const ValueKey('post_audio_export_notice'),
                message: l10n.appliedOnExportNoticeWindows,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSidebarSlider({
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required String semanticLabel,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
  }) {
    return AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      valueLabel: valueLabel,
      semanticLabel: semanticLabel,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}
