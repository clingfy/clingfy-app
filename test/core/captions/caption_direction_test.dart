import 'package:clingfy/core/captions/bidi_strong_table.dart';
import 'package:clingfy/core/captions/caption_direction.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// The base direction of a caption line. Shared by the editor and the burn-in
/// rasterizer, so the two cannot disagree about which way a line reads.
void main() {
  test('Arabic first reads right to left', () {
    expect(captionTextDirection('مرحبا'), TextDirection.rtl);
    expect(captionTextDirection('مرحبا Clingfy'), TextDirection.rtl);
    expect(captionTextDirection('مرحبا!'), TextDirection.rtl);
  });

  test('Hebrew counts as right to left too', () {
    expect(captionTextDirection('שלום'), TextDirection.rtl);
  });

  test('Latin first reads left to right, even with Arabic after it', () {
    expect(captionTextDirection('Clingfy مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('hello'), TextDirection.ltr);
  });

  /// Neutrals do not decide: a leading number or quote is skipped and the
  /// first real letter wins.
  test('leading digits and punctuation are skipped', () {
    expect(captionTextDirection('2026 مرحبا'), TextDirection.rtl);
    expect(captionTextDirection('«مرحبا»'), TextDirection.rtl);
    expect(captionTextDirection('42 hello'), TextDirection.ltr);
  });

  /// Found in review. Counting only Latin as left-to-right made every other
  /// LTR script look neutral, so these read as RTL and burned in backwards.
  test('every left-to-right script counts, not only Latin', () {
    expect(captionTextDirection('Привет مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('Γειά σου مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('Ở đây 3 كلمات'), TextDirection.ltr);
    expect(captionTextDirection('日本語 مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('こんにちは مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('नमस्ते مرحبا'), TextDirection.ltr);
    expect(captionTextDirection('안녕 مرحبا'), TextDirection.ltr);
  });

  /// Also found in review: digits and symbols inside the letter ranges.
  test('digits and symbols never decide, whichever block they sit in', () {
    // Arabic-Indic and Extended Arabic-Indic digits are numbers, not letters.
    expect(captionTextDirection('٣ iPhone'), TextDirection.ltr);
    expect(captionTextDirection('۳ iPhone'), TextDirection.ltr);
    // The Arabic comma and harakat are not letters either.
    expect(captionTextDirection('، hello'), TextDirection.ltr);
    // × and ÷ sit in Latin-1 but are neutral.
    expect(captionTextDirection('5 × 3 تساوي 15'), TextDirection.rtl);
    expect(captionTextDirection('÷ مرحبا'), TextDirection.rtl);
    // Fullwidth and CJK punctuation, and a BOM.
    expect(captionTextDirection('「مرحبا」'), TextDirection.rtl);
    expect(captionTextDirection('\uFEFFمرحبا'), TextDirection.rtl);
  });

  test('a leading emoji is neutral', () {
    expect(captionTextDirection('😀 مرحبا'), TextDirection.rtl);
    expect(captionTextDirection('🎉 hello'), TextDirection.ltr);
    // A supplementary-plane CJK ideograph is still a letter.
    expect(captionTextDirection('𠀋 مرحبا'), TextDirection.ltr);
  });

  /// Found in the second review, against the hand-written ranges the
  /// generated table replaced.
  test('an emoji with a variation selector is neutral', () {
    // ❤️ is U+2764 U+FE0F. The selector is a combining mark (NSM), not a letter.
    expect(captionTextDirection('❤️ شكرا'), TextDirection.rtl);
    expect(captionTextDirection('☀️ صباح الخير'), TextDirection.rtl);
    expect(captionTextDirection('1️⃣ الخطوة الأولى'), TextDirection.rtl);
    expect(captionTextDirection('✌️ תודה'), TextDirection.rtl);
  });

  test('direction marks decide, as they were typed to', () {
    // RLM (U+200F) is strong R and LRM (U+200E) strong L: they exist so a line
    // that opens with a brand name or a number can still be forced.
    expect(captionTextDirection('\u200FiPhone 15 جديد'), TextDirection.rtl);
    expect(captionTextDirection('\u200Eمرحبا'), TextDirection.ltr);
  });

  test('Arabic ligature symbols that are not letters do not decide', () {
    // ﷽ (U+FDFD) is ON; ﷺ (U+FDFA) is a letter.
    expect(captionTextDirection('﷽ Welcome everyone'), TextDirection.ltr);
    expect(captionTextDirection('ﷺ hello'), TextDirection.rtl);
  });

  test('letterlike symbols that are letters do decide', () {
    // ℹ (U+2139) is bidi class L.
    expect(captionTextDirection('ℹ ملاحظة'), TextDirection.ltr);
  });

  group('generated table', () {
    void checkWellFormed(List<int> ranges, String name) {
      expect(ranges.length.isEven, isTrue, reason: '$name has an odd length');
      for (var i = 0; i < ranges.length; i += 2) {
        expect(
          ranges[i] <= ranges[i + 1],
          isTrue,
          reason: '$name pair $i is reversed',
        );
        if (i >= 2) {
          expect(
            ranges[i] > ranges[i - 1],
            isTrue,
            reason: '$name is unsorted or overlapping at pair $i',
          );
        }
      }
    }

    test('both lists are sorted, non-overlapping inclusive pairs', () {
      checkWellFormed(kBidiStrongLtr, 'kBidiStrongLtr');
      checkWellFormed(kBidiStrongRtl, 'kBidiStrongRtl');
    });

    test('no character is both left-to-right and right-to-left', () {
      var j = 0;
      for (var i = 0; i < kBidiStrongLtr.length; i += 2) {
        while (j < kBidiStrongRtl.length &&
            kBidiStrongRtl[j + 1] < kBidiStrongLtr[i]) {
          j += 2;
        }
        if (j < kBidiStrongRtl.length) {
          expect(
            kBidiStrongRtl[j] > kBidiStrongLtr[i + 1],
            isTrue,
            reason: 'overlap near 0x${kBidiStrongLtr[i].toRadixString(16)}',
          );
        }
      }
    });

    /// The lookup is a binary search over pairs, and an off-by-one there drops
    /// the first or last range of a table without any ordinary sentence
    /// noticing. So every boundary of every range is checked, and the code
    /// point just outside it. A strong-L character before an Arabic word makes
    /// the line LTR; a neutral one leaves it RTL, which is how the L table is
    /// observed through the public function.
    test('every range boundary is found, and its neighbours are not', () {
      bool usable(int cp) =>
          cp >= 0 && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF);
      bool inList(List<int> list, int cp) {
        for (var i = 0; i < list.length; i += 2) {
          if (cp >= list[i] && cp <= list[i + 1]) return true;
        }
        return false;
      }

      TextDirection probeLtr(int cp) =>
          captionTextDirection('${String.fromCharCode(cp)}مرحبا');
      TextDirection probeRtl(int cp) =>
          captionTextDirection('${String.fromCharCode(cp)}hello');

      for (var i = 0; i < kBidiStrongLtr.length; i += 2) {
        for (final cp in [kBidiStrongLtr[i], kBidiStrongLtr[i + 1]]) {
          if (!usable(cp)) continue;
          expect(
            probeLtr(cp),
            TextDirection.ltr,
            reason: 'L 0x${cp.toRadixString(16)}',
          );
        }
        for (final cp in [kBidiStrongLtr[i] - 1, kBidiStrongLtr[i + 1] + 1]) {
          if (!usable(cp) || inList(kBidiStrongLtr, cp)) continue;
          expect(
            probeLtr(cp),
            // Neutral or right-to-left: either leaves the Arabic deciding.
            TextDirection.rtl,
            reason: 'just outside L at 0x${cp.toRadixString(16)}',
          );
        }
      }
      for (var i = 0; i < kBidiStrongRtl.length; i += 2) {
        for (final cp in [kBidiStrongRtl[i], kBidiStrongRtl[i + 1]]) {
          if (!usable(cp)) continue;
          expect(
            probeRtl(cp),
            TextDirection.rtl,
            reason: 'R 0x${cp.toRadixString(16)}',
          );
        }
        for (final cp in [kBidiStrongRtl[i] - 1, kBidiStrongRtl[i + 1] + 1]) {
          if (!usable(cp) || inList(kBidiStrongRtl, cp)) continue;
          expect(
            probeRtl(cp),
            TextDirection.ltr,
            reason: 'just outside R at 0x${cp.toRadixString(16)}',
          );
        }
      }
    });

    /// Regenerating with an older interpreter would silently drop letters,
    /// and every other test here derives its expectations from the table.
    test('was generated from Unicode 16 or newer', () {
      final parts = kBidiUnicodeVersion.split('.').map(int.parse).toList();
      expect(parts, hasLength(3));
      expect(parts[0], greaterThanOrEqualTo(16));
    });
  });

  /// P2 skips isolates: apps wrap a pasted name in one so it cannot steer
  /// the sentence around it.
  test('text inside an isolate does not decide', () {
    expect(
      captionTextDirection('\u2066Clingfy\u2069 مرحبا'),
      TextDirection.rtl,
    );
    expect(captionTextDirection('\u2067مرحبا\u2069 hello'), TextDirection.ltr);
    expect(
      captionTextDirection('\u2068\u2066a\u2069b\u2069 مرحبا'),
      TextDirection.rtl,
      reason: 'nested isolates are skipped as a whole',
    );
    // An unmatched PDI is just ignored.
    expect(captionTextDirection('\u2069 hello'), TextDirection.ltr);
  });

  group('isolateCaptionLines', () {
    test('a single line is left exactly as it is', () {
      expect(isolateCaptionLines('مرحبا Clingfy!'), 'مرحبا Clingfy!');
    });

    test('each line of several is wrapped in its own isolate', () {
      expect(isolateCaptionLines('a\nب'), '\u2068a\u2069\n\u2068ب\u2069');
    });
  });

  test('Arabic presentation forms are letters', () {
    expect(captionTextDirection('ﻣﺮﺣﺒﺎ'), TextDirection.rtl);
  });

  test('nothing strong at all is left to right', () {
    expect(captionTextDirection(''), TextDirection.ltr);
    expect(captionTextDirection('123 !?'), TextDirection.ltr);
  });
}
