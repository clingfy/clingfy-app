import 'package:flutter/material.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';

/// Phase 9.3.1 — live camera preview rendered as a Flutter [Texture] inside the
/// app window (NOT a captured topmost overlay), so the camera is not burned into
/// screen.mov. Shown only while recording with the camera overlay enabled; the
/// texture is fed by the native recorder and shows nothing until frames arrive.
///
/// `cameraEnabled` is passed in (sourced from the overlay controller at the
/// shell) rather than read from a provider, so leaf-widget tests don't need an
/// OverlayController in scope.
class LiveCameraPreview extends StatefulWidget {
  const LiveCameraPreview({
    super.key,
    required this.isRecording,
    required this.cameraEnabled,
  });

  final bool isRecording;
  final bool cameraEnabled;

  @override
  State<LiveCameraPreview> createState() => _LiveCameraPreviewState();
}

class _LiveCameraPreviewState extends State<LiveCameraPreview> {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 240,
          height: 135,
          child: ColoredBox(
            color: Colors.black,
            child: Texture(textureId: textureId),
          ),
        ),
      ),
    );
  }
}
