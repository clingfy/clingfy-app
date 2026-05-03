import 'dart:async';

import 'package:flutter/material.dart';

class PreviewWithOverlayControls extends StatefulWidget {
  final Widget preview;
  final bool isPlaying;
  final bool controlsEnabled;
  final bool allowOverlayInteraction;
  final Function(bool) onPlayPause;

  const PreviewWithOverlayControls({
    super.key,
    required this.preview,
    required this.isPlaying,
    required this.controlsEnabled,
    bool? allowOverlayInteraction,
    required this.onPlayPause,
  }) : allowOverlayInteraction = allowOverlayInteraction ?? controlsEnabled;

  @override
  State<PreviewWithOverlayControls> createState() =>
      _PreviewWithOverlayControlsState();
}

class _PreviewWithOverlayControlsState
    extends State<PreviewWithOverlayControls> {
  static const double _buttonSize = 80;
  static const Duration _hideDelay = Duration(seconds: 1);
  bool _showButton = false;
  Timer? _hideTimer;

  void _onEnter() {
    if (!widget.controlsEnabled || !widget.allowOverlayInteraction) return;
    _hideTimer?.cancel();
    if (!_showButton) setState(() => _showButton = true);
  }

  void _onExit() {
    if (!widget.controlsEnabled || !widget.allowOverlayInteraction) return;
    _hideTimer?.cancel();
    if (!widget.isPlaying) return;
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      if (_showButton) setState(() => _showButton = false);
    });
  }

  @override
  void didUpdateWidget(covariant PreviewWithOverlayControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.controlsEnabled || !widget.allowOverlayInteraction) {
      _hideTimer?.cancel();
      if (_showButton) setState(() => _showButton = false);
      return;
    }
    if (oldWidget.isPlaying && !widget.isPlaying) {
      _hideTimer?.cancel();
      if (!_showButton) setState(() => _showButton = true);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final interactive =
        widget.controlsEnabled && widget.allowOverlayInteraction;
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Theme.of(context).colorScheme.scrim,
            child: widget.preview,
          ),
        ),
        Positioned.fill(
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: interactive && _showButton ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: _PlayPauseVisual(
                    isPlaying: widget.isPlaying,
                    isHovering: _showButton,
                  ),
                ),
              ),
              SizedBox(
                width: _buttonSize,
                height: _buttonSize,
                child: MouseRegion(
                  onEnter: interactive ? (_) => _onEnter() : null,
                  onExit: interactive ? (_) => _onExit() : null,
                  cursor: interactive
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: interactive
                        ? () => widget.onPlayPause(!widget.isPlaying)
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayPauseVisual extends StatefulWidget {
  final bool isPlaying;
  final bool isHovering;

  const _PlayPauseVisual({required this.isPlaying, required this.isHovering});

  @override
  State<_PlayPauseVisual> createState() => _PlayPauseVisualState();
}

class _PlayPauseVisualState extends State<_PlayPauseVisual>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: widget.isPlaying ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_PlayPauseVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hovering = widget.isHovering;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: colors.scrim.withValues(alpha: hovering ? 0.6 : 0.4),
        shape: BoxShape.circle,
        border: Border.all(
          color: colors.onPrimary.withValues(alpha: hovering ? 0.5 : 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.scrim.withValues(alpha: 0.55),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: colors.scrim.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: AnimatedIcon(
          icon: AnimatedIcons.play_pause,
          progress: _controller,
          color: colors.onPrimary,
          size: 40,
        ),
      ),
    );
  }
}
