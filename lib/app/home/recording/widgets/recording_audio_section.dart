import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;
import 'package:shared_preferences/shared_preferences.dart';

const _micInputMonitorCompactKey = Key('mic_input_monitor_compact');
const _micInputMonitorExpandedKey = Key('mic_input_monitor_expanded');
const _micInputMonitorToggleKey = Key('mic_input_monitor_toggle');
const _micInputMonitorBadgeKey = Key('mic_input_monitor_badge');

enum _MicMonitorVisibility {
  hidden('hidden'),
  compact('compact'),
  expanded('expanded');

  const _MicMonitorVisibility(this.storageValue);

  final String storageValue;

  static _MicMonitorVisibility? fromStorageValue(String? raw) {
    for (final value in _MicMonitorVisibility.values) {
      if (value.storageValue == raw) {
        return value;
      }
    }
    return null;
  }
}

class RecordingAudioSection extends StatefulWidget {
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

  @override
  State<RecordingAudioSection> createState() => _RecordingAudioSectionState();
}

class _RecordingAudioSectionState extends State<RecordingAudioSection> {
  static const _prefMicMonitorVisibility = 'pref.recordingMicMonitorVisibility';
  static const _monitorAnimationDuration = Duration(milliseconds: 180);
  static const _monitorInnerAnimationDuration = Duration(milliseconds: 140);

  _MicMonitorVisibility _preferredVisibleMode = _MicMonitorVisibility.compact;
  bool _didHydrateMonitorPreference = false;

  bool get _hasSelectedMicrophone =>
      _validAudioId != '__none__' && _validAudioId.isNotEmpty;

  String get _validAudioId =>
      widget.selectedAudioSourceId == '__none__' ||
          widget.audioSources.any(
            (source) => source.id == widget.selectedAudioSourceId,
          )
      ? widget.selectedAudioSourceId
      : '__none__';

  _MicMonitorVisibility get _effectiveVisibility {
    if (!_hasSelectedMicrophone) return _MicMonitorVisibility.hidden;
    return _preferredVisibleMode;
  }

  Duration get _animatedDuration =>
      _didHydrateMonitorPreference ? _monitorAnimationDuration : Duration.zero;

  Duration get _animatedInnerDuration => _didHydrateMonitorPreference
      ? _monitorInnerAnimationDuration
      : Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadMicMonitorPreference();
  }

  Future<void> _loadMicMonitorPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final rawValue = prefs.getString(_prefMicMonitorVisibility);
    final resolved =
        _MicMonitorVisibility.fromStorageValue(rawValue) ??
        _MicMonitorVisibility.compact;

    if (!mounted) return;

    setState(() {
      _preferredVisibleMode = resolved == _MicMonitorVisibility.hidden
          ? _MicMonitorVisibility.compact
          : resolved;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _didHydrateMonitorPreference = true;
      });
    });
  }

  Future<void> _persistMicMonitorPreference(
    _MicMonitorVisibility visibility,
  ) async {
    if (visibility == _MicMonitorVisibility.hidden) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefMicMonitorVisibility, visibility.storageValue);
  }

  void _setPreferredMicMonitorVisibility(_MicMonitorVisibility visibility) {
    if (visibility == _MicMonitorVisibility.hidden ||
        _preferredVisibleMode == visibility) {
      return;
    }

    setState(() {
      _preferredVisibleMode = visibility;
    });
    _persistMicMonitorPreference(visibility);
  }

  void _toggleExpanded() {
    final next = _preferredVisibleMode == _MicMonitorVisibility.expanded
        ? _MicMonitorVisibility.compact
        : _MicMonitorVisibility.expanded;
    _setPreferredMicMonitorVisibility(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSection(
      title: l10n.audio,
      titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
      trailing: AppIconButton(
        tooltip: l10n.refreshAudio,
        onPressed: (widget.loadingAudio || widget.isRecording)
            ? null
            : widget.onRefreshAudio,
        icon: Icons.refresh,
      ),
      child: widget.loadingAudio
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              children: [
                AppFormRow(
                  label: l10n.inputDevice,
                  control: PlatformDropdown<String>(
                    value: _validAudioId,
                    items: [
                      PlatformMenuItem(value: '__none__', label: l10n.noAudio),
                      ...widget.audioSources.map(
                        (source) => PlatformMenuItem(
                          value: source.id,
                          label: source.name,
                        ),
                      ),
                    ],
                    onChanged: widget.isRecording
                        ? null
                        : widget.onAudioSourceChanged,
                  ),
                ),
                AnimatedSwitcher(
                  duration: _animatedDuration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SizeTransition(
                        sizeFactor: animation,
                        axisAlignment: -1,
                        child: child,
                      ),
                    );
                  },
                  child: _effectiveVisibility == _MicMonitorVisibility.hidden
                      ? const SizedBox.shrink(
                          key: ValueKey('mic_monitor_hidden'),
                        )
                      : Padding(
                          key: ValueKey<String>(
                            'mic_monitor_${_effectiveVisibility.storageValue}',
                          ),
                          padding: const EdgeInsets.only(
                            top: AppSidebarTokens.rowGap,
                          ),
                          child: AppFormRow(
                            control: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: AppSidebarTokens.controlMinWidth,
                                maxWidth: AppSidebarTokens.controlMaxWidth,
                              ),
                              child: _MicMonitorContainer(
                                visibility: _effectiveVisibility,
                                levelLinear: widget.micInputLevelLinear,
                                levelDbfs: widget.micInputLevelDbfs,
                                inputTooLow: widget.micInputTooLow,
                                onToggleExpanded: _toggleExpanded,
                                sizeAnimationDuration: _animatedDuration,
                                contentAnimationDuration:
                                    _animatedInnerDuration,
                              ),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: AppSidebarTokens.rowGap),
                AppToggleRow(
                  title: l10n.recordingSystemAudio,
                  value: widget.systemAudioEnabled,
                  onChanged: widget.isRecording
                      ? null
                      : widget.onSystemAudioEnabledChanged,
                ),
                if (widget.systemAudioEnabled &&
                    _validAudioId != '__none__') ...[
                  const SizedBox(height: AppSidebarTokens.rowGap),
                  AppToggleRow(
                    title: l10n.recordingExcludeMicFromSystemAudio,
                    value: widget.excludeMicFromSystemAudio,
                    onChanged: widget.isRecording
                        ? null
                        : widget.onExcludeMicFromSystemAudioChanged,
                  ),
                ],
              ],
            ),
    );
  }
}

class _MicMonitorContainer extends StatelessWidget {
  const _MicMonitorContainer({
    required this.visibility,
    required this.levelLinear,
    required this.levelDbfs,
    required this.inputTooLow,
    required this.onToggleExpanded,
    required this.sizeAnimationDuration,
    required this.contentAnimationDuration,
  });

  final _MicMonitorVisibility visibility;
  final double levelLinear;
  final double levelDbfs;
  final bool inputTooLow;
  final VoidCallback onToggleExpanded;
  final Duration sizeAnimationDuration;
  final Duration contentAnimationDuration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: sizeAnimationDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: contentAnimationDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: visibility == _MicMonitorVisibility.expanded
            ? _MicInputMonitorPanel(
                key: const ValueKey('mic_monitor_expanded'),
                levelLinear: levelLinear,
                levelDbfs: levelDbfs,
                inputTooLow: inputTooLow,
                onCollapse: onToggleExpanded,
              )
            : _MicMonitorCompactRow(
                key: const ValueKey('mic_monitor_compact'),
                levelLinear: levelLinear,
                levelDbfs: levelDbfs,
                inputTooLow: inputTooLow,
                onExpand: onToggleExpanded,
              ),
      ),
    );
  }
}

class _MicMonitorCompactRow extends StatelessWidget {
  const _MicMonitorCompactRow({
    super.key,
    required this.levelLinear,
    required this.levelDbfs,
    required this.inputTooLow,
    required this.onExpand,
  });

  final double levelLinear;
  final double levelDbfs;
  final bool inputTooLow;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final meterState = _MicMonitorVisualState.fromContext(
      context: context,
      hasSelectedMicrophone: true,
      inputTooLow: inputTooLow,
    );
    final valueStyle = AppSidebarTokens.valueStyle(theme).copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final chromeColor = inputTooLow
        ? theme.colorScheme.error.withValues(alpha: 0.06)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2);
    final borderColor = inputTooLow
        ? theme.colorScheme.error.withValues(alpha: 0.14)
        : theme.dividerColor.withValues(alpha: 0.1);
    final trailing = inputTooLow
        ? _MicMonitorStatusBadge(
            key: const ValueKey('compact_low_input_badge'),
            label: l10n.micInputMonitorLowBadge,
            compact: true,
          )
        : Text(
            '${levelDbfs.toStringAsFixed(1)} dBFS',
            key: const ValueKey('compact_dbfs_value'),
            style: valueStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    return Tooltip(
      message: l10n.micInputMonitorExpandTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: _micInputMonitorCompactKey,
          onTap: onExpand,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: chromeColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.mic_none_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            l10n.micInputMonitorTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppSidebarTokens.valueStyle(theme).copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 6,
                              value: levelLinear.clamp(0.0, 1.0),
                              backgroundColor: meterState.backgroundColor,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                meterState.fillColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 140),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: trailing,
                ),
                const SizedBox(width: 2),
                _MicMonitorChevronButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: l10n.micInputMonitorExpandTooltip,
                  onPressed: onExpand,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicInputMonitorPanel extends StatelessWidget {
  const _MicInputMonitorPanel({
    super.key,
    required this.levelLinear,
    required this.levelDbfs,
    required this.inputTooLow,
    required this.onCollapse,
  });

  final double levelLinear;
  final double levelDbfs;
  final bool inputTooLow;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final panelTitleStyle = AppSidebarTokens.rowTitleStyle(
      theme,
    ).copyWith(fontSize: 12, fontWeight: FontWeight.w600);
    final valueStyle = AppSidebarTokens.valueStyle(theme);
    final helperStyle = AppSidebarTokens.helperStyle(theme);
    final meterState = _MicMonitorVisualState.fromContext(
      context: context,
      hasSelectedMicrophone: true,
      inputTooLow: inputTooLow,
    );
    final footerText = inputTooLow
        ? l10n.micInputMonitorLowHint
        : l10n.micInputMonitorLiveHint;

    return Container(
      key: _micInputMonitorExpandedKey,
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.micInputMonitorTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: panelTitleStyle,
                  ),
                ),
                const SizedBox(width: AppSidebarTokens.compactGap),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 140),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: inputTooLow
                      ? _MicMonitorStatusBadge(
                          key: const ValueKey('expanded_low_input_badge'),
                          label: l10n.micInputMonitorLowBadge,
                        )
                      : Text(
                          '${levelDbfs.toStringAsFixed(1)} dBFS',
                          key: const ValueKey('expanded_dbfs_value'),
                          style: valueStyle.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                ),
                const SizedBox(width: 4),
                _MicMonitorChevronButton(
                  tooltip: l10n.micInputMonitorCollapseTooltip,
                  icon: Icons.keyboard_arrow_up_rounded,
                  onPressed: onCollapse,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: levelLinear.clamp(0.0, 1.0),
                backgroundColor: meterState.backgroundColor,
                valueColor: AlwaysStoppedAnimation<Color>(meterState.fillColor),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 24,
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  footerText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: helperStyle.copyWith(color: meterState.footerColor),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MicMonitorChevronButton extends StatelessWidget {
  const _MicMonitorChevronButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (onPressed == null) {
      return Icon(
        icon,
        key: _micInputMonitorToggleKey,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    return AppIconButton(
      key: _micInputMonitorToggleKey,
      tooltip: tooltip,
      icon: icon,
      size: 18,
      color: theme.colorScheme.onSurfaceVariant,
      onPressed: onPressed,
    );
  }
}

class _MicMonitorStatusBadge extends StatelessWidget {
  const _MicMonitorStatusBadge({
    super.key,
    required this.label,
    this.compact = false,
  });

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      key: _micInputMonitorBadgeKey,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppSidebarTokens.valueStyle(theme).copyWith(
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

class _MicMonitorVisualState {
  const _MicMonitorVisualState({
    required this.fillColor,
    required this.backgroundColor,
    required this.footerColor,
  });

  final Color fillColor;
  final Color backgroundColor;
  final Color footerColor;

  factory _MicMonitorVisualState.fromContext({
    required BuildContext context,
    required bool hasSelectedMicrophone,
    required bool inputTooLow,
  }) {
    final theme = Theme.of(context);

    if (!hasSelectedMicrophone) {
      return _MicMonitorVisualState(
        fillColor: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.28),
        backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.75,
        ),
        footerColor: theme.colorScheme.onSurfaceVariant,
      );
    }

    if (inputTooLow) {
      return _MicMonitorVisualState(
        fillColor: theme.colorScheme.error,
        backgroundColor: theme.colorScheme.error.withValues(alpha: 0.12),
        footerColor: theme.colorScheme.error,
      );
    }

    return _MicMonitorVisualState(
      fillColor: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      footerColor: theme.colorScheme.onSurfaceVariant,
    );
  }
}
