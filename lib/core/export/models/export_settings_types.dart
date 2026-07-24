enum ExportFormat { mov, mp4, gif }

enum ExportCodec { hevc, h264 }

enum ExportBitratePreset { auto, low, medium, high }

/// GIF output size, a file-size lever specific to GIF export. GIF has a full
/// color table per frame, so its long edge is capped for sanity (a 4K GIF is
/// multiple GB). Each preset caps the long edge to a different pixel budget;
/// fps stays fixed at 15 across all presets for cross-platform (Windows)
/// parity, so dimension is the size lever, not frame rate.
enum GifSizePreset { small, medium, large }

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

GifSizePreset gifSizePresetFromWire(
  String? raw, {
  GifSizePreset fallback = GifSizePreset.large,
}) {
  switch (raw?.toLowerCase().trim()) {
    case 'small':
      return GifSizePreset.small;
    case 'medium':
      return GifSizePreset.medium;
    case 'large':
      return GifSizePreset.large;
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

extension GifSizePresetWire on GifSizePreset {
  String get wireValue {
    switch (this) {
      case GifSizePreset.small:
        return 'small';
      case GifSizePreset.medium:
        return 'medium';
      case GifSizePreset.large:
        return 'large';
    }
  }

  /// GIF long-edge cap in pixels for this preset.
  ///
  /// Display/UI hint only. The authoritative cap the exporter enforces lives
  /// natively in `GifExportPolicy.maxLongEdge(forSizePreset:)`
  /// (`macos/Runner/Capture/Export/GifExportPolicy.swift`); these two must stay
  /// in sync. A landscape 16:9 canvas at `large` becomes 1080×608, etc.
  int get longEdgePx {
    switch (this) {
      case GifSizePreset.small:
        return 480;
      case GifSizePreset.medium:
        return 720;
      case GifSizePreset.large:
        return 1080;
    }
  }
}
