import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class InlinePreview extends StatelessWidget {
  const InlinePreview({
    super.key,
    required this.cornerRadius,
    this.onPlatformViewCreated,
  });

  /// Outer Flutter panel radius in logical points. Plumbed into the native
  /// view so its root CALayer rounds to match — Flutter's Clip.antiAlias
  /// does not reliably clip hosted AppKit pixels at the four corners.
  final double cornerRadius;
  final PlatformViewCreatedCallback? onPlatformViewCreated;

  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: 'inline_preview_view',
      layoutDirection: TextDirection.ltr,
      creationParamsCodec: const StandardMessageCodec(),
      creationParams: <String, dynamic>{'cornerRadius': cornerRadius},
      onPlatformViewCreated: onPlatformViewCreated,
    );
  }
}
