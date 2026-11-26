import BBCore
import simd

/// VT-cell → GPU-instance translation for `MetalRenderer`.
struct CellInstanceBuilder {
    let metrics: CellMetrics
    /// Zero means "no hovered link".
    let hoveredLinkID: UInt16
    /// Keyed on *buffer* line. `cmdHoverStartCol < 0` means "no range".
    let cmdHoverBufferLine: Int32
    let cmdHoverStartCol: Int32
    let cmdHoverEndCol: Int32
    let defaultBgRgb: UInt32
    let keepBgOpaque: Bool
    let backgroundOpacity: Float
    let cursorColor: SIMD4<Float>
    let selectionColor: SIMD4<Float>
    let selectionForeground: SIMD4<Float>
    let leftInsetPoints: Float
    let topInsetPoints: Float
    /// Must be the instance the renderer holds: `lookupOrInsert` rasterises a missing glyph into it in place.
    let atlas: GlyphAtlas

    /// Appends to `out`, which the caller pre-clears.
    func buildRow(
        snapshot: BBSnapshot,
        row: Int,
        isSelected: (Int32, Int) -> Bool,
        blockCursorCell: (row: Int, col: Int)?,
        into out: inout [CellInstance]
    ) {
        let selectionTint = selectionColor
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)
        let cellsPtr = snapshot.cellsPointer
        let cols = snapshot.cols
        let hoveredID = hoveredLinkID
        let rowBufferLine = Int32(clamping: row - snapshot.displayOffset)
        let cmdHoverActiveOnThisRow =
            cmdHoverStartCol >= 0
            && cmdHoverBufferLine == rowBufferLine
        out.reserveCapacity(cols)

        let cellCount = snapshot.cellCount
        // Not `rowBufferLine`: that clamps the difference, this clamps each operand, and they
        // diverge in overflow corners.
        let bufferLine = Int32(clamping: row) - Int32(clamping: snapshot.displayOffset)

        for col in 0..<cols {
            let idx = row * cols + col
            // `cellsPtr` is a raw pointer: reading past `cellCount` is UB, not a trap.
            if idx >= cellCount { break }
            let cell = cellsPtr[idx]

            // The spacer right of a WIDE_CHAR is covered by that glyph's 2x quad; a quad emitted here draws
            // after the glyph and overpaints its right half. Exception: an unselected block cursor on the spacer.
            if col > 0,
               Self.isSpacerCoveredByWideGlyph(cell: cell, leftNeighbor: cellsPtr[idx - 1]) {
                let cursorOnSpacer = blockCursorCell?.row == row && blockCursorCell?.col == col
                if !cursorOnSpacer || isSelected(bufferLine, col) { continue }
            }

            let attrs = Self.attributeBits(
                cell: cell,
                hoveredLinkID: hoveredID,
                cmdHoverActiveOnRow: cmdHoverActiveOnThisRow,
                cmdHoverStartCol: cmdHoverStartCol,
                cmdHoverEndCol: cmdHoverEndCol,
                col: col
            )
            let resolved = Self.resolveColors(
                cell: cell,
                defaultBg: defaultBgRgb,
                keepBgOpaque: keepBgOpaque,
                backgroundOpacity: backgroundOpacity
            )
            var fg = resolved.fg
            let hasBg = resolved.hasBg

            // The spacer's own quad is skipped above, so the leading cell's 2x quad carries a
            // selection that starts on the spacer.
            let selected = isSelected(bufferLine, col)
                || ((cell.flags & UInt16(WIDE_CHAR)) != 0
                    && col + 1 < cols
                    && isSelected(bufferLine, col + 1))
            var effectiveBg = selected ? selectionTint : resolved.bg
            var effectiveHasBg = selected ? true : hasBg
            if selected, Self.contrastRatio(fg, selectionTint) < Self.minSelectedContrast {
                fg = selectionForeground
            }

            // Selection wins over the cursor.
            if !selected,
               let bc = blockCursorCell,
               bc.row == row,
               bc.col == col {
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

    private func emitCell(
        cell: BBCell, col: Int, row: Int,
        cellW: Float, cellH: Float,
        fg: SIMD4<Float>, bg: SIMD4<Float>, hasBg: Bool,
        attrs: SIMD4<UInt32>, selected: Bool,
        into out: inout [CellInstance]
    ) {
        let xPx = Float(col) * cellW + leftInsetPoints
        let yPx = Float(row) * cellH + topInsetPoints

        // A spacer reaching here is the unselected block-cursor cell or has no glyph quad to its left.
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

        // The atlas rasterises WIDE_CHAR glyphs into a 2x-wide slot and reports a doubled uvSize.x.
        let isWide = (cell.flags & UInt16(WIDE_CHAR)) != 0
        // Text-default base + VS16: the atlas rasterises the colour emoji from the grapheme, not the base scalar.
        let isEmojiPresentation = (cell.flags & UInt16(EMOJI_PRESENTATION)) != 0
        let quadW = isWide ? cellW * 2.0 : cellW
        let quadSize = SIMD2<Float>(quadW, cellH)

        let scalar = cell.ch
        // HIDDEN (SGR 8) cells never get a glyph quad, so the selection tint and block cursor cannot reveal them.
        let isConcealed = (cell.flags & UInt16(HIDDEN)) != 0
        if scalar != 0 && scalar != 0x20 /* space */ && !isConcealed {
            let glyphStyle = GlyphAtlas.Style(
                bold: (cell.flags & UInt16(BOLD)) != 0,
                italic: (cell.flags & UInt16(ITALIC)) != 0
            )
            if let us = Unicode.Scalar(scalar),
               let entry = atlas.lookupOrInsert(
                   scalar: us, wide: isWide, style: glyphStyle,
                   emojiPresentation: isEmojiPresentation) {
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
            // Zero-coverage quad so the shader's bg/accent paths still fire.
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
        if cmdHoverActiveOnRow {
            let c = Int32(col)
            if c >= cmdHoverStartCol && c <= cmdHoverEndCol {
                flags |= CellAttributeMask.linkHover.rawValue
            }
        }
        let cf = cell.flags
        if (cf & UInt16(STRIKE)) != 0 { flags |= CellAttributeMask.strike.rawValue }
        if (cf & UInt16(UNDERLINE)) != 0 { flags |= CellAttributeMask.underline.rawValue }
        if (cf & UInt16(UNDERLINE_DOUBLE)) != 0 { flags |= CellAttributeMask.underlineDouble.rawValue }
        if (cf & UInt16(UNDERCURL)) != 0 { flags |= CellAttributeMask.undercurl.rawValue }
        if (cf & UInt16(UNDERLINE_DOTTED)) != 0 { flags |= CellAttributeMask.underlineDotted.rawValue }
        if (cf & UInt16(UNDERLINE_DASHED)) != 0 { flags |= CellAttributeMask.underlineDashed.rawValue }
        // attrs.z carries the CSI 58 underline colour; the shader treats UNDERLINE_COLOR_UNSET as "fall back to fg".
        return SIMD4<UInt32>(flags, 0, cell.underline_color, 0)
    }

    /// Returns the base colours before selection tint and block-cursor inversion.
    static func resolveColors(
        cell: BBCell,
        defaultBg: UInt32,
        keepBgOpaque: Bool,
        backgroundOpacity: Float
    ) -> (fg: SIMD4<Float>, bg: SIMD4<Float>, hasBg: Bool) {
        var fg = rgbToSIMD(cell.fg)
        var bg = rgbToSIMD(cell.bg)
        let reverse = (cell.flags & UInt16(REVERSE)) != 0
        if reverse {
            let orig = fg
            fg = bg
            bg = orig
        }
        // DIM (SGR 2), applied after REVERSE, fades fg toward the cell's bg: halving toward black raises
        // contrast on a light theme. Blended in sRGB-encoded space like the rest of the pipeline.
        if (cell.flags & UInt16(DIM)) != 0 {
            fg.x = (fg.x + bg.x) * 0.5
            fg.y = (fg.y + bg.y) * 0.5
            fg.z = (fg.z + bg.z) * 0.5
        }
        let isDefaultBg = !reverse && cell.bg == defaultBg
        let hasBg = shouldPaintBgQuad(cellBg: cell.bg, defaultBg: defaultBg, reverse: reverse)

        // Default bg gets alpha 0 so the transparent clearColor shows through.
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

    static func isSpacerCoveredByWideGlyph(cell: BBCell, leftNeighbor: BBCell) -> Bool {
        (cell.flags & UInt16(WIDE_CHAR_SPACER)) != 0
            && (leftNeighbor.flags & UInt16(WIDE_CHAR)) != 0
    }

    /// Compares against the active theme's default bg, not literal 0x000000: palette black on a
    /// non-black theme is an explicit background.
    static func shouldPaintBgQuad(
        cellBg: UInt32, defaultBg: UInt32, reverse: Bool
    ) -> Bool {
        if reverse { return true }
        return cellBg != defaultBg
    }

    static let inv255: Float = 1.0 / 255.0

    static let minSelectedContrast: Float = 1.8

    /// Relative luminance (sRGB, WCAG 2 formula).
    static func relativeLuminance(_ c: SIMD4<Float>) -> Float {
        func lin(_ v: Float) -> Float {
            v <= 0.03928 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
    }

    static func contrastRatio(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
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
