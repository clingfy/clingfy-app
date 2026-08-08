import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Where subtitles go when a project is exported.
///
/// The client asked for both destinations, and they are not alternatives: a
/// burned-in caption survives re-upload to any platform that strips sidecars,
/// while a sidecar stays searchable, translatable, and switchable off. Which
/// one matters depends on where the video is going, and the person exporting
/// is the only one who knows that.
enum SubtitleMode {
  /// No subtitles in the output, even when cues exist. The transcript is still
  /// kept in the project — turning burn-in off is not the same as deleting the
  /// work.
  none('none'),

  /// Composited into the frames.
  burnIn('burnIn'),

  /// Written next to the exported video as `.srt` and `.vtt`.
  sidecar('sidecar'),

  /// Both.
  both('both');

  const SubtitleMode(this.wireValue);

  final String wireValue;

  bool get burnsIn => this == SubtitleMode.burnIn || this == SubtitleMode.both;
  bool get writesSidecar =>
      this == SubtitleMode.sidecar || this == SubtitleMode.both;

  static SubtitleMode fromWire(String? value) {
    for (final mode in SubtitleMode.values) {
      if (mode.wireValue == value) return mode;
    }
    return SubtitleMode.burnIn;
  }
}

/// Serialises a cue track to SubRip (`.srt`) and WebVTT (`.vtt`).
///
/// Pure string work with no I/O so it can be tested exactly, and so the export
/// pipeline decides where the bytes land.
///
/// Both formats are line-oriented and cue-delimited by blank lines, which is
/// the source of every edge case here: a cue whose own text contains a blank
/// line silently truncates the file from that point on in most parsers.
abstract final class SubtitleSerializer {
  /// Newline used in both outputs.
  ///
  /// WebVTT permits LF, CRLF, or CR. SubRip has no formal specification, but
  /// every parser in practice — ffmpeg, VLC, mpv, YouTube, browsers — accepts
  /// LF, and ffmpeg itself writes it.
  static const String _newline = '\n';

  /// SubRip: 1-based numbered cues, comma decimal separator.
  static String toSrt(List<Caption> captions) {
    final buffer = StringBuffer();
    var index = 0;
    for (final cue in _usable(captions)) {
      index++;
      buffer
        ..write(index)
        ..write(_newline)
        ..write(_timestamp(cue.startMs, decimalSeparator: ','))
        ..write(' --> ')
        ..write(_timestamp(_endOf(cue), decimalSeparator: ','))
        ..write(_newline)
        ..write(_sanitizeText(cue.text))
        ..write(_newline)
        ..write(_newline);
    }
    return buffer.toString();
  }

  /// WebVTT: `WEBVTT` header, period decimal separator, no cue numbering.
  ///
  /// Cue identifiers are optional in the format and deliberately omitted — an
  /// identifier line that happens to contain `-->` is a parse error, and cue
  /// ids here come from a transcription engine.
  static String toWebVtt(List<Caption> captions) {
    final buffer = StringBuffer()
      ..write('WEBVTT')
      ..write(_newline)
      ..write(_newline);
    for (final cue in _usable(captions)) {
      buffer
        ..write(_timestamp(cue.startMs, decimalSeparator: '.'))
        ..write(' --> ')
        ..write(_timestamp(_endOf(cue), decimalSeparator: '.'))
        ..write(_newline)
        ..write(_sanitizeText(cue.text))
        ..write(_newline)
        ..write(_newline);
    }
    return buffer.toString();
  }

  /// Cues that would produce anything a player can show, in time order.
  ///
  /// Dropped rather than written:
  /// - empty or whitespace-only text — a cue that displays nothing still
  ///   occupies its slot and suppresses whatever a player would otherwise show
  /// - negative start times
  ///
  /// Sorted because a transcript merged from two audio sources arrives
  /// interleaved, and out-of-order cues are undefined behaviour in both
  /// formats — some players show them, some stop at the first backwards jump.
  static List<Caption> _usable(List<Caption> captions) {
    final usable = [
      for (final cue in captions)
        if (cue.startMs >= 0 && _sanitizeText(cue.text).isNotEmpty) cue,
    ];
    usable.sort((a, b) {
      final byStart = a.startMs.compareTo(b.startMs);
      return byStart != 0 ? byStart : a.endMs.compareTo(b.endMs);
    });
    return usable;
  }

  /// A cue must occupy time to be displayed at all.
  ///
  /// A zero-length or inverted cue is given one frame at 60fps rather than
  /// being dropped: the text was really transcribed there, and a flash is more
  /// honest than silence.
  static int _endOf(Caption cue) =>
      cue.endMs > cue.startMs ? cue.endMs : cue.startMs + 16;

  /// `HH:MM:SS,mmm` / `HH:MM:SS.mmm`.
  ///
  /// Hours are not clamped to two digits — a parser that mis-reads a
  /// three-digit hour is a better failure than silently relocating a cue from
  /// hour 100 to hour 0. No screen recording is that long, but a corrupt
  /// timestamp from a bad transcription could be.
  static String _timestamp(int ms, {required String decimalSeparator}) {
    final safe = ms < 0 ? 0 : ms;
    final hours = safe ~/ 3600000;
    final minutes = (safe % 3600000) ~/ 60000;
    final seconds = (safe % 60000) ~/ 1000;
    final millis = safe % 1000;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}'
        '$decimalSeparator'
        '${millis.toString().padLeft(3, '0')}';
  }

  /// Makes cue text safe to sit inside a blank-line-delimited block.
  ///
  /// A blank line inside a cue ends that cue as far as the parser is
  /// concerned, so everything after it in the file is read as a malformed
  /// timestamp and usually discarded — one stray newline from an edit field
  /// silently truncates the whole subtitle track.
  ///
  /// `-->` gets the same treatment for the same reason: a text line carrying it
  /// reads as a timing line to SRT parsers and as a malformed cue to strict
  /// WebVTT ones. Cue text is editable in the caption editor, so this needs no
  /// unusual transcription to reach.
  static String _sanitizeText(String text) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim().replaceAll('-->', '→'))
        .where((line) => line.isNotEmpty);
    return lines.join(_newline);
  }
}
