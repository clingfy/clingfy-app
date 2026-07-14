import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/ui/platform/platform_kind.dart' as platform_kind;

/// Inline preview surface. macOS embeds an AppKit view that draws the
/// AVPlayerLayer directly; Windows mounts a `Texture(textureId:)` widget
/// that consumes the DXGI shared-handle texture PreviewEngine pushes
/// frames into. Step 5.5.2 introduced the Windows branch — before that
/// the widget hardcoded AppKitView and the Windows preview rendered
/// black because nothing in the tree consumed the registered texture.
class InlinePreview extends StatelessWidget {
  const InlinePreview({
    super.key,
    required this.cornerRadius,
    this.onPlatformViewCreated,
  });

  /// Test seam: when non-null, overrides the host-OS check used to
  /// decide which branch to render. Production reads
  /// `platform_kind.isWindows()` when this is null. Tests use it so
  /// the Windows / AppKit branches can be exercised on any host.
  @visibleForTesting
  static bool? debugIsWindowsOverride;

  /// Outer Flutter panel radius in logical points. Plumbed into the
  /// macOS native view so its root CALayer rounds to match — Flutter's
  /// Clip.antiAlias does not reliably clip hosted AppKit pixels at the
  /// four corners. Ignored on Windows; the parent `InlinePreviewPanel`
  /// already applies `clipBehavior: Clip.antiAlias` and the Texture
  /// widget honours that clip.
  final double cornerRadius;
  final PlatformViewCreatedCallback? onPlatformViewCreated;

  @override
  Widget build(BuildContext context) {
    final isWindows = debugIsWindowsOverride ?? platform_kind.isWindows();
    if (isWindows) {
      return _WindowsInlinePreview(
        onPlatformViewCreated: onPlatformViewCreated,
      );
    }
    return AppKitView(
      viewType: 'inline_preview_view',
      layoutDirection: TextDirection.ltr,
      creationParamsCodec: const StandardMessageCodec(),
      creationParams: <String, dynamic>{'cornerRadius': cornerRadius},
      onPlatformViewCreated: onPlatformViewCreated,
    );
  }
}

/// Windows-side preview surface. Watches `RecordingController` for the
/// texture id surfaced by `previewOpen`. Until the id arrives the
/// surface is intentionally black — the parent panel's loading overlay
/// covers it during `previewLoading`, so a blank state here is benign.
class _WindowsInlinePreview extends StatefulWidget {
  const _WindowsInlinePreview({this.onPlatformViewCreated});

  final PlatformViewCreatedCallback? onPlatformViewCreated;

  @override
  State<_WindowsInlinePreview> createState() => _WindowsInlinePreviewState();
}

class _WindowsInlinePreviewState extends State<_WindowsInlinePreview> {
  bool _hostMountedNotified = false;

  @override
  void initState() {
    super.initState();
    // `onPlatformViewCreated` is how the parent panel learns the host
    // is in the tree and can call `onPreviewHostMounted` — which in
    // turn triggers `_mountPreviewIfNeeded` and the native
    // `previewOpen` call. On macOS the AppKit view fires this from the
    // platform-view registrar; on Windows we have to fire it ourselves
    // exactly once after the widget is built. Negative id is the
    // documented "no platform view created" sentinel for this callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hostMountedNotified) return;
      _hostMountedNotified = true;
      widget.onPlatformViewCreated?.call(-1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final textureId = context.select<RecordingController, int?>(
      (rc) => rc.inlinePreviewTextureId,
    );
    final aspect = context.select<RecordingController, double?>(
      (rc) => rc.inlinePreviewTextureAspect,
    );
    if (textureId == null) {
      return const ColoredBox(color: Colors.black);
    }
    // A bare `Texture` stretches the native canvas to fill its layout box,
    // distorting the video whenever the panel isn't canvas-shaped (side
    // panel closed → wider, timeline hidden → taller). Pin the texture to
    // the canvas's own aspect and letterbox it in the panel — the macOS
    // AppKit view does the equivalent natively (resize-aspect layer
    // gravity), which is why only Windows showed the stretch.
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          // 16:9 fallback matches the engine's fixed canvas
          // (PreviewEngine kTextureWidth × kTextureHeight = 1280×720)
          // for replies that predate the aspect plumbing.
          aspectRatio: (aspect != null && aspect > 0) ? aspect : 16 / 9,
          child: Texture(textureId: textureId),
        ),
      ),
    );
  }
}
