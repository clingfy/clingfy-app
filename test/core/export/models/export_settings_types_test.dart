import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export parsers use safe fallback for unknown values', () {
    expect(exportFormatFromWire('mov'), ExportFormat.mov);
    expect(
      exportFormatFromWire('legacy', fallback: ExportFormat.mp4),
      ExportFormat.mp4,
    );

    expect(exportCodecFromWire('h264'), ExportCodec.h264);
    expect(
      exportCodecFromWire('legacy', fallback: ExportCodec.hevc),
      ExportCodec.hevc,
    );

    expect(exportBitratePresetFromWire('high'), ExportBitratePreset.high);
    expect(
      exportBitratePresetFromWire(
        'legacy',
        fallback: ExportBitratePreset.medium,
      ),
      ExportBitratePreset.medium,
    );

    expect(gifSizePresetFromWire('small'), GifSizePreset.small);
    expect(gifSizePresetFromWire('MEDIUM'), GifSizePreset.medium);
    expect(gifSizePresetFromWire('  large '), GifSizePreset.large);
    expect(
      gifSizePresetFromWire('legacy', fallback: GifSizePreset.small),
      GifSizePreset.small,
    );
  });

  test('GIF size preset defaults to large when absent (backward compat)', () {
    // Older payloads and fresh installs carry no `gifSize`; they must render at
    // the same 1080 long-edge cap that shipped before the control existed.
    expect(gifSizePresetFromWire(null), GifSizePreset.large);
    expect(gifSizePresetFromWire(''), GifSizePreset.large);
    expect(gifSizePresetFromWire('nonsense'), GifSizePreset.large);
  });

  test('GIF size preset wire values and pixel caps', () {
    expect(GifSizePreset.small.wireValue, 'small');
    expect(GifSizePreset.medium.wireValue, 'medium');
    expect(GifSizePreset.large.wireValue, 'large');

    // These caps mirror GifExportPolicy.{small,medium,large}MaxLongEdge on the
    // native side — the two must stay in sync.
    expect(GifSizePreset.small.longEdgePx, 480);
    expect(GifSizePreset.medium.longEdgePx, 720);
    expect(GifSizePreset.large.longEdgePx, 1080);

    // Every preset round-trips through its wire value (guards a future value
    // added without a matching parse case).
    for (final size in GifSizePreset.values) {
      final fallback = size == GifSizePreset.large
          ? GifSizePreset.small
          : GifSizePreset.large;
      expect(
        gifSizePresetFromWire(size.wireValue, fallback: fallback),
        size,
        reason:
            'GifSizePreset.${size.name} must parse back from its wire value',
      );
    }
  });

  test('enum wire values stay backward-compatible', () {
    expect(ExportFormat.mov.wireValue, 'mov');
    expect(ExportFormat.mp4.wireValue, 'mp4');
    expect(ExportFormat.gif.wireValue, 'gif');

    expect(ExportCodec.hevc.wireValue, 'hevc');
    expect(ExportCodec.h264.wireValue, 'h264');

    expect(ExportBitratePreset.auto.wireValue, 'auto');
    expect(ExportBitratePreset.low.wireValue, 'low');
    expect(ExportBitratePreset.medium.wireValue, 'medium');
    expect(ExportBitratePreset.high.wireValue, 'high');
  });

  test(
    'GIF parses from wire (regression: missing case silently fell to mov)',
    () {
      // The export dialog round-trips the chosen format through wireValue ->
      // exportFormatFromWire when persisting it. A missing `gif` case here
      // coerced every GIF selection back to MOV, so exports always produced
      // a .mov file regardless of the dropdown.
      expect(exportFormatFromWire('gif'), ExportFormat.gif);
    },
  );

  test('every export enum round-trips through its wire value', () {
    // Guards against a future enum value being added without a matching
    // parse case (the failure mode that shipped the GIF bug). A fallback
    // distinct from the value under test makes a missing case observable.
    for (final format in ExportFormat.values) {
      final fallback = format == ExportFormat.mov
          ? ExportFormat.mp4
          : ExportFormat.mov;
      expect(
        exportFormatFromWire(format.wireValue, fallback: fallback),
        format,
        reason:
            'ExportFormat.${format.name} must parse back from its wire value',
      );
    }

    for (final codec in ExportCodec.values) {
      final fallback = codec == ExportCodec.hevc
          ? ExportCodec.h264
          : ExportCodec.hevc;
      expect(
        exportCodecFromWire(codec.wireValue, fallback: fallback),
        codec,
        reason: 'ExportCodec.${codec.name} must parse back from its wire value',
      );
    }

    for (final bitrate in ExportBitratePreset.values) {
      final fallback = bitrate == ExportBitratePreset.auto
          ? ExportBitratePreset.high
          : ExportBitratePreset.auto;
      expect(
        exportBitratePresetFromWire(bitrate.wireValue, fallback: fallback),
        bitrate,
        reason:
            'ExportBitratePreset.${bitrate.name} must parse back from its wire value',
      );
    }
  });

  group('AudioQuality', () {
    test('wire values round-trip', () {
      for (final q in AudioQuality.values) {
        expect(audioQualityFromWire(q.wireValue), q);
      }
    });

    /// An absent key, an older build's payload, or anything unrecognised must
    /// read as `standard` — the rate macOS has always exported. Anything else
    /// would change an existing user's output on upgrade.
    test('unknown, empty and null all fall back to standard', () {
      expect(audioQualityFromWire(null), AudioQuality.standard);
      expect(audioQualityFromWire(''), AudioQuality.standard);
      expect(audioQualityFromWire('ultra'), AudioQuality.standard);
      expect(audioQualityFromWire('auto'), AudioQuality.standard);
    });

    test('parsing is case and whitespace insensitive, like its neighbours', () {
      expect(audioQualityFromWire('  HIGH '), AudioQuality.high);
      expect(audioQualityFromWire('Best'), AudioQuality.best);
    });

    test('an explicit fallback is honoured', () {
      expect(
        audioQualityFromWire('nonsense', fallback: AudioQuality.best),
        AudioQuality.best,
      );
    });

    /// These are the numbers the UI prints, and they must match the native
    /// ceilings they describe: AACEncoderSettings.exportTargetPerChannel is
    /// 96/128/160 kbps per channel, doubled for stereo. Pinned here because a
    /// drift between the two would be a label that lies about the file.
    test('target rates are the advertised stereo kbps', () {
      expect(AudioQuality.standard.targetKbps, 192);
      expect(AudioQuality.high.targetKbps, 256);
      expect(AudioQuality.best.targetKbps, 320);
    });

    test('the ladder only goes up', () {
      expect(
        AudioQuality.standard.targetKbps,
        lessThan(AudioQuality.high.targetKbps),
      );
      expect(
        AudioQuality.high.targetKbps,
        lessThan(AudioQuality.best.targetKbps),
      );
    });
  });

  group('GIF length cap', () {
    test('is sixty seconds, the same as the native GifExportPolicy', () {
      expect(kGifMaxExportDurationMs, 60000);
    });

    test('exactly the cap is allowed; one ms more is not', () {
      expect(gifExceedsDurationCap(60000), isFalse);
      expect(gifExceedsDurationCap(60001), isTrue);
    });

    test('an unknown length is not refused', () {
      expect(gifExceedsDurationCap(null), isFalse);
    });

    test('measures the export the way the native exporter does', () {
      Clip clip(int inMs, int outMs, {bool enabled = true}) => Clip(
        id: '$inMs',
        sourceInMs: inMs,
        sourceOutMs: outMs,
        timelineStartMs: 0,
        enabled: enabled,
      );
      expect(exportedGifDurationMs([], 90000), 90000, reason: 'no clips: all');
      expect(
        exportedGifDurationMs([clip(0, 10000), clip(30000, 45000)], 90000),
        25000,
      );
      expect(
        exportedGifDurationMs([clip(0, 10000, enabled: false)], 90000),
        90000,
        reason: 'only disabled clips: nothing is cut',
      );
      // A restored last clip running past the end counts only what exists.
      expect(exportedGifDurationMs([clip(0, 60200)], 60000), 60000);
    });

    test('formats the length as m:ss, rounding up', () {
      expect(formatGifDuration(102000), '1:42');
      expect(formatGifDuration(60001), '1:01');
      expect(formatGifDuration(5000), '0:05');
    });
  });
}
