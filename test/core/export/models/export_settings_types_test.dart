import 'package:clingfy/core/export/models/export_settings_types.dart';
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
}
