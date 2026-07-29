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

  /// Re-encodes a composed export frame from sRGB into BT.709.
  ///
  /// This is the PUBLISHED curve, and that is a deliberate choice against a
  /// measured alternative. Apple's decoders read a 709 tag at gamma 1.961, so
  /// encoding at 1.961 instead makes exports round-trip almost exactly through
  /// AVFoundation — measured worst-case error 1 code value, against 17 for the
  /// published OETF, whose 4.5x linear toe those decoders never undo.
  ///
  /// The published curve still wins, because the round trip is not the goal.
  /// Screen recordings are watched on the web far more than they are inspected
  /// in QuickTime, and spec is what stays correct as the Windows port and the
  /// editor grow — an Apple-tuned encode would be a permanent platform
  /// divergence baked into every file users have already exported. Where the
  /// two disagree is the toe, below code 64; from code 96 up they differ by at
  /// most 2.
  ///
  /// The consequence, stated plainly so nobody treats it as a bug: shadows
  /// will read slightly dark in QuickTime and Preview. That is Apple's decoder
  /// disagreeing with the standard, and it belongs in the PREVIEW path, not in
  /// the file.
  ///
  /// Returns the image unchanged if the kernel failed to compile. That is the
  /// deliberate choice: a colour shift is a wrong-looking export, but no
  /// export at all is a broken product, and the compile failure is logged at
  /// the call site rather than swallowed here.
  static func encodeToBt709(_ image: CIImage) -> CIImage {
    guard let kernel = srgbToBt709Kernel else { return image }
    return kernel.apply(extent: image.extent, arguments: [image]) ?? image
  }
}
