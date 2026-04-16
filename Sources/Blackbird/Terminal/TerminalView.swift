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
    public let metrics: CellMetrics
    public let encoder = KeyEncoder()

    private var currentSnapshot: BBSnapshot?
    private var cancellables: [AnyCancellable] = []

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
        self.preferredFramesPerSecond = 120
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

    private func propagateResize() {
        guard let session else { return }
        let grid = metrics.grid(forPixelSize: bounds.size)
        guard grid.cols > 0, grid.rows > 0 else { return }
        let size = PTY.Size(cols: UInt16(grid.cols), rows: UInt16(grid.rows))
        guard size != lastPropagatedSize else { return }
        lastPropagatedSize = size
        // TerminalSession.resize is synchronous — returns after the snapshot
        // is in place so the next MTKView frame renders at the new size.
        session.resize(to: size)
    }

    // MARK: - Rendering

    public func render(snapshot: BBSnapshot) {
        self.currentSnapshot = snapshot
        // MTKView redraws on CADisplayLink cadence; no needsDisplay needed.
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
        renderer.render(in: view, snapshot: currentSnapshot, focused: focused)
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
                self.window?.title = title ?? "Blackbird"
            }
        }.store(in: &cancellables)
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
                // Write the control byte to the PTY master. The line
                // discipline handles the rest — IF it's configured to.
                session.sendImmediate(Data([UInt8(scalar.value)]))
                // For Ctrl+C / Ctrl+Z, also force-signal the foreground
                // pgroup ONLY when the line discipline has ISIG enabled
                // (shell at prompt, `sleep 100`, cmatrix in cooked-ish
                // mode). When ISIG is off — the foreground app has put the
                // tty in raw mode (nvim, tmux, htop, claude-code) — we must
                // NOT also kill(), or nvim reports "Caught deadly signal"
                // and exits instead of handling Ctrl+C internally (cancel
                // current op / close buffer prompt).
                //
                // The ISIG query reads termios from the master fd, which
                // reflects whatever the slave app last set. This is cheap
                // (one tcgetattr per Ctrl keystroke) and robust against
                // apps toggling raw mode mid-session.
                if (scalar.value == 0x03 || scalar.value == 0x1A) &&
                   session.isISIGEnabled() {
                    let sig: Int32 = (scalar.value == 0x03) ? SIGINT : SIGTSTP
                    session.sendSignalToForeground(sig)
                }
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

    // MARK: - Mouse reporting

    private func mouseReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseReportClick) || mode.contains(.mouseMotion) || mode.contains(.mouseDrag)
    }

    private func sgrMouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.sgrMouse) ?? false
    }

    public override func mouseDown(with event: NSEvent) {
        guard mouseReportingEnabled(), let session else { super.mouseDown(with: event); return }
        sendMouseEvent(event, button: 0, press: true, session: session)
    }

    public override func mouseUp(with event: NSEvent) {
        guard mouseReportingEnabled(), let session else { super.mouseUp(with: event); return }
        sendMouseEvent(event, button: 0, press: false, session: session)
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
            let lines = Int32(event.scrollingDeltaY / 3.0)  // convert pixels to ~lines
            if lines != 0 {
                session.scroll(delta: lines)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let mode = currentSnapshot?.termMode,
              (mode.contains(.mouseMotion) || mode.contains(.mouseDrag)),
              let session else { super.mouseDragged(with: event); return }
        sendMouseEvent(event, button: 32, press: true, session: session)
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
