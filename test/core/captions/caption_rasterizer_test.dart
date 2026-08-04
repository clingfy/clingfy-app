import 'dart:io';
import 'dart:ui' as ui;

import 'package:clingfy/core/captions/caption_rasterizer.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('caption-rasterizer-test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Caption cue(String id, String text, {int start = 0, int end = 1000}) =>
      Caption(id: id, startMs: start, endMs: end, text: text);

  group('font scaling', () {
    // A caption authored against 1080p must not render at a quarter size on a
    // 4K export. This is the rule the preview has to apply too, or what the
    // user proofreads is not what they ship.
    test('scales font size with video height against the reference', () {
      const r = CaptionRasterizer(style: CaptionStyle(fontSizePx: 28));
      expect(r.scaledFontSize(1080), closeTo(28, 0.001));
      expect(r.scaledFontSize(2160), closeTo(56, 0.001), reason: '4K doubles');
      expect(r.scaledFontSize(720), closeTo(18.67, 0.01));
    });

    test('degenerate height falls back to the authored size', () {
      const r = CaptionRasterizer(style: CaptionStyle(fontSizePx: 28));
      expect(r.scaledFontSize(0), 28);
      expect(r.scaledFontSize(-100), 28);
    });

    test('a 4K bitmap is materially larger than a 1080p one', () async {
      const r = CaptionRasterizer();
      final hd = await r.renderCue(
        text: 'Hello world',
        videoSize: const Size(1920, 1080),
      );
      final uhd = await r.renderCue(
        text: 'Hello world',
        videoSize: const Size(3840, 2160),
      );
      expect(
        uhd.height,
        greaterThan(hd.height * 1.8),
        reason:
            'rasterizing at export resolution is the point; a 4K caption '
            'upscaled from 1080p would be visibly soft',
      );
      hd.dispose();
      uhd.dispose();
    });
  });

  group('layout', () {
    test('wraps to the max width fraction rather than running off frame', () {
      const r = CaptionRasterizer(maxWidthFraction: 0.9);
      final painter = r.layOut(
        text: 'a very long caption ' * 20,
        videoSize: const Size(1920, 1080),
      );
      expect(painter.width, lessThanOrEqualTo(1920 * 0.9 + 1));
      expect(painter.didExceedMaxLines || painter.height > 0, isTrue);
      painter.dispose();
    });

    test('a longer line is at least as wide as a short one', () {
      const r = CaptionRasterizer();
      final short = r.layOut(text: 'Hi', videoSize: const Size(1920, 1080));
      final long = r.layOut(
        text: 'Hi there, this is quite a bit longer',
        videoSize: const Size(1920, 1080),
      );
      expect(long.width, greaterThan(short.width));
      short.dispose();
      long.dispose();
    });

    /// Arabic is why rendering lives in Flutter at all. This does not assert
    /// glyph shaping — that needs a rendered-pixel or platform check — but it
    /// does assert the text engine produced a real laid-out box rather than
    /// collapsing, which is what happens when a script has no coverage.
    test('lays out Arabic without collapsing', () {
      const r = CaptionRasterizer();
      final arabic = r.layOut(
        text: 'مرحبا بكم في كلينجفاي',
        videoSize: const Size(1920, 1080),
      );
      expect(arabic.width, greaterThan(0));
      expect(arabic.height, greaterThan(0));
      arabic.dispose();
    });

    test('lays out a mixed Arabic and Latin line', () {
      const r = CaptionRasterizer();
      final mixed = r.layOut(
        text: 'مرحبا Clingfy',
        videoSize: const Size(1920, 1080),
      );
      final arabicOnly = r.layOut(
        text: 'مرحبا',
        videoSize: const Size(1920, 1080),
      );
      expect(
        mixed.width,
        greaterThan(arabicOnly.width),
        reason: 'the Latin run must contribute width, not be dropped',
      );
      mixed.dispose();
      arabicOnly.dispose();
    });
  });

  group('rasterize', () {
    test('writes one PNG per cue and returns a matching manifest', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [
          cue('cue_0', 'First line', start: 0, end: 1000),
          cue('cue_1', 'Second line', start: 2000, end: 3000),
        ],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );

      expect(manifest.entries.length, 2);
      expect(manifest.entries.map((e) => e.id), ['cue_0', 'cue_1']);
      for (final entry in manifest.entries) {
        final file = File('${tempDir.path}/${entry.bitmapName}');
        expect(
          file.existsSync(),
          isTrue,
          reason: '${entry.bitmapName} missing',
        );
        expect(file.lengthSync(), greaterThan(0));
      }
    });

    test('written files really are PNGs', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [cue('c', 'Hello')],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );
      final bytes = File(
        '${tempDir.path}/${manifest.entries.single.bitmapName}',
      ).readAsBytesSync();
      // PNG magic number. Native loads these with CIImage(contentsOf:), which
      // silently returns nil on anything else.
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });

    test('skips blank cues instead of writing empty bitmaps', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [cue('a', 'Real'), cue('b', '   '), cue('c', '')],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );
      expect(manifest.entries.map((e) => e.id), ['a']);
      expect(tempDir.listSync().length, 1);
    });

    test('creates the directory when it does not exist', () async {
      const r = CaptionRasterizer();
      final nested = Directory('${tempDir.path}/does/not/exist');
      final manifest = await r.rasterize(
        captions: [cue('c', 'Hello')],
        videoSize: const Size(1280, 720),
        directory: nested,
      );
      expect(nested.existsSync(), isTrue);
      expect(manifest.entries.length, 1);
    });

    test('sanitises ids that would be illegal file names', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [cue('../../etc/passwd', 'Hello')],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );
      final name = manifest.entries.single.bitmapName;
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('..')));
      expect(File('${tempDir.path}/$name').existsSync(), isTrue);
      // The id itself is preserved for correlation; only the file name changes.
      expect(manifest.entries.single.id, '../../etc/passwd');
    });

    /// Sanitising is lossy. The clip mapper suffixes split pieces as `id#n`
    /// and `#` sanitises to `_`, so `abc#1` and `abc_1` both want `abc_1.png`.
    /// Without a uniquing pass the second overwrites the first and one cue
    /// silently renders the other's text.
    test('distinct ids that sanitise alike get distinct files', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [
          cue('abc#1', 'From the split piece'),
          cue('abc_1', 'From a different cue'),
        ],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );

      final names = manifest.entries.map((e) => e.bitmapName).toList();
      expect(names.toSet().length, 2, reason: 'file names must not collide');
      expect(tempDir.listSync().length, 2, reason: 'neither file overwritten');
      for (final entry in manifest.entries) {
        expect(
          File('${tempDir.path}/${entry.bitmapName}').existsSync(),
          isTrue,
        );
      }
    });

    test('preserves cue timings exactly', () async {
      const r = CaptionRasterizer();
      final manifest = await r.rasterize(
        captions: [cue('c', 'Hello', start: 1234, end: 5678)],
        videoSize: const Size(1280, 720),
        directory: tempDir,
      );
      expect(manifest.entries.single.startMs, 1234);
      expect(manifest.entries.single.endMs, 5678);
    });
  });

  group('export args', () {
    // The shape here is parsed by ExportVideoRequest.fromFlutter and
    // CaptionCueTrack.Cue.fromFlutter on the Swift side. A rename on either
    // side silently produces captionless exports, so this test pins the keys.
    test('entry keys match what native parses', () {
      const entry = CaptionBitmapEntry(
        id: 'cue_7',
        startMs: 1200,
        endMs: 2400,
        bitmapName: 'cue_7.png',
      );
      expect(entry.toExportArgs(), {
        'id': 'cue_7',
        'startMs': 1200,
        'endMs': 2400,
        'bitmapName': 'cue_7.png',
      });
    });

    test('manifest keys match what native parses', () {
      const manifest = CaptionBitmapManifest(
        directoryPath: '/tmp/caps',
        entries: [
          CaptionBitmapEntry(
            id: 'a',
            startMs: 0,
            endMs: 1,
            bitmapName: 'a.png',
          ),
        ],
      );
      final args = manifest.toExportArgs();
      expect(args['captionBitmapDirectory'], '/tmp/caps');
      expect((args['captions'] as List).length, 1);
    });

    /// An export with no captions must send no caption keys at all, so the
    /// payload is byte-identical to one from before this feature and native
    /// takes its unchanged no-op path.
    test('an empty manifest contributes nothing to the payload', () {
      const manifest = CaptionBitmapManifest(
        directoryPath: '/tmp/caps',
        entries: [],
      );
      expect(manifest.isEmpty, isTrue);
      expect(manifest.toExportArgs(), isEmpty);
    });
  });

  group('image output', () {
    test('bitmap is sized to the text, not to the frame', () async {
      const r = CaptionRasterizer();
      final image = await r.renderCue(
        text: 'Short',
        videoSize: const Size(1920, 1080),
      );
      // A full-frame RGBA bitmap per cue at 4K would be ~33MB each; sizing to
      // the text is what keeps the temp directory sane.
      expect(image.width, lessThan(1920));
      expect(image.height, lessThan(1080 ~/ 4));
      expect(image.width, greaterThan(0));
      image.dispose();
    });

    test('a wrapped caption is taller than a single line', () async {
      const r = CaptionRasterizer();
      const videoSize = Size(1920, 1080);
      // Long enough to genuinely wrap at this scale. An earlier version of this
      // test used a 57-character string at 640x360, where the font is ~9px and
      // the line box is ~576px wide, so it never wrapped and the assertion
      // compared two single-line bitmaps.
      const longText =
          'A much longer caption that has to wrap onto several lines because it '
          'keeps going well past the width of the frame and simply will not fit '
          'on one line no matter how the layout engine tries to arrange it';

      final singleLine = r.layOut(text: 'One line', videoSize: videoSize);
      final wrappedLine = r.layOut(text: longText, videoSize: videoSize);
      expect(
        singleLine.computeLineMetrics().length,
        1,
        reason: 'control must be a single line',
      );
      expect(
        wrappedLine.computeLineMetrics().length,
        greaterThan(1),
        reason: 'the test is meaningless unless this text actually wraps',
      );
      singleLine.dispose();
      wrappedLine.dispose();

      final single = await r.renderCue(text: 'One line', videoSize: videoSize);
      final wrapped = await r.renderCue(text: longText, videoSize: videoSize);
      expect(wrapped.height, greaterThan(single.height));
      single.dispose();
      wrapped.dispose();
    });

    test('produces a decodable image', () async {
      const r = CaptionRasterizer();
      final image = await r.renderCue(
        text: 'Hello',
        videoSize: const Size(1280, 720),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(bytes, isNotNull);
      expect(bytes!.lengthInBytes, image.width * image.height * 4);
      image.dispose();
    });
  });
}
