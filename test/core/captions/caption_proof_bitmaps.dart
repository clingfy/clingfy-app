import 'dart:io';

import 'package:clingfy/core/captions/caption_rasterizer.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Not a test — a generator, run through `flutter test` because rasterizing
/// needs a Flutter engine.
///
/// Writes the caption bitmaps that `CaptionBurnInProofTests` (Swift) burns into
/// a real recording, so a human can look at the result. This is the visual half
/// of the spike: shaping, legibility, position and colour over real content are
/// exactly the things unit tests cannot judge.
///
/// Run:
///   flutter test test/core/captions/caption_proof_bitmaps.dart
///
/// Output: /tmp/clingfy-caption-proof/
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate caption proof bitmaps', () async {
    final dir = Directory('/tmp/clingfy-caption-proof');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    // Cues deliberately chosen to exercise what can go wrong:
    //  - plain English, the case that will actually ship first
    //  - a long line, to see wrapping and whether it stays readable
    //  - Arabic, the reason rendering lives in Flutter rather than CoreText
    //  - a mixed line, where bidi run ordering is visible to the eye
    const captions = <Caption>[
      Caption(
        id: 'cue_0',
        startMs: 500,
        endMs: 4000,
        text: 'This caption was rendered by Flutter and burned in natively.',
      ),
      Caption(
        id: 'cue_1',
        startMs: 4500,
        endMs: 9000,
        text:
            'A deliberately long line, so we can see how wrapping behaves '
            'and whether it stays readable over a real screen recording.',
      ),
      Caption(
        id: 'cue_2',
        startMs: 9500,
        endMs: 13000,
        text: 'مرحبا بكم في كلينجفاي',
      ),
      Caption(id: 'cue_3', startMs: 13500, endMs: 17000, text: 'مرحبا Clingfy'),
    ];

    // 1080p: matches what the Swift proof renders at.
    const rasterizer = CaptionRasterizer();
    final manifest = await rasterizer.rasterize(
      captions: captions,
      videoSize: const Size(1920, 1080),
      directory: dir,
    );

    // Hand the manifest to the Swift side as JSON so the two cannot drift on
    // ids, timings or file names.
    final lines = manifest.entries
        .map(
          (e) =>
              '{"id":"${e.id}","startMs":${e.startMs},'
              '"endMs":${e.endMs},"bitmapName":"${e.bitmapName}"}',
        )
        .join(',\n  ');
    File('${dir.path}/manifest.json').writeAsStringSync('[\n  $lines\n]\n');

    expect(manifest.entries.length, captions.length);
    // ignore: avoid_print
    print('caption proof bitmaps -> ${dir.path}');
    for (final e in manifest.entries) {
      final f = File('${dir.path}/${e.bitmapName}');
      // ignore: avoid_print
      print(
        '  ${e.bitmapName}  ${f.lengthSync()} bytes  '
        '[${e.startMs}-${e.endMs}ms]',
      );
    }
  });
}
