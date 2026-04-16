import AppKit
import CoreText
import Combine
import Metal
import MetalKit

/// Fixed-cell metrics derived from a monospaced font.
public struct CellMetrics {
    public let font: NSFont
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(font: NSFont) {
        self.font = font
        let ct = font as CTFont
        self.ascent = CTFontGetAscent(ct)
        self.descent = CTFontGetDescent(ct)
        self.leading = CTFontGetLeading(ct)
        self.cellHeight = (ascent + descent + leading).rounded()
        // Measure the advance of 'M' — a reliable monospace cell width.
        var glyph = CGGlyph(0)
        var chars: [UniChar] = [UInt16(("M" as Character).asciiValue ?? 77)]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        self.cellWidth = advance.width.rounded()
    }

    public func grid(forPixelSize size: CGSize) -> (cols: Int, rows: Int) {
        let cols = max(1, Int(size.width / cellWidth))
        let rows = max(1, Int(size.height / cellHeight))
        return (cols, rows)
    }
}

/// MTKView that renders a BBSnapshot via Metal and forwards keyboard input
/// through a KeyEncoder to a TerminalSession.
///
/// Plan 3 Task 1: clears to solid black via MetalRenderer. Task 2+ adds
/// shader pipeline, glyph atlas, and per-cell instancing for 120Hz performance.
public final class TerminalView: MTKView, MTKViewDelegate {

    public weak var session: TerminalSession? {
        didSet { subscribeToSession() }
    }

    public let renderer: MetalRenderer
    public private(set) var metrics: CellMetrics
    public let encoder = KeyEncoder()

    private var prefsCancellable: AnyCancellable?

    private var currentSnapshot: BBSnapshot?
    private var cancellables: [AnyCancellable] = []
    private let scrollIndicator = ScrollIndicator(frame: .zero)

    private final class FlashView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let bellFlashView: FlashView = {
        let v = FlashView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.alphaValue = 0
        return v
    }()
    private var lastBellCounter: UInt64 = 0

    public private(set) var selection: Selection? {
        didSet {
            if oldValue != selection { setNeedsDisplay(bounds) }
        }
    }
    private var isDragging = false

    private var findBar: FindBar?
    private var findMatches: [(line: Int32, startCol: Int, endCol: Int)] = []
    private var findCurrentIndex: Int = 0
    private var findQuery: String = ""

    #if DEBUG
    private var frameCount = 0
    private var lastFrameLogTime = Date()
    #endif

    public init(frame frameRect: NSRect, device: MTLDevice) {
        // TerminalView is the authoritative owner of CellMetrics; the renderer
        // shares this same instance so layout and rendering never diverge.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        // The atlas rasterizes glyphs at pixel resolution for sharp text on
        // Retina displays. Use the primary screen's scale at construction;
        // if the window later moves to a display with a different scale the
        // atlas will still render correctly (linear filtering covers mild
        // upsampling), just without re-rasterizing at the new resolution.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let renderer = MetalRenderer(device: device, metrics: metrics, scale: scale) else {
            fatalError("Metal device could not produce a command queue")
        }
        self.renderer = renderer
        self.metrics = metrics
        super.init(frame: frameRect, device: device)
        self.delegate = self
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Must match the render pipeline's colorAttachments[0].pixelFormat
        // set up by MetalRenderer (Task 2+).
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        // Upper-bound the redraw rate. CVDisplayLink syncs to the display's
        // vblank, so this effectively becomes "whatever the screen supports":
        // 60 Hz on a standard Retina, 120 Hz on a ProMotion MacBook or Studio
        // Display. Moving the window between displays is handled by the OS —
        // the link reattaches to the new screen automatically. The observer
        // below (viewDidMoveToWindow) is just belt-and-suspenders logging.
        self.preferredFramesPerSecond = 120
        // Opt in to triple-buffered presentation. On ProMotion displays this
        // signals "high-framerate workload" so macOS's adaptive refresh
        // promotes the display to 120 Hz while we're the frontmost window
        // (inactive apps still throttle to 60 Hz for battery — that's
        // intentional OS-level behavior and not something we should fight).
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 3
            metalLayer.displaySyncEnabled = true
        }

        // Minimal right-edge scroll indicator (pass-through hit testing —
        // never swallows mouse events). Positioned in layout() so it tracks
        // the bottom inset shared with the grid.
        addSubview(scrollIndicator)

        bellFlashView.frame = bounds
        bellFlashView.autoresizingMask = [.width, .height]
        addSubview(bellFlashView)

        prefsCancellable = Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncFontFromPreferences() }
            }
    }

    /// Rebuild metrics/atlas when Preferences.fontName or fontSize changes.
    /// Called on every objectWillChange emission; compares against the
    /// currently-applied font to avoid redundant atlas rebuilds.
    private func syncFontFromPreferences() {
        let p = Preferences.shared
        let wantName = p.fontName
        let wantSize = CGFloat(p.fontSize)
        if metrics.font.familyName == wantName && metrics.font.pointSize == wantSize {
            return
        }
        let newFont: NSFont
        if let f = NSFont(name: wantName, size: wantSize) {
            newFont = f
        } else {
            newFont = .monospacedSystemFont(ofSize: wantSize, weight: .regular)
        }
        let newMetrics = CellMetrics(font: newFont)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.metrics = newMetrics
        renderer.reconfigure(metrics: newMetrics, scale: scale)
        // Window resize increments should follow the new cell size too.
        window?.contentResizeIncrements = NSSize(
            width: newMetrics.cellWidth,
            height: newMetrics.cellHeight
        )
        // Force a grid recomputation on the next layout — propagateResize
        // compares against lastPropagatedSize, so clear it.
        lastPropagatedSize = nil
        propagateResize()
        // Re-layout the scroll indicator (its Y depends on cellHeight).
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let inset = Self.bottomContentInsetPoints
        let width: CGFloat = 10
        scrollIndicator.frame = NSRect(
            x: bounds.width - width,
            y: inset,
            width: width,
            height: max(0, bounds.height - inset)
        )
    }

    public required init(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Drag ended — commit the real grid size now. The renderer's stretched
        // viewport (used during drag) flips back to the bounds-based viewport
        // on the next frame, and the shell gets a single SIGWINCH to the
        // final dimensions.
        propagateResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // propagateResize is a no-op during live resize; content stretches via
        // the renderer's in-drag viewport until viewDidEndLiveResize fires.
        // Outside live resize (programmatic set, zoom button, window first
        // appears), this is where the session learns the current size.
        propagateResize()
    }

    private var lastPropagatedSize: PTY.Size?

    /// Space reserved at the bottom of the view so the last grid row never
    /// runs into the window's rounded corner. macOS window corner radius is
    /// ~10 pt; keep the bottom row one cell-height above so descenders and
    /// block cursors clear comfortably. Matches the feel of Terminal.app and
    /// iTerm2, which both leave breathing room below the prompt.
    public static let bottomContentInsetPoints: CGFloat = 10

    private func propagateResize() {
        guard let session else { return }
        let usableHeight = max(metrics.cellHeight, bounds.height - Self.bottomContentInsetPoints)
        let grid = metrics.grid(forPixelSize: CGSize(width: bounds.width, height: usableHeight))
        guard grid.cols > 0, grid.rows > 0 else { return }
        let size = PTY.Size(cols: UInt16(grid.cols), rows: UInt16(grid.rows))
        guard size != lastPropagatedSize else { return }
        lastPropagatedSize = size
        // TerminalSession.resize is synchronous — returns after the snapshot
        // is in place so the next MTKView frame renders at the new size.
        session.resize(to: size)
    }

    // MARK: - Rendering

    public func applyTheme(_ palette: ThemePalette) {
        let bgR = Double((palette.background >> 16) & 0xFF) / 255.0
        let bgG = Double((palette.background >> 8)  & 0xFF) / 255.0
        let bgB = Double(palette.background & 0xFF) / 255.0
        clearColor = MTLClearColor(red: bgR, green: bgG, blue: bgB, alpha: 1)
        renderer.setCursorColor(rgb: palette.cursor)
    }

    public func render(snapshot: BBSnapshot) {
        self.currentSnapshot = snapshot
        // MTKView redraws on CADisplayLink cadence; no needsDisplay needed.
        // Scroll indicator consumes the same snapshot — keep it in lockstep
        // with the grid so a sudden `clear` or big output reshapes the thumb
        // on the frame the viewport itself changes.
        scrollIndicator.update(
            displayOffset: snapshot.displayOffset,
            historySize: snapshot.historySize,
            rows: snapshot.rows
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if DEBUG
        if let screen = window?.screen {
            // On macOS, `maximumFramesPerSecond` reflects the screen's native
            // refresh rate (60 on standard displays, 120 on ProMotion). The
            // OS clamps our preferred rate to this automatically via the
            // internal CVDisplayLink, so no manual retarget is needed — this
            // is just so the DEBUG fps log can be sanity-checked against the
            // expected ceiling.
            let maxFPS = screen.maximumFramesPerSecond
            NSLog("[Blackbird] attached to screen '%@' @ %d Hz max",
                  screen.localizedName, maxFPS)
        }
        #endif
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Intentionally empty: setFrameSize + viewDidEndLiveResize already
        // cover the points-based resize path. Adding a PTY resize here would
        // double-fire SIGWINCH on every non-live resize (zoom button, etc).
        // This hook remains for future per-pixel tracking (e.g., Retina
        // scale-factor changes) but doesn't drive the grid geometry today.
    }

    public func draw(in view: MTKView) {
        let focused = window?.isKeyWindow ?? false
        renderer.render(in: view, snapshot: currentSnapshot, focused: focused, selection: selection)
        #if DEBUG
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastFrameLogTime) >= 1.0 {
            NSLog("[Blackbird] %d fps", frameCount)
            frameCount = 0
            lastFrameLogTime = now
        }
        #endif
    }

    // MARK: - Session observation

    private func subscribeToSession() {
        cancellables.removeAll()
        guard let session else { return }

        session.$snapshot.sink { [weak self] snap in
            guard let self, let snap else { return }
            DispatchQueue.main.async {
                self.render(snapshot: snap)
            }
        }.store(in: &cancellables)

        session.$title.sink { [weak self] title in
            guard let self else { return }
            DispatchQueue.main.async {
                // Tab labels in AppKit's native tab group mirror window.title,
                // so one write covers both the titlebar and the tab. When the
                // shell hasn't emitted OSC 0/2 yet (stock zsh/bash until the
                // user configures precmd), fall back to the session's default
                // (shell basename) set by MainWindowController.
                let fallback = self.window?.title ?? "Blackbird"
                let useTitle = title?.isEmpty == false ? title : fallback
                self.window?.title = useTitle ?? "Blackbird"
            }
        }.store(in: &cancellables)

        session.$bellCounter.sink { [weak self] counter in
            guard let self else { return }
            guard counter > self.lastBellCounter else { return }
            self.lastBellCounter = counter
            DispatchQueue.main.async { self.flashBell() }
        }.store(in: &cancellables)
    }

    private func flashBell() {
        guard Preferences.shared.bell == .visual else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            bellFlashView.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self?.bellFlashView.animator().alphaValue = 0
            }
        }
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        #if DEBUG
        NSLog("[Blackbird] keyDown: keyCode=%d flags=0x%lx chars=%@ charsIgnoring=%@",
              event.keyCode,
              UInt(event.modifierFlags.rawValue),
              event.characters?.debugDescription ?? "nil",
              event.charactersIgnoringModifiers?.debugDescription ?? "nil")
        #endif

        // ⌘-prefixed events never encode into PTY bytes. They're reserved for
        // application-level shortcuts (menu items, window management). This
        // enforces the spec's ⌘C/⌃C strict separation: ⌃C always sends 0x03
        // (via KeyEncoder's control path), ⌘C is never re-encoded as 'c'.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        guard let session else {
            NSLog("[Blackbird] keyDown: no session, passing to super")
            super.keyDown(with: event)
            return
        }

        // Any shell-bound keystroke also cancels an active selection.
        if selection != nil { selection = nil }

        // Any non-⌘ keystroke represents user input headed for the shell, so
        // snap the viewport back to the live grid first. Users reading
        // scrollback get pulled back to the prompt the moment they type —
        // matching Terminal.app and iTerm2. No-op when already at bottom.
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }

        // Fast path for control characters: macOS translates Ctrl+letter into
        // the corresponding control byte (0x01-0x1A) in event.characters.
        // Send that byte directly to the PTY without round-tripping through
        // the encoder. This is the most reliable path for Ctrl+C (0x03),
        // Ctrl+D (0x04), Ctrl+Z (0x1A), etc.
        if event.modifierFlags.contains(.control) {
            #if DEBUG
            NSLog("[Blackbird] keyDown: Control modifier detected")
            #endif
            if let chars = event.characters,
               let scalar = chars.unicodeScalars.first,
               scalar.value >= 1, scalar.value <= 0x1F {
                // Synchronous write so there's no perceptible latency before
                // the line discipline sees the byte. From here the kernel
                // does exactly the right thing — without any kill() from us:
                //
                //   ISIG on  (shell prompt, `sleep 100`, cmatrix cbreak):
                //     0x03 matches c_cc[VINTR] → echo `^C\n` (ECHOCTL) →
                //     SIGINT to fg pgroup → shell/sleep handles, prints the
                //     new prompt on the next line. Order is correct because
                //     the echo and the signal come from the same code path
                //     inside the tty layer.
                //
                //   ISIG off (nvim, tmux, htop — apps in raw mode):
                //     byte passes through to the app's stdin untouched. The
                //     app handles Ctrl+C internally (cancel op, close prompt)
                //     instead of dying from a "deadly signal".
                //
                // Getting VINTR/VSUSP/VEOF/VERASE right required passing nil
                // termios to forkpty (see PTY.swift) so the kernel's
                // TTYDEF_* defaults apply. Without that, c_cc was all-zeros
                // and Ctrl+C was just data.
                session.sendImmediate(Data([UInt8(scalar.value)]))
                return
            }
            // Fast path didn't match — fall through to encoder which also
            // handles Ctrl via controlByte().
            #if DEBUG
            NSLog("[Blackbird] keyDown: fast path didn't match, trying encoder")
            #endif
        }

        let mods = KeyEncoder.Modifiers(event: event)

        if let special = Self.specialKey(for: event) {
            let appCursor = currentSnapshot?.termMode.contains(.appCursor) ?? false
            let bytes = encoder.encodeSpecial(special, modifiers: mods, applicationCursorKeys: appCursor)
            if !bytes.isEmpty { session.send(bytes) }
            return
        }

        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let bytes = encoder.encode(chars: chars, modifiers: mods)
        #if DEBUG
        if !bytes.isEmpty {
            NSLog("[Blackbird] keyDown: encoder produced %d bytes: %@",
                  bytes.count,
                  bytes.map { String(format: "0x%02x", $0) }.joined(separator: " "))
        } else {
            NSLog("[Blackbird] keyDown: encoder produced empty data for chars=%@ mods=%d",
                  chars.debugDescription, mods.rawValue)
        }
        #endif
        if !bytes.isEmpty { session.send(bytes) }
    }

    private static func specialKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        let key = event.specialKey
        switch key {
        case NSEvent.SpecialKey.upArrow:    return .up
        case NSEvent.SpecialKey.downArrow:  return .down
        case NSEvent.SpecialKey.leftArrow:  return .left
        case NSEvent.SpecialKey.rightArrow: return .right
        case NSEvent.SpecialKey.home:       return .home
        case NSEvent.SpecialKey.end:        return .end
        case NSEvent.SpecialKey.pageUp:     return .pageUp
        case NSEvent.SpecialKey.pageDown:   return .pageDown
        // NSEvent.SpecialKey.delete is the Backspace key. We intentionally do
        // NOT map it to SpecialKey.delete (CSI 3 ~) — Backspace must send the
        // DEL byte (0x7F), which the char-based path produces naturally from
        // event.charactersIgnoringModifiers. Only forward-delete maps here.
        case NSEvent.SpecialKey.deleteForward: return .delete
        case NSEvent.SpecialKey.f1:  return .f1
        case NSEvent.SpecialKey.f2:  return .f2
        case NSEvent.SpecialKey.f3:  return .f3
        case NSEvent.SpecialKey.f4:  return .f4
        case NSEvent.SpecialKey.f5:  return .f5
        case NSEvent.SpecialKey.f6:  return .f6
        case NSEvent.SpecialKey.f7:  return .f7
        case NSEvent.SpecialKey.f8:  return .f8
        case NSEvent.SpecialKey.f9:  return .f9
        case NSEvent.SpecialKey.f10: return .f10
        case NSEvent.SpecialKey.f11: return .f11
        case NSEvent.SpecialKey.f12: return .f12
        default: return nil
        }
    }

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let session else { return }
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }
        let bytes = Data(str.utf8)
        let bracketedPaste = currentSnapshot?.termMode.contains(.bracketedPaste) ?? false
        if bracketedPaste {
            var wrapped = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC[200~
            wrapped.append(bytes)
            wrapped.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))  // ESC[201~
            session.send(wrapped)
        } else {
            session.send(bytes)
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let sel = selection, let session else { return }
        let (a, b) = sel.normalized
        let text = session.textRange(from: a, to: b, rectangular: sel.mode == .rectangular)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard let snap = currentSnapshot else { return }
        // "All visible" = top row of the current viewport through bottom row.
        // Buffer line for the top of the viewport is -displayOffset.
        let topLine    = -Int32(snap.displayOffset)
        let bottomLine = Int32(snap.rows - 1) - Int32(snap.displayOffset)
        let top = BufferPoint(line: topLine,    col: 0)
        let bot = BufferPoint(line: bottomLine, col: snap.cols - 1)
        selection = Selection(anchor: top, cursor: bot, mode: .character)
    }

    @objc public func performFindPanelAction(_ sender: Any?) {
        // Cocoa's Edit > Find submenu maps ⌘F to this selector.
        if findBar == nil { installFindBar() }
        findBar?.focus()
    }

    @objc public func performFindNextAction(_ sender: Any?)     { advanceFind(direction: .forward) }
    @objc public func performFindPreviousAction(_ sender: Any?) { advanceFind(direction: .backward) }

    @objc public func clearBufferAndScrollback(_ sender: Any?) {
        session?.clearAll()
    }

    @objc public func increaseFontSize(_ sender: Any?) {
        let p = Preferences.shared
        p.fontSize = min(32, p.fontSize + 1)
    }

    @objc public func decreaseFontSize(_ sender: Any?) {
        let p = Preferences.shared
        p.fontSize = max(9, p.fontSize - 1)
    }

    @objc public func resetFontSize(_ sender: Any?) {
        Preferences.shared.fontSize = 13
    }

    private func installFindBar() {
        let h: CGFloat = 32
        let bar = FindBar(frame: NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.delegate = self
        addSubview(bar)
        findBar = bar
    }

    fileprivate func advanceFind(direction: FindBar.Direction) {
        guard !findMatches.isEmpty else { return }
        switch direction {
        case .forward:  findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        case .backward: findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    fileprivate func performSearch(query: String) {
        findQuery = query
        findMatches.removeAll()
        findCurrentIndex = 0
        guard let session, let snap = currentSnapshot, !query.isEmpty else {
            findBar?.setMatchCount(0, of: 0)
            selection = nil
            return
        }
        // Search the entire retained buffer: from -historySize through rows-1.
        // textRange clamps out-of-range lines itself.
        let topLine: Int32 = -Int32(snap.historySize)
        let bottomLine = Int32(snap.rows - 1)
        if topLine > bottomLine { return }
        for ln in topLine...bottomLine {
            let hay = session.textRange(
                from: BufferPoint(line: ln, col: 0),
                to:   BufferPoint(line: ln, col: snap.cols - 1),
                rectangular: false
            )
            guard !hay.isEmpty else { continue }
            var cursor = hay.startIndex
            while let r = hay.range(of: query, options: [.caseInsensitive], range: cursor..<hay.endIndex) {
                let startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                let endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                findMatches.append((line: ln, startCol: startCol, endCol: endCol))
                cursor = r.upperBound
            }
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    private func highlightCurrentMatch() {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
        selection = Selection(
            anchor: BufferPoint(line: m.line, col: m.startCol),
            cursor: BufferPoint(line: m.line, col: m.endCol),
            mode: .character
        )
        // Scroll the match into view. displayOffset is how many lines
        // the viewport is above the live grid; positive delta to scroll()
        // means "show older content" (upward).
        guard let snap = currentSnapshot else { return }
        let displayRowForMatch = Int(m.line) + snap.displayOffset
        if displayRowForMatch < 0 {
            session?.scroll(delta: Int32(-displayRowForMatch))
        } else if displayRowForMatch >= snap.rows {
            session?.scroll(delta: Int32(snap.rows - 1 - displayRowForMatch))
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):                      return selection != nil
        case #selector(selectAll(_:)):                 return currentSnapshot != nil
        case #selector(paste(_:)):                     return NSPasteboard.general.string(forType: .string) != nil
        case #selector(performFindPanelAction(_:)):    return currentSnapshot != nil
        case #selector(performFindNextAction(_:)):     return !findMatches.isEmpty
        case #selector(performFindPreviousAction(_:)): return !findMatches.isEmpty
        case #selector(clearBufferAndScrollback(_:)):  return session != nil
        case #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)): return session != nil
        default:                                       return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        copyItem.target = self
        pasteItem.target = self
        m.addItem(copyItem)
        m.addItem(pasteItem)
        return m
    }

    // MARK: - Mouse reporting

    private func mouseReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseReportClick) || mode.contains(.mouseMotion) || mode.contains(.mouseDrag)
    }

    private func sgrMouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.sgrMouse) ?? false
    }

    public override func mouseDown(with event: NSEvent) {
        // ⌘-click on a URL → open it. Runs before mouse-reporting and
        // selection so TUIs can't swallow the gesture. Restricted to
        // non-mouse-reporting context (or ⌥-held inside a TUI) so that
        // vim's own <C-click> binding still works when the TUI asks for
        // the click.
        //
        // If no URL is under the click, ⌘-drag acts like a titlebar drag
        // and moves the window (matches iTerm2 "⌘-drag to move"). Any view
        // can initiate window drag by calling `performDrag(with:)`; the
        // call blocks until the mouse is released, so this returns cleanly
        // without triggering the selection path below.
        if event.modifierFlags.contains(.command) {
            let underlyingOption = event.modifierFlags.contains(.option)
            if !mouseReportingEnabled() || underlyingOption,
               let snap = currentSnapshot {
                let p = bufferPointFromEvent(event)
                if let m = URLDetector.match(
                    at: p,
                    in: URLDetector.scan(snapshot: snap)
                ) {
                    NSWorkspace.shared.open(m.url)
                    return
                }
            }
            // No URL under the click — treat as window drag.
            window?.performDrag(with: event)
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: true, session: session)
            return
        }
        let point = bufferPointFromEvent(event)
        let mode: Selection.Mode
        switch event.clickCount {
        case 3: mode = .line
        case 2: mode = .word
        default:
            mode = event.modifierFlags.contains(.command) ? .rectangular : .character
        }
        selection = Selection(anchor: point, cursor: point, mode: mode)
        isDragging = true
        if mode == .word || mode == .line {
            expandSelectionUnderAnchor()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            // Collapse a zero-width char-mode selection so the overlay
            // doesn't show a 1-cell highlight from a stray click.
            if let s = selection, s.anchor == s.cursor, s.mode == .character {
                selection = nil
            }
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: false, session: session)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard mouseReportingEnabled(), let session else { super.rightMouseDown(with: event); return }
        sendMouseEvent(event, button: 2, press: true, session: session)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard mouseReportingEnabled(), let session else { super.rightMouseUp(with: event); return }
        sendMouseEvent(event, button: 2, press: false, session: session)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let session else { super.scrollWheel(with: event); return }
        if mouseReportingEnabled() {
            // Mouse mode: forward as SGR/X10 scroll events.
            // Wheel up = button 64, wheel down = button 65.
            if event.scrollingDeltaY > 0 {
                sendMouseEvent(event, button: 64, press: true, session: session)
            } else if event.scrollingDeltaY < 0 {
                sendMouseEvent(event, button: 65, press: true, session: session)
            }
        } else {
            // Normal mode: scroll the display through scrollback history.
            // Two input types to reconcile:
            //
            //   Trackpad / Magic Mouse (hasPreciseScrollingDeltas == true):
            //     scrollingDeltaY is in points. Scaling by cellHeight gives
            //     pixel-accurate scrolling (move the pointer one row's worth
            //     of points → scroll one row). Multiply by 2 so a casual
            //     two-finger flick covers ~2 screenfuls, matching Terminal.app
            //     feel.
            //
            //   Classic wheel (hasPreciseScrollingDeltas == false):
            //     scrollingDeltaY is ~1 per physical click. 3 lines per click
            //     is the common terminal-emulator default (alacritty, kitty).
            //
            // Rounding away from zero ensures tiny trackpad flicks register
            // at least one line instead of truncating to 0.
            let delta = event.scrollingDeltaY
            let raw: Double = event.hasPreciseScrollingDeltas
                ? Double(delta) / Double(metrics.cellHeight) * 2.0
                : Double(delta) * 3.0
            let lines = Int32(raw.rounded(.toNearestOrAwayFromZero))
            if lines != 0 {
                session.scroll(delta: lines)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDragging, var sel = selection {
            // Autoscroll when dragging past the viewport edges so the user
            // can select into scrollback / future output.
            let local = convert(event.locationInWindow, from: nil)
            if local.y > bounds.height - metrics.cellHeight {
                session?.scroll(delta: -1)
            } else if local.y < metrics.cellHeight {
                session?.scroll(delta: 1)
            }
            sel.cursor = bufferPointFromEvent(event)
            selection = sel
            return
        }
        // No selection in progress — forward to PTY if the app asked for
        // motion/drag reporting.
        if let mode = currentSnapshot?.termMode,
           (mode.contains(.mouseMotion) || mode.contains(.mouseDrag)),
           let session {
            sendMouseEvent(event, button: 32, press: true, session: session)
        }
    }

    private func bufferPointFromEvent(_ event: NSEvent) -> BufferPoint {
        let local = convert(event.locationInWindow, from: nil)
        let snap = currentSnapshot
        return bufferPoint(
            forView: local,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            viewportHeight: bounds.height,
            displayOffset: snap?.displayOffset ?? 0,
            cols: snap?.cols ?? 80,
            rows: snap?.rows ?? 24
        )
    }

    /// Grow the current `.word` or `.line` selection outward from `anchor`.
    /// `.word` uses the shared `wordRange(around:in:displayOffset:)` helper;
    /// `.line` selects the entire grid line.
    private func expandSelectionUnderAnchor() {
        guard var sel = selection, let snap = currentSnapshot else { return }
        switch sel.mode {
        case .word:
            if let (a, b) = wordRange(around: sel.anchor, in: snap, displayOffset: snap.displayOffset) {
                sel.anchor = a
                sel.cursor = b
                selection = sel
            }
        case .line:
            sel.anchor = BufferPoint(line: sel.anchor.line, col: 0)
            sel.cursor = BufferPoint(line: sel.cursor.line, col: snap.cols - 1)
            selection = sel
        default:
            break
        }
    }

    private func sendMouseEvent(_ event: NSEvent, button: Int, press: Bool, session: TerminalSession) {
        let loc = convert(event.locationInWindow, from: nil)
        let col = max(0, Int(loc.x / metrics.cellWidth))
        let row = max(0, Int((bounds.height - loc.y) / metrics.cellHeight))
        if sgrMouseEnabled() {
            // SGR 1006: ESC [ < button ; col+1 ; row+1 M/m
            let finalChar: Character = press ? "M" : "m"
            let seq = "\u{1B}[<\(button);\(col + 1);\(row + 1)\(finalChar)"
            session.send(Data(seq.utf8))
        } else {
            // X10/normal: ESC [ M cb cx cy (6-byte, limited to 223 cols/rows).
            guard col < 223, row < 223 else { return }
            let cb = UInt8(button + 32)
            let cx = UInt8(col + 33)
            let cy = UInt8(row + 33)
            session.send(Data([0x1B, 0x5B, 0x4D, cb, cx, cy]))
        }
    }
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
        performSearch(query: query)
    }

    public func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {
        advanceFind(direction: direction)
    }

    public func findBarDidClose(_ bar: FindBar) {
        findBar?.removeFromSuperview()
        findBar = nil
        selection = nil
        window?.makeFirstResponder(self)
    }
}
