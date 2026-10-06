enum ExportFormat { mov, mp4, gif }

enum ExportCodec { hevc, h264 }

enum ExportBitratePreset { auto, low, medium, high }

/// GIF output size, a file-size lever specific to GIF export. GIF has a full
/// color table per frame, so its long edge is capped for sanity (a 4K GIF is
/// multiple GB). Each preset caps the long edge to a different pixel budget;
/// fps stays fixed at 15 across all presets for cross-platform (Windows)
/// parity, so dimension is the size lever, not frame rate.
enum GifSizePreset { small, medium, large }

/// Export audio quality: the AAC bitrate ceiling for the exported mix.
///
/// A CEILING, not a fixed rate, and that distinction is the whole design.
/// AAC-LC rejects a bitrate its sample rate cannot carry, and it rejects it
/// late and opaquely — `AVAssetWriter.canAdd` and `startWriting()` both
/// succeed and the encoder only fails on the first appended sample buffer, as
/// `-11861 "Cannot Encode Media"`. So a recording made on a 16 kHz Bluetooth
/// headset mic still encodes at what 16 kHz allows no matter which tier the
/// user picks; the tier only raises the ceiling for sources that can use it.
/// See `macos/Runner/Capture/Audio/AACEncoderSettings.swift`.
///
/// `standard` is what macOS has exported since the beginning, so taking the
/// default never changes an existing user's output. The roadmap's original
/// ladder (128/192/256) was written believing today's default was 128 kbps; it
/// is 192 on macOS, and shipping that ladder with `standard` as the default
/// would have quietly downgraded every Mac export.
enum AudioQuality { standard, high, best }

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

AudioQuality audioQualityFromWire(
  String? raw, {
  AudioQuality fallback = AudioQuality.standard,
}) {
  switch (raw?.toLowerCase().trim()) {
    case 'standard':
      return AudioQuality.standard;
    case 'high':
      return AudioQuality.high;
    case 'best':
      return AudioQuality.best;
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

extension AudioQualityWire on AudioQuality {
  String get wireValue {
    switch (this) {
      case AudioQuality.standard:
        return 'standard';
      case AudioQuality.high:
        return 'high';
      case AudioQuality.best:
        return 'best';
    }
  }

  /// Target stereo bitrate in kbps, for labelling the control.
  ///
  /// Display hint only, exactly like [GifSizePresetWire.longEdgePx]. The
  /// authoritative ceilings live natively — `AACEncoderSettings.ceiling`
  /// (macOS) and `ResolveAudioBitrateBps` (Windows) — and these must stay in
  /// sync with them. What a given export actually gets can be LOWER than this:
  /// a low-sample-rate source is clamped, and Windows' AAC encoder MFT accepts
  /// a narrower set of rates than Apple's, so the upper tiers are not offered
  /// there at all rather than shown as choices that do nothing.
  int get targetKbps {
    switch (this) {
      case AudioQuality.standard:
        return 192;
      case AudioQuality.high:
        return 256;
      case AudioQuality.best:
        return 320;
    }
  }
}
