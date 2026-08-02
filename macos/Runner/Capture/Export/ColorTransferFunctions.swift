import CoreImage
import Foundation

/// The sRGB and BT.709 transfer functions, written out rather than delegated.
///
/// Four rounds of end-to-end measurement failed to identify what
/// `CGColorSpace.itur_709` actually does to a buffer: its output matches
/// neither the BT.709 OETF, nor Apple's 1.961 decode, nor a reversed
/// conversion. A transform nobody can name is a black box, and colour is the
/// wrong place to keep one.
///
/// These are the published curves, so their behaviour is a fact rather than
/// an observation — and a unit test over them runs in milliseconds instead of
/// through six confounded pipeline stages.
enum ColorTransferFunctions {

  /// sRGB EOTF: encoded value -> linear light.
  static func srgbToLinear(_ encoded: Double) -> Double {
    encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
  }

  /// sRGB OETF: linear light -> encoded value.
  static func linearToSrgb(_ linear: Double) -> Double {
    linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
  }

  /// BT.709 OETF: linear light -> encoded value.
  ///
  /// Steeper than sRGB, so a correct sRGB -> 709 encode moves code values
  /// DOWN everywhere except the endpoints. That single property is what the
  /// tests assert, because every wrong result in this investigation moved
  /// them up.
  static func linearToBt709(_ linear: Double) -> Double {
    linear < 0.018 ? 4.5 * linear : 1.099 * pow(linear, 0.45) - 0.099
  }

  /// BT.709 EOTF: encoded value -> linear light.
  static func bt709ToLinear(_ encoded: Double) -> Double {
    encoded < 0.081 ? encoded / 4.5 : pow((encoded + 0.099) / 1.099, 1.0 / 0.45)
  }

  /// Re-encodes one 8-bit sRGB channel into BT.709.
  static func srgbToBt709(_ value: UInt8) -> UInt8 {
    let linear = srgbToLinear(Double(value) / 255.0)
    let encoded = linearToBt709(linear)
    return UInt8(max(0.0, min(255.0, (encoded * 255.0).rounded())))
  }

  /// Inverse of `srgbToBt709`, for the preview sink: a 709-encoded value
  /// shown on an sRGB display.
  static func bt709ToSrgb(_ value: UInt8) -> UInt8 {
    let linear = bt709ToLinear(Double(value) / 255.0)
    let encoded = linearToSrgb(linear)
    return UInt8(max(0.0, min(255.0, (encoded * 255.0).rounded())))
  }
}

// MARK: - GPU

extension ColorTransferFunctions {

  /// `srgbToBt709` as a GPU kernel, for the export render.
  ///
  /// A kernel rather than a `CIColorCube` LUT on purpose: the curve is exact
  /// everywhere, with no table resolution to trade off near black — which is
  /// where sRGB's linear toe lives and where a coarse LUT does its worst
  /// visible damage. It is also literally the formula above, so the two can be
  /// checked against each other at all 256 code values.
  ///
  /// Samples arrive premultiplied, so this unpremultiplies, transfers, and
  /// premultiplies back. Export frames are opaque by the time they reach here,
  /// which makes that a no-op in practice and correct anyway if it ever stops
  /// being true.
  ///
  /// This assumes the kernel sees sRGB-ENCODED samples, which holds because
  /// `VideoColorPipeline.makeCIContext()` sets a gamma-encoded sRGB working
  /// space rather than Core Image's linear default. That is an assumption
  /// about someone else's framework, so it is not left as a comment —
  /// `ColorTransferFunctionTests` renders this kernel through that exact
  /// context and fails if the premise is wrong.
  static let srgbToBt709Kernel: CIColorKernel? = CIColorKernel(
    source:
      "kernel vec4 srgbToBt709(__sample s) {"
      + "  float alpha = max(s.a, 0.0001);"
      + "  vec3 encoded = clamp(s.rgb / alpha, 0.0, 1.0);"
      // sRGB EOTF: encoded -> linear light.
      + "  vec3 linear = mix("
      + "    encoded / 12.92,"
      + "    pow((encoded + 0.055) / 1.055, vec3(2.4)),"
      + "    step(vec3(0.04045), encoded));"
      // BT.709 OETF: linear light -> encoded.
      + "  vec3 out709 = mix("
      + "    4.5 * linear,"
      + "    1.099 * pow(linear, vec3(0.45)) - 0.099,"
      + "    step(vec3(0.018), linear));"
      + "  return vec4(clamp(out709, 0.0, 1.0) * s.a, s.a);"
      + "}"
  )

  /// Re-encodes a composed export frame from sRGB into BT.709, using the
  /// PUBLISHED curve.
  ///
  /// Kept as the reference implementation and the sweep baseline. It is NOT
  /// what the export writes — see `encodeForExport`. Encoding with this curve
  /// shipped briefly and was reverted: Apple's decoders read a 709 tag at
  /// gamma 1.961 rather than as an inverse OETF, so the 4.5x linear toe is
  /// never undone and shadows collapse. Measured on a real dark-mode
  /// recording, stored luma 20 rendered at 1.3 in QuickTime where the standard
  /// gives 13.1 — a tenfold loss of level across most of the frame.
  ///
  static func encodeToBt709(_ image: CIImage) -> CIImage {
    guard let kernel = srgbToBt709Kernel else { return image }
    return kernel.apply(extent: image.extent, arguments: [image]) ?? image
  }

  // MARK: - The transfer the export actually writes

  /// Apple's decode gamma for a BT.709 tag.
  ///
  /// The export encodes with this rather than the published OETF, and the
  /// reasoning is a measurement, not a preference for Apple.
  ///
  /// Both choices are wrong by the same amount — worst case 18 code values —
  /// just on different players. What is not symmetric is the DIRECTION:
  ///
  ///     encode              worst on Apple   worst on strict spec
  ///     published OETF                18.0                    0.0
  ///     gamma 1.961                    0.0                   18.0
  ///     gamma 2.000                    1.9                   19.0
  ///
  /// Splitting the difference is worse on both sides, because the error lives
  /// in the toe's shape rather than the exponent — there is no compromise
  /// curve to find.
  ///
  /// So the tie-break is which failure is more damaging. Encoding to spec
  /// makes Apple CRUSH: on a real dark-mode recording, stored luma 20 rendered
  /// at 1.3 against the 13.1 the standard intends, and roughly 70% of the
  /// frame sat in that band — shadow detail gone, unrecoverably to the eye.
  /// Encoding at 1.961 makes strict-spec players LIFT: authored 32 shows near
  /// 45, washed but with every level still distinguishable. Lifting is the
  /// gentler error, and QuickTime, Preview, Safari and Messages are where
  /// macOS users actually check a recording.
  ///
  /// Revisit if Windows or browser playback becomes the primary target; the
  /// sweep that produced the table above is a second to re-run.
  static let exportTransferGamma = 1.961

  /// The export's transfer as a GPU kernel: sRGB in, `exportTransferGamma` out.
  static let srgbToExportTransferKernel: CIColorKernel? = CIColorKernel(
    source:
      "kernel vec4 srgbToExportTransfer(__sample s, float gamma) {"
      + "  float alpha = max(s.a, 0.0001);"
      + "  vec3 encoded = clamp(s.rgb / alpha, 0.0, 1.0);"
      // sRGB EOTF: encoded -> linear light.
      + "  vec3 linear = mix("
      + "    encoded / 12.92,"
      + "    pow((encoded + 0.055) / 1.055, vec3(2.4)),"
      + "    step(vec3(0.04045), encoded));"
      // Pure power-law OETF at the decoder's own gamma — no toe, because the
      // decoder does not undo one.
      + "  vec3 out709 = pow(linear, vec3(1.0 / gamma));"
      + "  return vec4(clamp(out709, 0.0, 1.0) * s.a, s.a);"
      + "}"
  )

  /// CPU twin of `srgbToExportTransferKernel`.
  ///
  /// Not a convenience: anything that needs to reason about what the export
  /// wrote — notably the Display-P3 parity test, which compares a reference
  /// render against the encoded file — must use THIS, so the test and the
  /// product cannot drift onto different curves. They did once, and the P3
  /// test sat at 92% of its tolerance until someone printed the margin.
  static func srgbToExportTransfer(_ value: UInt8) -> UInt8 {
    let linear = srgbToLinear(Double(value) / 255.0)
    let encoded = pow(linear, 1.0 / exportTransferGamma)
    return UInt8(max(0.0, min(255.0, (encoded * 255.0).rounded())))
  }

  /// The transfer every exported frame goes through. See `exportTransferGamma`.
  ///
  /// Returns the image unchanged if the kernel failed to compile: a colour
  /// shift is a wrong-looking export, but no export at all is a broken
  /// product.
  static func encodeForExport(_ image: CIImage) -> CIImage {
    guard let kernel = srgbToExportTransferKernel else { return image }
    return kernel.apply(
      extent: image.extent, arguments: [image, Float(exportTransferGamma)]) ?? image
  }

  // MARK: - Reading an exported file back

  /// The inverse of `srgbToExportTransferKernel`: exported value -> sRGB.
  static let exportTransferToSrgbKernel: CIColorKernel? = CIColorKernel(
    source:
      "kernel vec4 exportTransferToSrgb(__sample s, float gamma) {"
      + "  float alpha = max(s.a, 0.0001);"
      + "  vec3 encoded = clamp(s.rgb / alpha, 0.0, 1.0);"
      // Undo the pure power law the export wrote — the same decode Apple
      // applies to a 709 tag.
      + "  vec3 linear = pow(encoded, vec3(gamma));"
      // sRGB OETF: linear light -> encoded.
      + "  vec3 srgb = mix("
      + "    linear * 12.92,"
      + "    1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,"
      + "    step(vec3(0.0031308), linear));"
      + "  return vec4(clamp(srgb, 0.0, 1.0) * s.a, s.a);"
      + "}"
  )

  /// CPU twin of `exportTransferToSrgbKernel`, and the exact inverse of
  /// `srgbToExportTransfer`.
  static func exportTransferToSrgb(_ value: UInt8) -> UInt8 {
    let linear = pow(Double(value) / 255.0, exportTransferGamma)
    let encoded = linearToSrgb(linear)
    return UInt8(max(0.0, min(255.0, (encoded * 255.0).rounded())))
  }

  /// Decodes a frame read back out of an exported file into sRGB.
  ///
  /// Needed by anything that re-reads the export's own output and hands the
  /// pixels to something that will treat them as sRGB. The GIF transcode is
  /// the case that made this necessary: it reads the finished MOV, whose
  /// pixels carry `exportTransferGamma`, and writes them into a container
  /// viewers read as sRGB — so without this, every GIF shipped its midtones
  /// about 11 code values dark.
  ///
  /// Deliberately expressed as the inverse of `exportTransferGamma` rather
  /// than as a fixed curve: if the export's transfer ever changes, this
  /// follows it, and the two cannot drift apart.
  ///
  /// Returns the image unchanged if the kernel failed to compile, for the same
  /// reason `encodeForExport` does.
  static func decodeFromExport(_ image: CIImage) -> CIImage {
    guard let kernel = exportTransferToSrgbKernel else { return image }
    return kernel.apply(
      extent: image.extent, arguments: [image, Float(exportTransferGamma)]) ?? image
  }
}
