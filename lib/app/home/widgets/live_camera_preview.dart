import 'package:flutter/material.dart';

import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/widgets/camera_overlay_bubble.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';

/// Immutable snapshot of the recording-overlay styling the live in-app camera
/// preview needs. Value-equal so a `context.select` upstream only rebuilds the
/// preview when a style the bubble actually renders changes.
@immutable
class CameraOverlayPreviewStyle {
  const CameraOverlayPreviewStyle({
    this.shape = OverlayShape.defaultValue,
    this.roundness = 0.0,
    this.opacity = 1.0,
    this.mirror = true,
    this.shadow = OverlayShadow.none,
    this.border = OverlayBorder.none,
    this.borderWidth = 0.0,
    this.borderColor = 0xFFFFFFFF,
  });

  factory CameraOverlayPreviewStyle.fromController(OverlayController o) {
    return CameraOverlayPreviewStyle(
      shape: o.overlayShape,
      roundness: o.overlayRoundness,
      opacity: o.overlayOpacity,
      mirror: o.overlayMirror,
      shadow: o.overlayShadow,
      border: o.overlayBorder,
      borderWidth: o.overlayBorderWidth,
      borderColor: o.overlayBorderColor,
    );
  }

  final OverlayShape shape;
  final double roundness;
  final double opacity;
  final bool mirror;
  final OverlayShadow shadow;
  final OverlayBorder border;
  final double borderWidth;
  final int borderColor;

  bool get hasBorder => border != OverlayBorder.none && borderWidth > 0;

  @override
  bool operator ==(Object other) =>
      other is CameraOverlayPreviewStyle &&
      other.shape == shape &&
      other.roundness == roundness &&
      other.opacity == opacity &&
      other.mirror == mirror &&
      other.shadow == shadow &&
      other.border == border &&
      other.borderWidth == borderWidth &&
      other.borderColor == borderColor;

  @override
  int get hashCode => Object.hash(
    shape,
    roundness,
    opacity,
    mirror,
    shadow,
    border,
    borderWidth,
    borderColor,
  );
}

/// Phase 9.3.1 — live camera preview rendered as a Flutter [Texture] inside the
/// app window (NOT a captured topmost overlay), so the camera is not burned into
/// screen.mov. Shown only while recording with the camera overlay enabled; the
/// texture is fed by the native recorder and shows nothing until frames arrive.
///
/// The raw texture is composited into the styled recording-overlay bubble
/// ([CameraOverlayBubble]) so shape / roundness / border / shadow / opacity /
/// mirror reflect the current overlay settings live — Windows parity with the
/// macOS native live overlay. (Chroma key is an export/inline-preview effect and
/// is not applied to the live in-app preview.)
///
/// `cameraEnabled` and `overlayStyle` are passed in (sourced from the overlay
/// controller at the shell) rather than read from a provider, so leaf-widget
/// tests don't need an OverlayController in scope.
class LiveCameraPreview extends StatefulWidget {
  const LiveCameraPreview({
    super.key,
    required this.isRecording,
    required this.cameraEnabled,
    this.overlayStyle = const CameraOverlayPreviewStyle(),
  });

  final bool isRecording;
  final bool cameraEnabled;
  final CameraOverlayPreviewStyle overlayStyle;

  @override
  State<LiveCameraPreview> createState() => _LiveCameraPreviewState();
}

class _LiveCameraPreviewState extends State<LiveCameraPreview> {
  // Square bubble so circle / hexagon / star read correctly; the texture is
  // cover-cropped into it (assumed 16:9 webcam — mild over-crop on 4:3 is
  // acceptable for a small live preview).
  static const double _bubbleSide = 180;

  int? _textureId;
  bool _fetchStarted = false;

  Future<void> _ensureTextureId() async {
    if (_fetchStarted) return;
    _fetchStarted = true;
    final id = await NativeBridge.instance.getCameraPreviewTextureId();
    if (mounted) {
      setState(() => _textureId = id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isRecording || !widget.cameraEnabled) {
      return const SizedBox.shrink();
    }
    // Fetch the (stable, app-lifetime) texture id once, lazily.
    _ensureTextureId();
    final textureId = _textureId;
    if (textureId == null) {
      return const SizedBox.shrink();
    }
    final style = widget.overlayStyle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: CameraOverlayBubble(
        shape: style.shape,
        roundness: style.roundness,
        opacity: style.opacity,
        mirror: style.mirror,
        shadow: style.shadow,
        borderWidth: style.borderWidth,
        borderColor: Color(style.borderColor),
        hasBorder: style.hasBorder,
        size: const Size(_bubbleSide, _bubbleSide),
        child: ColoredBox(
          color: Colors.black,
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: 16,
              height: 9,
              child: Texture(textureId: textureId),
            ),
          ),
        ),
      ),
    );
  }
}
