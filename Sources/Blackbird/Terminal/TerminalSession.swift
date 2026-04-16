import Foundation
import Combine
import AppKit

/// Owns a PTY and a BBTerm. Wires PTY output into the VT parser, publishes
/// snapshots of the grid to observers.
///
/// Thread model:
/// - PTY output arrives on PTY's read queue; we dispatch into `coreQueue`.
/// - `coreQueue` is the single owner of `bbterm`.
/// - After feeding bytes, a new snapshot is taken and published on `main`.
/// - Input via `send(_:)` hops to PTY's write queue (PTY handles its own serialization).
public final class TerminalSession: ObservableObject {

    public typealias Size = PTY.Size

    @Published public private(set) var snapshot: BBSnapshot?
    @Published public private(set) var title: String?
    @Published public private(set) var bellCounter: UInt64 = 0
    /// Set once after the shell process has exited. The value is the child's
    /// exit code (-1 for abnormal termination). Observers (e.g. the window
    /// controller) close the window in response.
    @Published public private(set) var exitCode: Int32?

    private let bbterm: BBTerm
    private let pty: PTY
    private let coreQueue = DispatchQueue(label: "blackbird.core")

    public static func start(
        shell: String,
        arguments: [String],
        size: Size,
        initialWorkingDirectory: String? = nil
    ) throws -> TerminalSession {
        guard let bb = BBTerm(size: .init(cols: size.cols, rows: size.rows)) else {
            throw SessionError.coreInitFailed
        }
        let pty = try PTY.spawn(
            executable: shell,
            arguments: arguments,
            envOverrides: [:],
            size: size,
            initialWorkingDirectory: initialWorkingDirectory
        )
        return TerminalSession(bbterm: bb, pty: pty)
    }

    public enum SessionError: Error {
        case coreInitFailed
    }

    private init(bbterm: BBTerm, pty: PTY) {
        self.bbterm = bbterm
        self.pty = pty
        wire()
    }

    deinit {
        terminate()
    }

    // MARK: - Public API

    public func send(_ data: Data) {
        pty.write(data)
    }

    /// Write bytes synchronously, bypassing the async write queue. Use for
    /// urgent control characters (Ctrl+C → 0x03, Ctrl+Z → 0x1A) where the
    /// user expects instant response.
    public func sendImmediate(_ data: Data) {
        pty.writeImmediate(data)
    }

    /// Whether the shell currently has a foreground child process (anything
    /// other than the shell itself). Used to gate the confirm-close prompt.
    public func hasForegroundChild() -> Bool {
        pty.hasForegroundChild()
    }

    /// Current working directory of the foreground process — inherited by
    /// new tabs / windows created via ⌘T / ⌘N.
    public func foregroundWorkingDirectory() -> String? {
        pty.foregroundWorkingDirectory()
    }

    /// Send a POSIX signal directly to the terminal's foreground process group.
    /// More reliable than writing 0x03 for SIGINT because it bypasses the
    /// line discipline — works even if the shell changed termios (ISIG off,
    /// VINTR remapped, etc.).
    public func sendSignalToForeground(_ sig: Int32) {
        pty.sendSignalToForeground(sig)
    }

    public func resize(to size: Size) {
        // Synchronous on the caller's thread. coreQueue serializes PTY +
        // BBTerm resize (same guarantee as before) but we block the caller
        // (typically main during a window drag) so the returned snapshot is
        // already new-size when the next MTKView frame draws. Async resize
        // produced a one-frame lag that users saw as jitter — content at old
        // grid size against new viewport for ~8ms, then catching up.
        //
        // Blocking cost: a single bb_term_resize call plus snapshot, well
        // under a millisecond in practice. Safe from deadlock: coreQueue
        // never syncs back to the caller's queue.
        var newSnap: BBSnapshot?
        coreQueue.sync {
            self.pty.resize(to: size)
            self.bbterm.resize(to: .init(cols: size.cols, rows: size.rows))
            newSnap = self.bbterm.snapshot()
        }
        guard let newSnap else { return }
        if Thread.isMainThread {
            self.snapshot = newSnap
        } else {
            DispatchQueue.main.async { self.snapshot = newSnap }
        }
    }

    public func scroll(delta: Int32) {
        var snap: BBSnapshot?
        coreQueue.sync {
            bbterm.scroll(delta: delta)
            snap = bbterm.snapshot()
        }
        if let snap {
            if Thread.isMainThread {
                self.snapshot = snap
            } else {
                DispatchQueue.main.async { self.snapshot = snap }
            }
        }
    }

    /// Snap the viewport back to the live grid. Call from the input path
    /// (keystrokes, paste) so the user is never left "orphaned" in scrollback
    /// while typing. No-op if already pinned.
    public func scrollToBottom() {
        var snap: BBSnapshot?
        coreQueue.sync {
            bbterm.scrollToBottom()
            snap = bbterm.snapshot()
        }
        if let snap {
            if Thread.isMainThread {
                self.snapshot = snap
            } else {
                DispatchQueue.main.async { self.snapshot = snap }
            }
        }
    }

    /// ⌘K target — clear viewport + scrollback while preserving palette /
    /// cursor / title. Publishes a fresh snapshot so the renderer shows the
    /// empty grid on the next frame.
    public func clearAll() {
        var s: BBSnapshot?
        coreQueue.sync {
            bbterm.clearAll()
            s = bbterm.snapshot()
        }
        if let s {
            if Thread.isMainThread { snapshot = s }
            else { DispatchQueue.main.async { self.snapshot = s } }
        }
    }

    /// Push a full palette into the Rust term + publish a fresh snapshot so
    /// cells re-color on the next draw. Serialized through `coreQueue`.
    public func applyPalette(_ palette: ThemePalette) {
        var newSnap: BBSnapshot?
        coreQueue.sync {
            for (i, c) in palette.ansi.enumerated() {
                bbterm.setColor(slot: i, rgb: c)
            }
            // NamedColor layout in alacritty 0.26:
            //   256 = Foreground, 257 = Background, 258 = Cursor
            bbterm.setColor(slot: 256, rgb: palette.foreground)
            bbterm.setColor(slot: 257, rgb: palette.background)
            bbterm.setColor(slot: 258, rgb: palette.cursor)
            newSnap = bbterm.snapshot()
        }
        guard let newSnap else { return }
        if Thread.isMainThread { snapshot = newSnap }
        else { DispatchQueue.main.async { self.snapshot = newSnap } }
    }

    /// Extract text between two buffer points. Serialized through the core
    /// queue so the grid can't mutate mid-read (same discipline as other
    /// `bbterm.*` accessors).
    public func textRange(from start: BufferPoint, to end: BufferPoint, rectangular: Bool) -> String {
        var out = ""
        coreQueue.sync {
            out = bbterm.textRange(
                startLine: start.line, startCol: start.col,
                endLine: end.line, endCol: end.col,
                rectangular: rectangular
            ) ?? ""
        }
        return out
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Wiring

    private func wire() {
        // Route PTY bytes -> core queue -> bbterm -> publish snapshot.
        pty.onBytes = { [weak self] data in
            guard let self else { return }
            self.coreQueue.async {
                self.feed(data)
            }
        }

        // When the child exits (natural or SIGHUP), publish the exit code.
        pty.onExit = { [weak self] code in
            self?.exitCode = code
        }

        // Route bbterm events (title/bell/fatal) to published properties.
        bbterm.onEvent { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async {
                switch event {
                case .title(let t):
                    self.title = t
                case .bell:
                    self.bellCounter &+= 1
                case .ptyWrite(let data):
                    // Terminal-to-shell response (DSR, DA1, DA2, etc). Write
                    // the bytes back to the PTY so the querying app receives
                    // the answer. Without this, nvim and other apps time out
                    // waiting for terminal identification.
                    self.send(data)
                case .osc52Clipboard(let raw):
                    // OSC 52 payload is "<target>;<base64>"; target chars
                    // are a subset of c,p,q,s,0-7. Strip everything up to
                    // the first ';' and base64-decode the rest. Silently
                    // drop when the pref is off, when the payload is a
                    // read request ("?"), or when decoding fails — a
                    // misbehaving remote shouldn't stuff arbitrary bytes
                    // into the user's clipboard or crash the session.
                    guard Preferences.shared.osc52Enabled else { break }
                    guard let sep = raw.firstIndex(of: ";") else { break }
                    let b64 = String(raw[raw.index(after: sep)...])
                    if b64 == "?" { break }
                    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                          let text = String(data: data, encoding: .utf8) else {
                        break
                    }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                case .cursorShape:
                    break  // Plan 5/3 will surface cursor shape.
                case .fatal(let msg):
                    // Surface as a title prefix for visibility; Plan 7 adds a
                    // dedicated diagnostics channel.
                    self.title = "[fatal] core panic: \(msg)"
                }
            }
        }

        // Take an initial snapshot so observers have something on screen.
        coreQueue.async { [weak self] in
            guard let self else { return }
            if let snap = self.bbterm.snapshot() {
                DispatchQueue.main.async {
                    self.snapshot = snap
                }
            }
        }
    }

    /// Called on `coreQueue`.
    private func feed(_ data: Data) {
        let bytes = [UInt8](data)
        bbterm.input(bytes)
        if let snap = bbterm.snapshot() {
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = snap
            }
        }
    }
}
