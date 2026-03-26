import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
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
    final accentColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSliderRow(
          label: l10n.volume,
          valueText: '${audioVolume.toInt()}%',
          slider: _buildSidebarSlider(
            context,
            value: audioVolume,
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: hasAudio ? onAudioVolumeChanged : null,
            onChangeEnd: onAudioVolumeChangeEnd,
            accentColor: accentColor,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppSliderRow(
          label: l10n.audioGain,
          valueText: audioGainDb == 0 ? l10n.off : '+${audioGainDb.toInt()}dB',
          slider: _buildSidebarSlider(
            context,
            value: audioGainDb,
            min: 0,
            max: 24,
            divisions: 24,
            onChanged: hasAudio ? onAudioGainChanged : null,
            onChangeEnd: onAudioGainChangeEnd,
            accentColor: accentColor,
          ),
        ),
        if (!hasAudio) ...[
          const SizedBox(height: AppSidebarTokens.compactGap),
          AppInlineNotice(message: l10n.noMicAudioFound),
        ],
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
