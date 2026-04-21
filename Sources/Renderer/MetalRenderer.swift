import Metal
import MetalKit
import AppKit
import BBCore
import os

public final class MetalRenderer {

    /// Shared `os.Logger` for renderer diagnostics. GPU command-buffer errors
    /// (device lost, page fault, shader trap) and teardown-drain events route
    /// here so they survive in the unified log with readable `privacy: .public`
    /// strings — the project-wide rule from `feedback_nslog_private_format`:
    /// NSLog's runtime format redacts everything to `<private>`, which hides
    /// the diagnostic we actually need.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "renderer")

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

    /// Triple-buffered instance-data ring. Each `render(in:)` call writes to
    /// the buffer at `frameIndex` and advances the index; the command buffer
    /// holds a reference to that specific buffer until the GPU is done
    /// reading. Without triple-buffering, `.storageModeShared` lets the CPU
    /// start writing the next frame while the GPU is still sampling the
    /// previous one — a data race that shows up as flicker/tearing under
    /// fast typing on loaded systems. Three buffers + a 3-slot semaphore
    /// match Apple's canonical "MTKView drawable pool" sizing.
    ///
    /// Each buffer grows independently — capacity is tracked per-slot so
    /// a ring reallocation only rebuilds the slot that overflowed, not
    /// all three.
    private var instanceBuffers: [MTLBuffer]
    private var instanceCapacities: [Int]
    private var frameIndex: Int = 0
    /// The slot the current `render(in:)` call has locked. Set after
    /// `inflightSemaphore.wait()`, read by `buildInstances` and the encoder,
    /// cleared on completion. Not thread-safe on its own — `render(in:)`
    /// always runs on the main thread.
    private var currentSlot: Int = 0
    /// Three tokens match three buffers. Every `render(in:)` waits on one
    /// before touching its slot; the command buffer's completion handler
    /// signals. The GPU can run up to three frames ahead of the CPU;
    /// beyond that, the CPU blocks, which is the correct backpressure
    /// shape for a latency-sensitive text renderer.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    private var cursorColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// Accent colour applied by the fragment shader whenever a cell's
    /// `linkHover` attribute bit is set. Defaults to an sRGB approximation
    /// of macOS's `controlAccentColor` so the underline looks right even
    /// without a theme-provided override.
    private var accentColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
    /// OSC 8 link id currently under the pointer. Cells with matching
    /// `link_id` receive the accent underline via the `linkHover`
    /// attribute bit. Zero means "no hovered link" — the renderer skips
    /// the underline branch entirely.
    private var hoveredLinkID: UInt16 = 0
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

    /// Identity of every input that affects pixels on screen, packed for
    /// Equatable comparison. When `render()` is called with a key equal to
    /// the one rendered last frame, the GPU already holds the correct
    /// pixels: we skip buildInstances, encoding, and present entirely.
    /// CAMetalLayer's compositor retains the previously presented drawable
    /// so the screen stays correct.
    ///
    /// Typed storage (struct, not a hash) because hashing would either:
    ///   - be too loose (collisions silently miss redraws), or
    ///   - pay the Hashable overhead every frame anyway.
    /// Equatable on 13 fields comes out to a handful of CPU instructions;
    /// the branch predictor handles the common "identical" case fast.
    private struct FrameKey: Equatable {
        /// Monotonic sequence id from BBSnapshot (0 when snapshot is nil).
        /// Intentionally NOT the handle pointer: the allocator can reuse an
        /// address after a snapshot is released, which would make two
        /// distinct snapshots look identical to pointer-equality and cause
        /// a popup-close or cursor-move repaint to be silently dropped.
        /// The sequence counter is assigned once at BBSnapshot init and
        /// never repeats within a process lifetime.
        let snapshotSeq: UInt64
        let hoveredLinkID: UInt16
        /// Flattened selection identity. 0 mode tag means "no selection"; 1-4
        /// are the four Selection.Mode variants. Separate fields for
        /// anchor/cursor line/col avoid the bit-packing collision risk of
        /// squeezing four values into a single UInt64 with overlapping bit
        /// ranges (two different selections could coincide on the packed
        /// result, which would silently drop a selection-change repaint).
        let selMode: UInt8
        let selALine: Int32
        let selBLine: Int32
        let selACol: Int32
        let selBCol: Int32
        let focused: Bool
        let cursorRow: Int32
        let cursorCol: Int32
        let cursorShape: UInt8
        let cursorVisible: Bool
        let displayOffset: UInt16
        let topInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>     // Equatable; avoids collision risk
        let cursorColor: SIMD4<Float>
        let blinkSkip: Bool
    }
    private var lastFrameKey: FrameKey?

    /// Strict subset of FrameKey fields that decide whether a prior frame's
    /// per-row cache is still visually correct: everything in FrameKey
    /// EXCEPT `snapshotSeq`, `cursorRow`, and `cursorCol`. Snapshot
    /// sequence changing is the normal "new content" path; cursor movement
    /// is covered by alacritty's damage tracking (it damages both the old
    /// and new cursor cells). A mismatch on any other field invalidates
    /// the whole cache and forces a full rebuild — selection sweeps,
    /// theme hot-swaps, display-offset changes, etc.
    private struct CacheKey: Equatable {
        let cols: Int
        let rows: Int
        let hoveredLinkID: UInt16
        let selMode: UInt8
        let selALine: Int32
        let selBLine: Int32
        let selACol: Int32
        let selBCol: Int32
        let focused: Bool
        /// Effective cursor shape: user override if set, else the snapshot's
        /// DECSCUSR shape. `setCursorShapeOverride` also invalidates
        /// `lastCacheKey` directly, so pinning a shape that happens to equal
        /// the current snapshot shape still repaints exactly once.
        let cursorShape: UInt8
        let cursorVisible: Bool
        let displayOffset: UInt16
        let topInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>
        let cursorColor: SIMD4<Float>
        let blinkSkip: Bool
    }
    private var lastCacheKey: CacheKey?

    /// Per-row instance cache. Index i holds the CellInstances emitted by
    /// buildRowInstances for visible row i under the current CacheKey.
    /// Reused across frames when CacheKey is stable; only damaged rows
    /// (from `BBSnapshot.damagedRows`) are rebuilt. Flattened into the
    /// GPU instance buffer each frame — a ~1 MB memcpy that costs far
    /// less than iterating 16 000 cells.
    private var rowInstanceCache: [[CellInstance]] = []

    /// Kill switch for the dirty-rows fast path. Set `BB_NO_DIRTY_ROWS=1`
    /// and restart to force a full rebuild every frame — useful when
    /// debugging a "some rows look stale" artifact to confirm whether
    /// the cache is responsible. Evaluated once per renderer.
    private let dirtyRowsDisabled: Bool = {
        guard let cstr = getenv("BB_NO_DIRTY_ROWS") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    /// Runtime escape hatch. Set the env var `BB_NO_FRAME_SKIP=1` and
    /// restart to disable the skip path entirely — every draw(in:) call
    /// runs the full encode + present. Useful when a user reports a
    /// redraw artifact ("looks weird after closing popup X") and we
    /// want to A/B test whether frame-skip is responsible. Evaluated
    /// once per renderer via `getenv` — changes require an app restart.
    private let frameSkipDisabled: Bool = {
        guard let cstr = getenv("BB_NO_FRAME_SKIP") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    public func setCursorBlinkEnabled(_ enabled: Bool) {
        if enabled != cursorBlinkEnabled {
            cursorBlinkEnabled = enabled
            blinkPhaseStart = CACurrentMediaTime()
            // Reset the blink phase → visible cursor on the next frame
            // regardless of where in the cycle we were. Clearing the skip
            // cache forces that next frame to actually encode.
            lastFrameKey = nil
        }
    }

    /// User-pinned cursor shape. `nil` → follow the snapshot's DECSCUSR
    /// value (default behaviour). A non-nil value overrides the shape the
    /// shell most recently set, so users who want a bar cursor regardless
    /// of `\e[2 q'` / `\e[0 q'` get it.
    ///
    /// Cache invalidation runs through the frame-key / cache-key
    /// substitution in `draw(in:)`: changing the override mutates
    /// `effectiveShape`, which flows into both keys and forces a rebuild.
    /// We also null the last-keys here so the override lands on the very
    /// next frame even if the snapshot is otherwise identical.
    private var cursorShapeOverride: UInt8? = nil

    public func setCursorShapeOverride(_ shape: UInt8?) {
        if shape != cursorShapeOverride {
            cursorShapeOverride = shape
            lastFrameKey = nil
            lastCacheKey = nil
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

    /// Replace the accent colour used for link-hover underlines. Themes
    /// that ship an accent override can plumb it through here; otherwise
    /// the default (controlAccentColor-equivalent sRGB blue) applies.
    public func setAccentColor(rgba: SIMD4<Float>) {
        accentColor = rgba
    }

    /// Set the OSC 8 link id currently under the pointer. The next frame
    /// highlights every cell whose `link_id` matches. Passing 0 clears the
    /// highlight.
    public func setHoveredLinkID(_ id: UInt16) {
        hoveredLinkID = id
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
        let bytes = startCap * MemoryLayout<CellInstance>.stride
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(3)
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: [.storageModeShared]) else {
                return nil
            }
            buffers.append(b)
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pso
        self.cursorPipelineState = cursorPSO
        self.atlas = atlas
        self.metrics = metrics
        self.instanceBuffers = buffers
        self.instanceCapacities = [startCap, startCap, startCap]
        // Warm ASCII + box-drawing into the atlas before the first draw so
        // no user keystroke pays for the CTLineCreate path on the hot
        // first-paint. Safe: this is a plain call into `lookupOrInsert`,
        // which is idempotent.
        atlas.prewarmCommonGlyphs()
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
        // The skip-cache + per-row cache are read/written from `render(in:)`
        // on the main thread; any mutation here must match that contract or
        // a concurrent render would see half-updated state. Enforce it —
        // comments elsewhere in the file claim main-thread but nothing was
        // asserting it.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let a = GlyphAtlas(device: device, metrics: newMetrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return false
        }
        self.metrics = newMetrics
        self.atlas = a
        // Re-warm the new atlas so the post-resize first repaint doesn't
        // pay for CoreText rasterisation of every visible character.
        a.prewarmCommonGlyphs()
        // A new atlas points to different texture contents; the skip
        // cache is now stale. Force the next render to encode and present
        // even if every FrameKey field matches the previous frame.
        self.lastFrameKey = nil
        self.lastCacheKey = nil
        self.rowInstanceCache = []
        return true
    }

    /// Clear the frame-skip cache. Call after any mutation that changes
    /// what pixels the GPU would produce given the same FrameKey —
    /// currently only the atlas reconfigure and blink-phase reset hit this.
    /// Left `public` so callers outside the renderer (e.g. a future theme
    /// hot-swap that only mutates the palette) can force a repaint.
    public func invalidate() {
        // Same main-thread contract as `reconfigure` — see note there.
        dispatchPrecondition(condition: .onQueue(.main))
        self.lastFrameKey = nil
        self.lastCacheKey = nil
        self.rowInstanceCache = []
    }

    /// Rebuild instances for a single visible row into an output Vec,
    /// consulting snapshot cells, selection, hover, and cursor-inversion
    /// state. Pure — does not touch GPU buffers or cache state. Called by
    /// `buildInstances` for every row on a full rebuild, or only for the
    /// damaged rows on a partial rebuild.
    ///
    /// Returns a `[CellInstance]` because rows emit a variable count of
    /// instances (blank cells contribute nothing; wide-glyph rows emit
    /// fewer than cols; selection/link-hover may push to 1-per-cell). The
    /// caller concatenates these into the GPU buffer each frame.
    private func buildRowInstances(
        snapshot: BBSnapshot,
        row: Int,
        isSelected: (Int32, Int) -> Bool,
        blockCursorCell: (row: Int, col: Int)?
    ) -> [CellInstance] {
        let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)
        let cellsPtr = snapshot.cellsPointer
        let cols = snapshot.cols
        let hoveredID = hoveredLinkID
        // Upper bound: every cell emits at most one instance. Reserve so
        // the common case avoids growing the Vec.
        var out: [CellInstance] = []
        out.reserveCapacity(cols)

        for col in 0..<cols {
            let idx = row * cols + col
            // `cellsPtr` is a raw pointer; reading past `cellCount` would
            // be UB, not a trap. Same invariant alacritty guarantees but
            // re-checked here so a buggy snapshot can't cascade.
            if idx >= snapshot.cellCount { break }
            let cell = cellsPtr[idx]
            let scalar = cell.ch
            var fg = Self.rgbToSIMD(cell.fg)
            var bg = Self.rgbToSIMD(cell.bg)
            let attrs: SIMD4<UInt32> = {
                var flags: UInt32 = 0
                if hoveredID != 0 && cell.link_id == hoveredID {
                    flags |= CellAttributeMask.linkHover.rawValue
                }
                // Translate cell_flags bits that the shader needs to
                // render into our flat renderer-side bitset. Cell flags
                // live in Rust-stable constants (BBCore bridging header);
                // mapping here keeps the shader ignorant of the Rust
                // layout so a future cell_flags reshuffle stays local.
                let cf = cell.flags
                if (cf & UInt16(STRIKE)) != 0 {
                    flags |= CellAttributeMask.strike.rawValue
                }
                if (cf & UInt16(UNDERLINE)) != 0 {
                    flags |= CellAttributeMask.underline.rawValue
                }
                if (cf & UInt16(UNDERLINE_DOUBLE)) != 0 {
                    flags |= CellAttributeMask.underlineDouble.rawValue
                }
                if (cf & UInt16(UNDERCURL)) != 0 {
                    flags |= CellAttributeMask.undercurl.rawValue
                }
                if (cf & UInt16(UNDERLINE_DOTTED)) != 0 {
                    flags |= CellAttributeMask.underlineDotted.rawValue
                }
                if (cf & UInt16(UNDERLINE_DASHED)) != 0 {
                    flags |= CellAttributeMask.underlineDashed.rawValue
                }
                // Pack CSI 58 underline colour into attrs.z. The shader
                // treats UNDERLINE_COLOR_UNSET as "fall back to fg",
                // so the cheapest path is to forward the u32 as-is.
                return SIMD4<UInt32>(flags, 0, cell.underline_color, 0)
            }()
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

            // WIDE_CHAR_SPACER / LEADING_WIDE_CHAR_SPACER sit to the right
            // of (or on the wrapped-leading col before) a wide glyph. The
            // wide glyph's 2x quad already covers this column, so any
            // draw here would overpaint its right half. Skip unless the
            // selection highlight needs a bg quad — in that case the
            // highlight must span both halves of the wide cell.
            let isSpacer = (cell.flags &
                (UInt16(WIDE_CHAR_SPACER) | UInt16(LEADING_WIDE_CHAR_SPACER))) != 0
            if isSpacer {
                if selected || effectiveHasBg || attrs.x != 0 {
                    out.append(CellInstance(
                        cellPosPx: SIMD2<Float>(xPx, yPx),
                        quadSizePx: SIMD2<Float>(cellW, cellH),
                        uvOrigin: .zero,
                        uvSize: .zero,
                        fgColor: fg,
                        bgColor: effectiveBg,
                        attrs: attrs
                    ))
                }
                continue
            }

            // WIDE_CHAR cells carry a CJK / wide-emoji glyph that logically
            // spans two cells. The atlas rasterises them into a 2x-wide
            // slot and reports a doubled uvSize.x; we draw a 2x-wide quad
            // so the full glyph lands on screen.
            let isWide = (cell.flags & UInt16(WIDE_CHAR)) != 0
            let quadW = isWide ? cellW * 2.0 : cellW
            let quadSize = SIMD2<Float>(quadW, cellH)

            // Render cell if it has a glyph OR a non-default background.
            if scalar != 0 && scalar != 0x20 /* space */ {
                let glyphStyle = GlyphAtlas.Style(
                    bold: (cell.flags & UInt16(BOLD)) != 0,
                    italic: (cell.flags & UInt16(ITALIC)) != 0
                )
                if let us = Unicode.Scalar(scalar),
                   let entry = atlas.lookupOrInsert(
                       scalar: us, wide: isWide, style: glyphStyle) {
                    out.append(CellInstance(
                        cellPosPx: SIMD2<Float>(xPx, yPx),
                        quadSizePx: quadSize,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        fgColor: fg,
                        bgColor: effectiveBg,
                        attrs: attrs
                    ))
                }
            } else if effectiveHasBg || attrs.x != 0 {
                // Space with colored background (status lines, vim highlights),
                // inside an active selection, or carrying an accent
                // attribute (link hover). Draw a full-cell quad with
                // zero coverage so the shader's bg/accent paths still fire.
                out.append(CellInstance(
                    cellPosPx: SIMD2<Float>(xPx, yPx),
                    quadSizePx: quadSize,
                    uvOrigin: .zero,
                    uvSize: .zero,
                    fgColor: fg,
                    bgColor: effectiveBg,
                    attrs: attrs
                ))
            }
        }
        return out
    }

    /// Orchestrates per-row rebuild + GPU buffer flatten using the
    /// `rowInstanceCache`. Either rebuilds every row (full path) or only
    /// the rows alacritty's damage iterator flagged as changed (partial
    /// path). Returns the total instance count the encoder should draw.
    @discardableResult
    private func buildInstances(
        snapshot: BBSnapshot,
        isSelected: (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil,
        partialRowsOnly: Set<Int>? = nil
    ) -> Int {
        let rows = snapshot.rows
        let cols = snapshot.cols
        let needed = cols * rows
        // Defensive bound — see original comment on the single-loop
        // version. Same invariant, same bail-out on violation.
        guard snapshot.cellCount >= needed else { return 0 }

        // Re-size the per-row cache when grid dims changed. Shrinking is
        // handled by assignment (old entries over the new row count are
        // dropped). Growing initializes new rows to empty so the partial
        // path — which assumes the cache is indexable for every visible
        // row — stays sound.
        if rowInstanceCache.count != rows {
            rowInstanceCache = Array(repeating: [], count: rows)
        }

        if let damaged = partialRowsOnly {
            // Partial rebuild: only the rows alacritty says changed.
            // Iterate a sorted copy so we never hit the same row twice
            // if a future source deduplicates imperfectly.
            for row in damaged where row >= 0 && row < rows {
                rowInstanceCache[row] = buildRowInstances(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell
                )
            }
        } else {
            // Full rebuild — cache key changed, first frame, or damage
            // exceeded the partial threshold.
            for row in 0..<rows {
                rowInstanceCache[row] = buildRowInstances(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell
                )
            }
        }

        // Flatten into the current-slot GPU buffer. Even the partial path
        // copies every row — the CPU savings come from skipping the
        // per-cell inner work on unchanged rows, not from skipping the
        // memcpy (which is tiny: ~1 MB at 80-byte stride × 16k cells).
        let total = rowInstanceCache.reduce(0) { $0 + $1.count }
        let slot = currentSlot
        if total > instanceCapacities[slot] {
            let newCap = max(total, instanceCapacities[slot] * 2)
            if let newBuf = device.makeBuffer(
                length: newCap * MemoryLayout<CellInstance>.stride,
                options: [.storageModeShared]
            ) {
                instanceBuffers[slot] = newBuf
                instanceCapacities[slot] = newCap
            } else {
                // Out-of-GPU-memory while growing — skip frame. Next
                // repaint will retry.
                return 0
            }
        }

        let ptr = instanceBuffers[slot].contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        for row in 0..<rows {
            let rowInsts = rowInstanceCache[row]
            if rowInsts.isEmpty { continue }
            rowInsts.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                // memcpy — safe because CellInstance is POD and the GPU
                // buffer is non-overlapping with the Swift Array storage.
                ptr.advanced(by: count).initialize(from: base, count: src.count)
                count += src.count
            }
        }
        return count
    }

    /// Extract selection endpoints into fields that feed `FrameKey`
    /// directly. Previously a `packSelection -> UInt64` helper was used,
    /// but its bit ranges overlapped (`aLine << 32` and `bLine << 16`
    /// shared bits 32-47; `aCol << 8` and `bCol` shared bits 8-15),
    /// which let two different selections produce the same packed token
    /// and get silently coalesced by frame-skip. Use five separate
    /// fields — zero-filled for the "no selection" case — so FrameKey's
    /// synthesised Equatable gives an exact match.
    private static func selectionFields(
        _ sel: Selection?
    ) -> (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32) {
        guard let s = sel else { return (0, 0, 0, 0, 0) }
        let (a, b) = s.normalized
        let modeTag: UInt8 = {
            switch s.mode {
            case .character:   return 1
            case .word:        return 2
            case .line:        return 3
            case .rectangular: return 4
            }
        }()
        return (
            mode: modeTag,
            aLine: a.line,
            bLine: b.line,
            aCol: Int32(clamping: a.col),
            bCol: Int32(clamping: b.col)
        )
    }

    private static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
        let r = Float((rgb >> 16) & 0xFF) / 255.0
        let g = Float((rgb >> 8) & 0xFF) / 255.0
        let b = Float(rgb & 0xFF) / 255.0
        return SIMD4<Float>(r, g, b, 1.0)
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool, selection: Selection? = nil) {
        // Compute the current frame's visual-state key BEFORE reaching for
        // currentDrawable. Acquiring a drawable is expensive (blocks on
        // the pool under contention); if nothing changed we shouldn't even
        // touch it. Note: blink state is computed here too because it
        // depends on CACurrentMediaTime.
        let blinkSkipNow: Bool = {
            guard cursorBlinkEnabled, focused, let s = snapshot, s.cursorVisible else {
                return false
            }
            let elapsed = CACurrentMediaTime() - blinkPhaseStart
            let phase = elapsed.truncatingRemainder(dividingBy: 1.06)
            return phase >= 0.53
        }()
        let selFields = Self.selectionFields(selection)
        let frameKey = FrameKey(
            snapshotSeq: snapshot?.sequenceID ?? 0,
            hoveredLinkID: hoveredLinkID,
            selMode: selFields.mode,
            selALine: selFields.aLine,
            selBLine: selFields.bLine,
            selACol: selFields.aCol,
            selBCol: selFields.bCol,
            focused: focused,
            cursorRow: Int32(snapshot?.cursorRow ?? -1),
            cursorCol: Int32(snapshot?.cursorCol ?? -1),
            cursorShape: cursorShapeOverride ?? UInt8(snapshot?.cursorShape ?? 3),
            cursorVisible: snapshot?.cursorVisible ?? false,
            displayOffset: UInt16(snapshot?.displayOffset ?? 0),
            topInsetPoints: topInsetPoints,
            defaultBgRgb: defaultBgRgb,
            backgroundOpacity: backgroundOpacity,
            keepBgOpaque: keepBgOpaque,
            accentColor: accentColor,
            cursorColor: cursorColor,
            blinkSkip: blinkSkipNow
        )
        if !frameSkipDisabled, frameKey == lastFrameKey {
            // Nothing that affects pixels has changed since the last
            // presented frame. Skip the whole pipeline — no CPU instance
            // rebuild, no GPU encode, no drawable acquisition. The
            // compositor keeps displaying the previously-presented frame.
            // Semaphore NOT touched on the skip path: we never claimed
            // a slot, so we don't signal back.
            return
        }
        lastFrameKey = frameKey

        // Lock a slot before we write to its instance buffer. If all three
        // slots are in flight on the GPU, wait — the CPU-side write below
        // would otherwise race the GPU's vertex-fetch on a .storageModeShared
        // buffer. Advance frameIndex so the next frame picks the next slot.
        inflightSemaphore.wait()
        currentSlot = frameIndex
        frameIndex = (frameIndex + 1) % 3
        let slot = currentSlot

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            // Release the slot we just claimed — we're abandoning this frame
            // without encoding, so the GPU never reads the buffer.
            inflightSemaphore.signal()
            return
        }

        // Signal the slot free when the GPU finishes reading it. Must be
        // registered before `commit()` so there's no race with an immediate
        // GPU-side completion.
        //
        // Also inspect `status`/`error` so GPU faults (device lost, page
        // fault, shader trap) surface in the unified log instead of
        // silently blanking the window. `privacy: .public` is load-bearing
        // for readability — see `feedback_nslog_private_format`.
        buffer.addCompletedHandler { [weak self] cb in
            if cb.status == .error {
                if let err = cb.error {
                    Self.logger.error("command buffer failed: \(String(describing: err), privacy: .public)")
                } else {
                    Self.logger.error("command buffer ended with .error status (no NSError)")
                }
            }
            self?.inflightSemaphore.signal()
        }

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
            // User's pinned shape (`cursorShapeOverride`) wins over the
            // snapshot's DECSCUSR shape. When nil, follow the shell. Used
            // everywhere below — `useCellInvertedCursor`, the "hidden"
            // short-circuit, and the cache key.
            let effectiveShape: UInt8 = cursorShapeOverride ?? UInt8(snap.cursorShape)
            let shape = UInt32(effectiveShape)
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
            // blinkSkip already computed for the frame-key check above.
            // Reuse that value so we never flicker from a phase transition
            // that happens between the key computation and the draw.
            let blinkSkip = blinkSkipNow
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

            // Decide whether to take the partial-rebuild path. The cache
            // is "compatible" when every visible-state input to the row
            // builder matches the prior frame (CacheKey equality). When
            // it matches AND alacritty reports partial damage with a
            // manageable count, we only rebuild the damaged rows — the
            // rest are copied from rowInstanceCache unchanged.
            //
            // The row-count threshold (rows / 2) guards against the case
            // where damage covers most of the screen anyway: the
            // per-row-skip overhead would exceed the savings. Above the
            // threshold, just rebuild everything.
            let newCacheKey = CacheKey(
                cols: snap.cols,
                rows: snap.rows,
                hoveredLinkID: hoveredLinkID,
                selMode: selFields.mode,
                selALine: selFields.aLine,
                selBLine: selFields.bLine,
                selACol: selFields.aCol,
                selBCol: selFields.bCol,
                focused: focused,
                cursorShape: effectiveShape,
                cursorVisible: snap.cursorVisible,
                displayOffset: UInt16(snap.displayOffset),
                topInsetPoints: topInsetPoints,
                defaultBgRgb: defaultBgRgb,
                backgroundOpacity: backgroundOpacity,
                keepBgOpaque: keepBgOpaque,
                accentColor: accentColor,
                cursorColor: cursorColor,
                blinkSkip: blinkSkipNow
            )
            let cacheCompatible = !dirtyRowsDisabled
                && lastCacheKey == newCacheKey
                && rowInstanceCache.count == snap.rows

            let partialRows: Set<Int>? = {
                guard cacheCompatible else { return nil }
                guard !snap.damageIsFull else { return nil }
                let damaged = snap.damagedRows
                if damaged.isEmpty || damaged.count >= (snap.rows + 1) / 2 {
                    return nil
                }
                return Set(damaged)
            }()

            let instanceCount = buildInstances(
                snapshot: snap,
                isSelected: isSelected,
                blockCursorCell: blockCursorCell,
                partialRowsOnly: partialRows
            )
            lastCacheKey = newCacheKey
            if instanceCount > 0 {
                var uniforms = FrameUniforms(
                    viewportPx: viewportPoints,
                    cellSizePx: cellSizePoints,
                    accentColor: accentColor
                )
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(instanceBuffers[slot], offset: 0, index: 0)
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

    deinit {
        // DispatchSemaphore's contract: "all associated waits must be
        // balanced before deallocation, or the program traps." If a window
        // closes while frames are still in flight, the GPU completion
        // handlers haven't run yet, so our inflightSemaphore has
        // outstanding waits without matching signals. Deallocating it in
        // that state aborts the process.
        //
        // The fix is simple: commit an empty command buffer on our queue
        // and `waitUntilCompleted`. The empty buffer orders behind any
        // real frames already committed, and waiting for it forces every
        // prior completion handler to run — which signals the semaphore
        // back to balance. Then deinit of the semaphore is safe.
        //
        // Called on whatever thread releases the last strong ref (usually
        // main, but not guaranteed). `waitUntilCompleted` is documented
        // safe from any thread; no additional synchronisation needed.
        if let drain = commandQueue.makeCommandBuffer() {
            drain.commit()
            drain.waitUntilCompleted()
        }
        #if DEBUG
        Self.logger.debug("MetalRenderer deinit — in-flight frames drained")
        #endif
    }
}

struct FrameUniforms {
    var viewportPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    /// sRGB RGBA colour used by the cell fragment shader for accent-
    /// attribute underlines. Task 7 uses this for OSC 8 hover highlight.
    /// Plumbed from the theme accent; defaults to a controlAccentColor-like
    /// blue so the renderer has something usable even before the theme
    /// installs one.
    var accentColor: SIMD4<Float>
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
