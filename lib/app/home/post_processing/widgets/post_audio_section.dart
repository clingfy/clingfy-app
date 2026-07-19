import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

class PostAudioSection extends StatelessWidget {
  const PostAudioSection({
    super.key,
    required this.hasAudio,
    this.gainAvailable,
    required this.audioVolume,
    required this.audioGainDb,
    required this.onAudioVolumeChanged,
    required this.onAudioVolumeChangeEnd,
    required this.onAudioGainChanged,
    required this.onAudioGainChangeEnd,
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
  final ValueChanged<double> onAudioVolumeChanged;
  final ValueChanged<double> onAudioVolumeChangeEnd;
  final ValueChanged<double> onAudioGainChanged;
  final ValueChanged<double> onAudioGainChangeEnd;

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
