import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:flutter/material.dart';

class PostAudioSection extends StatelessWidget {
  const PostAudioSection({
    super.key,
    required this.hasAudio,
    required this.audioVolume,
    required this.audioGainDb,
    required this.onAudioVolumeChanged,
    required this.onAudioVolumeChangeEnd,
    required this.onAudioGainChanged,
    required this.onAudioGainChangeEnd,
  });

  final bool hasAudio;
  final double audioVolume;
  final double audioGainDb;
  final ValueChanged<double> onAudioVolumeChanged;
  final ValueChanged<double> onAudioVolumeChangeEnd;
  final ValueChanged<double> onAudioGainChanged;
  final ValueChanged<double> onAudioGainChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

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
                onChanged: hasAudio ? onAudioGainChanged : null,
                onChangeEnd: onAudioGainChangeEnd,
              ),
            ),
            if (!hasAudio) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(message: l10n.noMicAudioFound),
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
