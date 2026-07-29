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

  /// sRGB -> a pure power-law transfer, as a GPU kernel.
  ///
  /// Not a published curve — a probe. The published BT.709 OETF has a 4.5x
  /// linear toe near black; several decoders do not undo it, treating a 709
  /// tag as a plain power law instead. That is measured, not assumed:
  /// ffmpeg's `zscale t=bt709` returns 192 on linear 0.502 where the published
  /// OETF predicts 180, and the export round trip crushes shadows by up to 17
  /// code values while midtones land within 2.
  ///
  /// This exists so "which curve does the decoder actually apply" stays a
  /// measurement. `ExportColorRampTests` uses it to compare candidate
  /// exponents against the real writer/decoder round trip.
  static let srgbToPureGammaKernel: CIColorKernel? = CIColorKernel(
    source:
      "kernel vec4 srgbToPureGamma(__sample s, float gamma) {"
      + "  float alpha = max(s.a, 0.0001);"
      + "  vec3 encoded = clamp(s.rgb / alpha, 0.0, 1.0);"
      // sRGB EOTF: encoded -> linear light.
      + "  vec3 linear = mix("
      + "    encoded / 12.92,"
      + "    pow((encoded + 0.055) / 1.055, vec3(2.4)),"
      + "    step(vec3(0.04045), encoded));"
      // Pure power-law OETF, no toe.
      + "  vec3 outGamma = pow(linear, vec3(1.0 / gamma));"
      + "  return vec4(clamp(outGamma, 0.0, 1.0) * s.a, s.a);"
      + "}"
  )

  /// CPU twin of `srgbToPureGammaKernel`, for the reference table.
  static func srgbToPureGamma(_ value: UInt8, gamma: Double) -> UInt8 {
    let linear = srgbToLinear(Double(value) / 255.0)
    let encoded = pow(linear, 1.0 / gamma)
    return UInt8(max(0.0, min(255.0, (encoded * 255.0).rounded())))
  }

  /// Applies the pure power-law encode at `gamma`.
  static func encodeToPureGamma(_ image: CIImage, gamma: Double) -> CIImage {
    guard let kernel = srgbToPureGammaKernel else { return image }
    return kernel.apply(extent: image.extent, arguments: [image, Float(gamma)]) ?? image
  }

  /// Re-encodes a composed export frame from sRGB into BT.709.
  ///
  /// Returns the image unchanged if the kernel failed to compile. That is the
  /// deliberate choice: a colour shift is a wrong-looking export, but no
  /// export at all is a broken product, and the compile failure is logged at
  /// the call site rather than swallowed here.
  static func encodeToBt709(_ image: CIImage) -> CIImage {
    guard let kernel = srgbToBt709Kernel else { return image }
    return kernel.apply(extent: image.extent, arguments: [image]) ?? image
  }

  /// The gamma the export actually encodes with — Apple's 709 decode value,
  /// not the published BT.709 OETF.
  ///
  /// This is measured, and the measurement is reproducible in about a second
  /// (`ExportColorRampTests.testACandidateTransferCurveRoundTripsWithinTolerance`).
  /// Sweeping candidate curves through the real writer and the real decode:
  ///
  ///     published 709 OETF   worst 17.0      pure gamma 2.000     worst  2.0
  ///     pure gamma 1.800     worst  9.0      pure gamma 2.200     worst 11.0
  ///     pure gamma 1.961     worst  1.0      pure gamma 2.400     worst 20.0
  ///
  /// The published OETF is standards-correct and wrong here: its 4.5x linear
  /// toe is never undone, so shadows crush by up to 17 code values while
  /// midtones land within 2. The minimum at 1.961 is sharp, and the same model
  /// independently reproduces the ORIGINAL defect — decoding an unencoded 128
  /// as gamma 1.961 and re-encoding to sRGB gives 139.2, matching the 128 ->
  /// 139 measured before any of this existed. Two independent measurements,
  /// one model.
  ///
  /// The trade-off this accepts: 1.961 is what Apple's decoders apply, so this
  /// makes exports match the editor in QuickTime, Preview, and anything else
  /// on AVFoundation. Players that instead treat a 709 tag as BT.1886 (gamma
  /// 2.4) will render these files slightly light. Optimising for the platform
  /// the product ships on is the deliberate call; revisit if Windows or
  /// browser playback becomes the primary target.
  static let exportTransferGamma = 1.961

  /// The transfer function the export writes. See `exportTransferGamma`.
  static func encodeForExport(_ image: CIImage) -> CIImage {
    encodeToPureGamma(image, gamma: exportTransferGamma)
  }
}
