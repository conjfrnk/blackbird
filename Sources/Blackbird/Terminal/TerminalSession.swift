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

    /// Maximum bytes we'll accept from an OSC 52 clipboard-write before
    /// dropping the payload. A misbehaving / malicious remote can emit
    /// unbounded base64 content; pinning the cap at the session layer
    /// prevents NSPasteboard DoS and caps the privacy blast radius.
    /// 1 MiB matches Ghostty's default and comfortably accommodates log-
    /// and code-paste workflows.
    public static let osc52MaxBytes: Int = 1 * 1024 * 1024

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

    /// The most recent OSC 133 prompt/command mark observed from the shell,
    /// paired with its payload (exit code for kind D, empty otherwise).
    @Published public internal(set) var lastPromptMark: (kind: BBTerm.PromptMarkKind, exitCode: String)?

    /// Ring of recorded prompt-start positions (OSC 133 A). Each entry is
    /// the (history_size, grid_row) at the instant the mark fired — which
    /// together pin the prompt's absolute line number in the buffer so we
    /// can scroll back to it even after thousands of lines of output have
    /// scrolled it off-screen. Capped at `promptMarkCap` FIFO so long
    /// sessions don't grow unbounded.
    @Published public internal(set) var promptMarks: [PromptMark] = []

    /// Current index inside `promptMarks` when cycling via
    /// `jumpToPreviousPrompt` / `jumpToNextPrompt`. Nil means "not in
    /// a jump cycle"; any new OSC 133 A resets to nil so the next Prev
    /// jump starts from the newest mark again.
    private var promptCursor: Int?

    private static let promptMarkCap = 200

    /// Position of a recorded prompt in buffer coordinates.
    public struct PromptMark: Equatable, Hashable {
        /// History size (scrollback line count) at the moment the prompt
        /// was emitted. Monotonically grows in most sessions, up to the
        /// scrollback cap; paired with `gridRow` this fixes the prompt's
        /// absolute line.
        public let historySize: Int
        /// Grid row (0 = top of visible viewport) at the moment the prompt
        /// was emitted.
        public let gridRow: Int
    }

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

    /// Feed raw bytes into the VT parser on the core queue. Does **not**
    /// pump the main runloop — resulting events (`.cwdChanged`, `.title`,
    /// `.bell`, …) hop to main via `DispatchQueue.main.async` inside
    /// `wire()`, so tests should drive settlement with an
    /// `XCTestExpectation` on the relevant `@Published` property (see
    /// `CwdTests`). A helper that polled the runloop was previously here
    /// and proved flaky under CI contention.
    func feedBytesForTests(_ bytes: Data) {
        coreQueue.sync {
            self.feed(bytes)
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

    /// Forward a window-focus change to the TUI as a `CSI I` / `CSI O`
    /// escape, gated on mode 1004 (`\e[?1004h`). No-op when the TUI
    /// hasn't requested focus events — Vim's `:checktime`, tmux's
    /// `focus-events on`, and similar features depend on this.
    ///
    /// Runs on the core queue so the mode read + PTY write are serialized
    /// with any in-flight `bb_term_input` call. Immediate rather than
    /// queued because the byte must land before the next keystroke or
    /// repaint to be causally correct with the focus change the user just
    /// made.
    public func focusChanged(_ focused: Bool) {
        coreQueue.async { [weak self] in
            guard let self, let bytes = self.bbterm.focusChangeBytes(focused: focused) else {
                return
            }
            self.pty?.writeImmediate(bytes)
        }
    }

    // MARK: - Prompt navigation

    /// Record the (history, grid row) position at which an OSC 133 A
    /// fired. Called on main from the event switch; takes a snapshot
    /// synchronously via the core queue so the reading is consistent.
    /// A new prompt resets `promptCursor` to nil so the next jump
    /// starts from the newest mark.
    private func recordPromptStart() {
        guard let snap = coreQueue.sync(execute: { self.bbterm.snapshot() }) else {
            return
        }
        let mark = PromptMark(historySize: snap.historySize, gridRow: snap.cursorRow)
        promptMarks.append(mark)
        if promptMarks.count > Self.promptMarkCap {
            promptMarks.removeFirst(promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    /// Scroll the viewport to the previous recorded prompt. First press
    /// from a resting state jumps to the newest mark; subsequent presses
    /// walk backwards through `promptMarks`. No-op when the ring is empty
    /// (shell hasn't sourced the OSC 133 integration, or no commands have
    /// run yet).
    public func jumpToPreviousPrompt() {
        guard !promptMarks.isEmpty else { return }
        let next: Int = {
            if let cur = promptCursor {
                return max(0, cur - 1)
            }
            return promptMarks.count - 1
        }()
        promptCursor = next
        scrollToMark(promptMarks[next])
    }

    /// Walk forward through the prompt ring toward the live view. No-op
    /// when the user isn't already in a jump cycle — there's no "newer"
    /// prompt than the one currently live.
    public func jumpToNextPrompt() {
        guard let cur = promptCursor, !promptMarks.isEmpty else { return }
        let next = min(promptMarks.count - 1, cur + 1)
        promptCursor = next
        scrollToMark(promptMarks[next])
    }

    // MARK: - Test-only access

    /// Internal hook for `PromptJumpTests` — appends a mark with the FIFO
    /// cap applied, without needing a real shell to emit OSC 133. Not
    /// public because the ring lifecycle is otherwise owned entirely by
    /// the event switch.
    internal func _testAppendMark(_ mark: PromptMark) {
        promptMarks.append(mark)
        if promptMarks.count > Self.promptMarkCap {
            promptMarks.removeFirst(promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    /// Internal accessor exposing the otherwise-private cycle index so
    /// tests can assert exact walk behaviour.
    internal var _testPromptCursor: Int? { promptCursor }

    /// Compute and apply the scroll delta that places a given mark near
    /// the top of the current viewport.
    ///
    /// Math: display_offset D means the viewport's top row shows buffer
    /// line (history_size - D). The mark's absolute line is
    /// mark.historySize + mark.gridRow, so the target D that puts it at
    /// the top is (current_history - mark.historySize - mark.gridRow).
    /// Clamped to [0, current_history] because display_offset can't go
    /// past the top of scrollback, and a negative target means the mark
    /// is already below the current live bottom (odd — only possible if
    /// scrollback was cleared between record and jump; fall back to live).
    private func scrollToMark(_ mark: PromptMark) {
        guard let snap = coreQueue.sync(execute: { self.bbterm.snapshot() }) else {
            return
        }
        let target = max(0, snap.historySize - mark.historySize - mark.gridRow)
        let clampedTarget = min(target, snap.historySize)
        let delta = clampedTarget - snap.displayOffset
        if delta != 0 {
            scroll(delta: Int32(clamping: delta))
        }
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
        // Clamp cols/rows to the same 2×2 floor and 1000×1000 ceiling the
        // Rust core enforces, so the PTY's TIOCSWINSZ gets dimensions
        // matching what alacritty will actually reflow into. Without
        // this, a 1×1 request sizes the PTY to 1×1 but leaves the grid
        // at 2×2; a UInt16.max request allocates hundreds of GB in the
        // grid. Keeping PTY + grid in lockstep avoids off-by-one cursor
        // / wrap bugs after the mismatch.
        let cols = min(1000, max(2, size.cols))
        let rows = min(1000, max(2, size.rows))
        let clamped = Size(cols: cols, rows: rows)
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
        // INVARIANT: every `pty` hookup in this method MUST use optional
        // chaining (`pty?.onBytes = …`). Headless test sessions run with
        // `pty == nil` and call `wire()` to get bbterm event dispatch; a
        // forced unwrap here will crash those tests. If you need eager
        // PTY setup, gate it with `if let pty { … }` and state why in a
        // comment — don't drop the guard.
        //
        // Route PTY bytes -> core queue -> bbterm -> publish snapshot.
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
                    if text.utf8.count > Self.osc52MaxBytes {
                        #if DEBUG
                        NSLog("[Blackbird] OSC 52 payload %d bytes exceeds %d cap — dropping",
                              text.utf8.count, Self.osc52MaxBytes)
                        #endif
                        break
                    }
                    // Scrub C0/C1 controls + bidi overrides before handing
                    // the payload to NSPasteboard. A compromised remote
                    // would otherwise push a Trojan Source blob or raw ESC
                    // sequences into the user's system clipboard —
                    // invisible to Blackbird's own paste scrubber because
                    // that runs on *inbound* paste, not on the write side.
                    // Symmetric treatment: anything dirty enough to strip
                    // on paste-in is dirty enough to strip on paste-out.
                    let data = Data(text.utf8)
                    let scrubbed = TerminalView.stripBidiOverrides(
                        TerminalView.sanitizePasteControls(data)
                    )
                    let clean = String(decoding: scrubbed, as: UTF8.self)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if !clean.isEmpty {
                        pb.setString(clean, forType: .string)
                    }
                case .cursorShape:
                    break  // Plan 5/3 will surface cursor shape.
                case .cwdChanged(let path):
                    // Rust core already gates on scheme=file and validates
                    // UTF-8; the payload is a ready-to-use filesystem path.
                    // Store on the main thread so reads from ⌘T / ⌘N stay
                    // trivially race-free (those actions also run on main).
                    self.lastKnownCwd = path
                case .promptMark(let kind, let exitCode):
                    // Shell integration: A = prompt start, B = command start,
                    // C = output start, D = command end (with exit code).
                    self.lastPromptMark = (kind, exitCode)
                    // Record kind-A positions so the user can jump back to
                    // previous prompts. A fresh snapshot pins (history, row)
                    // at this instant — the main-queue hop means the core
                    // queue may have advanced slightly, but missing a line
                    // or two of drift is negligible next to a multi-screen
                    // scrollback jump.
                    if kind == .promptStart {
                        self.recordPromptStart()
                    }
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
