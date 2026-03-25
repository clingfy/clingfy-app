import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

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
      final inactiveTrackColor =
          Theme.of(context).sliderTheme.inactiveTrackColor ??
          MacosColors.sliderBackgroundColor;
      final slider = MacosSlider(
        value: value,
        onChanged: _handleChanged,
        min: widget.min,
        max: widget.max,
        color: MacosTheme.of(context).primaryColor,
        backgroundColor: inactiveTrackColor,
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
