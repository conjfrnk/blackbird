import Metal
import MetalKit
import AppKit
import BBCore

public final class MetalRenderer {

    /// Glyph atlas slots. 4096 covers ASCII + Latin supplements + common CJK
    /// + box-drawing + emoji-presentation for typical workloads without
    /// hitting the "atlas full → new glyphs render as blanks" cliff that a
    /// smaller cap (prior 1024) would reach on a day of mixed-locale output.
    /// R8Unorm texture at default cell size ≈ 9 MB, trivial on any Mac we
    /// support.
    static let atlasCapacity = 4096

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let cursorPipelineState: MTLRenderPipelineState
    public var atlas: GlyphAtlas
    public var metrics: CellMetrics

    // Preallocated instance buffer. Growable via reallocateInstanceBuffer.
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    private var cursorColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// When a cell's resolved bg equals this value, we treat it as "default
    /// background" and skip drawing a bg quad. That lets the transparent
    /// clearColor show through — the window-level transparency effect.
    /// `0xFFFFFFFF` acts as a sentinel meaning "no theme bg configured yet".
    private var defaultBgRgb: UInt32 = 0xFFFFFFFF
    /// Overall opacity applied to non-default cell backgrounds. 1.0 keeps
    /// them solid; lower values let the framebuffer (clearColor) peek
    /// through — used when the user wants even vim status lines to be
    /// translucent (keepBgOpaque == false in iTerm2 terms).
    private var backgroundOpacity: Float = 1.0
    private var keepBgOpaque: Bool = true

    /// Vertical offset (in points) added to every cell and cursor. Used by
    /// TerminalView to keep text out of the titlebar region when the window
    /// uses `.fullSizeContentView` so the Metal clearColor can tint under the
    /// titlebar. TerminalView passes `safeAreaInsets.top` here on each layout.
    private var topInsetPoints: Float = 0.0

    public func setTopInsetPoints(_ points: Float) { topInsetPoints = points }

    /// Whether the cursor should blink when the window is focused. When on,
    /// the cursor renders for the first half of each ~1.06 s cycle and is
    /// skipped for the second half. The cycle resets every time the cursor
    /// moves (typing, arrow keys, output scrolling the prompt) so a moving
    /// cursor is always visible — just like xterm/iTerm/Terminal.app.
    private var cursorBlinkEnabled: Bool = false
    private var blinkPhaseStart: CFTimeInterval = 0
    private var lastCursorRow: Int32 = -1
    private var lastCursorCol: Int32 = -1

    public func setCursorBlinkEnabled(_ enabled: Bool) {
        if enabled != cursorBlinkEnabled {
            cursorBlinkEnabled = enabled
            blinkPhaseStart = CACurrentMediaTime()
        }
    }

    public func setDefaultBgRgb(_ rgb: UInt32) { defaultBgRgb = rgb }

    public func setBackgroundOpacity(_ opacity: Float, keepBgOpaque: Bool) {
        self.backgroundOpacity = opacity
        self.keepBgOpaque = keepBgOpaque
    }

    public func setCursorColor(rgb: UInt32) {
        let r = Float((rgb >> 16) & 0xFF) / 255.0
        let g = Float((rgb >> 8)  & 0xFF) / 255.0
        let b = Float(rgb & 0xFF) / 255.0
        cursorColor = SIMD4<Float>(r, g, b, 1.0)
    }

    public init?(device: MTLDevice, metrics: CellMetrics, scale: CGFloat = 2.0) {
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let library = device.makeDefaultLibrary() else { return nil }
        guard let vertexFn = library.makeFunction(name: "vertex_cell"),
              let fragmentFn = library.makeFunction(name: "fragment_cell") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        guard let cursorVertex = library.makeFunction(name: "vertex_cursor"),
              let cursorFragment = library.makeFunction(name: "fragment_cursor") else { return nil }
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = cursorVertex
        cursorDesc.fragmentFunction = cursorFragment
        cursorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Cursor is opaque white — no blending.
        guard let cursorPSO = try? device.makeRenderPipelineState(descriptor: cursorDesc) else { return nil }

        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return nil
        }

        // Start with space for a full 200x80 grid; grow as needed.
        let startCap = 200 * 80
        guard let buf = device.makeBuffer(
            length: startCap * MemoryLayout<CellInstance>.stride,
            options: [.storageModeShared]
        ) else { return nil }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pso
        self.cursorPipelineState = cursorPSO
        self.atlas = atlas
        self.metrics = metrics
        self.instanceBuffer = buf
        self.instanceCapacity = startCap
    }

    /// Rebuild metrics + atlas for a new font size. Safe to call from the
    /// main thread — allocations happen synchronously, but the next draw
    /// picks up the new atlas immediately.
    ///
    /// Atomic: metrics only change if the new atlas built successfully.
    /// Returns `true` on success, `false` when the atlas couldn't be
    /// allocated (e.g., GPU memory pressure) so callers can keep their
    /// own mirror of metrics in sync.
    @discardableResult
    public func reconfigure(metrics newMetrics: CellMetrics, scale: CGFloat) -> Bool {
        guard let a = GlyphAtlas(device: device, metrics: newMetrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return false
        }
        self.metrics = newMetrics
        self.atlas = a
        return true
    }

    /// Write cell instance data into `instanceBuffer`. Returns the count
    /// of instances actually written (= non-empty cells).
    ///
    /// `blockCursorCell`, when non-nil, identifies a single (row, col) whose
    /// cell should render *inverted* so it doubles as the block cursor: the
    /// glyph appears in the cell's current bg colour on top of a solid
    /// cursor-colour background. Callers use this for focused-block cursors
    /// so the character under the cursor stays visible (matches iTerm2 /
    /// Terminal.app). Other shapes (bar, underline, unfocused outline)
    /// continue to go through `cursorPipelineState`.
    @discardableResult
    private func buildInstances(
        snapshot: BBSnapshot,
        isSelected: (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil
    ) -> Int {
        let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)  // AppKit accent-ish blue
        let needed = snapshot.cols * snapshot.rows
        // Defensive: alacritty's display_iter always yields cols×rows cells,
        // and the Rust FFI preserves that invariant via Vec::with_capacity +
        // push-per-cell. But the cells pointer lives in Rust-owned memory
        // and we're about to index into it; a future refactor that breaks
        // the invariant would silently read past the buffer end with
        // assumingMemoryBound pointer arithmetic. Bail on the frame rather
        // than emit UB into the GPU's instance buffer.
        guard snapshot.cellCount >= needed else { return 0 }
        if needed > instanceCapacity {
            let newCap = max(needed, instanceCapacity * 2)
            if let newBuf = device.makeBuffer(
                length: newCap * MemoryLayout<CellInstance>.stride,
                options: [.storageModeShared]
            ) {
                instanceBuffer = newBuf
                instanceCapacity = newCap
            } else {
                // Out-of-GPU-memory (or device tear-down) while trying to
                // grow the instance buffer. Writing cells past the current
                // capacity would be UB; skip this frame instead. The renderer
                // retries on the next draw, so transient failures self-heal.
                return 0
            }
        }

        let ptr = instanceBuffer.contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)
        let cellsPtr = snapshot.cellsPointer

        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                let idx = row * snapshot.cols + col
                let cell = cellsPtr[idx]
                let scalar = cell.ch
                var fg = Self.rgbToSIMD(cell.fg)
                var bg = Self.rgbToSIMD(cell.bg)
                // Reverse video (SGR 7): swap the cell's fg and bg so the
                // glyph reads against the inverted highlight. Forces a bg
                // quad (we can't skip drawing into the clearColor because
                // the "new bg" is the original fg, which is a real colour).
                let reverse = (cell.flags & UInt16(REVERSE)) != 0
                if reverse {
                    let orig = fg
                    fg = bg
                    bg = orig
                }
                // DIM (SGR 2): halve the fg brightness so dimmed text reads
                // softer without affecting bg. Applied after REVERSE so the
                // resulting glyph colour is what's visibly dimmed.
                if (cell.flags & UInt16(DIM)) != 0 {
                    fg.x *= 0.5
                    fg.y *= 0.5
                    fg.z *= 0.5
                }
                // Treat the theme's default bg as "no bg" so the transparent
                // clearColor can show through. Cells with explicit colors
                // (vim highlights, status lines, syntax bg) still draw their
                // bg quad; whether they stay solid or become translucent is
                // a user choice (keepBgOpaque).
                // After a REVERSE swap the effective bg is the original fg,
                // which is always a concrete palette value — treat it as a
                // real background so the highlight paints.
                let effectiveBgRgb = reverse ? cell.fg : cell.bg
                let isDefaultBg = !reverse && cell.bg == defaultBgRgb
                let hasBg = reverse || (!isDefaultBg && effectiveBgRgb != 0x000000)

                // Determine the bg alpha for what we'll write into
                // CellInstance:
                //   - Default bg → alpha 0 so the shader's mix() produces a
                //     transparent result where the glyph doesn't cover —
                //     clearColor (already transparent) shows through.
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

                let bufferLine = Int32(row) - Int32(snapshot.displayOffset)
                let selected = isSelected(bufferLine, col)
                var effectiveBg = selected ? selectionTint : bg
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

                let xPx = Float(col) * cellW
                let yPx = Float(row) * cellH + topInsetPoints
                // Render cell if it has a glyph OR a non-default background.
                if scalar != 0 && scalar != 0x20 /* space */ {
                    if let us = Unicode.Scalar(scalar),
                       let entry = atlas.lookupOrInsert(scalar: us) {
                        ptr[count] = CellInstance(
                            cellPosPx: SIMD2<Float>(xPx, yPx),
                            uvOrigin: entry.uvOrigin,
                            uvSize: entry.uvSize,
                            fgColor: fg,
                            bgColor: effectiveBg
                        )
                        count += 1
                    }
                } else if effectiveHasBg {
                    // Space with colored background (status lines, vim highlights)
                    // or inside an active selection. Draw a full-cell quad with
                    // zero coverage → pure bg fill.
                    ptr[count] = CellInstance(
                        cellPosPx: SIMD2<Float>(xPx, yPx),
                        uvOrigin: .zero,
                        uvSize: .zero,
                        fgColor: fg,
                        bgColor: effectiveBg
                    )
                    count += 1
                }
            }
        }
        return count
    }

    private static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
        let r = Float((rgb >> 16) & 0xFF) / 255.0
        let g = Float((rgb >> 8) & 0xFF) / 255.0
        let b = Float(rgb & 0xFF) / 255.0
        return SIMD4<Float>(r, g, b, 1.0)
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool, selection: Selection? = nil) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Build a cheap closure that answers "is buffer-(line, col) inside
        // the current selection?". Called once per cell while building the
        // instance array. Rectangular mode hits an axis-aligned bounding
        // box; prose-style modes use the standard (start, end) sweep where
        // interior lines select the full width.
        let isSelected: (Int32, Int) -> Bool = { [selection] line, col in
            guard let sel = selection else { return false }
            let (a, b) = sel.normalized
            switch sel.mode {
            case .rectangular:
                let lo = min(a.line, b.line), hi = max(a.line, b.line)
                let cLo = min(a.col, b.col), cHi = max(a.col, b.col)
                return line >= lo && line <= hi && col >= cLo && col <= cHi
            case .line:
                // Line mode always highlights whole rows between a.line and
                // b.line — the drag path keeps anchor/cursor on their
                // original col, so without this the last (or first) dragged
                // line would only highlight up to the pointer's column.
                return line >= a.line && line <= b.line
            case .character, .word:
                if line < a.line || line > b.line { return false }
                if a.line == b.line { return col >= a.col && col <= b.col }
                if line == a.line { return col >= a.col }
                if line == b.line { return col <= b.col }
                return true
            }
        }

        if let snap = snapshot {
            // Viewport in points, not pixels. NDC conversion in the shader
            // divides point positions by point viewport, giving a scale-
            // independent result that the hardware rasterizes to the drawable's
            // pixel space. Text stays at its absolute cell-sized position as
            // the window grows/shrinks, with empty space on the right/bottom
            // when the grid hasn't caught up yet (which synchronous
            // session.resize now eliminates).
            let viewportPoints = SIMD2<Float>(
                Float(view.bounds.size.width),
                Float(view.bounds.size.height)
            )
            let cellSizePoints = SIMD2<Float>(
                Float(metrics.cellWidth),
                Float(metrics.cellHeight)
            )
            // Cursor position in viewport rows. When the user is scrolled back
            // into history (displayOffset > 0), the live cursor_row is offset
            // downward on-screen by that amount: rows 0..displayOffset-1 show
            // scrollback, and the live grid starts at screen row displayOffset.
            // If the resulting row falls below the viewport, the live cursor
            // isn't visible and we skip drawing it — scrolling back should
            // never show a phantom cursor on a scrollback line.
            let screenCursorRow = snap.cursorRow + snap.displayOffset
            let shape = UInt32(snap.cursorShape)
            // Reset the blink cycle every time the cursor moves, so a
            // moving cursor is continuously visible. Tracked in
            // grid-coordinate space (cursorRow/Col), not screen row.
            let curRow = Int32(snap.cursorRow)
            let curCol = Int32(snap.cursorCol)
            if curRow != lastCursorRow || curCol != lastCursorCol {
                lastCursorRow = curRow
                lastCursorCol = curCol
                blinkPhaseStart = CACurrentMediaTime()
            }
            // When enabled, skip the draw in the second half of each cycle.
            // Blink only runs while the window is focused; unfocused windows
            // already render a hollow outline that stays steady. The filled
            // state is driven by `focused` in the uniforms below.
            let blinkSkip: Bool = {
                guard cursorBlinkEnabled, focused else { return false }
                let elapsed = CACurrentMediaTime() - blinkPhaseStart
                let phase = elapsed.truncatingRemainder(dividingBy: 1.06)
                return phase >= 0.53
            }()
            let cursorOnScreen =
                snap.cursorVisible &&
                shape != 3 &&                 // DECSCUSR hidden — skip entirely
                snap.cursorCol < snap.cols &&
                screenCursorRow < snap.rows &&
                !blinkSkip
            // Focused block cursor renders via cell inversion (so the glyph
            // stays visible). Bar / underline / unfocused-outline go through
            // the cursor pipeline below. This mirrors iTerm2 behaviour and
            // keeps reverse-video cells intact when the cursor crosses them.
            let useCellInvertedCursor = cursorOnScreen && focused && shape == 0
            let blockCursorCell: (row: Int, col: Int)? = useCellInvertedCursor
                ? (row: screenCursorRow, col: snap.cursorCol)
                : nil
            let instanceCount = buildInstances(
                snapshot: snap,
                isSelected: isSelected,
                blockCursorCell: blockCursorCell
            )
            if instanceCount > 0 {
                var uniforms = FrameUniforms(
                    viewportPx: viewportPoints,
                    cellSizePx: cellSizePoints
                )
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: instanceCount
                )
            }
            if cursorOnScreen && !useCellInvertedCursor {
                var cu = CursorUniforms(
                    viewportPx: viewportPoints,
                    cursorPosPx: SIMD2<Float>(Float(snap.cursorCol) * Float(metrics.cellWidth),
                                              Float(screenCursorRow) * Float(metrics.cellHeight) + topInsetPoints),
                    cellSizePx: cellSizePoints,
                    color: cursorColor,
                    strokeWidthPx: 1.0,
                    filled: focused ? 1.0 : 0.0,
                    shape: shape,
                    _pad: 0
                )
                encoder.setRenderPipelineState(cursorPipelineState)
                encoder.setVertexBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

struct FrameUniforms {
    var viewportPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
}

struct CursorUniforms {
    var viewportPx: SIMD2<Float>
    var cursorPosPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var color: SIMD4<Float>
    var strokeWidthPx: Float
    var filled: Float       // 1.0 = solid block (window focused), 0.0 = outline
    var shape: UInt32       // 0 = block, 1 = bar, 2 = underline, 3 = hidden
    var _pad: Float         // keeps struct layout / alignment stable
}
