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
