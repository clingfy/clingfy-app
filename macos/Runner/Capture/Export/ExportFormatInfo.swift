import AVFoundation

/// Container/file-type metadata for an export format.
/// Engine-domain DTO (the `AVFileType` field maps to an MF container on Windows —
/// see windows-port-inventory §7).
struct ExportFormatInfo {
  let ext: String
  let avFileType: AVFileType?  // nil for formats the GIF pipeline handles, not AVFoundation

  /// The one place a format string becomes a container.
  ///
  /// This decision used to live in three copies — `exportFormatInfo` in
  /// `ExportPrep` (which builds the output URL), plus `requestedFileType` and
  /// `ext(for:)` inside `LetterboxExporter`. They agreed by coincidence rather
  /// than construction, and the exporter renames the file to match its own
  /// answer, so a disagreement would move the output path out from under
  /// `ExportEngine` — and the exporter deletes whatever already sits at the
  /// renamed path before writing.
  ///
  /// Case-insensitive; anything unrecognised resolves to `.mov`, which is the
  /// container every preset and every writer on this platform accepts.
  static func resolve(_ formatRaw: String) -> ExportFormatInfo {
    switch formatRaw.lowercased() {
    case "mp4":
      return .init(ext: "mp4", avFileType: .mp4)
    case "m4v":
      return .init(ext: "m4v", avFileType: .m4v)
    case "mov":
      return .init(ext: "mov", avFileType: .mov)
    case "gif":
      // Rendered as a temp MOV and transcoded by GifExportSession; the exporter
      // itself never writes a GIF container.
      return .init(ext: "gif", avFileType: nil)
    default:
      return .init(ext: "mov", avFileType: .mov)
    }
  }
}
