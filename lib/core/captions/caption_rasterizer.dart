import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../timeline/model/edit_track.dart';

/// Paints caption cues to PNG bitmaps for the native export to composite.
///
/// ## Why the text is drawn here and not in Swift
///
/// The app already renders every script it ships — including Arabic, which
/// needs bidi reordering and contextual joining — correctly and with no bundled
/// font, because Flutter's text engine does it. The macOS target has no CoreText
/// usage at all. Doing layout natively would mean bundling a font, registering
/// it with `CTFontManager`, asserting that the resolved face was not silently
/// substituted, asserting that shaping actually happened, and then writing the
/// whole thing a second time in DirectWrite for Windows. Rasterizing here and
/// compositing there costs one directory of PNGs and skips all of it.
///
/// ## The contract with native
///
/// ```
///   Flutter                              Swift
///   ───────                              ─────
///   rasterize(...)                       ExportVideoRequest.fromFlutter
///     writes <tmp>/cue_0.png               captionBitmapDirectory: String?
///                  cue_1.png               captions: [{id,startMs,endMs,bitmapName}]
///     returns a manifest  ──────────▶    CaptionCueTrack + CaptionOverlayRenderer
/// ```
///
/// Bitmaps are sized to the text, not to the frame; native centres them
/// horizontally and lifts them off the bottom edge. Keeping them small matters:
/// a full-frame RGBA bitmap per cue at 4K would be ~33 MB each.
@immutable
class CaptionRasterizer {
  const CaptionRasterizer({
    this.style = const CaptionStyle(),
    this.maxWidthFraction = 0.9,
    this.referenceHeight = 1080.0,
  }) : assert(maxWidthFraction > 0 && maxWidthFraction <= 1),
       assert(referenceHeight > 0);

  final CaptionStyle style;

  /// Widest a caption may be, as a fraction of video width. Text beyond this
  /// wraps. 0.9 leaves a margin so captions do not run to the frame edge.
  final double maxWidthFraction;

  /// The video height `CaptionStyle.fontSizePx` is expressed against.
  ///
  /// Font size has to scale with the export, or a 28px caption authored against
  /// 1080p renders at a quarter of its intended size on a 4K export and is
  /// effectively unreadable. See [scaledFontSize].
  final double referenceHeight;

  /// `style.fontSizePx` scaled to a video of [videoHeight].
  ///
  /// Pure and public so the scaling rule is testable on its own and so the
  /// preview can apply the identical rule — if preview and export disagree here,
  /// what the user proofreads is not what they ship.
  double scaledFontSize(double videoHeight) {
    if (videoHeight <= 0) return style.fontSizePx;
    return style.fontSizePx * (videoHeight / referenceHeight);
  }

  /// Renders each cue to `<directory>/<id>.png` and returns the manifest to
  /// hand to native.
  ///
  /// Cues with no visible text are skipped rather than written as empty
  /// bitmaps, so a transcript with gaps does not litter the directory.
  Future<CaptionBitmapManifest> rasterize({
    required List<Caption> captions,
    required Size videoSize,
    required Directory directory,
  }) async {
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }

    final entries = <CaptionBitmapEntry>[];
    final usedNames = <String>{};
    for (final caption in captions) {
      final text = caption.text.trim();
      if (text.isEmpty) continue;

      final image = await renderCue(text: text, videoSize: videoSize);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) continue;

      final name = _uniqueName(_sanitize(caption.id), usedNames);
      await File('${directory.path}/$name').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );

      entries.add(
        CaptionBitmapEntry(
          id: caption.id,
          startMs: caption.startMs,
          endMs: caption.endMs,
          bitmapName: name,
        ),
      );
    }

    return CaptionBitmapManifest(
      directoryPath: directory.path,
      entries: entries,
    );
  }

  /// Paints one cue: a rounded background pill with the text on top, sized to
  /// the laid-out text.
  ///
  /// Exposed for tests and for the preview, so both draw through exactly the
  /// same painter as the export.
  Future<ui.Image> renderCue({
    required String text,
    required Size videoSize,
  }) async {
    final painter = layOut(text: text, videoSize: videoSize);

    final padX = painter.height * 0.4;
    final padY = painter.height * 0.22;
    final width = (painter.width + padX * 2).ceil();
    final height = (painter.height + padY * 2).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final background = Color(style.backgroundColorArgb);
    if (background.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Radius.circular(painter.height * 0.25),
        ),
        Paint()..color = background,
      );
    }
    painter.paint(canvas, Offset(padX, padY));

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    painter.dispose();
    return image;
  }

  /// Lays the text out at the export's scale, wrapped to [maxWidthFraction].
  ///
  /// Direction is left to Flutter: `TextDirection.ltr` here is the *layout*
  /// direction of the paragraph box, and Flutter's shaper still reorders and
  /// joins RTL runs inside it correctly. Forcing `rtl` for Arabic would flip
  /// alignment of a mixed line rather than fix anything.
  TextPainter layOut({required String text, required Size videoSize}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: scaledFontSize(videoSize.height),
          color: Color(style.textColorArgb),
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    );
    painter.layout(maxWidth: videoSize.width * maxWidthFraction);
    return painter;
  }

  /// Cue ids come from the ASR engine and end up as file names. Keep them to
  /// characters that survive a round trip through both file systems.
  static String _sanitize(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? 'cue' : cleaned;
  }

  /// Sanitising is lossy, so two distinct ids can map to one file name and the
  /// second would overwrite the first — a caption silently rendering the wrong
  /// text. Not hypothetical: the clip mapper suffixes split pieces as `id#n`,
  /// and `#` sanitises to `_`, so `abc#1` collides with a real `abc_1`.
  static String _uniqueName(String stem, Set<String> used) {
    var candidate = '$stem.png';
    var suffix = 2;
    while (!used.add(candidate)) {
      candidate = '$stem-$suffix.png';
      suffix++;
    }
    return candidate;
  }
}

/// One rasterized cue, in the shape `ExportVideoRequest.fromFlutter` parses.
@immutable
class CaptionBitmapEntry {
  const CaptionBitmapEntry({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.bitmapName,
  });

  final String id;
  final int startMs;
  final int endMs;

  /// File name only, not a path. Native resolves it against the manifest's
  /// directory, so the two sides cannot disagree about where bitmaps live.
  final String bitmapName;

  Map<String, dynamic> toExportArgs() => {
    'id': id,
    'startMs': startMs,
    'endMs': endMs,
    'bitmapName': bitmapName,
  };

  @override
  bool operator ==(Object other) =>
      other is CaptionBitmapEntry &&
      other.id == id &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.bitmapName == bitmapName;

  @override
  int get hashCode => Object.hash(id, startMs, endMs, bitmapName);
}

/// What gets handed to the export call.
@immutable
class CaptionBitmapManifest {
  const CaptionBitmapManifest({
    required this.directoryPath,
    required this.entries,
  });

  final String directoryPath;
  final List<CaptionBitmapEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// Merged into the `exportVideo` arguments. Returns an empty map when there
  /// is nothing to burn in, so the export payload is byte-identical to one from
  /// before captions existed and native takes its no-op path.
  Map<String, dynamic> toExportArgs() {
    if (entries.isEmpty) return const {};
    return {
      'captionBitmapDirectory': directoryPath,
      'captions': [for (final e in entries) e.toExportArgs()],
    };
  }
}
