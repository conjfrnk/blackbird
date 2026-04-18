import simd

/// Per-cell attribute bits carried to the GPU. Room for future glyph-level
/// flags (bold/italic already live in the Rust cell bits; those resolve
/// into texture lookups, not render toggles, so they stay out of this mask).
struct CellAttributeMask: OptionSet {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Bit 0: accent-coloured underline for the cell. Task 7 uses this for
    /// OSC 8 hover highlighting, but the plumbing is generic — any future
    /// "draw an accent underline here" attribute can reuse the same bit.
    static let linkHover = CellAttributeMask(rawValue: 1 << 0)
}

/// Per-cell instance data uploaded to the GPU each frame. 80-byte stride
/// (4x SIMD2 floats + 2x SIMD4 floats + SIMD4 uint). Field order + layout
/// must match the `CellInstance` struct in Shaders.metal exactly —
/// `SIMD4<UInt32>` carries the 4-byte flags plus 12 bytes of padding so
/// the shader-side `uint4` alignment stays sane on every Metal target.
struct CellInstance {
    var cellPosPx: SIMD2<Float>   //  8 bytes — cell position in points
    /// Quad size in points. Same as the uniform `cellSizePx` for narrow cells;
    /// `(cellW * 2, cellH)` for wide cells so CJK / wide emoji render at their
    /// real double-width without clipping.
    var quadSizePx: SIMD2<Float>  //  8 bytes
    var uvOrigin: SIMD2<Float>    //  8 bytes — glyph UV in atlas
    var uvSize: SIMD2<Float>      //  8 bytes
    var fgColor: SIMD4<Float>     // 16 bytes — RGBA foreground
    var bgColor: SIMD4<Float>     // 16 bytes — RGBA background
    /// Attribute bitmask (CellAttributeMask). Only `.x` is read; the rest
    /// of the lane is padding so the struct honours Metal's 16-byte
    /// alignment for uint4.
    var attrs: SIMD4<UInt32>      // 16 bytes (x = flags, yzw = _pad)
}
