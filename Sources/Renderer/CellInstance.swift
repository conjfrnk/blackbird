import simd

/// Per-cell attribute bits carried to the GPU. Distinct from `cell_flags`
/// on the Rust side because a few of these are renderer-computed (link
/// hover is injected by the mouse-tracking path, not by the VT parser)
/// and because the shader wants a flat bitset it can branch on cheaply
/// without knowing the BBCell layout. The renderer translates cell_flags
/// → CellAttributeMask in buildInstances.
///
/// Bit-budget reservation: bits 0-7 are render-state toggles; bits 8-31
/// are reserved for future per-cell data (e.g., an underline-color index
/// once colored underlines land in Task 2.5).
struct CellAttributeMask: OptionSet {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Bit 0: accent-coloured underline for the cell. Originally for OSC 8
    /// hover highlighting, but the plumbing is generic — any future "draw
    /// an accent underline here" attribute can reuse it.
    static let linkHover = CellAttributeMask(rawValue: 1 << 0)
    /// Bit 1: SGR 9 strikethrough. Drawn as a 1-2 pt band at cell mid-height
    /// in the cell's fg colour.
    static let strike = CellAttributeMask(rawValue: 1 << 1)
    /// Bit 2: SGR 4 plain single underline.
    static let underline = CellAttributeMask(rawValue: 1 << 2)
    /// Bit 3: SGR 4:2 / legacy style double underline.
    static let underlineDouble = CellAttributeMask(rawValue: 1 << 3)
    /// Bit 4: SGR 4:3 undercurl (wavy). LSP diagnostic squigglies.
    static let undercurl = CellAttributeMask(rawValue: 1 << 4)
    /// Bit 5: SGR 4:4 dotted underline.
    static let underlineDotted = CellAttributeMask(rawValue: 1 << 5)
    /// Bit 6: SGR 4:5 dashed underline.
    static let underlineDashed = CellAttributeMask(rawValue: 1 << 6)

    /// Mask covering every "paint a line under the glyph" bit. Shader uses
    /// this to short-circuit the underline composite when none is set.
    static let anyUnderline: CellAttributeMask = [
        .underline, .underlineDouble, .undercurl, .underlineDotted, .underlineDashed,
    ]
}

/// Per-cell instance data uploaded to the GPU each frame. 80-byte stride
/// (4x SIMD2 floats + 2x SIMD4 floats + SIMD4 uint). Field order + layout
/// must match the `CellInstance` struct in Shaders.metal exactly.
///
/// `attrs` layout:
///   - `.x`: CellAttributeMask bitmask (linkHover, strike, underline styles)
///   - `.y`: reserved (0)
///   - `.z`: CSI 58 underline-color, 0x00RRGGBB or 0xFFFFFFFF sentinel
///           meaning "fall back to fg". Shader unpacks to RGBA on demand —
///           keeping it as a packed u32 saves 12 bytes per cell vs a
///           dedicated SIMD4<Float>, which at 16k cells (200×80 grid) is
///           ~192 KiB per frame off the CPU→GPU bus.
///   - `.w`: reserved (0)
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
    /// Attribute bitmask + packed underline-color. See struct header.
    var attrs: SIMD4<UInt32>      // 16 bytes
}

/// Pin the CellInstance stride so a future field addition / reordering can't
/// silently diverge from the `CellInstance` struct in Shaders.metal. A
/// mismatch here would read garbage into every vertex attribute at runtime
/// and present as "random cells draw solid black" or UV-scrambled glyphs —
/// the kind of visual regression the audit (glyph-atlas F8) flagged as only
/// catchable by a static layout assertion.
///
/// If this fires after a deliberate field change: update Shaders.metal's
/// mirror struct to match, rebuild, and only then update this constant.
private let _cellInstanceLayoutPinned: Void = {
    assert(MemoryLayout<CellInstance>.stride == 80,
           "CellInstance stride drifted from the 80-byte contract mirrored "
           + "in Shaders.metal — update the shader struct BEFORE widening "
           + "this number.")
    assert(MemoryLayout<CellInstance>.alignment == 16,
           "CellInstance alignment must match Metal's natural 16-byte "
           + "alignment for SIMD4 types.")
}()

/// Forces evaluation of `_cellInstanceLayoutPinned` at module load so the
/// assertion fires during unit tests / debug runs rather than only when a
/// particular code path touches the constant.
@inline(never)
func _pinCellInstanceLayout() { _ = _cellInstanceLayoutPinned }
