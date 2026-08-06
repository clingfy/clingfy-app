import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Paints caption cues to PNG bitmaps for the native export to composite.
///
/// ## Why the text is drawn here and not in Swift
///
/// Flutter's text engine already does bidi reordering and contextual joining for
/// every script the app ships. The macOS target has no CoreText usage at all, so
/// laying out natively would mean writing that from scratch, registering fonts
/// with `CTFontManager`, and then writing the whole thing a second time in
/// DirectWrite for the Windows port. Rasterizing here and compositing there
/// skips all of it, and gives preview and export one shaper instead of two that
/// can disagree.
///
/// An earlier version of this comment claimed the win included *not* needing a
/// bundled font, since Flutter shapes Arabic against the host font stack. That
/// was wrong twice over, and the code now bundles one ([bundledCaptionFontFamily]):
/// the host stack drifts across machines and macOS versions, and in
/// `flutter test` it resolves to a stub that draws every glyph as a filled box —
/// which shipped a fully green test suite describing captions that were entirely
/// tofu. Bundling is about determinism and testability, not about capability.
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
    this.fontFamily = bundledCaptionFontFamily,
    this.fontFamilyFallback,
  }) : assert(maxWidthFraction > 0 && maxWidthFraction <= 1),
       assert(referenceHeight > 0);

  /// The bundled caption face, declared in `pubspec.yaml`'s `fonts:` block.
  ///
  /// Covers Latin, Romanian and Arabic in one file — see
  /// `assets/fonts/README.md`. Defaulting to it here is the point: leaving
  /// `fontFamily` null resolves against the host font stack, which is the
  /// nondeterminism bundling a font exists to remove.
  ///
  /// Setting only [fontFamilyFallback] does NOT work as a substitute. The stub
  /// font used by `flutter test` claims coverage of every codepoint, so the
  /// fallback chain is never consulted and text silently renders as boxes.
  static const String bundledCaptionFontFamily = 'ClingfyCaption';

  final CaptionStyle style;

  /// Family to draw captions in, or `null` to use the platform default.
  ///
  /// Passing a bundled family is what makes a caption look the same on every
  /// machine. Left to the platform, the render depends on whatever the host
  /// font stack resolves, which drifts across macOS versions — and in
  /// `flutter test` resolves to a stub that draws every glyph as a filled box,
  /// which is how a whole suite of green tests once described tofu.
  final String? fontFamily;

  /// Families to fall back through when [fontFamily] lacks a glyph.
  ///
  /// Worth setting even with a broad bundled family: a transcript can contain
  /// anything a person said, including scripts and emoji the bundled face does
  /// not cover, and silently drawing a box is worse than falling back.
  final List<String>? fontFamilyFallback;

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
    // Rendered this pass, so two cues with the same text cost one render even
    // when neither was on disk to begin with.
    final rendered = <String>{};
    for (final caption in captions) {
      final text = caption.text.trim();
      if (text.isEmpty) continue;

      final name = _bitmapNameFor(text, videoSize);
      final file = File('${directory.path}/$name');
      // The name is a hash of everything the pixels depend on, so a file that
      // is already there is already correct. Skipping it is what makes editing
      // one cue in a long transcript cost one render rather than all of them.
      if (rendered.add(name) && !file.existsSync()) {
        final image = await renderCue(text: text, videoSize: videoSize);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) {
          // Un-mark it: `rendered` is what makes a repeated line cost one
          // render, so leaving a failed name in there would let a LATER cue
          // with the same text skip the render AND still emit a manifest entry
          // pointing at a PNG that was never written.
          rendered.remove(name);
          Log.w(
            "Captions",
            "Cue bitmap encode returned no bytes; the cue will not burn in",
            null,
            null,
            {'cue': caption.id},
          );
          continue;
        }
        await file.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }

      entries.add(
        CaptionBitmapEntry(
          id: caption.id,
          startMs: caption.startMs,
          endMs: caption.endMs,
          bitmapName: name,
        ),
      );
    }

    // Anything the current cue set does not reference is debris from an earlier
    // pass. Without this the directory grows without bound inside the user's
    // project bundle, which they back up and move around.
    _sweep(directory, keep: {for (final e in entries) e.bitmapName});

    return CaptionBitmapManifest(
      directoryPath: directory.path,
      entries: entries,
    );
  }

  /// Deletes bitmaps in [directory] that nothing references any more.
  ///
  /// Best-effort: a file that cannot be removed is left alone rather than
  /// failing a render the user is waiting on.
  static void _sweep(Directory directory, {required Set<String> keep}) {
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.png') || keep.contains(name)) continue;
        entity.deleteSync();
      }
    } catch (_) {
      // Leaving debris is strictly better than failing the render.
    }
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
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
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

  /// The file name for a cue's bitmap: a hash of everything the pixels depend
  /// on.
  ///
  /// Content-addressed rather than derived from the cue id, for three reasons
  /// that all matter once the live preview rasterises too:
  ///
  /// * A rewrite of an unchanged cue is a no-op, so correcting one line in a
  ///   300-cue transcript renders one bitmap instead of three hundred.
  /// * Two cues with the same text — including the two halves of a cue split
  ///   by a cut — share one file instead of duplicating it.
  /// * Nothing is lossy, so two distinct cue ids can no longer collide onto one
  ///   name and silently render each other's text.
  ///
  /// The canvas is part of the key because the pixels genuinely depend on it:
  /// the font scales with canvas height and the wrap width is a fraction of
  /// canvas width, so the same sentence is a different bitmap — sometimes a
  /// different LINE COUNT — at a different layout or resolution preset.
  static String bitmapName({
    required String text,
    required Size videoSize,
    required CaptionStyle style,
    required String? fontFamily,
    required double maxWidthFraction,
    required double referenceHeight,
  }) {
    final key = [
      text,
      videoSize.width.round(),
      videoSize.height.round(),
      style.fontSizePx,
      style.textColorArgb,
      style.backgroundColorArgb,
      fontFamily ?? '',
      maxWidthFraction,
      referenceHeight,
    ].join('\u0000');
    return '${sha1.convert(utf8.encode(key))}.png';
  }

  String _bitmapNameFor(String text, Size videoSize) => bitmapName(
    text: text,
    videoSize: videoSize,
    style: style,
    fontFamily: fontFamily,
    maxWidthFraction: maxWidthFraction,
    referenceHeight: referenceHeight,
  );
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
