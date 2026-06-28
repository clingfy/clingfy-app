import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:flutter/material.dart';

/// A transient "cut here" surface shown only while the cut modifier (Option) is
/// held over the timeline.
///
/// It lives inside [TimelineScrollableCanvas]'s content-space `Stack`, so a
/// pointer's local x maps straight to a timeline ms via
/// [TimelineViewportController.canvasXToMs] — no scroll-offset math, and it
/// never covers the track-header column (that lives in the outer row). Because
/// it is mounted *only while armed*, it can't shadow the timeline's
/// scroll/pan or the clip trim handles when the modifier is up — which is what
/// makes a held-modifier tool conflict-free where a persistent opaque overlay
/// would not.
///
/// ```
///        Option held? ── no ──► layer absent, normal seek/select/scroll
///             │ yes
///             ▼
///   layer mounts (content-space, full canvas) ─ opaque
///     hover → guide line + scissors glyph follow pointer (ValueNotifier)
///     click → canvasXToMs(localX) → onCutAt(ms)
/// ```
///
/// The guide line + scissors glyph follow the pointer through a local
/// [ValueNotifier], repainted inside a [RepaintBoundary], so a mouse move never
/// rebuilds the lanes or ruler.
class ScissorsCutLayer extends StatefulWidget {
  const ScissorsCutLayer({
    super.key,
    required this.viewportController,
    required this.onCutAt,
  });

  final TimelineViewportController viewportController;

  /// Called with the timeline ms under the pointer when the user clicks to cut.
  final ValueChanged<int> onCutAt;

  @override
  State<ScissorsCutLayer> createState() => _ScissorsCutLayerState();
}

class _ScissorsCutLayerState extends State<ScissorsCutLayer> {
  // Pointer position in content-space, or null when the pointer is off the
  // layer. A ValueNotifier (not setState) so following the pointer repaints
  // only the guide overlay inside its RepaintBoundary, never the lanes/ruler.
  final ValueNotifier<Offset?> _pointer = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  void _cutAt(double localX) {
    widget.onCutAt(widget.viewportController.canvasXToMs(localX));
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Positioned.fill(
      child: MouseRegion(
        key: const Key('timeline_scissors_cut_layer'),
        // Flutter has no scissors system cursor on macOS; hide the OS cursor
        // and draw our own glyph that follows the pointer.
        cursor: SystemMouseCursors.none,
        opaque: true,
        // Seed the glyph position on mount: onHover doesn't fire for a pointer
        // that's already stationary when the layer appears, so without onEnter
        // the OS cursor is hidden but no scissors is drawn until the first move.
        onEnter: (e) => _pointer.value = e.localPosition,
        onHover: (e) => _pointer.value = e.localPosition,
        onExit: (_) => _pointer.value = null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            _pointer.value = d.localPosition;
            _cutAt(d.localPosition.dx);
          },
          child: RepaintBoundary(
            child: ValueListenableBuilder<Offset?>(
              valueListenable: _pointer,
              builder: (context, p, _) {
                if (p == null) return const SizedBox.expand();
                return Stack(
                  children: [
                    // Vertical guide showing the cut column.
                    Positioned(
                      left: p.dx - _kGuideWidth / 2,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: _kGuideWidth,
                          color: accent.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                    // Scissors glyph riding the pointer (the "cursor").
                    Positioned(
                      left: p.dx + _kGlyphGap,
                      top: (p.dy - _kGlyphSize / 2).clamp(0.0, double.infinity),
                      child: IgnorePointer(
                        child: Icon(
                          Icons.content_cut_rounded,
                          size: _kGlyphSize,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

const double _kGuideWidth = 1.5;
const double _kGlyphSize = 18.0;
const double _kGlyphGap = 4.0;
