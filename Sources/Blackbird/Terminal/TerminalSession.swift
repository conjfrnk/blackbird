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
    /// Effective, observable title for UI binding. Always equals `displayTitle`
    /// — republished whenever the shell emits OSC 0/2 or the user changes
    /// `titleOverride`, so Combine subscribers (e.g., `TerminalView` → `window.title`)
    /// pick up both sources.
    @Published public private(set) var title: String?
    @Published public private(set) var bellCounter: UInt64 = 0
    /// Set once after the shell process has exited. The value is the child's
    /// exit code (-1 for abnormal termination). Observers (e.g. the window
    /// controller) close the window in response.
    @Published public private(set) var exitCode: Int32?

    /// Last working directory reported by the shell via OSC 7. Consumed by
    /// `AppDelegate.newWindowForTab` (⌘T) to inherit the current tab's cwd —
    /// see spec §4.4. Nil until the shell has emitted at least one valid
    /// OSC 7 sequence; callers should fall back to `foregroundWorkingDirectory()`
    /// (procinfo-based) when nil. Tests (@testable import) can set this
    /// directly to exercise the tab-creation path without driving the shell.
    @Published public internal(set) var lastKnownCwd: String?

    // MARK: - Title state

    /// Last title the shell emitted via OSC 0/2. Empty before any emit.
    /// Mutated on main thread (see the `bbterm.onEvent` dispatch back to main).
    private var oscTitle: String = ""

    /// User-set manual override. When non-nil and non-empty, the UI shows
    /// this instead of the shell's OSC title. Setting to nil or an empty
    /// string reverts to auto (OSC) mode.
    public var titleOverride: String? {
        didSet {
            // Treat empty string as "clear the override" — matches the
            // Rename alert's empty-field behaviour (see MainWindowController.beginRenameActiveTab).
            if titleOverride?.isEmpty == true {
                // Guard against recursion: only reassign if not already nil.
                if titleOverride != nil {
                    titleOverride = nil
                    return  // didSet will re-fire with nil and publish.
                }
            }
            publishTitle()
        }
    }

    /// The title to display in the window / tab bar. Override wins when set;
    /// otherwise falls back to the shell-reported OSC title; otherwise a
    /// generic default.
    public var displayTitle: String {
        if let override = titleOverride, !override.isEmpty { return override }
        return oscTitle.isEmpty ? defaultTitle : oscTitle
    }

    /// Fallback title used when neither an override nor an OSC title is set.
    /// Kept short; the window controller seeds a shell-basename title at
    /// session start, so this only appears in tests / headless instances.
    private var defaultTitle: String { "Terminal" }

    /// Called by the event router when the shell emits OSC 0/2. Keeps
    /// `oscTitle` and the published `title` in sync. Harmless to call with
    /// the same string twice — the `@Published` will still fire, which is
    /// fine; downstream is idempotent.
    public func applyOscTitle(_ newValue: String) {
        oscTitle = newValue
        publishTitle()
    }

    /// Recompute `displayTitle` and republish on the `@Published title`
    /// pipeline. UI observes via Combine (`TerminalView.$title.sink`);
    /// there's no notification channel — Combine is canonical. Callers on
    /// any thread hop to main if needed.
    private func publishTitle() {
        let value: String? = displayTitle
        if Thread.isMainThread {
            self.title = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.title = value
            }
        }
    }

    private let bbterm: BBTerm
    /// Optional so tests can construct a title-only headless session without
    /// spawning a child process. Production paths always have a PTY.
    private let pty: PTY?
    private let coreQueue = DispatchQueue(label: "blackbird.core")

    #if DEBUG
    /// Cwd this session was *spawned* with — recorded by the test-only
    /// headless tab-creation helpers so `CwdTests` can assert on what got
    /// forwarded to `PTY.spawn(initialWorkingDirectory:)` without actually
    /// spawning a child process. Nil in production paths; never read by
    /// them.
    var spawnedCwd: String?
    #endif

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

    #if DEBUG
    /// Headless factory for title-logic tests. Creates a BBTerm at a trivial
    /// size and skips the PTY spawn entirely — so no child process, no fd,
    /// no background queues. Only `applyOscTitle`, `titleOverride`, and
    /// `displayTitle` are useful on the returned instance; public methods
    /// that touch the PTY are all no-ops via optional chaining.
    static func makeHeadlessForTests() -> TerminalSession {
        // BBTerm.init accepts anything ≥ 2; pick the minimum so we don't
        // waste allocation for unit-test purposes.
        guard let bb = BBTerm(size: .init(cols: 2, rows: 2)) else {
            // BBTerm.init only fails if the Rust core refuses the args;
            // our hardcoded 2×2 is well within the floor it enforces, so
            // in practice this path is unreachable. fatalError is better
            // than returning an unusable optional to the test.
            fatalError("BBTerm.init(size:) returned nil for 2×2 headless test session")
        }
        return TerminalSession(headlessBBTerm: bb)
    }

    private init(headlessBBTerm bb: BBTerm) {
        self.bbterm = bb
        self.pty = nil
        // `wire()` is safe in headless mode: every PTY hookup uses optional
        // chaining, so with `pty == nil` only the bbterm.onEvent handler is
        // installed. That's exactly what the OSC 7 / cwd tests need — feed
        // bytes in, observe `lastKnownCwd` / `title` land. Title tests that
        // poke `applyOscTitle` directly still work because that path runs
        // synchronously on the caller.
        wire()
    }

    /// Synchronously drive raw bytes into the VT parser. Blocks until the
    /// bytes have been consumed *and* any resulting bbterm events have
    /// landed on main, so a caller can assert on `lastKnownCwd` / `title`
    /// on the next line without polling. Only available in DEBUG builds —
    /// the headless harness is test-only.
    func feedBytesForTests(_ bytes: Data) {
        coreQueue.sync {
            self.feed(bytes)
        }
        // Drain main-queue hops scheduled by the event dispatch in wire()
        // (cwdChanged / title publish back to main). A single main-sync
        // is enough because the dispatch is a one-level DispatchQueue.main.async.
        if Thread.isMainThread {
            // We're already on main — the async blocks sit behind us on
            // the queue. Pumping the runloop once lets them run.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } else {
            DispatchQueue.main.sync { }
        }
    }
    #endif

    deinit {
        terminate()
    }

    // MARK: - Public API

    public func send(_ data: Data) {
        pty?.write(data)
    }

    /// Write bytes synchronously, bypassing the async write queue. Use for
    /// urgent control characters (Ctrl+C → 0x03, Ctrl+Z → 0x1A) where the
    /// user expects instant response.
    public func sendImmediate(_ data: Data) {
        pty?.writeImmediate(data)
    }

    /// Whether the shell currently has a foreground child process (anything
    /// other than the shell itself). Used to gate the confirm-close prompt.
    public func hasForegroundChild() -> Bool {
        pty?.hasForegroundChild() ?? false
    }

    /// Current working directory of the foreground process — inherited by
    /// new tabs / windows created via ⌘T / ⌘N.
    public func foregroundWorkingDirectory() -> String? {
        pty?.foregroundWorkingDirectory()
    }

    /// Send a POSIX signal directly to the terminal's foreground process group.
    /// More reliable than writing 0x03 for SIGINT because it bypasses the
    /// line discipline — works even if the shell changed termios (ISIG off,
    /// VINTR remapped, etc.).
    public func sendSignalToForeground(_ sig: Int32) {
        pty?.sendSignalToForeground(sig)
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
        //
        // Clamp cols/rows to the same 2×2 floor the Rust core enforces, so
        // the PTY's TIOCSWINSZ gets dimensions matching what alacritty will
        // actually reflow into. Without this, a 1×1 request sizes the PTY
        // to 1×1 but leaves the grid at 2×2 — the shell would receive a
        // SIGWINCH for a 1×1 tty while our grid renders 2×2, and the mismatch
        // shows up as off-by-one cursor or wrap behaviour until the next
        // legit resize.
        let clamped = Size(cols: max(2, size.cols), rows: max(2, size.rows))
        var newSnap: BBSnapshot?
        coreQueue.sync {
            self.pty?.resize(to: clamped)
            self.bbterm.resize(to: .init(cols: clamped.cols, rows: clamped.rows))
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
        pty?.terminate()
    }

    // MARK: - Wiring

    private func wire() {
        // Route PTY bytes -> core queue -> bbterm -> publish snapshot.
        // Guard because headless test instances don't own a PTY.
        pty?.onBytes = { [weak self] data in
            guard let self else { return }
            self.coreQueue.async {
                self.feed(data)
            }
        }

        // When the child exits (natural or SIGHUP), publish the exit code.
        pty?.onExit = { [weak self] code in
            self?.exitCode = code
        }

        // Route bbterm events (title/bell/fatal) to published properties.
        bbterm.onEvent { [weak self] event in
            guard let self else { return }
            // Terminal → shell replies (DSR, DA1, DA2, DECRPM) must round-
            // trip with minimum latency. The event fires from inside
            // bbterm.input on coreQueue, so handing directly to pty.write
            // skips a main-thread bounce that otherwise stalls nvim's
            // startup probes behind unrelated main-queue work (redraws,
            // animation tick, etc).
            if case .ptyWrite(let data) = event {
                self.send(data)
                return
            }
            DispatchQueue.main.async {
                switch event {
                case .title(let t):
                    // Route through applyOscTitle so a user-set override
                    // isn't trampled by a late shell OSC 0/2, and so the
                    // .terminalSessionTitleDidChange notification fires.
                    self.applyOscTitle(t)
                case .bell:
                    self.bellCounter &+= 1
                case .ptyWrite:
                    break  // handled above, before the main hop
                case .osc52Clipboard(let text):
                    // alacritty_terminal 0.26 already decodes the OSC 52
                    // payload: ClipboardStore(target, plaintext). The
                    // `target` char (c/p/q/s/0-7) isn't surfaced through
                    // the C ABI — we always write to NSPasteboard.general,
                    // which is the only clipboard macOS exposes anyway.
                    //
                    // The previous implementation assumed `text` was
                    // "target;base64" and stripped the first ';' then
                    // base64-decoded the tail. With the real payload that
                    // silently dropped every write (no ';' in decoded
                    // plaintext, or base64 decode failed on the text
                    // after it), so OSC 52 never actually pasted.
                    //
                    // Treat an empty payload as a clipboard-clear (OSC 52
                    // ; c ; ST). Silently drop when the pref is off —
                    // a misbehaving remote shouldn't stuff arbitrary
                    // bytes into the user's clipboard or crash the
                    // session.
                    guard Preferences.shared.osc52Enabled else { break }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if !text.isEmpty {
                        pb.setString(text, forType: .string)
                    }
                case .cursorShape:
                    break  // Plan 5/3 will surface cursor shape.
                case .cwdChanged(let path):
                    // Rust core already gates on scheme=file and validates
                    // UTF-8; the payload is a ready-to-use filesystem path.
                    // Store on the main thread so reads from ⌘T / ⌘N stay
                    // trivially race-free (those actions also run on main).
                    self.lastKnownCwd = path
                case .fatal(let msg):
                    // Surface as a title prefix for visibility; Plan 7 adds a
                    // dedicated diagnostics channel. Fatal should display
                    // regardless of any user-set override AND must not let a
                    // stale override resurface later. Clear the override and
                    // route through the state machine so the
                    // oscTitle/titleOverride/displayTitle invariant holds —
                    // single writer, no divergence between `title` and
                    // `displayTitle`.
                    self.titleOverride = nil
                    self.applyOscTitle("[fatal] core panic: \(msg)")
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
