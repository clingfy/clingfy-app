import AppKit

extension NSColor {
  /// Packs the color into a 0xAARRGGBB integer in the device RGB space.
  /// Used when handing overlay/border colors back across the Flutter bridge.
  var argbIntValue: Int {
    let resolved = usingColorSpace(.deviceRGB) ?? self
    let a = Int(round(resolved.alphaComponent * 255.0))
    let r = Int(round(resolved.redComponent * 255.0))
    let g = Int(round(resolved.greenComponent * 255.0))
    let b = Int(round(resolved.blueComponent * 255.0))
    return (a << 24) | (r << 16) | (g << 8) | b
  }
}
