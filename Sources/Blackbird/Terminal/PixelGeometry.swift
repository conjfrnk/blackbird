import CoreGraphics

extension CGFloat {
    static let sanePx: CGFloat = 1_000_000

    /// `Int(_:)` traps on NaN, ±Infinity and magnitudes beyond `Int.max`; sanitize before any pixel→cell cast.
    var sanitizedPixel: CGFloat {
        isFinite ? Swift.min(Swift.max(0, self), CGFloat.sanePx) : 0
    }
}
