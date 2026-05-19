import AVFoundation

/// Container/file-type metadata for an export format.
/// Engine-domain DTO (the `AVFileType` field maps to an MF container on Windows —
/// see windows-port-inventory §7).
struct ExportFormatInfo {
  let ext: String
  let avFileType: AVFileType?  // nil for formats not handled by AVAssetExportSession (gif)
}
