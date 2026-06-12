enum ExportFormat { mov, mp4, gif }

enum ExportCodec { hevc, h264 }

enum ExportBitratePreset { auto, low, medium, high }

ExportFormat exportFormatFromWire(
  String? raw, {
  ExportFormat fallback = ExportFormat.mov,
}) {
  switch (raw?.toLowerCase().trim()) {
    case 'mov':
      return ExportFormat.mov;
    case 'mp4':
      return ExportFormat.mp4;
    case 'gif':
      return ExportFormat.gif;
    default:
      return fallback;
  }
}

ExportCodec exportCodecFromWire(
  String? raw, {
  ExportCodec fallback = ExportCodec.hevc,
}) {
  switch (raw?.toLowerCase().trim()) {
    case 'hevc':
      return ExportCodec.hevc;
    case 'h264':
      return ExportCodec.h264;
    default:
      return fallback;
  }
}

ExportBitratePreset exportBitratePresetFromWire(
  String? raw, {
  ExportBitratePreset fallback = ExportBitratePreset.auto,
}) {
  switch (raw?.toLowerCase().trim()) {
    case 'auto':
      return ExportBitratePreset.auto;
    case 'low':
      return ExportBitratePreset.low;
    case 'medium':
      return ExportBitratePreset.medium;
    case 'high':
      return ExportBitratePreset.high;
    default:
      return fallback;
  }
}

extension ExportFormatWire on ExportFormat {
  String get wireValue {
    switch (this) {
      case ExportFormat.mov:
        return 'mov';
      case ExportFormat.mp4:
        return 'mp4';
      case ExportFormat.gif:
        return 'gif';
    }
  }

  bool get isGif => this == ExportFormat.gif;
}

extension ExportCodecWire on ExportCodec {
  String get wireValue {
    switch (this) {
      case ExportCodec.hevc:
        return 'hevc';
      case ExportCodec.h264:
        return 'h264';
    }
  }
}

extension ExportBitratePresetWire on ExportBitratePreset {
  String get wireValue {
    switch (this) {
      case ExportBitratePreset.auto:
        return 'auto';
      case ExportBitratePreset.low:
        return 'low';
      case ExportBitratePreset.medium:
        return 'medium';
      case ExportBitratePreset.high:
        return 'high';
    }
  }
}
