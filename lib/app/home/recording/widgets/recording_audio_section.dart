import 'dart:math' as math;

import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

const _micInputMeterKey = Key('mic_input_meter');
const _micInputMeterTooltipKey = Key('mic_input_meter_tooltip');
const _micInputMeterFillKey = Key('mic_input_meter_fill');
const _micInputMeterOutlineKey = Key('mic_input_meter_outline');

class RecordingAudioSection extends StatelessWidget {
  const RecordingAudioSection({
    super.key,
    required this.isRecording,
    required this.audioSources,
    required this.selectedAudioSourceId,
    required this.loadingAudio,
    required this.systemAudioEnabled,
    required this.excludeMicFromSystemAudio,
    required this.micInputLevelLinear,
    required this.micInputLevelDbfs,
    required this.micInputTooLow,
    required this.onAudioSourceChanged,
    required this.onRefreshAudio,
    required this.onSystemAudioEnabledChanged,
    required this.onExcludeMicFromSystemAudioChanged,
  });

  final bool isRecording;
  final List<AudioSource> audioSources;
  final String selectedAudioSourceId;
  final bool loadingAudio;
  final bool systemAudioEnabled;
  final bool excludeMicFromSystemAudio;
  final double micInputLevelLinear;
  final double micInputLevelDbfs;
  final bool micInputTooLow;
  final ValueChanged<String?> onAudioSourceChanged;
  final VoidCallback onRefreshAudio;
  final ValueChanged<bool> onSystemAudioEnabledChanged;
  final ValueChanged<bool> onExcludeMicFromSystemAudioChanged;

  String get _validAudioId =>
      selectedAudioSourceId == '__none__' ||
          audioSources.any((source) => source.id == selectedAudioSourceId)
      ? selectedAudioSourceId
      : '__none__';

  bool get _hasSelectedMicrophone =>
      _validAudioId != '__none__' && _validAudioId.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSection(
      title: l10n.audio,
      titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
      trailing: AppIconButton(
        tooltip: l10n.refreshAudio,
        onPressed: (loadingAudio || isRecording) ? null : onRefreshAudio,
        icon: Icons.refresh,
      ),
      child: loadingAudio
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              children: [
                AppFormRow(
                  label: l10n.inputDevice,
                  control: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: AppSidebarTokens.controlMinWidth,
                      maxWidth: AppSidebarTokens.controlMaxWidth,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: PlatformDropdown<String>(
                            value: _validAudioId,
                            minWidth: 0,
                            maxWidth: double.infinity,
                            expand: true,
                            items: [
                              PlatformMenuItem(
                                value: '__none__',
                                label: l10n.noAudio,
                              ),
                              ...audioSources.map(
                                (source) => PlatformMenuItem(
                                  value: source.id,
                                  label: source.name,
                                ),
                              ),
                            ],
                            onChanged: isRecording
                                ? null
                                : onAudioSourceChanged,
                          ),
                        ),
                        const SizedBox(width: AppSidebarTokens.rowGap),
                        _MicInputMeterIcon(
                          hasSelectedMicrophone: _hasSelectedMicrophone,
                          levelLinear: micInputLevelLinear,
                          levelDbfs: micInputLevelDbfs,
                          inputTooLow: micInputTooLow,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSidebarTokens.rowGap),
                AppToggleRow(
                  title: l10n.recordingSystemAudio,
                  value: systemAudioEnabled,
                  onChanged: isRecording ? null : onSystemAudioEnabledChanged,
                ),
                if (systemAudioEnabled && _validAudioId != '__none__') ...[
                  const SizedBox(height: AppSidebarTokens.rowGap),
                  AppToggleRow(
                    title: l10n.recordingExcludeMicFromSystemAudio,
                    value: excludeMicFromSystemAudio,
                    onChanged: isRecording
                        ? null
                        : onExcludeMicFromSystemAudioChanged,
                  ),
                ],
              ],
            ),
    );
  }
}

class _MicInputMeterIcon extends StatefulWidget {
  const _MicInputMeterIcon({
    required this.hasSelectedMicrophone,
    required this.levelLinear,
    required this.levelDbfs,
    required this.inputTooLow,
  });

  static const Color _activeFillColor = Color(0xFF34C759);

  final bool hasSelectedMicrophone;
  final double levelLinear;
  final double levelDbfs;
  final bool inputTooLow;

  @override
  State<_MicInputMeterIcon> createState() => _MicInputMeterIconState();
}

class _MicInputMeterIconState extends State<_MicInputMeterIcon> {
  static const Duration _attackDuration = Duration(milliseconds: 90);
  static const Duration _releaseDuration = Duration(milliseconds: 220);

  late double _animatedLevel;
  Duration _animationDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _animatedLevel = _visualLevelFor(widget);
  }

  @override
  void didUpdateWidget(covariant _MicInputMeterIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextLevel = _visualLevelFor(widget);
    if ((nextLevel - _animatedLevel).abs() < 0.0001) {
      return;
    }

    setState(() {
      _animationDuration = nextLevel >= _animatedLevel
          ? _attackDuration
          : _releaseDuration;
      _animatedLevel = nextLevel;
    });
  }

  double _visualLevelFor(_MicInputMeterIcon widget) {
    final linear = widget.hasSelectedMicrophone
        ? widget.levelLinear.clamp(0.0, 1.0)
        : 0.0;
    if (linear <= 0) return 0.0;
    return math.pow(linear, 0.6).toDouble().clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final visualState = _MicInputMeterVisualState.fromContext(
      context: context,
      hasSelectedMicrophone: widget.hasSelectedMicrophone,
    );
    final controlSize = isMac()
        ? AppSidebarTokens.controlHeightMac
        : AppSidebarTokens.controlHeightDefault;
    final tooltipMessage = !widget.hasSelectedMicrophone
        ? l10n.micInputIndicatorDisabledTooltip
        : widget.inputTooLow
        ? l10n.micInputIndicatorLowTooltip
        : l10n.micInputIndicatorLiveTooltip(
            widget.levelDbfs.toStringAsFixed(1),
          );

    return Tooltip(
      key: _micInputMeterTooltipKey,
      message: tooltipMessage,
      child: SizedBox(
        width: controlSize,
        height: controlSize,
        child: DecoratedBox(
          key: _micInputMeterKey,
          decoration: BoxDecoration(
            color: visualState.chromeColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: visualState.borderColor),
          ),
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _animatedLevel),
              duration: _animationDuration,
              curve: Curves.easeOutCubic,
              builder: (context, animatedLevel, _) {
                return SizedBox.square(
                  dimension: 18,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (widget.hasSelectedMicrophone)
                        Opacity(
                          opacity: 0.14,
                          child: Icon(
                            Icons.mic_rounded,
                            size: 18,
                            color: _MicInputMeterIcon._activeFillColor,
                          ),
                        ),
                      ClipRect(
                        child: Align(
                          key: _micInputMeterFillKey,
                          alignment: Alignment.bottomCenter,
                          heightFactor: animatedLevel.clamp(0.0, 1.0),
                          child: Icon(
                            Icons.mic_rounded,
                            size: 18,
                            color: _MicInputMeterIcon._activeFillColor,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.mic_none_rounded,
                        key: _micInputMeterOutlineKey,
                        size: 19,
                        color: visualState.outlineColor,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MicInputMeterVisualState {
  const _MicInputMeterVisualState({
    required this.outlineColor,
    required this.chromeColor,
    required this.borderColor,
  });

  final Color outlineColor;
  final Color chromeColor;
  final Color borderColor;

  factory _MicInputMeterVisualState.fromContext({
    required BuildContext context,
    required bool hasSelectedMicrophone,
  }) {
    final theme = Theme.of(context);

    if (!hasSelectedMicrophone) {
      return _MicInputMeterVisualState(
        outlineColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: 0.62,
        ),
        chromeColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.34,
        ),
        borderColor: theme.dividerColor.withValues(alpha: 0.14),
      );
    }

    return _MicInputMeterVisualState(
      outlineColor: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.86),
      chromeColor: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.48,
      ),
      borderColor: theme.dividerColor.withValues(alpha: 0.18),
    );
  }
}
