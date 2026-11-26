import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox
import CoreText
import Combine
import Metal
import MetalKit
import os

public struct CellMetrics {
    public let font: NSFont
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat
    /// Underline centre in points ABOVE the cell's bottom edge (the baseline sits `descent` above
    /// it; CoreText's underline position is negative below the baseline).
    public let underlineCenterFromBottom: CGFloat
    public let underlineThickness: CGFloat
    public let strikeCenterFromBottom: CGFloat

    public init(font: NSFont) {
        self.font = font
        let ct = font as CTFont
        self.ascent = CTFontGetAscent(ct)
        self.descent = CTFontGetDescent(ct)
        self.leading = CTFontGetLeading(ct)
        let ulPos = CTFontGetUnderlinePosition(ct)
        let ulThick = CTFontGetUnderlineThickness(ct)
        let xHeight = CTFontGetXHeight(ct)
        let thick = (ulThick.isFinite && ulThick > 0) ? ulThick : max(1, font.pointSize / 14)
        self.underlineThickness = max(1, thick)
        let ulCenter = self.descent + (ulPos.isFinite ? ulPos : -1.0)
        self.underlineCenterFromBottom = max(self.underlineThickness / 2 + 0.5, ulCenter)
        let xh = (xHeight.isFinite && xHeight > 0) ? xHeight : font.pointSize * 0.5
        self.strikeCenterFromBottom = self.descent + xh / 2
        // Check isFinite before max: max(1, NaN) is NaN, which traps Int(NaN) in grid(forPixelSize:).
        // The 1pt floor keeps grid math off division-by-zero and Metal off a zero-sized texture.
        let rawCellHeight = (ascent + descent + leading).rounded()
        self.cellHeight = rawCellHeight.isFinite ? max(1, rawCellHeight) : 1
        var glyph = CGGlyph(0)
        var chars: [UniChar] = [UniChar(UInt8(ascii: "M"))]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        let rawCellWidth = advance.width.rounded()
        self.cellWidth = rawCellWidth.isFinite ? max(1, rawCellWidth) : 1
    }

    public func grid(forPixelSize size: CGSize) -> (cols: Int, rows: Int) {
        // NaN, infinite or absurd sizes trap the `Int(Double)` cast; clamp per axis first.
        let w = size.width.sanitizedPixel
        let h = size.height.sanitizedPixel
        let cols = max(1, Int(w / cellWidth))
        let rows = max(1, Int(h / cellHeight))
        return (cols, rows)
    }
}

public final class TerminalView: MTKView, MTKViewDelegate {

    public weak var session: TerminalSession? {
        didSet { subscribeToSession() }
    }

    var defaultTitle: String?

    public let renderer: MetalRenderer
    public private(set) var metrics: CellMetrics
    public private(set) var encoder: KeyEncoder = {
        let isMeta = Preferences.shared.optionKey == .meta
        return KeyEncoder(optionIsMeta: isMeta)
    }()

    private var prefsCancellable: AnyCancellable?

    private struct PrefsObservedKey: Equatable {
        let fontName: String
        let fontSize: Double
        let optionKey: Preferences.OptionKey
    }
    private var lastObservedPrefsKey: PrefsObservedKey?

    /// `nil` follows the global `Preferences.shared.fontSize`. Session-lifetime only, not persisted.
    /// `adjustFontSizeOverride(by:)` is the only writer and clamps to `Preferences.fontSizeRange`.
    public private(set) var fontSizeOverride: Double?

    var effectiveFontSize: Double { fontSizeOverride ?? Preferences.shared.fontSize }

    /// `render(snapshot:)` is the only writer. `a11yCache` is keyed on a raw pointer into the FFI
    /// heap that the allocator can hand to the next snapshot (ABA), so every swap invalidates it.
    var currentSnapshot: BBSnapshot? {
        didSet {
            a11yCache.invalidate()
            scheduleAccessibilityValueChanged()
            findController.snapshotDidChange()
        }
    }

    #if DEBUG
    var a11ySnapshotOverride: A11ySnapshotSource?
    var hyperlinkResolverOverride: HyperlinkResolver?
    #endif

    var urlOpener: URLOpener = DefaultURLOpener()

    // MARK: - Hover

    lazy var hoverCoordinator = HoverCoordinator(view: self)
    var pendingInsertTextModifiers: KeyEncoder.Modifiers?
    var pendingInsertTextIsRepeat = false
    var pendingInsertTextKeypadKeyCode: UInt16?
    /// `keyCode` -> text the input context committed for a held keypad key. `keyUp` re-encodes THIS
    /// text for the release: the layout decides it, not the encoder's fixed US table.
    var keypadCommittedText = [UInt16: String]()
    private struct ForwardedKeyDown {
        let modifiers: KeyEncoder.Modifiers
        let chars: String
    }
    /// `keyCode` → the first (non-repeat) `keyDown` the TUI was given. `keyUp` forwards a release only
    /// for these, encoded from the PRESS's modifiers and characters, never the key-up event's own.
    private var forwardedKeyDowns: [UInt16: ForwardedKeyDown] = [:]
    var wheelAccumulator = WheelScrollAccumulator()

    private var pinchAccumulator: CGFloat = 0
    let tooltipController = TooltipController()
    /// Owned here, not on `hoverCoordinator`: `deinit` cancels it, and reaching through the
    /// coordinator's `unowned view` back-ref during the view's own deinit traps.
    var hoverTooltipItem: DispatchWorkItem?
    var hoverTrackingArea: NSTrackingArea?

    struct BBXYPoint: Equatable { let col: Int; let row: Int }
    /// Dedupes DEC 1003 any-event motion reports on the same cell.
    var lastReportedMotionCell: BBXYPoint?
    /// Not shared with `lastReportedMotionCell`: a drag's last cell would suppress a hover report there.
    var lastReportedDragCell: BBXYPoint?

    let windowResizeController = WindowResizeController()

    var windowResizeControllerStartFrame: NSRect?

    private var cancellables: [AnyCancellable] = []
    private let scrollIndicator = ScrollIndicator(frame: .zero)

    var composition: TerminalView.Composition?
    /// Raised by `insertText(_:)` during one `keyDown(with:)` pass so keyDown does not also encode
    /// the event (the shell would see the character twice). Cleared at the top of keyDown.
    var didInsertTextViaIME: Bool = false
    var preeditOverlay: PreeditOverlayView?

    #if DEBUG
    var ptyRecorderForTests: RecordingPTY?
    var cursorOverrideForTests: (row: Int, col: Int)?
    var pasteTextRecorderForTests: ((String) -> Void)?
    #endif

    let bellController = BellController()

    // `wakeRenderLoop()`, not `setNeedsDisplay`: the view runs with `enableSetNeedsDisplay = false`.
    public internal(set) var selection: Selection? {
        didSet {
            if oldValue != selection { wakeRenderLoop() }
        }
    }

    lazy var selectionController = SelectionController(view: self)

    var lastMouseDownMark: ClickSequenceMark?

    /// A ⌘-mousedown on a resolvable URL. The URL opens on mouseUp, and only if the pointer stayed
    /// within the slop, so ⌘-drag-to-move-window still works from a link.
    /// While non-nil the gesture is CONSUMED: no xterm mouse report and no selection. ⌘ has no bit
    /// in the xterm mouse protocol (shift=4, meta=8, ctrl=16), so a TUI could not have seen it.
    struct PendingLinkClick {
        let url: URL
        let downEvent: NSEvent
        let clickCount: Int
        /// Past the slop the gesture is no longer a click but stays CONSUMED: the press was never
        /// reported, so neither the drags nor the release may be.
        var cancelled = false

        /// Points, window space. 3 pt matches the slop AppKit allows before a click becomes a drag.
        static let dragSlopPoints: CGFloat = 3

        func isStillAClick(at location: NSPoint) -> Bool {
            let dx = location.x - downEvent.locationInWindow.x
            let dy = location.y - downEvent.locationInWindow.y
            return abs(dx) <= Self.dragSlopPoints && abs(dy) <= Self.dragSlopPoints
        }
    }
    var pendingLinkClick: PendingLinkClick?

    /// `mouseUp` mirrors what `mouseDown` did rather than re-evaluating the predicate: the TUI can
    /// flip mouse mode between the two events, and a release must never arrive without its press.
    var didReportMouseDown = false

    var didReportRightMouseDown = false

    var didReportMiddleMouseDown = false

    /// AppKit delivers `mouseDragged` only on pointer motion, so a timer drives edge-autoscroll.
    let selectionAutoscroller = SelectionAutoscroller()

    lazy var findController = FindController(view: self)

    var isDropTargeted: Bool = false {
        didSet {
            guard oldValue != isDropTargeted else { return }
            dropHighlightView.isHidden = !isDropTargeted
        }
    }

    private let dropHighlightView: NSBox = {
        let b = NSBox(frame: .zero)
        b.boxType = .custom
        b.borderColor = .controlAccentColor
        b.borderWidth = 2
        b.cornerRadius = 4
        b.fillColor = .clear
        b.titlePosition = .noTitle
        b.isHidden = true
        return b
    }()

    #if DEBUG
    private var frameCount = 0
    private var lastFrameLogTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0
    private var frameIntervalMinMs: Double = .infinity
    private var frameIntervalMaxMs: Double = 0
    private var frameIntervalSumMs: Double = 0
    // `os.Logger`, not `NSLog`: NSLog's runtime format string redacts the whole message as `<private>`.
    private static let fpsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                          category: "fps")
    private static let keyLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                          category: "keyboard")
    #endif

    /// Stays outside `#if DEBUG`. Never log keystrokes or paste contents.
    static let securityLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "security")

    nonisolated static let mouseLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                    category: "mouse")

    static let rendererLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "renderer")
    static let didLogEarlyClick = OSAllocatedUnfairLock(initialState: false)

    static func logEarlyClickOnce() {
        didLogEarlyClick.withLock { didLog in
            if !didLog {
                didLog = true
                mouseLogger.warning("click before first snapshot publish — bufferPoint returning origin sentinel against synthetic grid")
            }
        }
    }

    public init(frame frameRect: NSRect, device: MTLDevice) {
        let prefs = Preferences.shared
        let font = Self.resolveFont(name: prefs.fontName, size: CGFloat(prefs.fontSize))
        let metrics = CellMetrics(font: font)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let renderer = MetalRenderer(device: device, metrics: metrics, scale: scale) else {
            fatalError("MetalRenderer init failed; see unified log under category=\"renderer\" for the underlying error")
        }
        self.renderer = renderer
        self.metrics = metrics
        super.init(frame: frameRect, device: device)
        self.delegate = self
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Must match the render pipeline's colorAttachments[0].pixelFormat set up by MetalRenderer.
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 120
        // 3 drawables: with a 2-deep pool macOS's display coalescer never promotes the compositor
        // to 120 Hz on ProMotion panels.
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 3
            metalLayer.displaySyncEnabled = true
            // Pin sRGB so Display P3 panels do not reinterpret the 8-bit values in P3 primaries. The
            // format is `.bgra8Unorm` (not `_srgb`): the shader works in gamma-encoded space.
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        addSubview(scrollIndicator)

        bellController.attach(to: self)

        dropHighlightView.frame = bounds
        dropHighlightView.autoresizingMask = [.width, .height]
        addSubview(dropHighlightView)

        // Do NOT write UserDefaults in this sink: the write re-fires `Preferences.objectWillChange`
        // through SwiftUI's global UserDefaults observer and loops indefinitely.
        prefsCancellable = Preferences.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let p = Preferences.shared
                let key = PrefsObservedKey(
                    fontName: p.fontName,
                    fontSize: p.fontSize,
                    optionKey: p.optionKey
                )
                if key == self.lastObservedPrefsKey {
                    return
                }
                // Stamp only after a successful apply so a failed atlas rebuild retries.
                if self.applyEffectiveFont() {
                    self.lastObservedPrefsKey = key
                }
                self.syncEncoderFromPreferences()
            }

        pushSystemAccentToRenderer()
        // Process-global: `accentObservers` survives `viewDidMoveToWindow` rebuilding `focusObservers`.
        accentObservers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pushSystemAccentToRenderer()
            self.needsDisplay = true
        })
    }

    private func pushSystemAccentToRenderer() {
        let sRGB = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let r = Float(sRGB?.redComponent ?? 0.0)
        let g = Float(sRGB?.greenComponent ?? 0.48)
        let b = Float(sRGB?.blueComponent ?? 1.0)
        let a = Float(sRGB?.alphaComponent ?? 1.0)
        renderer.setAccentColor(rgba: SIMD4<Float>(r, g, b, a))
    }

    private func syncEncoderFromPreferences() {
        let wantMeta = Preferences.shared.optionKey == .meta
        if encoder.optionIsMeta != wantMeta {
            encoder = KeyEncoder(optionIsMeta: wantMeta)
        }
    }

    /// Returns `false` only when the renderer failed to rebuild its atlas; the caller must then
    /// NOT advance dedupe state, so the next emission retries.
    @discardableResult
    func applyEffectiveFont() -> Bool {
        let wantName = Preferences.shared.fontName
        let wantSize = CGFloat(effectiveFontSize)
        if metrics.font.familyName == wantName && metrics.font.pointSize == wantSize {
            return true
        }
        let newFont = Self.resolveFont(name: wantName, size: wantSize)
        let newMetrics = CellMetrics(font: newFont)
        // Rasterise at the window's current screen's scale, not the primary screen's.
        let scale = window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        // Commit the new metrics only if the atlas was rebuilt, or grid math and glyphs drift apart.
        guard renderer.reconfigure(metrics: newMetrics, scale: scale) else {
            Self.rendererLogger.error(
                "applyEffectiveFont reconfigure failed — keeping cellW=\(self.metrics.cellWidth, privacy: .public) cellH=\(self.metrics.cellHeight, privacy: .public); requested cellW=\(newMetrics.cellWidth, privacy: .public) cellH=\(newMetrics.cellHeight, privacy: .public) scale=\(scale, privacy: .public)"
            )
            return false
        }
        self.metrics = newMetrics
        if let window {
            window.contentMinSize = NSSize(
                width: newMetrics.cellWidth * 20 + 2 * Self.horizontalContentInsetPoints,
                height: newMetrics.cellHeight * 4 + titlebarOnlyTopInset + Self.bottomContentInsetPoints
            )
        }
        // propagateResize dedupes against lastPropagatedSize; clear it to force a re-grid.
        lastPropagatedSize = nil
        // Async so a coreQueue backlog (shell streaming output) cannot block main.
        propagateResize(async: true)
        needsLayout = true
        return true
    }

    /// Titlebar height excluding AppKit's phantom reservation for the suppressed native tab bar.
    var titlebarOnlyTopInset: CGFloat {
        guard let window else { return 28 }
        var maskWithoutFullSize = window.styleMask
        maskWithoutFullSize.remove(.fullSizeContentView)
        let contentRectForStyle = NSWindow.contentRect(
            forFrameRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: maskWithoutFullSize
        )
        let titlebar = 100 - contentRectForStyle.height
        return max(22, titlebar)
    }

    public override func layout() {
        super.layout()
        let bottom = Self.bottomContentInsetPoints
        let top = titlebarOnlyTopInset
        renderer.setTopInsetPoints(Float(top))
        renderer.setLeftInsetPoints(Float(Self.horizontalContentInsetPoints))
        let width: CGFloat = 10
        scrollIndicator.frame = NSRect(
            x: bounds.width - width,
            y: bottom,
            width: width,
            height: max(0, bounds.height - bottom - top)
        )
        if composition != nil {
            refreshPreeditOverlay()
        }
    }

    public required init(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { forgetForwardedKeyDowns() }
        return resigned
    }

    /// NSView's default is `true` for a non-opaque view (translucency on), and AppKit then turns
    /// every click-drag into a window drag before `mouseDragged(with:)` sees it.
    public override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Synchronous presentation during resize

    private(set) var synchronousResizePresentation = false

    #if DEBUG
    var synchronousDrawsForTesting = 0
    #endif

    /// With `presentsWithTransaction` on, the new-size drawable and the new layer bounds reach the
    /// screen together; otherwise the compositor scales one to the other's bounds mid-drag.
    public func beginSynchronousResizePresentation() {
        guard !synchronousResizePresentation else { return }
        synchronousResizePresentation = true
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
    }

    public func endSynchronousResizePresentation() {
        guard synchronousResizePresentation else { return }
        synchronousResizePresentation = false
        (layer as? CAMetalLayer)?.presentsWithTransaction = false
    }

    /// `MTKView.draw()` runs the delegate even while paused; the renderer tolerates a missing drawable.
    private func drawSynchronously() {
        #if DEBUG
        synchronousDrawsForTesting += 1
        #endif
        draw()
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        beginSynchronousResizePresentation()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endSynchronousResizePresentation()
        propagateResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        propagateResize()
        // Present now, inside AppKit's transaction. The display-link tick that follows sees an
        // equal FrameKey and skips, so a drawable is never acquired twice per vblank.
        if synchronousResizePresentation {
            drawSynchronously()
        }
    }

    private var lastPropagatedSize: PTY.Size?
    /// Distinct from `lastPropagatedSize != nil`, which a font change and a titlebar-inset change
    /// reset to force a re-grid; those must not earn the first resize's synchronous path.
    private var hasPropagatedOnce = false
    private var forceNonBlockingResizeDelivery = false
    private var lastSafeAreaTop: Float = -1

    /// Scoped, not inferred: at AppKit's select-time frame apply a background tab still reports
    /// `isVisible == false` and its group's `selectedWindow` is still the OUTGOING tab.
    func withNonBlockingResizeDelivery(_ body: () -> Void) {
        let previous = forceNonBlockingResizeDelivery
        forceNonBlockingResizeDelivery = true
        defer { forceNonBlockingResizeDelivery = previous }
        body()
    }

    /// Keeps the last grid row clear of the window's rounded corner (~10 pt radius).
    public static let bottomContentInsetPoints: CGFloat = 10

    public static let horizontalContentInsetPoints: CGFloat = 8

    /// Top-left origin of the cell in this view's local, top-down coordinate space.
    public func cellOriginPx(row: Int, col: Int) -> CGPoint {
        let x = Self.horizontalContentInsetPoints + CGFloat(col) * metrics.cellWidth
        let y = titlebarOnlyTopInset + CGFloat(row) * metrics.cellHeight
        return CGPoint(x: x, y: y)
    }

    /// Does NOT know the live grid size: row/col are clamped only to a 100_000 sanity cap, so
    /// callers needing `[0, cols)` / `[0, rows)` must re-clamp against the current `BBSnapshot`.
    public func cellAt(point: CGPoint) -> (row: Int, col: Int) {
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight
        guard cw > 0, ch > 0 else { return (0, 0) }
        let safeX = point.x.sanitizedPixel
        let safeY = point.y.sanitizedPixel
        let xInGrid = safeX - Self.horizontalContentInsetPoints
        let yInGrid = safeY - titlebarOnlyTopInset
        let rawCol = Int(max(0, xInGrid) / cw)
        let rawRow = Int(max(0, yInGrid) / ch)
        let col = max(0, min(rawCol, 100_000))
        let row = max(0, min(rawRow, 100_000))
        return (row, col)
    }

    /// Shared with `MainWindowController.startSession` so the start size and the first SIGWINCH agree.
    public static func usableViewSize(
        forBounds bounds: CGSize,
        titlebarTopInset: CGFloat,
        metrics: CellMetrics
    ) -> CGSize {
        let usableWidth = max(
            metrics.cellWidth,
            bounds.width - 2 * Self.horizontalContentInsetPoints
        )
        let usableHeight = max(
            metrics.cellHeight,
            bounds.height - titlebarTopInset - Self.bottomContentInsetPoints
        )
        return CGSize(width: usableWidth, height: usableHeight)
    }

    private func propagateResize(async asyncResize: Bool = false) {
        let usable = Self.usableViewSize(
            forBounds: bounds.size,
            titlebarTopInset: titlebarOnlyTopInset,
            metrics: metrics
        )
        let grid = metrics.grid(forPixelSize: usable)
        // cols/rows can exceed UInt16.max on a degenerate cell size; `clamping:` avoids the trap.
        let size = PTY.Size(
            cols: UInt16(clamping: grid.cols),
            rows: UInt16(clamping: grid.rows)
        )
        let previous = lastPropagatedSize
        guard size != previous else { return }
        lastPropagatedSize = size
        // .async: non-drag callers; never blocks main on a coreQueue backlog.
        // .sync: the first resize (the shell must start at the real grid size) and row-only changes.
        // .coalesced: a column change reflows the whole scrollback (10-37 ms); off main, latest-wins.
        // `.sync` is cheap only when the core is idle: not for a fan-out onto a background tab
        // (main would wait out its feed backlog) nor behind a pending coalesced resize.
        let delivery: ResizeDelivery
        if asyncResize {
            delivery = .async
        } else if forceNonBlockingResizeDelivery {
            delivery = .coalesced
        } else if session?.hasPendingCoalescedResize == true {
            delivery = .coalesced
        } else if !hasPropagatedOnce || size.cols == previous?.cols {
            delivery = .sync
        } else {
            delivery = .coalesced
        }
        hasPropagatedOnce = true
        #if DEBUG
        lastResizeDeliveryForTesting = delivery
        #endif
        guard let session else { return }
        switch delivery {
        case .async:     session.resizeAsync(to: size)
        case .sync:      session.resize(to: size)
        case .coalesced: session.resizeCoalesced(to: size)
        }
    }

    enum ResizeDelivery: Equatable {
        case sync
        case async
        case coalesced
    }

    #if DEBUG
    public func lastPropagatedSizeForTesting() -> PTY.Size? { lastPropagatedSize }

    var lastResizeDeliveryForTesting: ResizeDelivery?
    #endif

    // MARK: - Rendering

    public func applyTheme(_ palette: ThemePalette) {
        wakeRenderLoop()
        let bgR = Double((palette.background >> 16) & 0xFF) / 255.0
        let bgG = Double((palette.background >> 8)  & 0xFF) / 255.0
        let bgB = Double(palette.background & 0xFF) / 255.0
        let (opacity, blurRadius) = Preferences.shared.translucencyResolved
        // Cells with the default bg skip their bg quad, so clearColor shows through them.
        clearColor = MTLClearColor(red: bgR, green: bgG, blue: bgB, alpha: opacity)
        themeDefaultBgRgb = palette.background
        themeDefaultFgRgb = palette.foreground
        renderer.setDefaultBgRgb(palette.background)
        renderer.setCursorColor(rgb: palette.cursor)
        renderer.setSelectionColors(highlightRgb: palette.selection, foregroundRgb: palette.selectionForeground)
        renderer.setBackgroundOpacity(Float(opacity), keepBgOpaque: false)
        renderer.setCursorBlinkEnabled(Preferences.shared.cursorBlink)
        renderer.setCursorShapeOverride(Preferences.shared.cursorShape.rendererOverride)
        setWindowAppearance(opacity: opacity, themeBg: (bgR, bgG, bgB))
        window?.setBackgroundBlurRadius(blurRadius)
        findController.applyTheme(palette)
        if composition != nil {
            refreshPreeditOverlay()
        }
    }

    var themeDefaultBgRgb: UInt32 = 0x000000

    var themeDefaultFgRgb: UInt32 = 0xFFFFFF

    private func setWindowAppearance(opacity: Double, themeBg: (r: Double, g: Double, b: Double)) {
        let transparent = opacity < 0.999
        layer?.isOpaque = !transparent
        guard let window else { return }
        window.isOpaque = !transparent
        // Always, even when fully opaque: AppKit's default titlebar chrome reads as a separate bar.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(
            calibratedRed: themeBg.r,
            green: themeBg.g,
            blue: themeBg.b,
            alpha: opacity
        )
        // Theme lightness (Rec. 709 luminance), not the OS appearance, decides AppKit's title-text colour.
        let luminance = 0.2126 * themeBg.r + 0.7152 * themeBg.g + 0.0722 * themeBg.b
        window.appearance = NSAppearance(named: luminance > 0.5 ? .aqua : .darkAqua)
    }

    public func render(snapshot: BBSnapshot) {
        wakeRenderLoop()
        // A partial wheel line accrued under one delivery mode must not be credited to the next.
        let wheelBits: BBTermMode = [.altScreen, .alternateScroll, .mouseReportClick, .mouseMotion, .mouseDrag]
        if let prev = currentSnapshot?.termMode,
           prev.intersection(wheelBits) != snapshot.termMode.intersection(wheelBits) {
            wheelAccumulator.reset()
        }
        let wasFocusMode = currentSnapshot?.termMode.contains(.focusInOut) ?? false
        let nowFocusMode = snapshot.termMode.contains(.focusInOut)
        if let sel = selection, let prev = currentSnapshot {
            let result = SelectionReconciler.reconciled(
                selection: sel,
                wordDragAnchor: selectionController.wordDragAnchorWord,
                prev: prev,
                next: snapshot
            )
            selection = result.selection
            selectionController.wordDragAnchorWord = result.wordDragAnchor
        }
        // The preedit overlay is pinned to the cursor cell. Compare the cell rect across the swap
        // rather than refreshing unconditionally: a streaming TUI must not rebuild it every frame.
        let preeditAnchor: NSRect? = composition != nil ? cursorCellRectInView() : nil
        self.currentSnapshot = snapshot
        if let preeditAnchor, cursorCellRectInView() != preeditAnchor {
            refreshPreeditOverlay()
        }
        // Unconditional, not gated on ⌘: OSC 8 link ids are assigned PER SNAPSHOT by the core, so
        // the id under a stationary pointer may now name a different URL (or none).
        hoverCoordinator.handleSnapshotPublished()
        scrollIndicator.update(
            displayOffset: snapshot.displayOffset,
            historySize: snapshot.historySize,
            rows: snapshot.rows
        )
        if let s = session {
            scrollIndicator.updatePromptMarks(
                s.promptMarks,
                linesScrolled: snapshot.linesScrolled,
                historySize: snapshot.historySize,
                rows: snapshot.rows,
                accentColor: NSColor.controlAccentColor
            )
        }
        // DECSET 1004 enabled while already key: report focus now, through the session's single emitter.
        if !wasFocusMode, nowFocusMode, window?.isKeyWindow == true {
            session?.focusChanged(true)
        }
    }

    private var focusObservers: [NSObjectProtocol] = []

    private var powerObservers: [NSObjectProtocol] = []
    private var occlusionObservers: [NSObjectProtocol] = []

    private var accentObservers: [NSObjectProtocol] = []

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            // A window torn down mid-gesture never delivers the live-resize end / right-mouse-up.
            endSynchronousResizePresentation()
        }
        // The tooltip panel is parented to the current window; dismiss it before that changes.
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        tooltipController.dismiss()
        // Tab tear-out moves the view without deinit; a timer firing while `window` is nil must not scroll.
        selectionAutoscroller.stop()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit does not reliably carry dragging-destination registration across window moves.
        registerForDraggedTypes([.fileURL])
        #if DEBUG
        if let screen = window?.screen {
            let maxFPS = screen.maximumFramesPerSecond
            Self.fpsLogger.log("attached to screen '\(screen.localizedName, privacy: .public)' @ \(maxFPS, privacy: .public) Hz max")
        }
        #endif

        for token in focusObservers {
            NotificationCenter.default.removeObserver(token)
        }
        focusObservers.removeAll()
        // Before the window guard, so a detached view is never driven by its old window's transitions.
        for token in powerObservers {
            NotificationCenter.default.removeObserver(token)
        }
        powerObservers.removeAll()
        for token in occlusionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        occlusionObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.wakeRenderLoop()
            // CSI I / CSI O emission is owned by MainWindowController → session.focusChanged; not here.
            self?.enableSecureEventInputIfNeeded()
            // `flagsChanged` only reaches the key window's first responder; sync ⌘ from the global state.
            self?.hoverCoordinator.syncCmdModifierHeld(fromEventFlags: NSEvent.modifierFlags)
        })
        focusObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.wakeRenderLoop()
            // A right-drag resize whose rightMouseUp went to another app would leave sync presentation on.
            self?.endSynchronousResizePresentation()
            self?.disableSecureEventInputIfHeld()
            self?.discardKeyboardStateOnResignKey()
            self?.hoverCoordinator.resetModifierAndHoverState()
        })
        #if DEBUG
        focusObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let screen = self.window?.screen else { return }
            Self.fpsLogger.log("window moved to screen '\(screen.localizedName, privacy: .public)' @ \(screen.maximumFramesPerSecond, privacy: .public) Hz max")
        })
        #endif

        // A not-yet-shown window reports not visible: paused until the first occlusion notification.
        isWindowOccluded = !window.occlusionState.contains(.visible)

        occlusionObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let win = (note.object as? NSWindow) ?? self.window
            let visible = win?.occlusionState.contains(.visible) ?? true
            self.windowOcclusionDidChange(visible: visible)
        })
        occlusionObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })

        powerObservers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })
        powerObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })

        applyPowerAwareFrameRate()
    }

    /// Hysteresis: once throttled, only `.nominal` unthrottles; once unthrottled, only `.serious`
    /// or worse throttles. `.fair` is a no-op in either direction.
    private var isThermalThrottled: Bool = false

    static let idleThrottleAfterFrames = 120
    static let idleFPS = 10
    private var consecutiveSkippedFrames = 0
    private(set) var isIdleThrottled = false

    func attentionNeeded() -> Bool {
        let tabSelected: Bool = {
            guard let window, let group = window.tabGroup else { return true }
            return group.selectedWindow === window
        }()
        return AttentionPolicy.needsAttention(
            appActive: NSApp.isActive,
            windowKey: window?.isKeyWindow ?? false,
            tabSelected: tabSelected
        )
    }

    func markTabUnseenAttention() {
        (window?.windowController as? MainWindowController)?.markUnseenAttention()
    }

    func wakeRenderLoop() {
        consecutiveSkippedFrames = 0
        if isIdleThrottled {
            isIdleThrottled = false
            applyPowerAwareFrameRate()
        }
    }

    private func noteFrameOutcome(skipped: Bool) {
        if skipped {
            consecutiveSkippedFrames &+= 1
            if !isIdleThrottled, consecutiveSkippedFrames >= Self.idleThrottleAfterFrames {
                isIdleThrottled = true
                applyPowerAwareFrameRate()
            }
        } else {
            consecutiveSkippedFrames = 0
        }
    }

    private var isWindowOccluded = false

    /// On becoming visible, draw one frame now: a background tab's layer still holds a drawable of
    /// the OLD size, which the first display-link tick would show stretched to the new bounds.
    func windowOcclusionDidChange(visible: Bool) {
        let wasOccluded = isWindowOccluded
        isWindowOccluded = !visible
        applyPowerAwareFrameRate()
        if visible && wasOccluded {
            wakeRenderLoop()
            drawSynchronously()
        }
    }

    private func applyPowerAwareFrameRate() {
        let info = ProcessInfo.processInfo
        let isOccluded = isWindowOccluded
        let nativeMax = window?.screen?.maximumFramesPerSecond ?? 60
        let rawThermal = info.thermalState
        let effectiveThermal: ProcessInfo.ThermalState
        switch rawThermal {
        case .nominal:
            isThermalThrottled = false
            effectiveThermal = .nominal
        case .fair:
            effectiveThermal = isThermalThrottled ? .serious : .fair
        case .serious, .critical:
            isThermalThrottled = true
            effectiveThermal = rawThermal
        @unknown default:
            effectiveThermal = rawThermal
        }
        let target = preferredFrameRate(
            isOccluded: isOccluded,
            isLowPowerMode: info.isLowPowerModeEnabled,
            thermalState: effectiveThermal,
            nativeMaxFPS: nativeMax
        )
        // Same-value guards: MTKView's setters are not documented as idempotent.
        switch target {
        case .paused:
            if !self.isPaused { self.isPaused = true }
        case .fps(let n):
            let fps = isIdleThrottled ? min(n, Self.idleFPS) : n
            if self.preferredFramesPerSecond != fps { self.preferredFramesPerSecond = fps }
            if self.isPaused { self.isPaused = false }
        }
    }

    #if DEBUG
    func _enterIdleThrottleForTesting() {
        isIdleThrottled = true
        applyPowerAwareFrameRate()
    }
    #endif

    deinit {
        for token in focusObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in powerObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in occlusionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in accentObservers {
            NotificationCenter.default.removeObserver(token)
        }
        // `deinit` must not read the coordinator's `unowned view` back-ref (it traps mid-deinit).
        hoverTooltipItem?.cancel()
        tooltipController.dismiss()
        selectionAutoscroller.stop()
        disableSecureEventInputIfHeld()
    }

    /// `EnableSecureEventInput` is refcounted by the OS: every Enable must be paired with exactly
    /// one Disable, or secure-input mode leaks system-wide.
    private var ownsSecureInput: Bool = false

    private func enableSecureEventInputIfNeeded() {
        guard !ownsSecureInput else { return }
        EnableSecureEventInput()
        ownsSecureInput = true
    }

    /// Public for AppDelegate's `applicationWillTerminate`: `deinit` may not run during termination.
    public func disableSecureEventInputIfHeld() {
        guard ownsSecureInput else { return }
        DisableSecureEventInput()
        ownsSecureInput = false
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        wakeRenderLoop()
        // setFrameSize owns the points-based resize; SIGWINCH must not also fire from here. This
        // callback only detects a backing-scale change (window moved between displays).
        guard bounds.width > 0 else { return }
        let newScale = size.width / bounds.width
        guard newScale > 0 else { return }
        if abs(newScale - renderer.atlas.scale) > 0.01 {
            if !renderer.reconfigure(metrics: metrics, scale: newScale) {
                Self.rendererLogger.error(
                    "drawableSizeWillChange reconfigure failed, atlas stays at \(self.renderer.atlas.scale, privacy: .public)x"
                )
            }
        }
    }

    public func draw(in view: MTKView) {
        // `titlebarOnlyTopInset`, deliberately NOT `safeAreaInsets.top` / `contentLayoutRect`: those
        // still reserve AppKit's phantom 36pt tab-bar band after the native strip is suppressed.
        let currentTop = Float(titlebarOnlyTopInset)
        renderer.setTopInsetPoints(currentTop)
        // Set here too so a draw that runs before layout() cannot paint cells at x=0.
        renderer.setLeftInsetPoints(Float(Self.horizontalContentInsetPoints))
        if currentTop != lastSafeAreaTop {
            lastSafeAreaTop = currentTop
            // Never resize synchronously from the draw callback: `session.resize(to:)` blocks and
            // re-enters the snapshot publisher. Defer to the next runloop turn.
            lastPropagatedSize = nil
            DispatchQueue.main.async { [weak self] in
                self?.propagateResize()
            }
        }
        let focused = window?.isKeyWindow ?? false
        // Link ids are u16 in BBCell; the snapshot API widens them to u32, so truncation is lossless.
        renderer.setHoveredLinkID(UInt16(truncatingIfNeeded: hoverCoordinator.hoveredLinkID))
        renderer.render(in: view, snapshot: currentSnapshot, focused: focused, selection: selection)
        noteFrameOutcome(skipped: renderer.didFrameSkipLastRender)
        // A skipped frame reached no screen: the keystroke timestamp stays armed for the next one.
        if !renderer.didFrameSkipLastRender {
            LatencyProbe.shared.markPresented()
        }
        #if DEBUG
        let nowMedia = CACurrentMediaTime()
        if lastFrameTime != 0 {
            let dtMs = (nowMedia - lastFrameTime) * 1000.0
            frameIntervalSumMs += dtMs
            if dtMs < frameIntervalMinMs { frameIntervalMinMs = dtMs }
            if dtMs > frameIntervalMaxMs { frameIntervalMaxMs = dtMs }
        }
        lastFrameTime = nowMedia
        frameCount += 1
        let elapsed = nowMedia - lastFrameLogTime
        if elapsed >= 1.0 {
            let intervals = max(1, frameCount - 1)
            let mean = frameIntervalSumMs / Double(intervals)
            let screenName = window?.screen?.localizedName ?? "nil"
            let maxFPS = window?.screen?.maximumFramesPerSecond ?? -1
            let minMs = frameIntervalMinMs.isFinite ? frameIntervalMinMs : 0
            var hwHz: Double = -1
            if let sNum = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgID = CGDirectDisplayID(sNum.uint32Value)
                if let mode = CGDisplayCopyDisplayMode(cgID) {
                    hwHz = mode.refreshRate
                }
            }
            let line = String(
                format: "%d fps over %.2fs — interval min/mean/max = %.2f/%.2f/%.2f ms — screen '%@' (max %d Hz, hw mode %.2f Hz)",
                frameCount, elapsed, minMs, mean, frameIntervalMaxMs,
                screenName, maxFPS, hwHz
            )
            Self.fpsLogger.log("\(line, privacy: .public)")
            frameCount = 0
            frameIntervalMinMs = .infinity
            frameIntervalMaxMs = 0
            frameIntervalSumMs = 0
            lastFrameLogTime = nowMedia
        }
        #endif
    }

    // MARK: - Session observation

    private func subscribeToSession() {
        cancellables.removeAll()
        bellController.resetCounter()
        // Clear the snapshot before the nil-session return, or the previous session's grid stays on screen.
        guard let session else {
            currentSnapshot = nil
            findController.reset()
            selection = nil
            hoverCoordinator.invalidateURLMatchCache()
            setNeedsDisplay(bounds)
            return
        }

        // Sequence ids are per-session and can collide: clear the seq-keyed caches on any rebind.
        hoverCoordinator.invalidateURLMatchCache()
        findController.findMatchesSeq = nil

        // No `.receive(on: DispatchQueue.main)`: as a Combine scheduler it always hops asynchronously,
        // and a synchronous resize needs the new-size snapshot in place before the next display-link tick.
        session.$snapshot
            .sink { [weak self] snap in
                dispatchPrecondition(condition: .onQueue(.main))
                guard let self, let snap else { return }
                self.render(snapshot: snap)
            }
            .store(in: &cancellables)

        session.titleState.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else { return }
                let fallback = self.defaultTitle ?? self.window?.title ?? "Blackbird"
                let useTitle = (title?.isEmpty == false ? title : fallback) ?? "Blackbird"
                // `NSWindow.title` KVO fires even on an identical write, rebuilding the tab pill strips.
                if self.window?.title != useTitle {
                    self.window?.title = useTitle
                }
            }
            .store(in: &cancellables)

        session.$bellCounter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] counter in
                guard let self else { return }
                self.bellController.handleBellCounter(counter)
                let prefs = Preferences.shared
                if counter > 0, prefs.bell != .off || prefs.programNotifications,
                   self.attentionNeeded() {
                    NSApp.requestUserAttention(.informationalRequest)
                    self.markTabUnseenAttention()
                }
            }
            .store(in: &cancellables)

        session.$coreFailureMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self else { return }
                (self.window?.windowController as? MainWindowController)?.presentCoreFailure(message)
            }
            .store(in: &cancellables)

        session.notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, Preferences.shared.programNotifications else { return }
                guard self.attentionNeeded() else { return }
                let titled = note.title.isEmpty
                    ? TerminalNotification(title: self.window?.title ?? "Blackbird", body: note.body)
                    : note
                NotificationPresenter.shared.post(titled, windowNumber: self.window?.windowNumber)
                self.markTabUnseenAttention()
            }
            .store(in: &cancellables)
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        wakeRenderLoop()
        hoverCoordinator.cancelHoverTooltip()
        #if DEBUG
        let keyCode = event.keyCode
        let modBits = UInt(event.modifierFlags.rawValue)
        let chDesc = event.characters?.debugDescription ?? "nil"
        let chIgn = event.charactersIgnoringModifiers?.debugDescription ?? "nil"
        Self.keyLogger.debug(
            "keyDown keyCode=\(keyCode, privacy: .public) flags=0x\(String(modBits, radix: 16), privacy: .public) chars=\(chDesc, privacy: .public) charsIgnoring=\(chIgn, privacy: .public)"
        )
        #endif

        if event.modifierFlags.contains(.command) {
            // A fresh press of a key still on the ledger means its key-up was lost; this shortcut's
            // key-up must not be paired with that earlier press.
            if !event.isARepeat { forwardedKeyDowns.removeValue(forKey: event.keyCode) }
            super.keyDown(with: event)
            return
        }

        guard let session else {
            #if DEBUG
            Self.keyLogger.debug("keyDown: no session, passing to super")
            #endif
            super.keyDown(with: event)
            return
        }

        LatencyProbe.shared.markKeystroke()

        if selection != nil { selection = nil }

        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }

        // A key that belongs to a composition never reaches the TUI, so it owes no release.
        let wasComposing = hasMarkedText()
        let imeAbsorbed = routeKeyDownThroughIME(event)
        // Only the press records: an auto-repeat carries the modifiers down NOW, which would
        // overwrite the ones the TUI was told.
        if !(wasComposing || hasMarkedText()),
           !event.isARepeat || forwardedKeyDowns[event.keyCode] == nil {
            forwardedKeyDowns[event.keyCode] = ForwardedKeyDown(
                modifiers: KeyEncoder.Modifiers(event: event),
                chars: KeyEventClassifier.normalizedReturnChars(
                    keyCode: event.keyCode,
                    chars: event.charactersIgnoringModifiers ?? event.characters ?? ""
                )
            )
        }
        if imeAbsorbed { return }

        if sendControlFastPath(event, session: session) { return }

        encodeAndSendKey(event)
    }

    /// Returns `true` when the IME absorbed the keystroke, so `keyDown` must NOT also encode it. A key
    /// arriving mid-composition is the IME's even if it ENDS the composition (Esc, Backspace).
    private func routeKeyDownThroughIME(_ event: NSEvent) -> Bool {
        didInsertTextViaIME = false
        // AppKit calls `insertText(_:replacementRange:)` with no modifier information; stash this
        // event's so that path can report Shift under kitty flags 4/8.
        pendingInsertTextModifiers = KeyEncoder.Modifiers(event: event)
        pendingInsertTextIsRepeat = event.isARepeat
        keypadCommittedText[event.keyCode] = nil
        pendingInsertTextKeypadKeyCode = KeyEventClassifier.isKeypadCharacterKey(event) ? event.keyCode : nil
        defer {
            pendingInsertTextModifiers = nil
            pendingInsertTextIsRepeat = false
            pendingInsertTextKeypadKeyCode = nil
        }
        // With Option as Meta, an Option+key chord is ESC + base char, not dead-key composition.
        let optionMetaChord = KeyEventClassifier.isOptionMetaChord(
            optionIsMeta: encoder.optionIsMeta,
            modifierFlags: event.modifierFlags
        )
        // The chords below have nothing to compose, but the input context would commit them via
        // `insertText` and bypass the encoder. A live composition still owns the key.
        let hadMarkedText = hasMarkedText()
        let isContextMenuChord = !hadMarkedText && KeyEventClassifier.isContextMenuKeyChord(
            keyCode: event.keyCode, modifierFlags: event.modifierFlags
        )
        // Under DECPAM a keypad digit / operator must reach `encodeSpecial`.
        let isApplicationKeypadKey = !hasMarkedText() && KeyEventClassifier.isApplicationKeypadKey(
            event, applicationKeypad: currentSnapshot?.termMode.contains(.appKeypad) ?? false
        )
        // With Option held the input context commits Shift+Tab's U+0019: a raw ^Y, not back-tab.
        let isBackTab = !hadMarkedText && KeyEventClassifier.isBackTab(
            keyCode: event.keyCode, chars: event.characters ?? ""
        )
        // The raw control character is committed with no modifiers: keypad Enter's U+0003 would
        // reach the PTY as Ctrl+C, Ctrl+Option chords with Ctrl / Meta dropped.
        let isNonComposableChord = !hadMarkedText && KeyEventClassifier.isNonComposableControlChord(
            keyCode: event.keyCode, modifierFlags: event.modifierFlags
        )
        if !optionMetaChord && !isContextMenuChord && !isApplicationKeypadKey && !isBackTab
            && !isNonComposableChord {
            inputContext?.handleEvent(event)
        }
        return hadMarkedText || hasMarkedText() || didInsertTextViaIME
    }

    /// With kitty disambiguate / report-all-as-esc or modifyOtherKeys active, every Ctrl combo goes
    /// through the encoder so Ctrl+i/m/[/h stay distinguishable from Tab / Enter / Esc / Backspace.
    private func sendControlFastPath(_ event: NSEvent, session: TerminalSession) -> Bool {
        guard event.modifierFlags.contains(.control) else { return false }
        // Keypad Enter's raw character is ETX (→ SIGINT); the encoder decides instead.
        if KeyEventClassifier.isEnterKey(keyCode: event.keyCode) { return false }
        // Ctrl+Shift+Tab reports U+0019 (back-tab), which is not a ^Y press.
        if KeyEventClassifier.isBackTab(
            keyCode: event.keyCode, chars: event.characters ?? ""
        ) { return false }
        #if DEBUG
        Self.keyLogger.debug("keyDown: Control modifier detected")
        #endif
        let termModeForCtrl = currentSnapshot?.termMode ?? []
        let kittyActive = termModeForCtrl.contains(.disambiguateEscCodes)
            || termModeForCtrl.contains(.reportAllKeysAsEsc)
        let modifyOther = termModeForCtrl.contains(.modifyOtherKeys)
        if kittyActive || modifyOther
            || (encoder.optionIsMeta && event.modifierFlags.contains(.option)) {
            // Encoder path. Ctrl+Option+letter in Meta mode must keep its ESC Meta prefix.
        } else if let chars = event.characters,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 1, scalar.value <= 0x1F {
            // The tty layer turns 0x03 into echo + SIGINT when ISIG is on; never kill() from here.
            // Relies on forkpty getting nil termios (PTY.swift) so the kernel's c_cc defaults apply.
            session.sendImmediate(Data([UInt8(scalar.value)]))
            return true
        }
        #if DEBUG
        Self.keyLogger.debug("keyDown: fast path didn't match, trying encoder")
        #endif
        return false
    }

    /// Kitty flag 2: a key-down with `isARepeat` is event type 2. Gated on the mode because the
    /// encoder drops every non-press event unless `reportEventTypes` is set.
    static func keyDownEventType(isRepeat: Bool, mode: BBTermMode) -> KeyEncoder.EventType {
        isRepeat && mode.contains(.reportEventTypes) ? .repeat : .press
    }

    /// An empty encoding (F13–F24, Mac system keys) forwards to `super` for the responder chain.
    private func encodeAndSendKey(_ event: NSEvent) {
        let mods = KeyEncoder.Modifiers(event: event)
        let termMode = currentSnapshot?.termMode ?? []
        let eventType = Self.keyDownEventType(isRepeat: event.isARepeat, mode: termMode)

        if let special = KeyEventClassifier.specialKey(for: event) {
            let appCursor = termMode.contains(.appCursor)
            let appKeypad = termMode.contains(.appKeypad)
            let bytes = encoder.encodeSpecial(
                special,
                modifiers: mods,
                applicationCursorKeys: appCursor,
                applicationKeypad: appKeypad,
                mode: termMode,
                eventType: eventType
            )
            if !bytes.isEmpty { sendToSession(bytes) }
            return
        }

        // `charactersIgnoringModifiers`: Meta mode wants Option+E to encode ESC "e", not ESC "´".
        let chars = KeyEventClassifier.normalizedTabChars(
            keyCode: event.keyCode,
            chars: KeyEventClassifier.normalizedReturnChars(
                keyCode: event.keyCode,
                chars: event.charactersIgnoringModifiers ?? event.characters ?? ""
            )
        )
        // Wholly private-use characters mean a function / system key with no printable form;
        // `encoder.encode(chars:)` would type the raw PUA bytes at the prompt.
        guard !KeyEventClassifier.isPrivateUseOnly(chars) else {
            super.keyDown(with: event)
            return
        }
        let bytes = encoder.encode(chars: chars, modifiers: mods, mode: termMode, eventType: eventType)
        #if DEBUG
        if !bytes.isEmpty {
            let hex = bytes.map { String(format: "0x%02x", $0) }.joined(separator: " ")
            Self.keyLogger.debug(
                "keyDown encoder produced \(bytes.count, privacy: .public) bytes: \(hex, privacy: .public)"
            )
        } else {
            Self.keyLogger.debug(
                "keyDown encoder produced empty data for chars=\(chars.debugDescription, privacy: .public) mods=\(mods.rawValue, privacy: .public)"
            )
        }
        #endif
        if !bytes.isEmpty {
            sendToSession(bytes)
            return
        }
        super.keyDown(with: event)
    }

    /// Emits bytes only under Kitty progressive-enhancement flag 2 (`reportEventTypes`).
    public override func keyUp(with event: NSEvent) {
        let press = forwardedKeyDowns.removeValue(forKey: event.keyCode)
        let committedKeypadText = keypadCommittedText.removeValue(forKey: event.keyCode)
        guard session != nil else {
            super.keyUp(with: event)
            return
        }
        let termMode = currentSnapshot?.termMode ?? []
        guard termMode.contains(.reportEventTypes) else {
            super.keyUp(with: event)
            return
        }
        // A release without a forwarded press is an app shortcut's key-up: the TUI never saw the
        // press, so it gets no release. The key-up's own `.command` flag does not decide it.
        guard let press else {
            super.keyUp(with: event)
            return
        }
        let mods = press.modifiers
        // A keypad key whose press the input context committed as layout text releases as that
        // same text; `encodeSpecial` would use the US table instead.
        if let text = committedKeypadText {
            let bytes = encoder.encode(chars: text, modifiers: mods, mode: termMode, eventType: .release)
            if !bytes.isEmpty {
                sendToSession(bytes)
            } else {
                super.keyUp(with: event)
            }
            return
        }
        if let special = KeyEventClassifier.specialKey(for: event) {
            // Kitty flag-2 release for arrows / nav / F-keys: `CSI <n> ; <mod>:3 <final>`.
            let appCursor = termMode.contains(.appCursor)
            let appKeypad = termMode.contains(.appKeypad)
            let bytes = encoder.encodeSpecial(
                special,
                modifiers: mods,
                applicationCursorKeys: appCursor,
                applicationKeypad: appKeypad,
                mode: termMode,
                eventType: .release
            )
            if !bytes.isEmpty {
                sendToSession(bytes)
            } else {
                super.keyUp(with: event)
            }
            return
        }
        let chars = KeyEventClassifier.normalizedTabChars(
            keyCode: event.keyCode,
            chars: press.chars
        )
        let bytes = encoder.encode(
            chars: chars, modifiers: mods, mode: termMode, eventType: .release
        )
        if !bytes.isEmpty {
            sendToSession(bytes)
        } else {
            super.keyUp(with: event)
        }
    }

    func discardKeyboardStateOnResignKey() {
        discardCompositionOnResignKey()
        forgetForwardedKeyDowns()
    }

    /// After focus leaves, key-ups go elsewhere; a leftover entry would pair with an unrelated later key-up.
    private func forgetForwardedKeyDowns() {
        forwardedKeyDowns.removeAll()
    }

    private static func resolveFont(name: String, size: CGFloat) -> NSFont {
        let mgr = NSFontManager.shared
        // 5 is the regular weight in the NSFontManager scale (0…15).
        if let f = mgr.font(withFamily: name, traits: [], weight: 5, size: size) {
            return f
        }
        if let f = NSFont(name: name, size: size) {
            return f
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @objc public func copy(_ sender: Any?) {
        guard let sel = selection, let session, let snap = currentSnapshot else { return }
        guard let raw = session.selectedText(sel, displayedIn: snap), !raw.isEmpty else { return }
        // Cap + scrub: a hostile remote's bidi-override / C0 payloads must not reach the system clipboard.
        let copyMax = 16 * 1024 * 1024
        // A Data slice is fine here: the sanitizers scan via withUnsafeBytes (slice-safe).
        let data = Data(raw.utf8).prefix(copyMax)
        let scrubbed = PasteSanitizer.stripBidiOverrides(
            PasteSanitizer.sanitizePasteControls(data)
        )
        var clean = String(decoding: scrubbed, as: UTF8.self)
        // The byte cap can land inside a multi-byte scalar; `String(decoding:)` then ends with U+FFFD.
        if data.count == copyMax, clean.hasSuffix("\u{FFFD}") {
            clean.removeLast()
        }
        let pb = NSPasteboard.general
        if clean.isEmpty {
            pb.clearContents()
            return
        }
        pb.clearContents()
        pb.setString(clean, forType: .string)
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard let snap = currentSnapshot else { return }
        // Buffer lines run from -historySize (oldest retained) through rows-1 (live bottom).
        let topLine    = -Int32(clamping: snap.historySize)
        let bottomLine = Int32(clamping: snap.rows - 1)
        let top = BufferPoint(line: topLine,    col: 0)
        let bot = BufferPoint(line: bottomLine, col: snap.cols - 1)
        selection = Selection(anchor: top, cursor: bot, mode: .character)
    }

    /// Kept for system-originated `performFindPanelAction:` sends.
    @objc public func performFindPanelAction(_ sender: Any?) {
        showFindBar(sender)
    }

    @objc public func showFindBar(_ sender: Any?) {
        if findController.findBar == nil { findController.installFindBar() }
        findController.findBar?.focusAndSelectQuery()
    }

    @objc public func useSelectionForFind(_ sender: Any?) {
        guard let raw = selectedStringForServices(), !raw.isEmpty else {
            bellController.ring()
            return
        }
        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let query = firstLine.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            bellController.ring()
            return
        }
        if findController.findBar == nil { findController.installFindBar() }
        findController.findBar?.setQuery(query)
        findController.findBar?.focus()
    }

    @objc public func exportScrollback(_ sender: Any?) {
        guard let session, currentSnapshot != nil, let window else {
            bellController.ring()
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(window.title.isEmpty ? "Blackbird" : window.title).txt"
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, self != nil else { return }
            // Ask for the whole buffer and let the core clamp at Save time: bounds from a menu-time
            // snapshot go stale while the sheet is up.
            let raw = session.textRange(
                from: BufferPoint(line: .min, col: 0),
                to:   BufferPoint(line: .max, col: .max),
                rectangular: false
            )
            let scrubbed = PasteSanitizer.stripBidiOverrides(
                PasteSanitizer.sanitizePasteControls(Data(raw.utf8))
            )
            do {
                try scrubbed.write(to: url, options: .atomic)
            } catch {
                Self.rendererLogger.error("exportScrollback: write failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc public func performFindNextAction(_ sender: Any?)     { findController.advanceFind(direction: .forward) }
    @objc public func performFindPreviousAction(_ sender: Any?) { findController.advanceFind(direction: .backward) }

    @objc public func toggleFindCaseSensitive(_ sender: Any?) {
        if findController.findBar == nil { findController.installFindBar() }
        findController.findBar?.toggleCaseSensitive(sender)
    }

    @objc public func toggleFindRegex(_ sender: Any?) {
        if findController.findBar == nil { findController.installFindBar() }
        findController.findBar?.toggleRegexMode(sender)
    }

    @objc public func clearBufferAndScrollback(_ sender: Any?) {
        session?.clearAll()
    }

    @objc public func increaseFontSize(_ sender: Any?) { adjustFontSizeOverride(by: +1) }

    @objc public func decreaseFontSize(_ sender: Any?) { adjustFontSizeOverride(by: -1) }

    /// Drops this view's override; deliberately does NOT touch `Preferences.shared.fontSize`.
    @objc public func resetFontSize(_ sender: Any?) {
        guard let previous = fontSizeOverride else { return }
        fontSizeOverride = nil
        if !applyEffectiveFont() {
            fontSizeOverride = previous
        }
    }

    /// An at-bound step that changes nothing must NOT materialize an override.
    private func adjustFontSizeOverride(by delta: Double) {
        let target = min(
            Preferences.fontSizeRange.upperBound,
            max(Preferences.fontSizeRange.lowerBound, effectiveFontSize + delta)
        )
        guard target != effectiveFontSize else { return }
        let previous = fontSizeOverride
        fontSizeOverride = target
        // Roll back on a failed apply: nothing re-fires for a per-view override, so it would
        // permanently disagree with the rendered metrics.
        if !applyEffectiveFont() {
            fontSizeOverride = previous
        }
    }

    public override func noResponder(for eventSelector: Selector) {
        guard !BellController.suppressed else { return }
        super.noResponder(for: eventSelector)
    }

    @objc public func jumpToPreviousPrompt(_ sender: Any?) {
        if session?.jumpToPreviousPrompt() != true {
            bellController.ring()
        }
    }

    @objc public func jumpToNextPrompt(_ sender: Any?) {
        if session?.jumpToNextPrompt() != true {
            bellController.ring()
        }
    }

    public override func magnify(with event: NSEvent) {
        wakeRenderLoop()
        pinchAccumulator += event.magnification
        while pinchAccumulator >= 0.15 {
            increaseFontSize(nil)
            pinchAccumulator -= 0.15
        }
        while pinchAccumulator <= -0.15 {
            decreaseFontSize(nil)
            pinchAccumulator += 0.15
        }
    }

    // MARK: - ⌘-click URL resolution

    /// OSC 8 wins; regex is the fallback. `screenRow` is 0-based from the top of the visible viewport.
    func resolveClickURL(screenRow: Int, col: Int) -> URL? {
        // The allowlist applies on every exit path, whatever the URL's origin.
        let allow: (URL?) -> URL? = { url in
            guard let url, OSC8URLPolicy.isAllowed(url) else { return nil }
            return url
        }
        // OSC 8 decouples the href from the visible text: block the click when the rendered anchor
        // claims a different host than the href. Regex URLs have no separate anchor.
        let acceptOSC8: (HyperlinkResolver, URL) -> URL? = { resolver, url in
            guard let allowedURL = allow(url) else { return nil }
            let anchor = resolver.osc8AnchorText(row: screenRow, col: col)
            if OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: anchor, url: allowedURL
            ) {
                Self.securityLogger.warning(
                    """
                    OSC 8 click blocked: anchor / href host mismatch \
                    (potential phishing). \
                    href=\(allowedURL.absoluteString, privacy: .public)
                    """
                )
                return nil
            }
            return allowedURL
        }
        // A blocked OSC 8 link does NOT fall through to regex: that would open the visible anchor
        // URL instead. Regex is consulted only when the cell carries no OSC 8 attribution.
        #if DEBUG
        if let override = hyperlinkResolverOverride {
            if let raw = override.osc8URL(row: screenRow, col: col) {
                return acceptOSC8(override, raw)
            }
            return allow(override.regexURL(row: screenRow, col: col))
        }
        #endif
        guard let snap = currentSnapshot else { return nil }
        let resolver = SnapshotHyperlinkResolver(
            snapshot: snap,
            regexMatches: cachedRegexMatches(for: snap)
        )
        if let raw = resolver.osc8URL(row: screenRow, col: col) {
            return acceptOSC8(resolver, raw)
        }
        return allow(resolver.regexURL(row: screenRow, col: col))
    }

    private func cachedRegexMatches(for snap: BBSnapshot) -> [URLMatch]? {
        guard hoverCoordinator.cachedURLMatchesSeq == snap.sequenceID else { return nil }
        return hoverCoordinator.cachedURLMatches
    }

    /// Non-nil only when `resolveClickURL` blocks the href for anchor/host divergence. Copy-only.
    func blockedDivergentOSC8Href(screenRow: Int, col: Int) -> URL? {
        let resolveDivergent: (HyperlinkResolver) -> URL? = { resolver in
            guard let raw = resolver.osc8URL(row: screenRow, col: col),
                  OSC8URLPolicy.isAllowed(raw) else { return nil }
            let anchor = resolver.osc8AnchorText(row: screenRow, col: col)
            return OSC8URLPolicy.anchorDivergesFromHost(anchorText: anchor, url: raw)
                ? raw : nil
        }
        #if DEBUG
        if let override = hyperlinkResolverOverride {
            return resolveDivergent(override)
        }
        #endif
        guard let snap = currentSnapshot else { return nil }
        return resolveDivergent(SnapshotHyperlinkResolver(
            snapshot: snap,
            regexMatches: cachedRegexMatches(for: snap)
        ))
    }

    // MARK: - NSAccessibility

    struct A11yCache {
        var snapshotIdentity: UnsafeRawPointer? = nil
        var value: String = ""
        var computations: Int = 0
        /// UTF-16 code-unit offset of each line's first character in `value`; the last element is
        /// `value.utf16.count`. NSAccessibility's `NSRange` API counts UTF-16 units, not graphemes.
        var lineOffsets: [Int]? = nil

        mutating func store(value: String, identity: UnsafeRawPointer?) {
            self.value = value
            self.snapshotIdentity = identity
            self.lineOffsets = nil
            self.computations += 1
        }

        mutating func invalidate() {
            self.snapshotIdentity = nil
            self.lineOffsets = nil
        }
    }

    var a11yCache = A11yCache()

    /// Main-thread only.
    var a11yValueChangedPending = false

    #if DEBUG
    static func makeHeadlessForTests() -> TerminalView? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100),
            device: device
        )
    }

    var urlOpenerForTests: URLOpener {
        get { urlOpener }
        set { urlOpener = newValue }
    }

    func installHyperlinkSnapshotForTests(
        rows: [String],
        linkAt spans: [(row: Int, cols: Range<Int>, url: String)]
    ) {
        hyperlinkResolverOverride = FakeHyperlinkSnapshot(rows: rows, spans: spans)
    }

    func performCmdClickForTests(row: Int, col: Int) {
        if let url = resolveClickURL(screenRow: row, col: col) {
            urlOpener.open(url)
        }
    }

    func setOptionIsMetaForTests(_ flag: Bool) {
        if encoder.optionIsMeta != flag {
            encoder = KeyEncoder(optionIsMeta: flag)
        }
    }

    func installCursorForTests(row: Int, col: Int) {
        cursorOverrideForTests = (row: row, col: col)
    }

    var _testOnly_currentFrameRateCap: Int {
        return self.isPaused ? 0 : self.preferredFramesPerSecond
    }

    func _testOnly_applyPowerAwareFrameRate() {
        self.applyPowerAwareFrameRate()
    }
    #endif

}

// MARK: - Modifier mapping

extension KeyEncoder.Modifiers {
    init(event: NSEvent) {
        var mods: KeyEncoder.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}

extension TerminalView: FindBarDelegate {
    public func findBar(_ bar: FindBar, didChangeQuery query: String) {
        findController.performSearch(query: query)
    }

    public func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {
        findController.advanceFind(direction: direction)
    }

    public func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {
        findController.performSearch(query: findController.findQuery)
    }

    public func findBarDidChangeHeight(_ bar: FindBar) {
        findController.barHeightDidChange()
    }

    public func findBarDidClose(_ bar: FindBar) {
        findController.findBar?.removeFromSuperview()
        findController.findBar = nil
        findController.reset()
        // `selection` is deliberately preserved so Esc-then-⌘C on a found match still copies.
        window?.makeFirstResponder(self)
    }

    public func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {
        switch kind {
        case .current: findController.replaceCurrentMatch(with: replacement)
        case .all:     findController.replaceAllMatches(with: replacement)
        }
    }

    public func findBarShouldAllowReplace(_ bar: FindBar) -> Bool {
        findController.shouldAllowReplace()
    }
}

// MARK: - Replace responder action

extension TerminalView {
    @objc public func performReplaceCurrent(_ sender: Any?) {
        if findController.findBar == nil {
            findController.installFindBar()
            findController.findBar?.setReplaceVisible(true)
            findController.findBar?.focus()
            return
        }
        guard let bar = findController.findBar else { return }
        if !bar.isReplaceVisible {
            bar.setReplaceVisible(true)
            return
        }
        bar.triggerReplaceCurrent()
    }
}
