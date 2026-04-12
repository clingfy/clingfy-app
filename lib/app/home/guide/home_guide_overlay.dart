import 'dart:math' as math;

import 'package:clingfy/app/home/guide/home_guide_anchors.dart';
import 'package:clingfy/app/home/guide/home_guide_controller.dart';
import 'package:clingfy/app/home/guide/home_guide_step.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class HomeGuideOverlay extends StatelessWidget {
  const HomeGuideOverlay({
    super.key,
    required this.controller,
    required this.anchors,
  });

  final HomeGuideController controller;
  final HomeGuideAnchors anchors;

  @override
  Widget build(BuildContext context) {
    return _HomeGuideOverlayBody(controller: controller, anchors: anchors);
  }
}

class _HomeGuideOverlayBody extends StatefulWidget {
  const _HomeGuideOverlayBody({
    required this.controller,
    required this.anchors,
  });

  final HomeGuideController controller;
  final HomeGuideAnchors anchors;

  @override
  State<_HomeGuideOverlayBody> createState() => _HomeGuideOverlayBodyState();
}

class _HomeGuideOverlayBodyState extends State<_HomeGuideOverlayBody> {
  static const int _maxMeasurementRetries = 3;

  final GlobalKey _overlayBoundsKey = GlobalKey(
    debugLabel: 'homeGuideOverlayBounds',
  );

  Rect? _highlightRect;
  double _highlightBorderRadius = 0;
  bool _observedVisible = false;
  HomeGuideStep _observedStep = HomeGuideStep.sidebar;
  int _observedSpotlightRequestToken = 0;
  int _measurementSequence = 0;

  HomeGuideController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    _observedVisible = _controller.isVisible;
    _observedStep = _controller.currentStep;
    _observedSpotlightRequestToken = _controller.spotlightRequestToken;
  }

  @override
  void didUpdateWidget(covariant _HomeGuideOverlayBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }

    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
    _observedVisible = widget.controller.isVisible;
    _observedStep = widget.controller.currentStep;
    _observedSpotlightRequestToken = widget.controller.spotlightRequestToken;
    _measurementSequence += 1;
    _highlightRect = null;
    _highlightBorderRadius = 0;
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }

    final isVisible = _controller.isVisible;
    final currentStep = _controller.currentStep;
    final spotlightRequestToken = _controller.spotlightRequestToken;

    final visibilityChanged = _observedVisible != isVisible;
    final stepChanged = _observedStep != currentStep;
    final spotlightRequestChanged =
        _observedSpotlightRequestToken != spotlightRequestToken;

    _observedVisible = isVisible;
    _observedStep = currentStep;
    _observedSpotlightRequestToken = spotlightRequestToken;

    if (!isVisible) {
      _measurementSequence += 1;
      if (visibilityChanged ||
          _highlightRect != null ||
          _highlightBorderRadius != 0) {
        setState(() {
          _highlightRect = null;
          _highlightBorderRadius = 0;
        });
      }
      return;
    }

    if (visibilityChanged || stepChanged) {
      _measurementSequence += 1;
      setState(() {
        if (stepChanged) {
          _highlightRect = null;
          _highlightBorderRadius = 0;
        }
      });
    }

    if (spotlightRequestChanged) {
      _startMeasurementSequence();
    }
  }

  void _startMeasurementSequence() {
    final sequence = ++_measurementSequence;
    _attemptMeasurement(sequence, 0);
  }

  void _attemptMeasurement(int sequence, int attempt) {
    if (!mounted ||
        sequence != _measurementSequence ||
        !_controller.isVisible) {
      return;
    }

    final geometry = _measureSpotlightGeometry();
    if (geometry != null) {
      final rectChanged = _highlightRect != geometry.rect;
      final radiusChanged = _highlightBorderRadius != geometry.borderRadius;
      if (rectChanged || radiusChanged) {
        setState(() {
          _highlightRect = geometry.rect;
          _highlightBorderRadius = geometry.borderRadius;
        });
      }
      return;
    }

    if (attempt >= _maxMeasurementRetries) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attemptMeasurement(sequence, attempt + 1);
    });
  }

  _HomeGuideSpotlightGeometry? _measureSpotlightGeometry() {
    final overlayObject = _overlayBoundsKey.currentContext?.findRenderObject();
    final targetObject = widget.anchors
        .keyForStep(_controller.currentStep)
        .currentContext
        ?.findRenderObject();

    if (overlayObject is! RenderBox ||
        targetObject is! RenderBox ||
        !overlayObject.hasSize ||
        !targetObject.hasSize) {
      return null;
    }

    final rawRect =
        targetObject.localToGlobal(Offset.zero, ancestor: overlayObject) &
        targetObject.size;
    if (rawRect.isEmpty) {
      return null;
    }

    final spec = _spotlightSpecForStep(context, _controller.currentStep);
    return _HomeGuideSpotlightGeometry(
      rect: _inflateAndClampRect(
        rect: rawRect,
        size: overlayObject.size,
        spec: spec,
      ),
      borderRadius: spec.borderRadius,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.isVisible) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: SizedBox.expand(
        key: _overlayBoundsKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final highlightRect = _highlightRect;
            final cardRect = _resolveCardRect(
              size: constraints.biggest,
              targetRect: highlightRect,
            );
            final content = _contentFor(context, _controller.currentStep);

            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('home_guide_overlay'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: CustomPaint(
                      painter: _HomeGuideScrimPainter(
                        highlightRect: highlightRect,
                        borderRadius: _highlightBorderRadius,
                        color: Colors.black.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ),
                if (highlightRect != null)
                  Positioned.fromRect(
                    rect: highlightRect,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const Key('home_guide_spotlight_frame'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            _highlightBorderRadius,
                          ),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.18),
                              blurRadius: 20,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: cardRect.left,
                  top: cardRect.top,
                  width: cardRect.width,
                  child: _HomeGuideCard(
                    key: const Key('home_guide_card'),
                    title: content.title,
                    body: content.body,
                    stepLabel: AppLocalizations.of(context)!
                        .homeGuideStepCounter(
                          _controller.currentStep.displayIndex,
                          HomeGuideStep.values.length,
                        ),
                    showBack: !_controller.currentStep.isFirst,
                    showDone: _controller.currentStep.isLast,
                    onBack: _controller.back,
                    onNext: _controller.next,
                    onSkip: () {
                      _controller.skip();
                    },
                    onDone: () {
                      _controller.finish();
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Rect _inflateAndClampRect({
    required Rect rect,
    required Size size,
    required _HomeGuideSpotlightSpec spec,
  }) {
    final inflated = rect.inflate(spec.inflate);
    return Rect.fromLTRB(
      math.max(spec.edgePadding, inflated.left),
      math.max(spec.edgePadding, inflated.top),
      math.min(size.width - spec.edgePadding, inflated.right),
      math.min(size.height - spec.edgePadding, inflated.bottom),
    );
  }

  _HomeGuideSpotlightSpec _spotlightSpecForStep(
    BuildContext context,
    HomeGuideStep step,
  ) {
    final chrome = Theme.of(context).appEditorChrome;
    return switch (step) {
      HomeGuideStep.sidebar => _HomeGuideSpotlightSpec(
        inflate: 0,
        borderRadius: chrome.panelRadius,
        edgePadding: 8,
      ),
      HomeGuideStep.captureSource ||
      HomeGuideStep.camera ||
      HomeGuideStep.output => const _HomeGuideSpotlightSpec(
        inflate: 10,
        borderRadius: 16,
        edgePadding: 8,
      ),
      HomeGuideStep.startRecording ||
      HomeGuideStep.help => _HomeGuideSpotlightSpec(
        inflate: 6,
        borderRadius: chrome.controlRadius,
        edgePadding: 8,
      ),
    };
  }

  Rect _resolveCardRect({required Size size, required Rect? targetRect}) {
    const cardWidth = 336.0;
    const estimatedCardHeight = 232.0;
    const edgePadding = 16.0;
    const gap = 18.0;
    final resolvedWidth = math.min(cardWidth, size.width - (edgePadding * 2));

    if (targetRect == null) {
      return Rect.fromLTWH(
        math.max(edgePadding, (size.width - resolvedWidth) / 2),
        math.max(edgePadding, (size.height - estimatedCardHeight) / 2),
        resolvedWidth,
        estimatedCardHeight,
      );
    }

    final canFitRight =
        size.width - targetRect.right - gap - edgePadding >= resolvedWidth;
    if (canFitRight) {
      return Rect.fromLTWH(
        targetRect.right + gap,
        _clampTop(
          targetRect.center.dy - (estimatedCardHeight / 2),
          size.height,
          estimatedCardHeight,
        ),
        resolvedWidth,
        estimatedCardHeight,
      );
    }

    final canFitLeft = targetRect.left - gap - edgePadding >= resolvedWidth;
    if (canFitLeft) {
      return Rect.fromLTWH(
        targetRect.left - gap - resolvedWidth,
        _clampTop(
          targetRect.center.dy - (estimatedCardHeight / 2),
          size.height,
          estimatedCardHeight,
        ),
        resolvedWidth,
        estimatedCardHeight,
      );
    }

    final canFitBelow =
        size.height - targetRect.bottom - gap - edgePadding >=
        estimatedCardHeight;
    if (canFitBelow) {
      return Rect.fromLTWH(
        _clampLeft(
          targetRect.center.dx - (resolvedWidth / 2),
          size.width,
          resolvedWidth,
        ),
        targetRect.bottom + gap,
        resolvedWidth,
        estimatedCardHeight,
      );
    }

    return Rect.fromLTWH(
      _clampLeft(
        targetRect.center.dx - (resolvedWidth / 2),
        size.width,
        resolvedWidth,
      ),
      _clampTop(
        targetRect.top - gap - estimatedCardHeight,
        size.height,
        estimatedCardHeight,
      ),
      resolvedWidth,
      estimatedCardHeight,
    );
  }

  double _clampLeft(double value, double width, double cardWidth) {
    const edgePadding = 16.0;
    return value.clamp(edgePadding, width - cardWidth - edgePadding);
  }

  double _clampTop(double value, double height, double cardHeight) {
    const edgePadding = 16.0;
    return value.clamp(edgePadding, height - cardHeight - edgePadding);
  }

  _HomeGuideContent _contentFor(BuildContext context, HomeGuideStep step) {
    final l10n = AppLocalizations.of(context)!;
    return switch (step) {
      HomeGuideStep.sidebar => _HomeGuideContent(
        title: l10n.homeGuideSidebarTitle,
        body: l10n.homeGuideSidebarBody,
      ),
      HomeGuideStep.captureSource => _HomeGuideContent(
        title: l10n.homeGuideCaptureSourceTitle,
        body: l10n.homeGuideCaptureSourceBody,
      ),
      HomeGuideStep.camera => _HomeGuideContent(
        title: l10n.homeGuideCameraTitle,
        body: l10n.homeGuideCameraBody,
      ),
      HomeGuideStep.output => _HomeGuideContent(
        title: l10n.homeGuideOutputTitle,
        body: l10n.homeGuideOutputBody,
      ),
      HomeGuideStep.startRecording => _HomeGuideContent(
        title: l10n.homeGuideStartRecordingTitle,
        body: l10n.homeGuideStartRecordingBody,
      ),
      HomeGuideStep.help => _HomeGuideContent(
        title: l10n.homeGuideHelpTitle,
        body: l10n.homeGuideHelpBody,
      ),
    };
  }
}

class _HomeGuideCard extends StatelessWidget {
  const _HomeGuideCard({
    super.key,
    required this.title,
    required this.body,
    required this.stepLabel,
    required this.showBack,
    required this.showDone,
    required this.onBack,
    required this.onNext,
    required this.onSkip,
    required this.onDone,
  });

  final String title;
  final String body;
  final String stepLabel;
  final bool showBack;
  final bool showDone;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.all(spacing.lg),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(
            theme.appEditorChrome.panelRadius,
          ),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          key: const Key('home_guide_card_content'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              stepLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.sm),
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.sm),
            Text(body, style: theme.textTheme.bodyMedium),
            SizedBox(height: spacing.lg),
            Wrap(
              spacing: spacing.sm,
              runSpacing: spacing.sm,
              alignment: WrapAlignment.spaceBetween,
              children: [
                AppButton(
                  key: const Key('home_guide_skip_button'),
                  label: l10n.skip,
                  variant: AppButtonVariant.secondary,
                  onPressed: onSkip,
                ),
                if (showBack)
                  AppButton(
                    key: const Key('home_guide_back_button'),
                    label: l10n.back,
                    variant: AppButtonVariant.secondary,
                    onPressed: onBack,
                  ),
                AppButton(
                  key: Key(
                    showDone
                        ? 'home_guide_done_button'
                        : 'home_guide_next_button',
                  ),
                  label: showDone ? l10n.done : l10n.next,
                  onPressed: showDone ? onDone : onNext,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeGuideContent {
  const _HomeGuideContent({required this.title, required this.body});

  final String title;
  final String body;
}

class _HomeGuideSpotlightSpec {
  const _HomeGuideSpotlightSpec({
    required this.inflate,
    required this.borderRadius,
    required this.edgePadding,
  });

  final double inflate;
  final double borderRadius;
  final double edgePadding;
}

class _HomeGuideSpotlightGeometry {
  const _HomeGuideSpotlightGeometry({
    required this.rect,
    required this.borderRadius,
  });

  final Rect rect;
  final double borderRadius;
}

class _HomeGuideScrimPainter extends CustomPainter {
  const _HomeGuideScrimPainter({
    required this.highlightRect,
    required this.borderRadius,
    required this.color,
  });

  final Rect? highlightRect;
  final double borderRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..color = color);

    final rect = highlightRect;
    if (rect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)),
        Paint()..blendMode = BlendMode.clear,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HomeGuideScrimPainter oldDelegate) {
    return oldDelegate.highlightRect != highlightRect ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.color != color;
  }
}
