import 'dart:math' as math;

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

const _kSliderMinWidth = 100.0;
const _kFieldSliderHeight = 40.0;
const _kCompactSliderHeight = 24.0;
const _kSliderShellRadius = 8.0;
const _kSliderShellPadding = 4.0;
const _kSliderTrackHeight = 8.0;
const _kSliderThumbWidth = 4.0;
const _kSliderThumbHeight = 22.0;
const _kSliderButtonSize = 20.0;
const _kSliderValueMinWidth = 56.0;
const _kSliderValueMaxWidth = 92.0;

enum AppSliderVariant { field, compact }

/// Cross-platform slider wrapper with a shared desktop shape.
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.variant = AppSliderVariant.field,
    this.valueLabel,
    this.semanticLabel,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final AppSliderVariant variant;
  final String? valueLabel;
  final String? semanticLabel;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  static const double _kDisabledOpacity = 0.55;
  static const double _kValueEpsilon = 0.0001;

  late double _lastValue;
  bool _gestureActive = false;

  bool get _isInteractive => widget.onChanged != null;

  @override
  void initState() {
    super.initState();
    _lastValue = _normalize(widget.value);
  }

  @override
  void didUpdateWidget(covariant AppSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastValue = _normalize(widget.value);
    if (!_isInteractive) {
      _gestureActive = false;
    }
  }

  double _normalize(double value) {
    final min = math.min(widget.min, widget.max);
    final max = math.max(widget.min, widget.max);
    final clamped = value.clamp(min, max).toDouble();
    final divisions = widget.divisions;
    if (divisions == null || divisions <= 0) {
      return clamped;
    }

    final range = max - min;
    if (range <= 0) {
      return clamped;
    }

    final step = range / divisions;
    final normalized = min + (((clamped - min) / step).round() * step);
    return normalized.clamp(min, max).toDouble();
  }

  double get _stepSize {
    final range = (widget.max - widget.min).abs();
    if (range <= 0) {
      return 0;
    }

    final divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      return range / divisions;
    }

    return range / 100;
  }

  String _defaultValueLabel(double value) {
    if ((value - value.roundToDouble()).abs() < _kValueEpsilon) {
      return value.round().toString();
    }

    return value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _resolvedValueLabel(double value) {
    final label = widget.valueLabel;
    if (label != null && label.trim().isNotEmpty) {
      return label;
    }
    return _defaultValueLabel(value);
  }

  void _handleChanged(double value) {
    final normalized = _normalize(value);
    _lastValue = normalized;
    widget.onChanged?.call(normalized);
  }

  void _handlePointerDown(PointerDownEvent _) {
    if (!_isInteractive) {
      return;
    }
    _gestureActive = true;
  }

  void _handlePointerEnd(PointerEvent _) {
    if (!_isInteractive || !_gestureActive) {
      return;
    }

    _gestureActive = false;
    widget.onChangeEnd?.call(_lastValue);
  }

  void _stepBy(int direction) {
    if (!_isInteractive) {
      return;
    }

    final step = _stepSize;
    if (step <= 0) {
      return;
    }

    final nextValue = _normalize(_lastValue + (step * direction));
    if ((nextValue - _lastValue).abs() < _kValueEpsilon) {
      return;
    }

    _handleChanged(nextValue);
    widget.onChangeEnd?.call(nextValue);
  }

  bool _canStepDown(double value) =>
      _isInteractive && value > widget.min + _kValueEpsilon;

  bool _canStepUp(double value) =>
      _isInteractive && value < widget.max - _kValueEpsilon;

  Widget _buildTrack({
    required double value,
    required double height,
    required Color activeColor,
    required Color trackColor,
    required Color thumbColor,
    required String semanticValue,
  }) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: _SliderTrack(
        value: value,
        min: widget.min,
        max: widget.max,
        height: height,
        activeColor: activeColor,
        trackColor: trackColor,
        thumbColor: thumbColor,
        semanticLabel: widget.semanticLabel,
        semanticValue: semanticValue,
        interactive: _isInteractive,
        onChanged: _handleChanged,
      ),
    );
  }

  Widget _buildFieldSlider(
    BuildContext context, {
    required double value,
    required Color shellColor,
    required Color shellBorderColor,
    required Color activeColor,
    required Color trackColor,
    required Color thumbColor,
    required Color valueColor,
    required Color secondaryIconColor,
    required TextStyle valueStyle,
    required String semanticValue,
    required String increaseTooltip,
    required String decreaseTooltip,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: _kSliderMinWidth),
      child: Container(
        height: _kFieldSliderHeight,
        decoration: BoxDecoration(
          color: shellColor,
          borderRadius: BorderRadius.circular(_kSliderShellRadius),
          border: Border.all(color: shellBorderColor),
        ),
        padding: const EdgeInsets.all(_kSliderShellPadding),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: _kSliderValueMinWidth,
                maxWidth: _kSliderValueMaxWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  semanticValue,
                  key: const Key('app_slider_value_label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle.copyWith(color: valueColor),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _SliderStepButton(
              buttonKey: const Key('app_slider_decrement_button'),
              icon: Icons.remove_rounded,
              tooltip: decreaseTooltip,
              enabled: _canStepDown(value),
              highlighted: true,
              backgroundColor: activeColor,
              foregroundColor:
                  ThemeData.estimateBrightnessForColor(activeColor) ==
                      Brightness.dark
                  ? Colors.white
                  : const Color(0xFF160D24),
              onPressed: () => _stepBy(-1),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _buildTrack(
                value: value,
                height: _kSliderButtonSize,
                activeColor: activeColor,
                trackColor: trackColor,
                thumbColor: thumbColor,
                semanticValue: semanticValue,
              ),
            ),
            const SizedBox(width: 4),
            _SliderStepButton(
              buttonKey: const Key('app_slider_increment_button'),
              icon: Icons.add_rounded,
              tooltip: increaseTooltip,
              enabled: _canStepUp(value),
              highlighted: false,
              backgroundColor: trackColor,
              foregroundColor: secondaryIconColor,
              onPressed: () => _stepBy(1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactSlider({
    required double value,
    required Color activeColor,
    required Color trackColor,
    required Color thumbColor,
    required String semanticValue,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: _kSliderMinWidth),
      child: SizedBox(
        height: _kCompactSliderHeight,
        child: _buildTrack(
          value: value,
          height: _kCompactSliderHeight,
          activeColor: activeColor,
          trackColor: trackColor,
          thumbColor: thumbColor,
          semanticValue: semanticValue,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _normalize(widget.value);
    final semanticValue = _resolvedValueLabel(value);
    final theme = Theme.of(context);
    final sliderTheme = SliderTheme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final brightness = theme.brightness;
    final activeColor =
        sliderTheme.activeTrackColor ?? theme.colorScheme.primary;
    final trackColor =
        sliderTheme.inactiveTrackColor ??
        (brightness == Brightness.dark
            ? theme.appTokens.panelBorder
            : theme.colorScheme.surfaceContainerHighest);
    final shellColor = brightness == Brightness.dark
        ? theme.appTokens.editorChromeBackground
        : theme.colorScheme.surface;
    final shellBorderColor = theme.dividerColor.withValues(
      alpha: brightness == Brightness.dark ? 0.28 : 0.18,
    );
    final thumbColor = brightness == Brightness.dark
        ? Colors.white
        : theme.colorScheme.onSurface.withValues(alpha: 0.88);
    final valueColor = theme.colorScheme.onSurfaceVariant;
    final secondaryIconColor = theme.colorScheme.onSurfaceVariant;
    final valueStyle = theme.appTypography.value;

    final slider = widget.variant == AppSliderVariant.compact
        ? _buildCompactSlider(
            value: value,
            activeColor: activeColor,
            trackColor: trackColor,
            thumbColor: thumbColor,
            semanticValue: semanticValue,
          )
        : _buildFieldSlider(
            context,
            value: value,
            shellColor: shellColor,
            shellBorderColor: shellBorderColor,
            activeColor: activeColor,
            trackColor: trackColor,
            thumbColor: thumbColor,
            valueColor: valueColor,
            secondaryIconColor: secondaryIconColor,
            valueStyle: valueStyle,
            semanticValue: semanticValue,
            increaseTooltip: l10n.increase,
            decreaseTooltip: l10n.decrease,
          );

    if (!_isInteractive) {
      return Semantics(
        enabled: false,
        child: Opacity(
          opacity: _kDisabledOpacity,
          child: IgnorePointer(child: slider),
        ),
      );
    }

    return slider;
  }
}

class _SliderTrack extends StatelessWidget {
  const _SliderTrack({
    required this.value,
    required this.min,
    required this.max,
    required this.height,
    required this.activeColor,
    required this.trackColor,
    required this.thumbColor,
    required this.semanticValue,
    required this.interactive,
    required this.onChanged,
    this.semanticLabel,
  });

  final double value;
  final double min;
  final double max;
  final double height;
  final Color activeColor;
  final Color trackColor;
  final Color thumbColor;
  final String? semanticLabel;
  final String semanticValue;
  final bool interactive;
  final ValueChanged<double> onChanged;

  double get _percentage {
    final range = max - min;
    if (range <= 0) {
      return 0;
    }
    return ((value - min) / range).clamp(0.0, 1.0);
  }

  void _update(double sliderWidth, double localPosition) {
    if (!interactive || sliderWidth <= 0) {
      return;
    }

    final clampedPosition = localPosition.clamp(0.0, sliderWidth).toDouble();
    final range = max - min;
    final nextValue = min + ((clampedPosition / sliderWidth) * range);
    onChanged(
      nextValue.clamp(math.min(min, max), math.max(min, max)).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      enabled: interactive,
      label: semanticLabel,
      value: semanticValue,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _kSliderMinWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            var width = constraints.maxWidth;
            if (!width.isFinite || width <= 0) {
              width = _kSliderMinWidth;
            }

            const horizontalPadding = _kSliderThumbWidth / 2;
            final trackWidth = math.max(0.0, width - (horizontalPadding * 2));
            final trackTop = (height - _kSliderTrackHeight) / 2;
            final thumbTop = (height - _kSliderThumbHeight) / 2;
            final thumbCenterX = horizontalPadding + (trackWidth * _percentage);

            return MouseRegion(
              cursor: interactive
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: SizedBox(
                height: height,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: interactive
                      ? (details) => _update(
                          trackWidth,
                          details.localPosition.dx - horizontalPadding,
                        )
                      : null,
                  onHorizontalDragStart: interactive
                      ? (details) => _update(
                          trackWidth,
                          details.localPosition.dx - horizontalPadding,
                        )
                      : null,
                  onHorizontalDragUpdate: interactive
                      ? (details) => _update(
                          trackWidth,
                          details.localPosition.dx - horizontalPadding,
                        )
                      : null,
                  child: Stack(
                    children: [
                      Positioned(
                        left: horizontalPadding,
                        top: trackTop,
                        child: Container(
                          key: const Key('app_slider_track'),
                          width: trackWidth,
                          height: _kSliderTrackHeight,
                          decoration: BoxDecoration(
                            color: trackColor,
                            borderRadius: BorderRadius.circular(
                              _kSliderTrackHeight / 2,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: horizontalPadding,
                        top: trackTop,
                        child: Container(
                          key: const Key('app_slider_active_fill'),
                          width: trackWidth * _percentage,
                          height: _kSliderTrackHeight,
                          decoration: BoxDecoration(
                            color: activeColor,
                            borderRadius: BorderRadius.circular(
                              _kSliderTrackHeight / 2,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: thumbCenterX - (_kSliderThumbWidth / 2),
                        top: thumbTop,
                        child: Container(
                          key: const Key('app_slider_thumb'),
                          width: _kSliderThumbWidth,
                          height: _kSliderThumbHeight,
                          decoration: BoxDecoration(
                            color: thumbColor,
                            borderRadius: BorderRadius.circular(
                              _kSliderThumbWidth,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color.fromRGBO(0, 0, 0, 0.18),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SliderStepButton extends StatelessWidget {
  const _SliderStepButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.highlighted,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool highlighted;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final resolvedBackground = enabled
        ? backgroundColor
        : backgroundColor.withValues(alpha: highlighted ? 0.42 : 0.55);
    final resolvedForeground = enabled
        ? foregroundColor
        : foregroundColor.withValues(alpha: 0.45);

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: SizedBox(
          key: buttonKey,
          width: _kSliderButtonSize,
          height: _kSliderButtonSize,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? onPressed : null,
              borderRadius: BorderRadius.circular(_kSliderShellRadius - 2),
              child: Ink(
                decoration: BoxDecoration(
                  color: resolvedBackground,
                  borderRadius: BorderRadius.circular(_kSliderShellRadius - 2),
                ),
                child: Icon(icon, size: 16, color: resolvedForeground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
