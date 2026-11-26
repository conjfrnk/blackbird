import simd

/// Bits 8-30 are reserved. Bit 31 is `BB_ATTR_NO_GLYPH`, set by the vertex shader itself
/// for zero-UV-rect instances: the CPU must never set it.
struct CellAttributeMask: OptionSet {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let linkHover = CellAttributeMask(rawValue: 1 << 0)
    static let strike = CellAttributeMask(rawValue: 1 << 1)
    static let underline = CellAttributeMask(rawValue: 1 << 2)
    static let underlineDouble = CellAttributeMask(rawValue: 1 << 3)
    static let undercurl = CellAttributeMask(rawValue: 1 << 4)
    static let underlineDotted = CellAttributeMask(rawValue: 1 << 5)
    static let underlineDashed = CellAttributeMask(rawValue: 1 << 6)
    static let isColorGlyph = CellAttributeMask(rawValue: 1 << 7)

    static let anyUnderline: CellAttributeMask = [
        .underline, .underlineDouble, .undercurl, .underlineDotted, .underlineDashed,
    ]
}

/// 80-byte stride. Field order and layout must match the `CellInstance` struct in Shaders.metal exactly.
/// `attrs`: `.x` CellAttributeMask, `.z` CSI 58 underline colour as 0x00RRGGBB or 0xFFFFFFFF for "use fg", `.y`/`.w` reserved (0).
struct CellInstance {
    var cellPosPx: SIMD2<Float>   // points
    var quadSizePx: SIMD2<Float>  // points; `(cellW * 2, cellH)` for wide cells
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    /// sRGB-encoded RGB with linear alpha, blended as-is into a `.bgra8Unorm` (not `_srgb`) target.
    var fgColor: SIMD4<Float>
    var bgColor: SIMD4<Float>
    var attrs: SIMD4<UInt32>
}

/// After a deliberate field change, update the mirror struct in Shaders.metal before this constant.
private let _cellInstanceLayoutPinned: Void = {
    precondition(MemoryLayout<CellInstance>.stride == 80,
                 "CellInstance stride drifted from the 80-byte contract mirrored "
                 + "in Shaders.metal — update the shader struct BEFORE widening "
                 + "this number.")
    precondition(MemoryLayout<CellInstance>.alignment == 16,
                 "CellInstance alignment must match Metal's natural 16-byte "
                 + "alignment for SIMD4 types.")
}()

@inline(never)
func _pinCellInstanceLayout() { _ = _cellInstanceLayoutPinned }
