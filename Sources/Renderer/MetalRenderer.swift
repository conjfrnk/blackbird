import Metal
import MetalKit
import AppKit
import BBCore
import os

public final class MetalRenderer {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "renderer")

    static let atlasCapacity = 4096

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    /// The focused block cursor renders via cell inversion, not through `cursorPipelineState`.
    private struct Pipelines {
        let pipelineState: MTLRenderPipelineState
        let cursorPipelineState: MTLRenderPipelineState
    }
    private let pipelines: Pipelines
    /// Swap only through `reconfigure(metrics:scale:)`, which invalidates the frame / row caches in
    /// lockstep: a fresh atlas restarts `generation` at 0 and could match cached pre-swap UVs.
    public private(set) var atlas: GlyphAtlas
    /// Written only by `reconfigure(metrics:scale:)`, which bumps `metricsGeneration` in lockstep.
    public private(set) var metrics: CellMetrics
    /// Bumped on every mutation of `metrics`; folded into both `FrameKey` and `CacheKey`.
    public private(set) var metricsGeneration: UInt64 = 0

    /// Triple-buffered: a command buffer holds its slot's buffer until the GPU is done reading, so
    /// the CPU never writes a `.storageModeShared` buffer mid-read. Capacity is tracked per slot.
    private struct TripleBufferRing {
        var instanceBuffers: [MTLBuffer]
        var instanceCapacities: [Int]
        var frameIndex: Int = 0
        /// The slot the current `render(in:)` call has locked. Main thread only.
        var currentSlot: Int = 0
        /// One token per buffer: `render(in:)` waits, the GPU completion handler signals.
        let inflightSemaphore = DispatchSemaphore(value: 3)
    }
    private var ring: TripleBufferRing
    private static let instanceCapacityHardCap = 4 * 1024 * 1024

    private struct ThemeColors {
        var cursorColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        /// Defaults to an sRGB approximation of macOS's `controlAccentColor`.
        var accentColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
        /// A cell whose resolved bg equals this draws no bg quad, so the transparent clearColor
        /// shows through. `0xFFFFFFFF` means "no theme bg configured yet".
        var defaultBgRgb: UInt32 = 0xFFFFFFFF
        var backgroundOpacity: Float = 1.0
        var keepBgOpaque: Bool = true
        var selectionColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
        var selectionForeground: SIMD4<Float> = SIMD4<Float>(0.10, 0.10, 0.12, 1.0)
    }
    private var themeColors = ThemeColors()

    /// OSC 8 link id currently under the pointer. Zero means "no hovered link".
    private var hoveredLinkID: UInt16 = 0

    /// ⌘-held regex URL under the pointer: a buffer line (not screen row — survives scrolling) and
    /// an inclusive column range. `startCol < 0` is the sentinel for "no range".
    private struct CmdHover {
        var bufferLine: Int32 = 0
        var startCol: Int32 = -1
        var endCol: Int32 = -1
    }
    private var cmdHover = CmdHover()

    /// `topInsetPoints` keeps text out of the titlebar region under `.fullSizeContentView`.
    private struct Insets {
        var topInsetPoints: Float = 0.0
        var leftInsetPoints: Float = 0.0
    }
    private var insets = Insets()

    public func setTopInsetPoints(_ points: Float) { insets.topInsetPoints = points }

    public func setLeftInsetPoints(_ points: Float) { insets.leftInsetPoints = points }

    #if DEBUG
    public func leftInsetPointsForTesting() -> Float { insets.leftInsetPoints }
    #endif

    private struct CursorState {
        var blinkEnabled: Bool = false
        var blinkPhaseStart: CFTimeInterval = 0
        var lastCursorRow: Int32 = -1
        var lastCursorCol: Int32 = -1
        /// `nil` → follow the snapshot's DECSCUSR value.
        var shapeOverride: UInt8? = nil
    }
    private var cursorState = CursorState()

    /// Blink phase of the last frame whose rows were built; a flip rebuilds only the cursor's row.
    private var lastBuiltBlinkSkip = false

    /// Pixel-affecting inputs shared by `FrameKey` and `CacheKey`; a missing input misses redraws.
    private struct VisualState: Equatable {
        let hoveredLinkID: UInt16
        /// 0 means "no selection"; 1-4 are the four Selection.Mode variants.
        let selMode: UInt8
        let selALine: Int32
        let selBLine: Int32
        let selACol: Int32
        let selBCol: Int32
        let focused: Bool
        let cursorShape: UInt8
        let cursorVisible: Bool
        /// UInt32: scrollback runs well past UInt16.max lines.
        let displayOffset: UInt32
        let topInsetPoints: Float
        let leftInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>
        let selectionColor: SIMD4<Float>
        let selectionForeground: SIMD4<Float>
        let cursorColor: SIMD4<Float>
        let cmdHoverBufferLine: Int32
        let cmdHoverStartCol: Int32
        let cmdHoverEndCol: Int32
        let metricsGeneration: UInt64
        /// A saturation flush rewrites atlas slots that cached `CellInstance` UVs point at; the
        /// generation bump forces a rebuild after any flush.
        let atlasGeneration: UInt64
    }

    /// Every input that affects pixels; a `render()` whose key equals the last encoded one skips.
    private struct FrameKey: Equatable {
        /// `BBSnapshot` sequence id (0 when nil). NOT the handle pointer: the allocator can reuse
        /// an address after a snapshot is released.
        let snapshotSeq: UInt64
        let cursorRow: Int32
        let cursorCol: Int32
        /// The view's bounds in points, which feed the uniform the shader divides by. FrameKey
        /// ONLY: cell instances are in points, so the per-row cache is viewport-independent.
        let viewportWidth: Float
        let viewportHeight: Float
        /// FrameKey ONLY: a flip changes only the cursor's row; it must not drop the row cache.
        let blinkSkip: Bool
        let visual: VisualState
    }
    private struct SkipCache {
        /// Assigned only on a committed encode; `nil` forces the next render to encode.
        var lastFrameKey: FrameKey?
        var lastCacheKey: CacheKey?
        /// A `sequenceID` jump of more than 1 means intermediate snapshots were coalesced away
        /// along with their damage sets, so a partial rebuild would leave stale rows.
        var lastRenderedSnapshotSeq: UInt64 = 0
        /// Index i holds the CellInstances for visible row i under the current CacheKey.
        var rowInstanceCache: [[CellInstance]] = []
        /// `true` when the most recent `render` returned without presenting a drawable.
        var didFrameSkipLastRender: Bool = false
    }
    private var skipCache = SkipCache()

    /// Not thread-safe; readers must observe it from the same queue as the `render` call (main).
    public var didFrameSkipLastRender: Bool { skipCache.didFrameSkipLastRender }

    #if DEBUG
    public var _testForceFrameKeyAdvanceOnFailedDrawable: Bool = false
    #endif

    /// FrameKey minus `snapshotSeq`, `cursorRow`, `cursorCol`, blink and the viewport: new content
    /// and cursor movement arrive as damage. A mismatch on any other field forces a full rebuild.
    private struct CacheKey: Equatable {
        let cols: Int
        let rows: Int
        let visual: VisualState
    }

    private struct DebugToggles {
        let dirtyRowsDisabled: Bool
        let frameSkipDisabled: Bool

        static func fromEnvironment() -> DebugToggles {
            DebugToggles(
                dirtyRowsDisabled: Self.envFlagSet("BB_NO_DIRTY_ROWS"),
                frameSkipDisabled: Self.envFlagSet("BB_NO_FRAME_SKIP")
            )
        }

        private static func envFlagSet(_ name: String) -> Bool {
            guard let cstr = getenv(name) else { return false }
            let raw = String(cString: cstr)
            return !raw.isEmpty && raw != "0"
        }
    }
    private let debugToggles = DebugToggles.fromEnvironment()

    public func setCursorBlinkEnabled(_ enabled: Bool) {
        if enabled != cursorState.blinkEnabled {
            cursorState.blinkEnabled = enabled
            cursorState.blinkPhaseStart = CACurrentMediaTime()
            skipCache.lastFrameKey = nil
        }
    }

    public func setCursorShapeOverride(_ shape: UInt8?) {
        if shape != cursorState.shapeOverride {
            cursorState.shapeOverride = shape
            skipCache.lastFrameKey = nil
            skipCache.lastCacheKey = nil
        }
    }

    public func setDefaultBgRgb(_ rgb: UInt32) { themeColors.defaultBgRgb = rgb }

    public func setSelectionColors(highlightRgb: UInt32, foregroundRgb: UInt32) {
        var h = CellInstanceBuilder.rgbToSIMD(highlightRgb)
        h.w = 1.0
        var f = CellInstanceBuilder.rgbToSIMD(foregroundRgb)
        f.w = 1.0
        themeColors.selectionColor = h
        themeColors.selectionForeground = f
    }

    public func setBackgroundOpacity(_ opacity: Float, keepBgOpaque: Bool) {
        self.themeColors.backgroundOpacity = opacity
        self.themeColors.keepBgOpaque = keepBgOpaque
    }

    public func setCursorColor(rgb: UInt32) {
        let r = Float((rgb >> 16) & 0xFF) * CellInstanceBuilder.inv255
        let g = Float((rgb >> 8)  & 0xFF) * CellInstanceBuilder.inv255
        let b = Float(rgb & 0xFF) * CellInstanceBuilder.inv255
        // The cursor pipeline has no blending (opaque overwrite), so the colour must be opaque.
        let color = SIMD4<Float>(r, g, b, 1.0)
        precondition(color.w == 1.0, "cursorColor must be opaque (cursor pipeline has no blending — see audit L14)")
        themeColors.cursorColor = color
    }

    public func setAccentColor(rgba: SIMD4<Float>) {
        themeColors.accentColor = rgba
    }

    public func setHoveredLinkID(_ id: UInt16) {
        hoveredLinkID = id
    }

    /// Pass `startCol < 0` to clear. Callers must force a redraw themselves (`needsDisplay = true`
    /// on the MTKView): this invalidates the per-row cache but does not schedule a repaint.
    public func setCmdHoverRange(bufferLine: Int32, startCol: Int32, endCol: Int32) {
        if cmdHover.bufferLine == bufferLine
            && cmdHover.startCol == startCol
            && cmdHover.endCol == endCol {
            return
        }
        cmdHover.bufferLine = bufferLine
        cmdHover.startCol = startCol
        cmdHover.endCol = endCol
        skipCache.lastCacheKey = nil
    }

    public init?(device: MTLDevice, metrics: CellMetrics, scale: CGFloat = 2.0) {
        // Pin the layout contract with the shader first: drift must crash, not scramble UVs.
        _pinCellInstanceLayout()
        _pinCursorUniformsLayout()
        guard let queue = device.makeCommandQueue() else {
            Self.logger.error("MetalRenderer.init: device.makeCommandQueue() returned nil")
            return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            Self.logger.error("MetalRenderer.init: device.makeDefaultLibrary() returned nil")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertex_cell"),
              let fragmentFn = library.makeFunction(name: "fragment_cell") else {
            Self.logger.error("MetalRenderer.init: cell shader makeFunction(vertex_cell/fragment_cell) returned nil")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        // `.bgra8Unorm` (NOT `_srgb`): every colour is uploaded sRGB-encoded and blended in that
        // space; the CAMetalLayer colorspace is pinned to sRGB on the window side.
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        // PREMULTIPLIED source (see Shaders.metal `fragment_cell`): the RGB factor is ONE, not
        // SRC_ALPHA, which would apply glyph coverage twice on default-bg cells.
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pso: MTLRenderPipelineState
        do {
            pso = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            // Log the NSError fields explicitly: `userInfo` carries the shader-compiler diagnostic.
            let ns = error as NSError
            Self.logger.error("cell render pipeline state creation failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            return nil
        }

        guard let cursorVertex = library.makeFunction(name: "vertex_cursor"),
              let cursorFragment = library.makeFunction(name: "fragment_cursor") else {
            Self.logger.error("MetalRenderer.init: cursor shader makeFunction(vertex_cursor/fragment_cursor) returned nil")
            return nil
        }
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = cursorVertex
        cursorDesc.fragmentFunction = cursorFragment
        cursorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let cursorPSO: MTLRenderPipelineState
        do {
            cursorPSO = try device.makeRenderPipelineState(descriptor: cursorDesc)
        } catch {
            let ns = error as NSError
            Self.logger.error("cursor render pipeline state creation failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            return nil
        }

        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            Self.logger.error("MetalRenderer.init: GlyphAtlas init failed (capacityGlyphs=\(Self.atlasCapacity, privacy: .public) scale=\(Double(scale), privacy: .public))")
            return nil
        }

        let startCap = 200 * 80
        let bytes = startCap * MemoryLayout<CellInstance>.stride
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(3)
        for i in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: [.storageModeShared]) else {
                Self.logger.error("MetalRenderer.init: device.makeBuffer(length=\(bytes, privacy: .public)) returned nil for instance buffer \(i, privacy: .public) of 3")
                return nil
            }
            buffers.append(b)
        }

        self.device = device
        self.commandQueue = queue
        self.pipelines = Pipelines(pipelineState: pso, cursorPipelineState: cursorPSO)
        self.atlas = atlas
        self.metrics = metrics
        self.metricsGeneration = 1
        self.ring = TripleBufferRing(
            instanceBuffers: buffers,
            instanceCapacities: [startCap, startCap, startCap]
        )
        // A saturation flush rewrites slot 0 of the shared-storage atlas textures; this drain
        // completes every prior frame's command buffer so the GPU is no longer sampling that slot.
        atlas.flushBarrier = { [weak self] in
            guard let self, let drain = self.commandQueue.makeCommandBuffer() else { return }
            drain.commit()
            drain.waitUntilCompleted()
        }
        let t0 = CACurrentMediaTime()
        atlas.prewarmCommonGlyphs()
        if StartupTelemetry.isEnabled {
            let dt = (CACurrentMediaTime() - t0) * 1000
            StartupTelemetry.logger.log(
                "atlas prewarm \(dt, format: .fixed(precision: 1), privacy: .public)ms"
            )
        }
    }

    #if DEBUG
    /// When > 0, the next `reconfigure` fails with renderer state untouched, and this decrements.
    public var reconfigureFailuresForTests: Int = 0
    #endif

    /// Atomic: metrics only change if the new atlas built successfully; returns `false` otherwise.
    @discardableResult
    public func reconfigure(metrics newMetrics: CellMetrics, scale: CGFloat) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        #if DEBUG
        if reconfigureFailuresForTests > 0 {
            reconfigureFailuresForTests -= 1
            return false
        }
        #endif
        guard let a = GlyphAtlas(device: device, metrics: newMetrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return false
        }
        self.metrics = newMetrics
        self.metricsGeneration &+= 1
        self.atlas = a
        // The flush barrier lives on the atlas instance, so the new atlas needs its own.
        a.flushBarrier = { [weak self] in
            guard let self, let drain = self.commandQueue.makeCommandBuffer() else { return }
            drain.commit()
            drain.waitUntilCompleted()
        }
        a.prewarmCommonGlyphs()
        self.skipCache.lastFrameKey = nil
        self.skipCache.lastCacheKey = nil
        self.skipCache.rowInstanceCache = []
        // Reset so a pre-reconfigure seq cannot trip the coalesced-snapshot guard.
        self.skipCache.lastRenderedSnapshotSeq = 0
        return true
    }

    public func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        self.skipCache.lastFrameKey = nil
        self.skipCache.lastCacheKey = nil
        self.skipCache.rowInstanceCache = []
        self.skipCache.lastRenderedSnapshotSeq = 0
    }

    @discardableResult
    /// Returns the flattened instance count, or nil when the per-slot GPU buffer could not grow.
    /// 0 means "encode and present an empty frame"; nil means "abandon the encode entirely".
    private func buildInstances(
        snapshot: BBSnapshot,
        isSelected: (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil,
        partialRowsOnly: Set<Int>? = nil
    ) -> Int? {
        let rows = snapshot.rows
        let cols = snapshot.cols
        let needed = cols * rows
        guard snapshot.cellCount >= needed else { return 0 }

        // The partial path assumes the cache is indexable for every visible row.
        if skipCache.rowInstanceCache.count != rows {
            skipCache.rowInstanceCache = Array(repeating: [], count: rows)
        }

        let builder = CellInstanceBuilder(
            metrics: metrics,
            hoveredLinkID: hoveredLinkID,
            cmdHoverBufferLine: cmdHover.bufferLine,
            cmdHoverStartCol: cmdHover.startCol,
            cmdHoverEndCol: cmdHover.endCol,
            defaultBgRgb: themeColors.defaultBgRgb,
            keepBgOpaque: themeColors.keepBgOpaque,
            backgroundOpacity: themeColors.backgroundOpacity,
            cursorColor: themeColors.cursorColor,
            selectionColor: themeColors.selectionColor,
            selectionForeground: themeColors.selectionForeground,
            leftInsetPoints: insets.leftInsetPoints,
            topInsetPoints: insets.topInsetPoints,
            atlas: atlas
        )

        if let damaged = partialRowsOnly {
            for row in damaged where row >= 0 && row < rows {
                skipCache.rowInstanceCache[row].removeAll(keepingCapacity: true)
                builder.buildRow(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &skipCache.rowInstanceCache[row]
                )
            }
        } else {
            for row in 0..<rows {
                skipCache.rowInstanceCache[row].removeAll(keepingCapacity: true)
                builder.buildRow(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &skipCache.rowInstanceCache[row]
                )
            }
        }

        let total = skipCache.rowInstanceCache.reduce(0) { $0 + $1.count }
        let slot = ring.currentSlot
        if total > ring.instanceCapacities[slot] {
            let doubled = ring.instanceCapacities[slot]
                .multipliedReportingOverflow(by: 2)
            let proposed: Int
            if doubled.overflow {
                proposed = Self.instanceCapacityHardCap
            } else {
                proposed = min(doubled.partialValue, Self.instanceCapacityHardCap)
            }
            let newCap = max(total, proposed)
            if total > Self.instanceCapacityHardCap {
                Self.logger.error("instance count \(total, privacy: .public) exceeds hard cap \(Self.instanceCapacityHardCap, privacy: .public); attempting allocation anyway (workload outgrew renderer sizing — investigate grid dims / row paint logic)")
            }
            let bufBytes = newCap * MemoryLayout<CellInstance>.stride
            if let newBuf = device.makeBuffer(
                length: bufBytes,
                options: [.storageModeShared]
            ) {
                ring.instanceBuffers[slot] = newBuf
                ring.instanceCapacities[slot] = newCap
            } else {
                Self.logger.error("instance buffer grow failed: requested \(newCap, privacy: .public) instances (\(bufBytes, privacy: .public) bytes); abandoning frame")
                return nil
            }
        }

        let ptr = ring.instanceBuffers[slot].contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        for row in 0..<rows {
            let rowInsts = skipCache.rowInstanceCache[row]
            if rowInsts.isEmpty { continue }
            rowInsts.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                // Safe: CellInstance is POD and the GPU buffer does not overlap the Array storage.
                ptr.advanced(by: count).initialize(from: base, count: src.count)
                count += src.count
            }
        }
        return count
    }

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

    private static func makeSelectionPredicate(
        _ selection: Selection?
    ) -> (Int32, Int) -> Bool {
        return { line, col in
            guard let sel = selection else { return false }
            let (a, b) = sel.normalized
            switch sel.mode {
            case .rectangular:
                let lo = min(a.line, b.line), hi = max(a.line, b.line)
                let cLo = min(a.col, b.col), cHi = max(a.col, b.col)
                return line >= lo && line <= hi && col >= cLo && col <= cHi
            case .line:
                // Whole rows: the drag path keeps anchor/cursor on their original col.
                return line >= a.line && line <= b.line
            case .character, .word:
                if line < a.line || line > b.line { return false }
                if a.line == b.line { return col >= a.col && col <= b.col }
                if line == a.line { return col >= a.col }
                if line == b.line { return col <= b.col }
                return true
            }
        }
    }

    private func computeBlinkSkip(snapshot: BBSnapshot?, focused: Bool) -> Bool {
        guard cursorState.blinkEnabled, focused, let s = snapshot, s.cursorVisible else {
            return false
        }
        let elapsed = CACurrentMediaTime() - cursorState.blinkPhaseStart
        let phase = elapsed.truncatingRemainder(dividingBy: 1.06)
        return phase >= 0.53
    }

    private func makeFrameKey(
        snapshot: BBSnapshot?,
        focused: Bool,
        selFields: (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32),
        blinkSkip: Bool,
        viewportPoints: CGSize
    ) -> FrameKey {
        return FrameKey(
            snapshotSeq: snapshot?.sequenceID ?? 0,
            cursorRow: Int32(clamping: snapshot?.cursorRow ?? -1),
            cursorCol: Int32(clamping: snapshot?.cursorCol ?? -1),
            // Sanitized: a NaN would make the key unequal to itself and defeat frame-skip.
            viewportWidth: Float(viewportPoints.width.sanitizedPixel),
            viewportHeight: Float(viewportPoints.height.sanitizedPixel),
            blinkSkip: blinkSkip,
            visual: VisualState(
                hoveredLinkID: hoveredLinkID,
                selMode: selFields.mode,
                selALine: selFields.aLine,
                selBLine: selFields.bLine,
                selACol: selFields.aCol,
                selBCol: selFields.bCol,
                focused: focused,
                cursorShape: cursorState.shapeOverride ?? UInt8(clamping: snapshot?.cursorShape ?? 3),
                cursorVisible: snapshot?.cursorVisible ?? false,
                displayOffset: UInt32(clamping: snapshot?.displayOffset ?? 0),
                topInsetPoints: insets.topInsetPoints,
                leftInsetPoints: insets.leftInsetPoints,
                defaultBgRgb: themeColors.defaultBgRgb,
                backgroundOpacity: themeColors.backgroundOpacity,
                keepBgOpaque: themeColors.keepBgOpaque,
                accentColor: themeColors.accentColor,
                selectionColor: themeColors.selectionColor,
                selectionForeground: themeColors.selectionForeground,
                cursorColor: themeColors.cursorColor,
                cmdHoverBufferLine: cmdHover.bufferLine,
                cmdHoverStartCol: cmdHover.startCol,
                cmdHoverEndCol: cmdHover.endCol,
                metricsGeneration: metricsGeneration,
                atlasGeneration: atlas.generation
            )
        )
    }

    // MARK: - Triple-buffer slot lifecycle

    /// Does NOT advance the rotation turn: an aborted frame must return both its token and its
    /// turn, or a later frame could claim a slot the GPU is still reading.
    private func claimSlot() -> Int {
        ring.inflightSemaphore.wait()
        ring.currentSlot = ring.frameIndex
        return ring.currentSlot
    }

    /// For a slot claimed but never committed; the rotation turn was never consumed.
    private func releaseSlotUnused() {
        ring.inflightSemaphore.signal()
    }

    /// Consumes the rotation turn; the semaphore signal is DEFERRED to the GPU completion handler.
    private func commitSlotRotation() {
        ring.frameIndex = (ring.frameIndex + 1) % 3
    }

    /// Abort AFTER the turn was consumed: return the token and roll back to the claimed slot.
    private func rollbackSlotRotation() {
        ring.inflightSemaphore.signal()
        ring.frameIndex = ring.currentSlot
    }

    /// MUST be called before `commit()`. Captures the semaphore strongly and NEVER `self`: a signal
    /// dropped after renderer deinit leaves the semaphore unbalanced and libdispatch aborts.
    private func registerSlotReleaseHandler(on buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { [semaphore = self.ring.inflightSemaphore] cb in
            if cb.status == .error {
                if let err = cb.error {
                    Self.logger.error("command buffer failed: \(String(describing: err), privacy: .public)")
                } else {
                    Self.logger.error("command buffer ended with .error status (no NSError)")
                }
            }
            semaphore.signal()
        }
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool, selection: Selection? = nil) {
        // Compute the key BEFORE reaching for currentDrawable, which can block on the pool.
        let blinkSkipNow = computeBlinkSkip(snapshot: snapshot, focused: focused)
        let selFields = Self.selectionFields(selection)
        let frameKey = makeFrameKey(
            snapshot: snapshot, focused: focused, selFields: selFields, blinkSkip: blinkSkipNow,
            viewportPoints: view.bounds.size
        )
        if !debugToggles.frameSkipDisabled, frameKey == skipCache.lastFrameKey {
            skipCache.didFrameSkipLastRender = true
            return
        }

        // Claim the slot BEFORE acquiring the drawable: waiting on the semaphore while holding a
        // drawable starves `CAMetalLayer`'s 3-slot drawable pool.
        let slot = claimSlot()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            releaseSlotUnused()
            // `lastFrameKey` is NOT advanced: it records the last ENCODED frame, and advancing it
            // here would let the next call skip and never re-encode.
            skipCache.didFrameSkipLastRender = true
            #if DEBUG
            if _testForceFrameKeyAdvanceOnFailedDrawable {
                skipCache.lastFrameKey = frameKey
            }
            #endif
            return
        }

        // Committed to encoding: advance the skip cache and consume the rotation turn only now.
        commitSlotRotation()
        skipCache.didFrameSkipLastRender = false
        skipCache.lastFrameKey = frameKey

        registerSlotReleaseHandler(on: buffer)

        let isSelected = Self.makeSelectionPredicate(selection)

        if let snap = snapshot {
            let geo = computeFrameGeometry(
                snap: snap, view: view, blinkSkip: blinkSkipNow, focused: focused
            )
            // `computeFrameGeometry` must capture the prior cursor position BEFORE this write.
            if geo.cursorMoved {
                cursorState.lastCursorRow = geo.curRow
                cursorState.lastCursorCol = geo.curCol
                cursorState.blinkPhaseStart = CACurrentMediaTime()
            }

            let blinkChanged = blinkSkipNow != lastBuiltBlinkSkip
            let plan = planRowRebuild(
                snap: snap, visual: frameKey.visual,
                blinkChanged: blinkChanged, geo: geo
            )

            guard let instanceCount = buildInstances(
                snapshot: snap,
                isSelected: isSelected,
                blockCursorCell: geo.blockCursorCell,
                partialRowsOnly: plan.partialRows
            ) else {
                // Grow failure: end the encoder, do NOT present, and return the slot token by hand
                // (the completion handler only fires for COMMITTED buffers).
                encoder.endEncoding()
                rollbackSlotRotation()
                skipCache.lastFrameKey = nil
                skipCache.didFrameSkipLastRender = true
                return
            }
            skipCache.lastCacheKey = plan.cacheKey
            lastBuiltBlinkSkip = blinkSkipNow
            // Updated only once the row cache is in sync with `snap`.
            skipCache.lastRenderedSnapshotSeq = snap.sequenceID
            if instanceCount > 0 {
                encodeCells(
                    encoder: encoder, slot: slot, instanceCount: instanceCount,
                    viewportPoints: geo.viewportPoints, cellSizePoints: geo.cellSizePoints
                )
            }
            if geo.cursorOnScreen && !geo.useCellInvertedCursor {
                encodeCursor(
                    encoder: encoder, paintCol: geo.cursorPaintCol,
                    isWide: geo.cursorIsWide, screenCursorRow: geo.screenCursorRow,
                    shape: geo.shape, viewportPoints: geo.viewportPoints,
                    cellSizePoints: geo.cellSizePoints, focused: focused
                )
            }
        }

        encoder.endEncoding()
        if drawable.layer.presentsWithTransaction {
            // The present must ride the CATransaction carrying the new layer bounds: commit →
            // waitUntilScheduled → `drawable.present()`. `present(_:)` does NOT wait for one.
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }

    /// `cursorPaintCol` / `cursorIsWide` are where the cursor is DRAWN; `curCol` stays the raw grid
    /// column. `prevCursor*` are read BEFORE `render` overwrites `cursorState.lastCursor*`.
    private struct FrameGeometry {
        let viewportPoints: SIMD2<Float>
        let cellSizePoints: SIMD2<Float>
        let screenCursorRow: Int
        let cursorPaintCol: Int
        let cursorIsWide: Bool
        let effectiveShape: UInt8
        let shape: UInt32
        let curRow: Int32
        let curCol: Int32
        let prevCursorRow: Int32
        let prevCursorCol: Int32
        let cursorMoved: Bool
        let cursorOnScreen: Bool
        let useCellInvertedCursor: Bool
        let blockCursorCell: (row: Int, col: Int)?
    }

    private func computeFrameGeometry(
        snap: BBSnapshot,
        view: MTKView,
        blinkSkip: Bool,
        focused: Bool
    ) -> FrameGeometry {
        // Viewport in points, not pixels: the shader divides point positions by it. Sanitised
        // exactly as the FrameKey does, so the key matches the value that reaches the shader.
        let viewportPoints = SIMD2<Float>(
            Float(view.bounds.size.width.sanitizedPixel),
            Float(view.bounds.size.height.sanitizedPixel)
        )
        let cellSizePoints = SIMD2<Float>(
            Float(metrics.cellWidth),
            Float(metrics.cellHeight)
        )
        // The live grid starts at screen row displayOffset; a cursor below the viewport is skipped.
        let screenCursorRow = snap.cursorRow + snap.displayOffset
        let effectiveShape: UInt8 = cursorState.shapeOverride ?? UInt8(clamping: snap.cursorShape)
        let shape = UInt32(effectiveShape)
        let curRow = Int32(clamping: snap.cursorRow)
        let curCol = Int32(clamping: snap.cursorCol)
        let prevCursorRow = cursorState.lastCursorRow
        let prevCursorCol = cursorState.lastCursorCol
        let cursorMoved = curRow != cursorState.lastCursorRow || curCol != cursorState.lastCursorCol
        let cursorOnScreen =
            snap.cursorVisible &&
            shape != 3 &&                 // DECSCUSR hidden
            snap.cursorCol < snap.cols &&
            screenCursorRow < snap.rows &&
            !blinkSkip
        // Focused block cursor renders via cell inversion (so the glyph stays visible).
        let useCellInvertedCursor = cursorOnScreen && focused && shape == 0
        let paint = Self.cursorPaintSpan(snap: snap, screenRow: screenCursorRow)
        let blockCursorCell: (row: Int, col: Int)? = useCellInvertedCursor
            ? (row: screenCursorRow, col: paint.col)
            : nil
        return FrameGeometry(
            viewportPoints: viewportPoints,
            cellSizePoints: cellSizePoints,
            screenCursorRow: screenCursorRow,
            cursorPaintCol: paint.col,
            cursorIsWide: paint.isWide,
            effectiveShape: effectiveShape,
            shape: shape,
            curRow: curRow,
            curCol: curCol,
            prevCursorRow: prevCursorRow,
            prevCursorCol: prevCursorCol,
            cursorMoved: cursorMoved,
            cursorOnScreen: cursorOnScreen,
            useCellInvertedCursor: useCellInvertedCursor,
            blockCursorCell: blockCursorCell
        )
    }

    /// A cursor on a `WIDE_CHAR` covers both of its cells; one parked on the trailing
    /// `WIDE_CHAR_SPACER` is drawn on the glyph's leading cell. The raw `cursorCol` is left alone.
    private static func cursorPaintSpan(snap: BBSnapshot, screenRow: Int) -> (col: Int, isWide: Bool) {
        let col = snap.cursorCol
        guard screenRow >= 0, screenRow < snap.rows, col >= 0, col < snap.cols else {
            return (col, false)
        }
        let idx = screenRow * snap.cols + col
        guard idx < snap.cellCount else { return (col, false) }
        let cells = snap.cellsPointer
        if col > 0,
           CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: cells[idx], leftNeighbor: cells[idx - 1]) {
            return (col - 1, true)
        }
        if (cells[idx].flags & UInt16(WIDE_CHAR)) != 0, col + 1 < snap.cols {
            return (col, true)
        }
        return (col, false)
    }

    /// `partialRows == nil` means a full rebuild.
    private struct RebuildPlan {
        let cacheKey: CacheKey
        let partialRows: Set<Int>?
    }

    /// Pure: `render` records the returned key only after `buildInstances` succeeds.
    private func planRowRebuild(
        snap: BBSnapshot,
        visual: VisualState,
        blinkChanged: Bool,
        geo: FrameGeometry
    ) -> RebuildPlan {
        let newCacheKey = CacheKey(cols: snap.cols, rows: snap.rows, visual: visual)
        let cacheCompatible = !debugToggles.dirtyRowsDisabled
            && skipCache.lastCacheKey == newCacheKey
            && skipCache.rowInstanceCache.count == snap.rows

        let snapshotCoalesced: Bool =
            skipCache.lastRenderedSnapshotSeq > 0
            && snap.sequenceID > skipCache.lastRenderedSnapshotSeq + 1

        let partialRows = decideRebuildRows(
            snap: snap,
            cacheCompatible: cacheCompatible,
            snapshotCoalesced: snapshotCoalesced,
            cursorMoved: geo.cursorMoved,
            blinkChanged: blinkChanged,
            prevCursorRow: geo.prevCursorRow,
            prevCursorCol: geo.prevCursorCol,
            curRow: geo.curRow
        )
        return RebuildPlan(cacheKey: newCacheKey, partialRows: partialRows)
    }

    /// nil forces a full rebuild. The rows the cursor left / moved to are always added: pure cursor
    /// motion doesn't always damage them, leaving a ghost inverted cell.
    func decideRebuildRows(
        snap: BBSnapshot,
        cacheCompatible: Bool,
        snapshotCoalesced: Bool,
        cursorMoved: Bool,
        blinkChanged: Bool,
        prevCursorRow: Int32,
        prevCursorCol: Int32,
        curRow: Int32
    ) -> Set<Int>? {
        guard cacheCompatible else { return nil }
        guard !snap.damageIsFull else { return nil }
        guard !snapshotCoalesced else { return nil }
        let damaged = snap.damagedRows
        // Empty damage (DSR/DA replies, mode toggles, bells) is the CHEAPEST case, not a rebuild.
        if damaged.count >= (snap.rows + 1) / 2 {
            return nil
        }
        var rows = Set(damaged)
        if cursorMoved {
            let prevScreenRow = Int(prevCursorRow) + Int(snap.displayOffset)
            if prevScreenRow >= 0 && prevScreenRow < snap.rows {
                rows.insert(prevScreenRow)
            }
            let newScreenRow = Int(curRow) + Int(snap.displayOffset)
            if newScreenRow >= 0 && newScreenRow < snap.rows {
                rows.insert(newScreenRow)
            }
            _ = prevCursorCol // silence unused warning
        }
        // A blink flip only changes the cursor cell's inversion, which lives in its row instances.
        if blinkChanged {
            let cursorScreenRow = Int(curRow) + Int(snap.displayOffset)
            if cursorScreenRow >= 0 && cursorScreenRow < snap.rows {
                rows.insert(cursorScreenRow)
            }
        }
        return rows
    }

    /// The colour atlas is always bound so the `BB_ATTR_IS_COLOR_GLYPH` branch is addressable.
    private func encodeCells(
        encoder: MTLRenderCommandEncoder,
        slot: Int,
        instanceCount: Int,
        viewportPoints: SIMD2<Float>,
        cellSizePoints: SIMD2<Float>
    ) {
        var uniforms = FrameUniforms(
            viewportPx: viewportPoints,
            cellSizePx: cellSizePoints,
            accentColor: themeColors.accentColor,
            decorationPx: SIMD4<Float>(
                Float(metrics.underlineCenterFromBottom),
                Float(metrics.underlineThickness),
                Float(metrics.strikeCenterFromBottom),
                0
            )
        )
        encoder.setRenderPipelineState(pipelines.pipelineState)
        encoder.setVertexBuffer(ring.instanceBuffers[slot], offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(atlas.colorTexture, index: 1)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
    }

    private func encodeCursor(
        encoder: MTLRenderCommandEncoder,
        paintCol: Int,
        isWide: Bool,
        screenCursorRow: Int,
        shape: UInt32,
        viewportPoints: SIMD2<Float>,
        cellSizePoints: SIMD2<Float>,
        focused: Bool
    ) {
        var cu = CursorUniforms(
            viewportPx: viewportPoints,
            cursorPosPx: SIMD2<Float>(Float(paintCol) * Float(metrics.cellWidth) + insets.leftInsetPoints,
                                      Float(screenCursorRow) * Float(metrics.cellHeight) + insets.topInsetPoints),
            cellSizePx: isWide ? SIMD2<Float>(cellSizePoints.x * 2, cellSizePoints.y) : cellSizePoints,
            color: themeColors.cursorColor,
            strokeWidthPx: 1.0,
            filled: focused ? 1.0 : 0.0,
            shape: shape,
            _pad: 0
        )
        encoder.setRenderPipelineState(pipelines.cursorPipelineState)
        encoder.setVertexBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
        encoder.setFragmentBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    deinit {
        // A DispatchSemaphore must be balanced before deallocation or the process traps: waiting on
        // an empty command buffer runs every committed frame's completion handler (the signals).
        var drained = false
        var drainAttempt = -1
        for attempt in 0..<2 {
            if let drain = commandQueue.makeCommandBuffer() {
                drain.commit()
                drain.waitUntilCompleted()
                drained = true
                drainAttempt = attempt
                break
            }
        }
        if !drained {
            Self.logger.error("MetalRenderer.deinit: drain commandBuffer creation failed (both attempts); relying on M-3 strong-captured signal to balance the semaphore")
        } else if drainAttempt > 0 {
            Self.logger.notice("MetalRenderer.deinit: drain commandBuffer succeeded on attempt \(drainAttempt + 1, privacy: .public); queue was momentarily unable to vend a buffer")
        }
        #if DEBUG
        if drained && drainAttempt == 0 {
            Self.logger.debug("MetalRenderer deinit — in-flight frames drained")
        }
        #endif
    }
}

struct FrameUniforms {
    var viewportPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    /// sRGB RGBA.
    var accentColor: SIMD4<Float>
    /// Points. x: underline centre above the quad bottom; y: thickness; z: strike centre.
    var decorationPx: SIMD4<Float>
}

struct CursorUniforms {
    var viewportPx: SIMD2<Float>
    var cursorPosPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var color: SIMD4<Float>
    var strokeWidthPx: Float
    var filled: Float       // 1.0 = solid block (window focused), 0.0 = outline
    var shape: UInt32       // 0 = block, 1 = bar, 2 = underline, 3 = hidden
    var _pad: Float
}

/// MUST stay byte-compatible with `CursorUniforms` in `Shaders.metal` (stride 64: Swift inserts 8
/// bytes of padding before `color`). Update the shader struct first, then the constant.
private let _cursorUniformsLayoutPinned: Void = {
    precondition(MemoryLayout<CursorUniforms>.stride == 64,
                 "CursorUniforms stride drifted from the 64-byte contract "
                 + "mirrored in Shaders.metal — update the shader struct "
                 + "BEFORE widening this number. Actual stride: "
                 + "\(MemoryLayout<CursorUniforms>.stride)")
    precondition(MemoryLayout<CursorUniforms>.alignment == 16,
                 "CursorUniforms must keep 16-byte alignment so SIMD4 fields "
                 + "land on Metal's natural alignment.")
}()

@inline(never)
func _pinCursorUniformsLayout() { _ = _cursorUniformsLayoutPinned }
