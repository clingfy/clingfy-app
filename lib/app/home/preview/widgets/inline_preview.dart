import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class InlinePreview extends StatelessWidget {
  const InlinePreview({super.key, this.onPlatformViewCreated});

  final PlatformViewCreatedCallback? onPlatformViewCreated;

  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: 'inline_preview_view',
      layoutDirection: TextDirection.ltr,
      creationParamsCodec: const StandardMessageCodec(),
      creationParams: const <String, dynamic>{},
      onPlatformViewCreated: onPlatformViewCreated,
    );
  }
}
