import BBCore
import simd

/// VT-cell → GPU-instance translation, hoisted out of `MetalRenderer` so the
/// cell-row → `CellInstance` responsibility lives in one unit-testable value
/// type instead of being smeared across the renderer's stateful methods.
///
/// The builder captures the per-frame visual inputs BY VALUE (theme colours,
/// insets, ⌘-hover range, hovered link id, metrics) plus a REFERENCE to the
/// live `GlyphAtlas` (glyph lookup mutates it on a miss — rasterize-and-store —
/// and `GlyphAtlas` is a `final class`, so the by-value capture is a reference
/// to the same instance the renderer holds; the rasterized slot is therefore
/// visible to the encoder that runs after the build).
///
/// BOUNDARY: the builder NEVER touches the triple-buffer ring, the inflight
/// semaphore, the slot lifecycle, the command buffer, or the renderer's
/// skip-cache. `MetalRenderer.buildInstances` constructs the builder once per
/// non-skipped frame, hands it each row's target `[CellInstance]` array to
/// fill, and then owns the flatten-into-GPU-buffer + slot-grow step itself.
/// The builder only reads its captured inputs and appends to the `out` array.
struct CellInstanceBuilder {
    /// Cell geometry (cellWidth / cellHeight). The builder reads only those two
    /// fields, but holds the whole value for parity with the renderer's call
    /// sites — `metrics` only ever changes through `MetalRenderer.reconfigure`,
    /// never mid-build.
    let metrics: CellMetrics
    /// OSC 8 link id currently under the pointer. Cells with matching `link_id`
    /// receive the accent underline via the `linkHover` attribute bit. Zero
    /// means "no hovered link".
    let hoveredLinkID: UInt16
    /// ⌘-held regex URL range under the pointer, keyed on *buffer* line so the
    /// underline survives scrollback motion. `cmdHoverStartCol < 0` disables the
    /// branch entirely (the "no range" sentinel).
    let cmdHoverBufferLine: Int32
    let cmdHoverStartCol: Int32
    let cmdHoverEndCol: Int32
    /// Theme-derived colour inputs consumed by `resolveColors` + the block-cursor
    /// inversion path. `defaultBgRgb` is the "treat as transparent" sentinel bg;
    /// `keepBgOpaque` / `backgroundOpacity` drive the explicit-bg alpha policy;
    /// `cursorColor` paints the focused block-cursor body (forced opaque).
    let defaultBgRgb: UInt32
    let keepBgOpaque: Bool
    let backgroundOpacity: Float
    let cursorColor: SIMD4<Float>
    /// Layout offsets in points added to every cell quad — the same values
    /// TerminalView feeds the renderer via `setTopInsetPoints` /
    /// `setLeftInsetPoints` on each `layout()`.
    let leftInsetPoints: Float
    let topInsetPoints: Float
    /// Live glyph atlas (REFERENCE — `GlyphAtlas` is a class). `emitCell` calls
    /// `lookupOrInsert`, which rasterises a missing glyph into the atlas in
    /// place; because this is the same instance the renderer holds, the new slot
    /// is visible to `encodeCells` later in the same frame. MUST stay a
    /// reference (never copied) so the rasterize-on-miss is not lost.
    let atlas: GlyphAtlas

    /// Rebuild instances for a single visible row into `out`, consulting
    /// snapshot cells, selection, hover, and cursor-inversion state. Pure
    /// apart from the output parameter and the atlas mutation-on-miss — does
    /// not touch GPU buffers or renderer cache state. Called by
    /// `MetalRenderer.buildInstances` for every row on a full rebuild, or only
    /// for the damaged rows on a partial rebuild.
    ///
    /// Appends to `out` in place (pre-cleared by the caller with
    /// `removeAll(keepingCapacity: true)`) instead of returning a fresh
    /// `[CellInstance]`: rows emit a variable count of instances (blank
    /// cells contribute nothing; wide-glyph rows emit fewer than cols;
    /// selection/link-hover may push to 1-per-cell), and on a partial
    /// rebuild the caller would otherwise free the prior array's storage
    /// and allocate a new one each frame. Keeping the backing buffer
    /// eliminates up to 80 heap alloc/free pairs per full rebuild, which
    /// at 120 Hz is ~9 600 heap operations/sec off the CPU. Audit
    /// metal-renderer F5.
    func buildRow(
        snapshot: BBSnapshot,
        row: Int,
        isSelected: (Int32, Int) -> Bool,
        blockCursorCell: (row: Int, col: Int)?,
        into out: inout [CellInstance]
    ) {
        let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)
        let cellsPtr = snapshot.cellsPointer
        let cols = snapshot.cols
        let hoveredID = hoveredLinkID
        // Row in *buffer* space (scrollback-adjusted) — the ⌘-hover range
        // is keyed on buffer line so the underline survives scrolling
        // without the caller re-resolving the pointer on every snapshot.
        // `Int32(clamping:)` for parity with the M-16 sites: the
        // subtraction operates on `Int`s sourced from BBCore, and a
        // future regression that lets either operand exceed Int32's
        // range (or pushes the difference negative-overflow) would
        // trap the renderer mid-frame. Clamping keeps the contract
        // pinned at the cast site. Audit UR-2 (2026-04-29).
        let rowBufferLine = Int32(clamping: row - snapshot.displayOffset)
        let cmdHoverActiveOnThisRow =
            cmdHoverStartCol >= 0
            && cmdHoverBufferLine == rowBufferLine
        // Upper bound: every cell emits at most one instance. Reserve so
        // the common case avoids growing the array — a no-op when `out`
        // already has >= cols capacity from the prior frame.
        out.reserveCapacity(cols)

        for col in 0..<cols {
            let idx = row * cols + col
            // `cellsPtr` is a raw pointer; reading past `cellCount` would
            // be UB, not a trap. Same invariant alacritty guarantees but
            // re-checked here so a buggy snapshot can't cascade.
            if idx >= snapshot.cellCount { break }
            let cell = cellsPtr[idx]

            let attrs = Self.attributeBits(
                cell: cell,
                hoveredLinkID: hoveredID,
                cmdHoverActiveOnRow: cmdHoverActiveOnThisRow,
                cmdHoverStartCol: cmdHoverStartCol,
                cmdHoverEndCol: cmdHoverEndCol,
                col: col
            )
            // Base fg/bg after reverse/dim/default-bg resolution (pre-selection,
            // pre-cursor). `var fg` because the block-cursor path overwrites it.
            let resolved = Self.resolveColors(
                cell: cell,
                defaultBg: defaultBgRgb,
                keepBgOpaque: keepBgOpaque,
                backgroundOpacity: backgroundOpacity
            )
            var fg = resolved.fg
            let hasBg = resolved.hasBg

            // `Int32(clamping:)` per UR-2 — same defense-in-depth
            // rationale as the `rowBufferLine` site above.
            let bufferLine = Int32(clamping: row) - Int32(clamping: snapshot.displayOffset)
            let selected = isSelected(bufferLine, col)
            var effectiveBg = selected ? selectionTint : resolved.bg
            var effectiveHasBg = selected ? true : hasBg

            // Invert at the cursor cell so the block cursor shows the
            // underlying glyph in reverse-video. Selection wins over
            // the cursor (matches iTerm2: selection highlight spans a
            // cell even if the cursor is on it).
            if !selected,
               let bc = blockCursorCell,
               bc.row == row,
               bc.col == col {
                // Use whatever the cell's bg *would* have been (explicit
                // or theme-default) as the glyph colour, so the
                // character reads against the cursor's body.
                let resolvedBg: UInt32 = hasBg ? cell.bg : defaultBgRgb
                fg = Self.rgbToSIMD(resolvedBg)
                effectiveBg = cursorColor
                effectiveBg.w = 1.0
                effectiveHasBg = true
            }

            emitCell(
                cell: cell, col: col, row: row,
                cellW: cellW, cellH: cellH,
                fg: fg, bg: effectiveBg, hasBg: effectiveHasBg,
                attrs: attrs, selected: selected,
                into: &out
            )
        }
    }

    /// Pack one resolved cell into the instance buffer: position the quad,
    /// skip wide-char spacers (unless a highlight must span both halves),
    /// double the quad for wide glyphs, look the glyph up in the atlas, and
    /// append a `CellInstance` (glyph, accent-only, or bg-only as applicable).
    /// `bg` / `hasBg` are the post-selection / post-cursor effective values.
    private func emitCell(
        cell: BBCell, col: Int, row: Int,
        cellW: Float, cellH: Float,
        fg: SIMD4<Float>, bg: SIMD4<Float>, hasBg: Bool,
        attrs: SIMD4<UInt32>, selected: Bool,
        into out: inout [CellInstance]
    ) {
        let xPx = Float(col) * cellW + leftInsetPoints
        let yPx = Float(row) * cellH + topInsetPoints

        // WIDE_CHAR_SPACER / LEADING_WIDE_CHAR_SPACER sit to the right of (or
        // on the wrapped-leading col before) a wide glyph. The wide glyph's 2x
        // quad already covers this column, so any draw here would overpaint its
        // right half. Skip unless the selection highlight (or bg/accent) needs
        // a bg quad — in that case the highlight must span both halves.
        let isSpacer = (cell.flags &
            (UInt16(WIDE_CHAR_SPACER) | UInt16(LEADING_WIDE_CHAR_SPACER))) != 0
        if isSpacer {
            if selected || hasBg || attrs.x != 0 {
                out.append(CellInstance(
                    cellPosPx: SIMD2<Float>(xPx, yPx),
                    quadSizePx: SIMD2<Float>(cellW, cellH),
                    uvOrigin: .zero,
                    uvSize: .zero,
                    fgColor: fg,
                    bgColor: bg,
                    attrs: attrs
                ))
            }
            return
        }

        // WIDE_CHAR cells carry a CJK / wide-emoji glyph that logically spans
        // two cells. The atlas rasterises them into a 2x-wide slot and reports
        // a doubled uvSize.x; we draw a 2x-wide quad so the full glyph lands.
        let isWide = (cell.flags & UInt16(WIDE_CHAR)) != 0
        // EMOJI_PRESENTATION: a text-default base + VS16 (⚠️ ‼️ ❤️) — the atlas
        // must rasterise the colour emoji from the base + VS16 grapheme rather
        // than the monochrome base scalar.
        let isEmojiPresentation = (cell.flags & UInt16(EMOJI_PRESENTATION)) != 0
        let quadW = isWide ? cellW * 2.0 : cellW
        let quadSize = SIMD2<Float>(quadW, cellH)

        let scalar = cell.ch
        // Render cell if it has a glyph OR a non-default background.
        if scalar != 0 && scalar != 0x20 /* space */ {
            let glyphStyle = GlyphAtlas.Style(
                bold: (cell.flags & UInt16(BOLD)) != 0,
                italic: (cell.flags & UInt16(ITALIC)) != 0
            )
            if let us = Unicode.Scalar(scalar),
               let entry = atlas.lookupOrInsert(
                   scalar: us, wide: isWide, style: glyphStyle,
                   emojiPresentation: isEmojiPresentation) {
                // Tell the fragment shader to sample the color atlas (texture 1)
                // instead of the mono coverage atlas (texture 0) for this cell.
                // Atlas `Entry.isColor` is the single source of truth.
                var colorAttrs = attrs
                if entry.isColor {
                    colorAttrs.x |= CellAttributeMask.isColorGlyph.rawValue
                }
                out.append(CellInstance(
                    cellPosPx: SIMD2<Float>(xPx, yPx),
                    quadSizePx: quadSize,
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    fgColor: fg,
                    bgColor: bg,
                    attrs: colorAttrs
                ))
            }
        } else if hasBg || attrs.x != 0 {
            // Space with colored background (status lines, vim highlights),
            // inside an active selection, or carrying an accent attribute (link
            // hover). Draw a full-cell quad with zero coverage so the shader's
            // bg/accent paths still fire.
            out.append(CellInstance(
                cellPosPx: SIMD2<Float>(xPx, yPx),
                quadSizePx: quadSize,
                uvOrigin: .zero,
                uvSize: .zero,
                fgColor: fg,
                bgColor: bg,
                attrs: attrs
            ))
        }
    }

    /// Translate a cell's link-hover state + `cell_flags` into the
    /// renderer-side attribute bitset the shader consumes: `attrs.x` is the
    /// flag mask (link-hover, strike, the five underline variants), `attrs.z`
    /// carries the CSI 58 underline colour forwarded as-is (the shader treats
    /// `UNDERLINE_COLOR_UNSET` as "fall back to fg"). Pure — depends only on
    /// its arguments. `internal` so `CellRenderHelpersTests` can pin the mapping.
    static func attributeBits(
        cell: BBCell,
        hoveredLinkID: UInt16,
        cmdHoverActiveOnRow: Bool,
        cmdHoverStartCol: Int32,
        cmdHoverEndCol: Int32,
        col: Int
    ) -> SIMD4<UInt32> {
        var flags: UInt32 = 0
        if hoveredLinkID != 0 && cell.link_id == hoveredLinkID {
            flags |= CellAttributeMask.linkHover.rawValue
        }
        // ⌘-held regex URL highlight: the same accent underline the OSC 8
        // hover uses, but gated on a buffer-line range instead of a link id.
        // Applies only when the cell falls inside the active range on the
        // active buffer line.
        if cmdHoverActiveOnRow {
            let c = Int32(col)
            if c >= cmdHoverStartCol && c <= cmdHoverEndCol {
                flags |= CellAttributeMask.linkHover.rawValue
            }
        }
        // Translate cell_flags bits that the shader needs to render into our
        // flat renderer-side bitset. Cell flags live in Rust-stable constants
        // (BBCore bridging header); mapping here keeps the shader ignorant of
        // the Rust layout so a future cell_flags reshuffle stays local.
        let cf = cell.flags
        if (cf & UInt16(STRIKE)) != 0 { flags |= CellAttributeMask.strike.rawValue }
        if (cf & UInt16(UNDERLINE)) != 0 { flags |= CellAttributeMask.underline.rawValue }
        if (cf & UInt16(UNDERLINE_DOUBLE)) != 0 { flags |= CellAttributeMask.underlineDouble.rawValue }
        if (cf & UInt16(UNDERCURL)) != 0 { flags |= CellAttributeMask.undercurl.rawValue }
        if (cf & UInt16(UNDERLINE_DOTTED)) != 0 { flags |= CellAttributeMask.underlineDotted.rawValue }
        if (cf & UInt16(UNDERLINE_DASHED)) != 0 { flags |= CellAttributeMask.underlineDashed.rawValue }
        // Pack CSI 58 underline colour into attrs.z. The shader treats
        // UNDERLINE_COLOR_UNSET as "fall back to fg", so the cheapest path is
        // to forward the u32 as-is.
        return SIMD4<UInt32>(flags, 0, cell.underline_color, 0)
    }

    /// Resolve a cell's foreground / background colours and whether it needs a
    /// background quad, applying REVERSE (SGR 7), DIM (SGR 2), default-bg
    /// transparency, and the `keepBgOpaque` / `backgroundOpacity` alpha policy.
    /// Returns the base colours BEFORE selection tint and block-cursor
    /// inversion (the caller layers those). Pure — `internal` so the colour
    /// resolution is unit-testable without a GPU.
    static func resolveColors(
        cell: BBCell,
        defaultBg: UInt32,
        keepBgOpaque: Bool,
        backgroundOpacity: Float
    ) -> (fg: SIMD4<Float>, bg: SIMD4<Float>, hasBg: Bool) {
        var fg = rgbToSIMD(cell.fg)
        var bg = rgbToSIMD(cell.bg)
        // Reverse video (SGR 7): swap the cell's fg and bg so the glyph reads
        // against the inverted highlight. Forces a bg quad (we can't skip
        // drawing into the clearColor because the "new bg" is the original fg,
        // which is a real colour).
        let reverse = (cell.flags & UInt16(REVERSE)) != 0
        if reverse {
            let orig = fg
            fg = bg
            bg = orig
        }
        // DIM (SGR 2): halve the fg brightness so dimmed text reads softer
        // without affecting bg. Applied after REVERSE so the resulting glyph
        // colour is what's visibly dimmed.
        //
        // Audit L13. The halve happens on sRGB-encoded float components
        // (matching `rgbToSIMD` which divides bytes by 255 without
        // linearization). Strictly correct "perceived half luminance" would
        // gamma-decode → halve linear → gamma-encode, which on a midgray maps
        // to roughly 0.73 in sRGB-encoded space rather than 0.50. We
        // deliberately keep the sRGB-encoded halve so DIM is consistent with
        // the rest of the pipeline (cell composition, alpha blending, selection
        // overlay) which all operate in sRGB-encoded space — gamma-correcting
        // just DIM would visually clash. iTerm2 makes the same choice.
        // Re-evaluate as a unit if the renderer ever moves to a fully-linear
        // pipeline.
        if (cell.flags & UInt16(DIM)) != 0 {
            fg.x *= 0.5
            fg.y *= 0.5
            fg.z *= 0.5
        }
        // Treat the theme's default bg as "no bg" so the transparent clearColor
        // can show through. Cells with explicit colors (vim highlights, status
        // lines, syntax bg) still draw their bg quad; whether they stay solid
        // or become translucent is a user choice (keepBgOpaque). The decision
        // compares against the active theme's `defaultBg`, NOT literal
        // 0x000000 — see `shouldPaintBgQuad` (audit H2).
        let isDefaultBg = !reverse && cell.bg == defaultBg
        let hasBg = shouldPaintBgQuad(cellBg: cell.bg, defaultBg: defaultBg, reverse: reverse)

        // Determine the bg alpha to write into CellInstance:
        //   - Default bg → alpha 0 so the shader's mix() produces a transparent
        //     result where the glyph doesn't cover — clearColor shows through.
        //   - Explicit bg, keepBgOpaque on → alpha 1 (unchanged).
        //   - Explicit bg, keepBgOpaque off → alpha = opacity.
        let bgAlpha: Float
        if isDefaultBg {
            bgAlpha = 0.0
        } else if keepBgOpaque {
            bgAlpha = 1.0
        } else {
            bgAlpha = backgroundOpacity
        }
        bg.w = bgAlpha
        return (fg, bg, hasBg)
    }

    /// Pure decision: should `buildRow` emit a background quad for this cell?
    ///
    /// `true` when:
    ///   - the cell has REVERSE attribute (the swapped-in fg is a real
    ///     palette colour the user wants painted), OR
    ///   - the cell's `bg` differs from the active theme's
    ///     `defaultBgRgb` (an explicit `\x1b[4Nm` SGR set this cell's
    ///     background to a palette colour, and even palette black on a
    ///     non-black theme is "explicit" — the user wants it painted).
    ///
    /// Pre-fix this compared `cell.bg` to literal `0x000000`, which on
    /// non-black themes (Atom dark, Catppuccin, Solarized …) silently
    /// dropped every `\x1b[40m` quad: vim status lines, htop column
    /// shading, syntax highlights using ANSI black all leaked the
    /// theme bg through. Audit H2.
    ///
    /// Internal so MetalRendererTests can pin the decision table.
    static func shouldPaintBgQuad(
        cellBg: UInt32, defaultBg: UInt32, reverse: Bool
    ) -> Bool {
        if reverse { return true }
        return cellBg != defaultBg
    }

    /// `1.0 / 255.0` precomputed so `rgbToSIMD` can multiply instead of
    /// dividing. Called up to `2 * cols * rows` times per full rebuild
    /// (fg + bg per cell) — at 200x80 that's 32 000 calls/frame. FP-div
    /// is ~15 cycles on modern cores; multiplying by a constant is ~4.
    /// Audit metal-renderer F6. Internal (not private) so
    /// `MetalRenderer.setCursorColor` shares the same constant.
    static let inv255: Float = 1.0 / 255.0

    private static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
        // Unpack the 24-bit colour into a 4-lane SIMD so the float
        // conversion and scaling are vectorised as a single op. `1.0`
        // in the alpha lane lands in the default fully-opaque result;
        // callers that need a different alpha (e.g. background-opacity
        // plumbing) mutate `.w` after the call.
        let bytes = SIMD4<UInt32>(
            (rgb >> 16) & 0xFF,
            (rgb >> 8) & 0xFF,
            rgb & 0xFF,
            0
        )
        var result = SIMD4<Float>(bytes) * Self.inv255
        result.w = 1.0
        return result
    }
}
