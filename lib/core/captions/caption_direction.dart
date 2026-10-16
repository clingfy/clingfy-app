import 'package:flutter/painting.dart';

import 'package:clingfy/core/captions/bidi_strong_table.dart';

/// The base direction of a caption line: the first strong character wins,
/// which is the Unicode bidi rule (UAX #9, P2-P3) for a paragraph. Empty or
/// neutral-only text is LTR.
///
/// One function for every place that lays a caption out. The editor used to
/// own this rule privately while the burn-in rasterizer hardcoded LTR, so an
/// Arabic-first line read right to left while being corrected and burned into
/// the export with its runs in English order: "مرحبا Clingfy" came out with the
/// Arabic word on the left, and the "!" of "مرحبا!" on the wrong end.
///
/// Because this decides the EXPORT's layout, "strong" means exactly what the
/// bidi algorithm means, and every caption player reading the .srt beside the
/// same video applies that rule. A wrong guess here is a burn-in that disagrees
/// with its own sidecar. Hand-written ranges got it wrong twice: counting only
/// Latin as left-to-right made "Привет مرحبا" read RTL, and the emoji variation
/// selector in "❤️ شكرا" counted as a letter. So the strong characters come from
/// a table generated from Unicode's own data (`tool/gen_caption_bidi_table.py`).
///
/// Text inside an isolate (LRI/RLI/FSI … PDI) is skipped, as P2 requires:
/// apps wrap a pasted brand name in one so it cannot steer the sentence.
TextDirection captionTextDirection(String text) {
  var isolateDepth = 0;
  for (final rune in text.runes) {
    if (rune == _lri || rune == _rli || rune == _fsi) {
      isolateDepth++;
      continue;
    }
    if (rune == _pdi) {
      if (isolateDepth > 0) isolateDepth--;
      continue;
    }
    if (isolateDepth > 0) continue;
    if (_inRanges(kBidiStrongRtl, rune)) return TextDirection.rtl;
    if (_inRanges(kBidiStrongLtr, rune)) return TextDirection.ltr;
  }
  return TextDirection.ltr;
}

/// [text] with every hard line wrapped in a first-strong isolate, so each line
/// orders its runs by its own first strong character.
///
/// UAX #9 treats a newline as a paragraph break, so "Hello everyone" and
/// "مرحبا Clingfy" on two lines of one cue are two paragraphs with two
/// directions, and that is how a player shows the .srt. A single
/// `TextPainter` gives every line the one direction it is handed, which would
/// burn the second line in backwards. An FSI … PDI pair around each line gives
/// it its own resolved direction; with centred text that changes only the
/// order of its runs, which is exactly the part that was wrong. Single-line
/// text is returned unchanged, so nothing about the common case moves.
String isolateCaptionLines(String text) {
  if (!text.contains('\n')) return text;
  final fsi = String.fromCharCode(_fsi);
  final pdi = String.fromCharCode(_pdi);
  return text.split('\n').map((line) => '$fsi$line$pdi').join('\n');
}

const int _lri = 0x2066;
const int _rli = 0x2067;
const int _fsi = 0x2068;
const int _pdi = 0x2069;

/// Whether [codePoint] falls in one of the inclusive `[start, end]` pairs in
/// [ranges], which are sorted and non-overlapping. Binary search over pairs.
bool _inRanges(List<int> ranges, int codePoint) {
  var lo = 0;
  var hi = ranges.length ~/ 2 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final start = ranges[mid * 2];
    final end = ranges[mid * 2 + 1];
    if (codePoint < start) {
      hi = mid - 1;
    } else if (codePoint > end) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}
