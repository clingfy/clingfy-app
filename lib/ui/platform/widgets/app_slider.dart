import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

const _kMacosSliderMinWidth = 100.0;
const _kMacosSliderBorderRadius = 16.0;
const _kMacosSliderHeight = 4.0;
const _kMacosSliderOverallHeight = 20.0;
const _kDarkSliderThumbDiameter = 10.0;

/// Cross-platform slider wrapper.
///
/// - macOS: `MacosSlider`
/// - fallback: Material `Slider`
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  static const double _kDisabledOpacity = 0.55;

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
    final clamped = value.clamp(widget.min, widget.max).toDouble();
    final divisions = widget.divisions;
    if (divisions == null || divisions <= 0) {
      return clamped;
    }

    final step = (widget.max - widget.min) / divisions;
    if (step == 0) {
      return clamped;
    }

    final normalized =
        widget.min + (((clamped - widget.min) / step).round() * step);
    return normalized.clamp(widget.min, widget.max).toDouble();
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

  @override
  Widget build(BuildContext context) {
    final value = _normalize(widget.value);
    if (isMac()) {
      final theme = Theme.of(context);
      final sliderTheme = theme.sliderTheme;
      final inactiveTrackColor =
          sliderTheme.inactiveTrackColor ?? MacosColors.sliderBackgroundColor;
      final slider = theme.brightness == Brightness.dark
          ? _DarkMacosSlider(
              value: value,
              min: widget.min,
              max: widget.max,
              onChanged: _handleChanged,
              activeColor:
                  sliderTheme.activeTrackColor ??
                  MacosTheme.of(context).primaryColor,
              backgroundColor: inactiveTrackColor,
              thumbColor:
                  sliderTheme.thumbColor ?? MacosColors.sliderThumbColor,
            )
          : MacosSlider(
              value: value,
              onChanged: _handleChanged,
              min: widget.min,
              max: widget.max,
              color:
                  sliderTheme.activeTrackColor ??
                  MacosTheme.of(context).primaryColor,
              backgroundColor: inactiveTrackColor,
              thumbColor:
                  sliderTheme.thumbColor ?? MacosColors.sliderThumbColor,
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

      return Listener(
        onPointerDown: _handlePointerDown,
        onPointerUp: _handlePointerEnd,
        onPointerCancel: _handlePointerEnd,
        child: slider,
      );
    }

    return Slider(
      value: value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      onChanged: widget.onChanged == null ? null : _handleChanged,
      onChangeEnd: widget.onChanged == null
          ? null
          : (value) => widget.onChangeEnd?.call(_normalize(value)),
    );
  }
}

class _DarkMacosSlider extends StatelessWidget {
  const _DarkMacosSlider({
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    required this.activeColor,
    required this.backgroundColor,
    required this.thumbColor,
  }) : assert(value >= min && value <= max),
       assert(min < max);

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final Color activeColor;
  final Color backgroundColor;
  final Color thumbColor;

  double get _percentage => (value - min) / (max - min);

  void _update(double sliderWidth, double localPosition) {
    final newValue = (localPosition / sliderWidth) * (max - min) + min;
    onChanged(newValue.clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      value: value.toStringAsFixed(2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _kMacosSliderMinWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            var width = constraints.maxWidth;
            if (width.isInfinite) {
              width = _kMacosSliderMinWidth;
            }

            const horizontalPadding = _kDarkSliderThumbDiameter / 2;
            width -= horizontalPadding * 2;

            final resolvedActiveColor = MacosDynamicColor.resolve(
              activeColor,
              context,
            );
            final resolvedBackgroundColor = MacosDynamicColor.resolve(
              backgroundColor,
              context,
            );
            final resolvedThumbColor = MacosDynamicColor.resolve(
              thumbColor,
              context,
            );
            final thumbCenterX = horizontalPadding + (width * _percentage);

            return SizedBox(
              height: _kMacosSliderOverallHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (details) {
                  _update(width, details.localPosition.dx - horizontalPadding);
                },
                onHorizontalDragUpdate: (details) {
                  _update(width, details.localPosition.dx - horizontalPadding);
                },
                onTapDown: (details) {
                  _update(width, details.localPosition.dx - horizontalPadding);
                },
                child: Stack(
                  children: [
                    Positioned(
                      left: horizontalPadding,
                      top:
                          (_kMacosSliderOverallHeight - _kMacosSliderHeight) /
                          2,
                      child: Container(
                        key: const Key('app_slider_inactive_track'),
                        width: width,
                        height: _kMacosSliderHeight,
                        decoration: BoxDecoration(
                          color: resolvedBackgroundColor,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(_kMacosSliderBorderRadius),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: horizontalPadding,
                      top:
                          (_kMacosSliderOverallHeight - _kMacosSliderHeight) /
                          2,
                      child: Container(
                        width: width * _percentage,
                        height: _kMacosSliderHeight,
                        decoration: BoxDecoration(
                          color: resolvedActiveColor,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(_kMacosSliderBorderRadius),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: thumbCenterX - (_kDarkSliderThumbDiameter / 2),
                      top:
                          (_kMacosSliderOverallHeight -
                              _kDarkSliderThumbDiameter) /
                          2,
                      child: Container(
                        key: const Key('app_slider_thumb'),
                        width: _kDarkSliderThumbDiameter,
                        height: _kDarkSliderThumbDiameter,
                        decoration: BoxDecoration(
                          color: resolvedThumbColor,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(_kDarkSliderThumbDiameter),
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color.fromRGBO(0, 0, 0, 0.12),
                              blurRadius: 1,
                              spreadRadius: 1,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
