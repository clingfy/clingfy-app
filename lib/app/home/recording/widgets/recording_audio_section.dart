import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

const _micInputMeterKey = Key('mic_input_meter');
const _micInputMeterTooltipKey = Key('mic_input_meter_tooltip');
const _micInputMeterIconKey = Key('mic_input_meter_icon');
const _micInputMeterFillKey = Key('mic_input_meter_fill');

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

    return AppSettingsGroup(
      title: l10n.audio,
      showHeader: false,
      children: loadingAudio
          ? const [
              Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ]
          : [
              AppFormRow(
                label: l10n.inputDevice,
                labelTrailing: AppIconButton(
                  tooltip: l10n.refreshAudio,
                  onPressed: (loadingAudio || isRecording)
                      ? null
                      : onRefreshAudio,
                  icon: Icons.refresh,
                ),
                control: SizedBox(
                  width: double.infinity,
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
                          onChanged: isRecording ? null : onAudioSourceChanged,
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
              if (systemAudioEnabled && _hasSelectedMicrophone) ...[
                const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
                AppInsetGroup(
                  children: [
                    AppToggleRow(
                      title: l10n.recordingExcludeMicFromSystemAudio,
                      value: excludeMicFromSystemAudio,
                      onChanged: isRecording
                          ? null
                          : onExcludeMicFromSystemAudioChanged,
                    ),
                  ],
                ),
              ],
            ],
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
  static const double _minimumDisplayDbfs = -60.0;
  static const double _iconSize = 18.0;
  static const double _iconCanvasSize = 20.0;

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
    if (!widget.hasSelectedMicrophone) {
      return 0.0;
    }

    if (widget.levelDbfs.isFinite) {
      final clampedDbfs = widget.levelDbfs
          .clamp(_minimumDisplayDbfs, 0.0)
          .toDouble();
      final normalized =
          ((clampedDbfs - _minimumDisplayDbfs) / -_minimumDisplayDbfs)
              .clamp(0.0, 1.0)
              .toDouble();

      if (normalized <= 0.0) {
        return 0.0;
      }

      return Curves.easeOutCubic.transform(normalized);
    }

    if (!widget.levelLinear.isFinite) {
      return 0.0;
    }

    final fallbackLinear = widget.levelLinear.clamp(0.0, 1.0).toDouble();
    if (fallbackLinear <= 0.0) {
      return 0.0;
    }

    return Curves.easeOutCubic.transform(fallbackLinear);
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
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: tooltipMessage,
        value: tooltipMessage,
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
                  final clampedLevel = animatedLevel.clamp(0.0, 1.0).toDouble();

                  return _MicFilledGlyph(
                    iconSize: _iconSize,
                    canvasSize: _iconCanvasSize,
                    level: clampedLevel,
                    baseColor: visualState.glyphTrackColor,
                    fillColor: visualState.glyphFillColor,
                    outlineColor: visualState.outlineColor,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MicFilledGlyph extends StatelessWidget {
  const _MicFilledGlyph({
    required this.iconSize,
    required this.canvasSize,
    required this.level,
    required this.baseColor,
    required this.fillColor,
    required this.outlineColor,
  });

  final double iconSize;
  final double canvasSize;
  final double level;
  final Color baseColor;
  final Color fillColor;
  final Color outlineColor;

  @override
  Widget build(BuildContext context) {
    final clampedLevel = level.clamp(0.0, 1.0).toDouble();

    return SizedBox.square(
      dimension: canvasSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.mic_rounded,
            key: _micInputMeterIconKey,
            size: iconSize,
            color: baseColor,
          ),
          if (clampedLevel > 0.0)
            _MicLiveFill(
              key: _micInputMeterFillKey,
              iconSize: iconSize,
              level: clampedLevel,
              color: fillColor,
            ),
          Icon(Icons.mic_none_rounded, size: iconSize, color: outlineColor),
        ],
      ),
    );
  }
}

class _MicLiveFill extends StatelessWidget {
  const _MicLiveFill({
    super.key,
    required this.iconSize,
    required this.level,
    required this.color,
  });

  final double iconSize;
  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clampedLevel = level.clamp(0.0, 1.0).toDouble();

    if (clampedLevel >= 0.999) {
      return Icon(Icons.mic_rounded, size: iconSize, color: color);
    }

    final transitionStart = (clampedLevel - 0.001).clamp(0.0, 1.0).toDouble();
    final transitionEnd = (clampedLevel + 0.001).clamp(0.0, 1.0).toDouble();

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [color, color, Colors.transparent, Colors.transparent],
          stops: [0.0, transitionStart, transitionEnd, 1.0],
        ).createShader(bounds);
      },
      child: Icon(Icons.mic_rounded, size: iconSize, color: Colors.white),
    );
  }
}

class _MicInputMeterVisualState {
  const _MicInputMeterVisualState({
    required this.outlineColor,
    required this.chromeColor,
    required this.borderColor,
    required this.glyphTrackColor,
    required this.glyphFillColor,
  });

  final Color outlineColor;
  final Color chromeColor;
  final Color borderColor;
  final Color glyphTrackColor;
  final Color glyphFillColor;

  factory _MicInputMeterVisualState.fromContext({
    required BuildContext context,
    required bool hasSelectedMicrophone,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final activeFillColor = isDark
        ? const Color(0xFF30D158)
        : const Color(0xFF34C759);

    if (!hasSelectedMicrophone) {
      return _MicInputMeterVisualState(
        outlineColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: 0.62,
        ),
        chromeColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.34,
        ),
        borderColor: theme.dividerColor.withValues(alpha: 0.14),
        glyphTrackColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: isDark ? 0.22 : 0.14,
        ),
        glyphFillColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: isDark ? 0.22 : 0.16,
        ),
      );
    }

    return _MicInputMeterVisualState(
      outlineColor: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.92),
      chromeColor: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.48,
      ),
      borderColor: theme.dividerColor.withValues(alpha: 0.18),
      glyphTrackColor: theme.colorScheme.onSurfaceVariant.withValues(
        alpha: isDark ? 0.26 : 0.18,
      ),
      glyphFillColor: activeFillColor,
    );
  }
}
