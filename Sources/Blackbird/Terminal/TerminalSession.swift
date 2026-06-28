import Foundation
import Combine
import QuartzCore
import os

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

    /// Strict-greater-than gate on the OSC 52 payload size. Extracted
    /// from the inline dispatch path so a unit test can pin the
    /// boundary (`utf8Count == osc52MaxBytes` is INSIDE, not dropped)
    /// without driving a 1 MiB payload through a real session — the
    /// only other way to exercise this comparison from the public API.
    internal static func osc52IsOversize(_ utf8Count: Int) -> Bool {
        utf8Count > osc52MaxBytes
    }

    /// `os.Logger` (not `NSLog`) so OSC 52 cap diagnostics survive the
    /// unified-log redaction NSLog incurs at runtime-format time.
    /// Declaration ungated (matching the call site, which logs in
    /// Release per SFH-005) — see commit 017275c.
    private static let osc52Logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "osc52")

    /// Diagnostics for resize panic-fallbacks (M3) and OSC 7 dropped-on-
    /// `.unknown` classification (L3). Both are non-fatal events the
    /// support engineer needs visible in `log stream` without spamming
    /// the unified log on each occurrence. Internal (not private) so the
    /// `ResizeController` (M3 warning) and `CwdTracker` (L3 notice)
    /// collaborators log through the one "session"-category logger — a single
    /// source of truth for the category, byte-identical to the inline output.
    static let sessionLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                      category: "session")
    // `loggedUnknownNamespaceDrop` (the OSC 7 `.unknown` drop-log latch) moved
    // to `CwdTracker` along with the cwd-change publishing + SSH-trust gate it
    // guards. The `@Published lastKnownCwd` store stays here (below).

    /// Shorthand. Routed through `StartupTelemetry.isEnabled` at each
    /// call site so Release builds don't emit diagnostic chatter unless
    /// the user opted in with `BLACKBIRD_STARTUP_LOG=1`.
    private static var startupLogger: Logger { StartupTelemetry.logger }
    /// Absolute time the session's PTY was spawned. First-byte and
    /// first-snapshot timestamps reference this baseline so the log
    /// reads as "spawn → first byte N ms" instead of raw clock.
    /// Audit L8: was a `var` written from `start(shell:)` on the
    /// caller's thread and read from `feed(_:)` on coreQueue with
    /// no synchronization. Promote to `let` and pass through init
    /// — the value is fixed at construction so there's no race.
    /// Internal (not private) so `SnapshotCoalescer` can read it for the
    /// first-byte / first-snapshot telemetry timestamps.
    let spawnedAt: CFTimeInterval
    // `loggedFirstByte` (first-byte log latch) and `publishedFirstSnapshot`
    // (first-snapshot-on-main latch) moved to `SnapshotCoalescer` along with
    // the feed/publish paths that own them.

    @Published public private(set) var snapshot: BBSnapshot?

    /// Single write site for the SwiftUI-observed snapshot. Called by
    /// `SnapshotCoalescer` on the main thread (the `@Published` store stays
    /// owned by the session; the coalescer publishes through this seam).
    func publish(_ snap: BBSnapshot) {
        self.snapshot = snap
    }
    /// Window / tab title state (OSC 0/2 + user override → one observable
    /// title). Hoisted out of this class — UI binds to `session.titleState.$title`;
    /// the rename flow sets `session.titleState.titleOverride`.
    public let titleState = SessionTitleState()
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

    /// The prompt-mark navigation concern (the ring's cursor, the scroll-to-mark
    /// math, the OSC 133 A record path, and the **two-token clear-epoch /
    /// generation** machinery that defends against phantom marks across a clear
    /// or reflow) lives in `PromptNavigator`. The `@Published` ring above and
    /// `lastPromptMark` below stay here as the observable UI surface — the
    /// navigator drives them through its `unowned session`, exactly as
    /// `SnapshotCoalescer` drives `@Published snapshot` via `publish(_:)`.
    /// IUO: needs `self` at init, assigned before `wire()` so no async path
    /// observes it nil. `private(set)` so only this session assigns it.
    private(set) var promptNavigator: PromptNavigator!

    /// The `PromptMark` value type lives on the navigator; this alias keeps the
    /// existing `TerminalSession.PromptMark` spelling (ScrollIndicator, tests)
    /// binding unchanged.
    public typealias PromptMark = PromptNavigator.PromptMark

    /// Internal (not private) so the `SnapshotCoalescer` / `PaletteApplier`
    /// collaborators can reach the FFI handle. Part I §6 single-queue ownership
    /// is preserved by discipline, not access control: those collaborators only
    /// touch `bbterm` from `coreQueue` (feed + the deferred snapshot/palette
    /// work items all run on `coreQueue`).
    let bbterm: BBTerm
    /// Optional so tests can construct a title-only headless session without
    /// spawning a child process. Production paths always have a PTY.
    /// Internal (not private) for the same reason as `bbterm`: the
    /// `FocusEmitter` (writeImmediate) and `ResizeController` (resize)
    /// collaborators forward to it. PTY owns its own read/write queue
    /// serialization, so single-owner discipline is preserved exactly as before
    /// — these collaborators only touch it from the same coreQueue contexts the
    /// inline code did.
    let pty: PTY?
    /// Marker installed on `coreQueue` so any sync-entry helper can detect
    /// it's already running on this session's coreQueue and avoid a
    /// `coreQueue.sync` self-deadlock (PS-01 / NEW-01).
    private let coreQueueToken: ObjectIdentifier
    /// Internal (not private) so `SnapshotCoalescer` / `PaletteApplier` can
    /// serialize their `bbterm` access through the same single owner queue.
    let coreQueue: DispatchQueue
    /// Process-wide key used by `setSpecific`. Different sessions have
    /// distinct token VALUES on the same key, so `getSpecific(key:)` on a
    /// thread that's servicing session A's coreQueue returns A's token but
    /// not B's.
    private static let coreQueueKey = DispatchSpecificKey<ObjectIdentifier>()
    /// True when the calling thread is currently servicing THIS session's
    /// `coreQueue`. Other sessions' coreQueues return false here.
    private var isOnCoreQueue: Bool {
        DispatchQueue.getSpecific(key: Self.coreQueueKey) == coreQueueToken
    }
    private var preferencesSubscription: AnyCancellable?

    // MARK: - Main-publish coalescer (audit F1)
    //
    // The snapshot-publish machinery (the pending slot, the dispatch-scheduled
    // flag, the burst scheduler, the snapshot/first-byte counters and the
    // feed/publish paths) lives in `SnapshotCoalescer`. The session keeps two
    // things here because they are SHARED with the terminate latch:
    //
    //   - `publishLock`: the coalescer locks THIS instance (no second lock), so
    //     user-action publishes (publishImmediate), feed-driven publishes, and
    //     `terminate()` all serialize on one lock exactly as before the split.
    //   - `isTerminated`: the F1/F11 gate read by the coalescer (under the lock)
    //     and by every other `coreQueue.async` path via `isTerminatedLocked()`.
    //
    // F11: queued feeds kept publishing snapshots after `onExit` / window
    // close. `isTerminated` gates the feed path so post-termination feeds are
    // dropped instead of still waking main.
    //
    // Internal (not private): the coalescer shares this exact `NSLock`.
    let publishLock = NSLock()
    /// Terminate latch. `private(set)` so only `terminate()` flips it; the
    /// coalescer reads it (under `publishLock`) but never writes it.
    private(set) var isTerminated: Bool = false

    /// The main-publish coalescer. Owns the F1/F11/H8 pending-slot machinery
    /// and the feed/scheduleSnapshotAfterBurst/publish paths, sharing this
    /// session's `publishLock` (IUO: needs `self` at init, assigned before
    /// `wire()` so no async path observes it nil). `private(set)` internal so
    /// `PaletteApplier` can route its post-apply snapshot through the same
    /// single-slot coalescer; only this session assigns it.
    private(set) var snapshotCoalescer: SnapshotCoalescer!

    /// Pushes resolved theme palettes into the core (Finding 1 peel). Stateless
    /// collaborator; assigned alongside the coalescer.
    private var paletteApplier: PaletteApplier!

    /// OSC 7 cwd ingest + SSH-trust classification (Part I §18). Owns the L3
    /// drop-log latch; drives the `@Published lastKnownCwd` store on this
    /// session. Assigned before `wire()` so the async event handler it backs
    /// never observes it nil.
    private var cwdTracker: CwdTracker!

    /// Window-focus escape emitter (DECSET 1004 gate + same-state dedup). Owns
    /// the `lastFocusEmitted` coreQueue-confined latch.
    private var focusEmitter: FocusEmitter!

    /// Terminal resize (grid + PTY winsize lockstep + reflow invalidation).
    /// Owns the `lastAppliedGridSize` coreQueue-confined reflow detector.
    private var resizeController: ResizeController!

    public static func start(
        shell: String,
        arguments: [String],
        size: Size,
        initialWorkingDirectory: String? = nil
    ) throws -> TerminalSession {
        let t0 = CACurrentMediaTime()
        guard let bb = BBTerm(size: .init(cols: size.cols, rows: size.rows)) else {
            throw SessionError.coreInitFailed
        }
        let tCore = CACurrentMediaTime()
        let pty = try PTY.spawn(
            executable: shell,
            arguments: arguments,
            envOverrides: [:],
            size: size,
            initialWorkingDirectory: initialWorkingDirectory
        )
        let tSpawn = CACurrentMediaTime()
        let s = TerminalSession(bbterm: bb, pty: pty, spawnedAt: tSpawn)
        let coreMs = (tCore - t0) * 1000
        let ptyMs = (tSpawn - tCore) * 1000
        if StartupTelemetry.isEnabled {
            Self.startupLogger.log(
                "start shell=\(shell, privacy: .public) core_init=\(coreMs, format: .fixed(precision: 1), privacy: .public)ms pty_spawn=\(ptyMs, format: .fixed(precision: 1), privacy: .public)ms"
            )
        }
        return s
    }

    public enum SessionError: Error {
        case coreInitFailed
    }

    private init(bbterm: BBTerm, pty: PTY, spawnedAt: CFTimeInterval) {
        self.bbterm = bbterm
        self.pty = pty
        self.spawnedAt = spawnedAt
        let q = DispatchQueue(label: "blackbird.core")
        let token = ObjectIdentifier(bbterm)
        q.setSpecific(key: Self.coreQueueKey, value: token)
        self.coreQueue = q
        self.coreQueueToken = token
        // Assigned before `wire()` so the async feed/snapshot/palette closures
        // it schedules never observe these IUO collaborators as nil.
        self.snapshotCoalescer = SnapshotCoalescer(session: self)
        self.paletteApplier = PaletteApplier(session: self)
        self.promptNavigator = PromptNavigator(session: self)
        self.cwdTracker = CwdTracker(session: self)
        self.focusEmitter = FocusEmitter(session: self)
        self.resizeController = ResizeController(session: self)
        wire()
    }

    #if DEBUG
    /// Headless factory for title-logic tests. Creates a BBTerm at a trivial
    /// size and skips the PTY spawn entirely — so no child process, no fd,
    /// no background queues. Only the `titleState` collaborator (its
    /// `applyOscTitle` / `titleOverride` / `displayTitle`) is useful on the
    /// returned instance; public methods that touch the PTY are all no-ops
    /// via optional chaining.
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
        // Headless test sessions never log spawn-relative timing.
        self.spawnedAt = CACurrentMediaTime()
        let q = DispatchQueue(label: "blackbird.core")
        let token = ObjectIdentifier(bb)
        q.setSpecific(key: Self.coreQueueKey, value: token)
        self.coreQueue = q
        self.coreQueueToken = token
        self.snapshotCoalescer = SnapshotCoalescer(session: self)
        self.paletteApplier = PaletteApplier(session: self)
        self.promptNavigator = PromptNavigator(session: self)
        self.cwdTracker = CwdTracker(session: self)
        self.focusEmitter = FocusEmitter(session: self)
        self.resizeController = ResizeController(session: self)
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
            self.snapshotCoalescer.feed(bytes)
        }
    }

    /// Test hook: production-shaped ASYNC feed. Mirrors the `setOnBytes`
    /// closure in `wire()` exactly (`coreQueue.async` → `feed`), so tests
    /// can enqueue a back-to-back burst the way a flooding PTY does —
    /// something the synchronous `feedBytesForTests` cannot, because its
    /// `coreQueue.sync` drains every internally deferred work item before
    /// the next chunk is enqueued.
    func enqueueBytesForTests(_ bytes: Data) {
        coreQueue.async { [weak self] in
            self?.snapshotCoalescer.feed(bytes)
        }
    }

    /// Test hook: block until every enqueued feed AND any snapshot work
    /// those feeds deferred to the tail of `coreQueue` has completed.
    /// Drains by invariant, not structure: a sync block on the serial
    /// queue can only observe `snapshotWorkQueued` between items, so
    /// reading false means all feeds enqueued before this call AND the
    /// snapshot work they deferred have finished — regardless of how many
    /// levels deep a future change makes the deferral.
    func waitForFeedsForTests() {
        while coreQueue.sync(execute: { snapshotCoalescer.snapshotWorkQueued }) {
            // Each pass queues behind whatever is currently in flight;
            // no spin in practice (≤2 iterations for a single burst).
        }
    }

    /// Test hook: running count of snapshot generations performed by the
    /// feed path since session start. Pins the burst-coalescing contract
    /// (a burst of N chunks must take O(bursts) snapshots, not N).
    /// coreQueue-confined storage; the sync read also gives the caller
    /// natural ordering behind any queued feeds.
    var snapshotsTakenForTests: Int {
        coreQueue.sync { snapshotCoalescer.snapshotsTakenCount }
    }

    /// Test-only synchronous snapshot accessor. Drives the same code path
    /// as the production `recordPromptStart` / `scroll` / `clearAll` etc.
    /// `coreQueue.sync(execute: bbterm.snapshot)` but does **not** publish
    /// to `@Published snapshot` — the goal is to exercise the
    /// `bb_term_take_snapshot` + `BBSnapshot` retain dance in isolation,
    /// without the main-queue dispatch and `objectWillChange` retain
    /// behaviour the published path would add. Used by
    /// `SingleSessionSteadyStateLeakTests` to churn snapshots against a
    /// long-lived session and pin the steady-state retain shape.
    func takeSnapshotForTests() -> BBSnapshot? {
        return coreQueue.sync { self.bbterm.snapshot() }
    }

    /// Test hook: drive `FocusEmitter.emissionBytes` on the core queue so unit
    /// tests can pin the DECSET 1004 gate + same-state dedup without an
    /// NSWindow. Mirrors `feedBytesForTests`.
    func focusEmissionBytesForTests(focused: Bool) -> Data? {
        return coreQueue.sync { self.focusEmitter.emissionBytes(focused: focused) }
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
    /// other than the shell itself). Used by App quit / window close
    /// confirm prompts and by `CwdResolver` to inherit the child's cwd
    /// for new tabs.
    public func hasForegroundChild() -> Bool {
        #if DEBUG
        if let override = _testForegroundChildOverride {
            return override
        }
        #endif
        return pty?.hasForegroundChild() ?? false
    }

    #if DEBUG
    /// Test-only override for `hasForegroundChild()`. The real
    /// implementation calls `tcgetpgrp` on the master fd, which a
    /// headless test session (`makeHeadlessForTests` — `pty == nil`)
    /// can't drive. Setting this to `true` lets tests simulate a
    /// running command (e.g. `DragDropTests` asserting a drop is
    /// still forwarded to claude / python / vim) without forking a
    /// child process. Cleared with `nil` to fall back to the real path.
    var _testForegroundChildOverride: Bool?
    #endif

    /// Current working directory of the foreground process — inherited by
    /// new tabs / windows created via ⌘T / ⌘N.
    public func foregroundWorkingDirectory() -> String? {
        pty?.foregroundWorkingDirectory()
    }

    /// Classify the foreground process tree for the OSC 7 ingest gate.
    /// `.local` → trust shell-reported cwd. `.remote` / `.unknown` →
    /// drop the OSC 7 payload (audit synthesis #4 / KNOWN_ISSUES "OSC 7
    /// trust over SSH").
    ///
    /// Production sessions always have a non-nil `pty`, so the fail-
    /// closed posture is enforced through `PTY.classifyForegroundNamespace()`
    /// which returns `.unknown` on syscall failure / BFS cap. Headless
    /// test sessions (`makeHeadlessForTests` — `pty == nil`) default to
    /// `.local` to preserve the historical "OSC 7 just lands in tests"
    /// ergonomics; tests that exercise the gate explicitly set
    /// `_testForegroundNamespaceOverride`.
    public func classifyForegroundNamespace() -> ForegroundNamespace {
        #if DEBUG
        if let override = _testForegroundNamespaceOverride {
            return override
        }
        #endif
        // Headless fallback intentionally `.local`, not `.unknown`. See
        // doc comment — production code paths always have a pty.
        return pty?.classifyForegroundNamespace() ?? .local
    }

    #if DEBUG
    /// Test-only override for `classifyForegroundNamespace()`. The real
    /// implementation walks `proc_listpids` from `tcgetpgrp(masterFD)`,
    /// which a headless test session (`makeHeadlessForTests` — `pty == nil`)
    /// can't drive without forking ssh. Setting this to a specific case
    /// lets tests simulate `.local`, `.remote(...)`, or `.unknown(...)`
    /// without spawning a real foreground child. Cleared with `nil` to
    /// fall back to the real path. Mirrors `_testForegroundChildOverride`.
    var _testForegroundNamespaceOverride: ForegroundNamespace?
    #endif

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
    /// The DECSET 1004 gate (read against the **live** core mode, not the
    /// async-published snapshot), the same-state dedup, and the coreQueue hop +
    /// `isTerminated` gate live in `FocusEmitter` (REFACTOR.md Part IV —
    /// focus-emission peel). This is the thin public seam `TerminalView` /
    /// `MainWindowController` bind unchanged.
    public func focusChanged(_ focused: Bool) {
        focusEmitter.emit(focused)
    }

    // MARK: - Prompt navigation
    //
    // The ring's cursor, the scroll-to-mark math, the OSC 133 A record path, and
    // the two-token clear-epoch / generation machinery live in `PromptNavigator`
    // (REFACTOR.md Part IV — prompt-nav peel). These are thin forwarders so menu
    // actions / `AppDelegate` / `PromptJumpTests` bind unchanged.

    /// Scroll the viewport to the previous recorded prompt. First press
    /// from a resting state jumps to the newest mark; subsequent presses
    /// walk backwards through `promptMarks`. No-op when the ring is empty
    /// (shell hasn't sourced the OSC 133 integration, or no commands have
    /// run yet).
    @discardableResult
    public func jumpToPreviousPrompt() -> Bool {
        promptNavigator.jumpToPreviousPrompt()
    }

    /// Walk forward through the prompt ring toward the live view. No-op
    /// when the user isn't already in a jump cycle — there's no "newer"
    /// prompt than the one currently live. Returns true when a jump
    /// happened so the view can surface "no more prompts" feedback.
    @discardableResult
    public func jumpToNextPrompt() -> Bool {
        promptNavigator.jumpToNextPrompt()
    }

    // MARK: - Test-only access

    #if DEBUG
    /// Internal hook for `PromptJumpTests` — appends a mark with the FIFO
    /// cap applied, without needing a real shell to emit OSC 133. Not
    /// public because the ring lifecycle is otherwise owned entirely by
    /// the event switch.
    internal func _testAppendMark(_ mark: PromptMark) {
        promptNavigator._testAppendMark(mark)
    }

    /// Internal accessor exposing the otherwise-private cycle index so
    /// tests can assert exact walk behaviour.
    internal var _testPromptCursor: Int? { promptNavigator._testPromptCursor }

    /// Audit L3: exposes the per-session one-shot latch so tests can
    /// assert "two `.unknown` OSC 7 events flip the latch exactly once".
    /// Setter is provided so a test can also reset between scenarios.
    internal var _testLoggedUnknownNamespaceDrop: Bool {
        get { cwdTracker.loggedUnknownNamespaceDrop }
        set { cwdTracker.loggedUnknownNamespaceDrop = newValue }
    }

    /// Exposes the Preferences Combine subscription so the
    /// `test_terminate_cancelsPreferencesSubscription` regression can
    /// assert it goes nil after `terminate()`. Internal-only — production
    /// callers must not retain or null this; lifecycle is owned by
    /// `wire()` / `terminate()`.
    internal var _testPreferencesSubscription: AnyCancellable? {
        preferencesSubscription
    }
    #endif

    /// Resize the grid + PTY winsize in lockstep (drag path: synchronous so the
    /// returned snapshot is already new-size when the next MTKView frame draws).
    /// The Bug #3 / Bug #9 ordering, the M3 panic-fallback, the S1-007
    /// termination gate, and the H8 publishImmediate routing live in
    /// `ResizeController` (REFACTOR.md Part IV — resize peel). Thin public seam
    /// `TerminalView` (window-drag) binds unchanged.
    public func resize(to size: Size) {
        resizeController.resize(to: size)
    }

    /// Async sibling of `resize(to:)` for non-drag callers (font-change path),
    /// where a coreQueue backlog must not hold main hostage while shells stream
    /// output. Logic lives in `ResizeController`; this is the thin public seam.
    public func resizeAsync(to size: Size) {
        resizeController.resizeAsync(to: size)
    }

    /// Documented floor 2, ceiling 1000 per axis. Visible to tests
    /// (`@testable internal`) so a Swift-mutation-pass boundary test
    /// can exercise the clamp directly without standing up a full
    /// `TerminalSession` + PTY.
    internal static func clampResize(_ size: Size) -> Size {
        let cols = min(1000, max(2, size.cols))
        let rows = min(1000, max(2, size.rows))
        return Size(cols: cols, rows: rows)
    }

    public func scroll(delta: Int32) {
        // NEW-01: tripwire if a future caller invokes us from within
        // coreQueue. Today no caller sits on coreQueue when reaching
        // these methods; if that ever changes the precondition fires
        // (visible failure) instead of the `coreQueue.sync` below
        // deadlocking the queue silently.
        dispatchPrecondition(condition: .notOnQueue(coreQueue))
        var snap: BBSnapshot?
        coreQueue.sync {
            bbterm.scroll(delta: delta)
            snap = bbterm.snapshot()
        }
        if let snap { snapshotCoalescer.publishImmediate(snap) }
    }

    /// Snap the viewport back to the live grid. Call from the input path
    /// (keystrokes, paste) so the user is never left "orphaned" in scrollback
    /// while typing. No-op if already pinned.
    public func scrollToBottom() {
        dispatchPrecondition(condition: .notOnQueue(coreQueue))
        var snap: BBSnapshot?
        coreQueue.sync {
            bbterm.scrollToBottom()
            snap = bbterm.snapshot()
        }
        if let snap { snapshotCoalescer.publishImmediate(snap) }
    }

    /// ⌘K target — clear viewport + scrollback while preserving palette /
    /// cursor / title. Publishes a fresh snapshot so the renderer shows the
    /// empty grid on the next frame.
    ///
    /// H-6: also invalidate prompt-mark state. The OSC 133 ring's
    /// `(history_size, grid_row)` tuples encode buffer positions that
    /// `bb_term_clear_all` has just deleted, so a post-clear ⌘[ would
    /// otherwise navigate to stale lines. Selection itself lives on
    /// `TerminalView` and is invalidated through the render-time gate
    /// (the `historyCollapsed` predicate added in the same change),
    /// which observes the post-clear snapshot we publish below.
    ///
    /// L-24: re-apply the user's current theme palette after the core
    /// clear. `bb_term_clear_all` preserves OSC 4 palette mutations by
    /// design, so a hostile remote that recoloured ANSI 0 to red leaves
    /// the post-clear shell with the wrong colours. Re-pushing the
    /// resolved theme overwrites any adversarial palette state.
    public func clearAll() {
        dispatchPrecondition(condition: .notOnQueue(coreQueue))
        var s: BBSnapshot?
        coreQueue.sync {
            bbterm.clearAll()
            // Audit S5-008: events fired on coreQueue BEFORE this point
            // carry the pre-bump epoch and their prompt-mark appends
            // self-discard on the main side. coreQueue-confined bump —
            // runs inside this `coreQueue.sync`, exactly as before.
            promptNavigator.bumpClearEpochCore()
            s = bbterm.snapshot()
        }
        // H-6: drop prompt-state tied to the now-deleted scrollback. The
        // render-side gate handles `selection`; we own the OSC 133 ring +
        // last-mark + cycle cursor here. Mutating @Published properties
        // on main keeps Combine subscribers race-free.
        //
        // Audit follow-up (2026-04-29): typed `@MainActor () -> Void`
        // for compile-time enforcement, sibling of `applyResolved` four
        // lines below (d3ca442 hotfix). The mutated `@Published`
        // properties (`promptMarks`, `promptCursor`, `lastPromptMark`)
        // are `@MainActor`-isolated; both delivery branches below enter
        // the main thread before invoking the closure. Typing it as
        // `@MainActor` makes the type system enforce what the runtime
        // guarantees: a future caller that hands `resetPromptState` to
        // e.g. `coreQueue.async(execute:)` would now fail to compile,
        // instead of trapping at runtime via `MainActor.assumeIsolated`.
        //
        // The body (S5-008: bump the ring generation so an in-flight
        // recordPromptStart whose snapshot predates the clear drops its
        // append instead of re-inserting a mark anchored to deleted
        // scrollback — and the main-side clear epoch so events that FIRED
        // before the clear but drain after self-discard too; then wipe the
        // ring + last-mark + cursor) lives in `PromptNavigator.resetForClear`.
        let resetPromptState: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.promptNavigator.resetForClear()
        }
        onMain(resetPromptState)
        if let s { snapshotCoalescer.publishImmediate(s) }
        // L-24: re-apply the resolved theme palette so OSC 4 mutations
        // from the pre-clear shell don't survive into the post-clear
        // session. `applyPalette` is async on `coreQueue` so it orders
        // naturally after the synchronous clear above.
        // ThemeManager.resolvedPalette is `@MainActor`-isolated; both
        // delivery branches below enter the main thread before invoking
        // the closure. Typing the closure as `@MainActor () -> Void`
        // makes the type system enforce what the runtime guarantees:
        // a future caller that hands `applyResolved` to e.g.
        // `coreQueue.async(execute:)` would now fail to compile, instead
        // of trapping at runtime via `MainActor.assumeIsolated`.
        let applyResolved: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let palette = ThemeManager.shared.resolvedPalette
            self.applyPalette(palette)
        }
        onMain(applyResolved)
    }

    /// Reads the `terminate()` latch under `publishLock`. Every `coreQueue`
    /// body and its main-hop re-check calls this to bail when the session tore
    /// down between scheduling and execution — the lock pairs with the store
    /// in `terminate()`, so reading the bare `Bool` would race that store. The
    /// lock guards only the read; callers branch on the returned value outside
    /// it, exactly as the inline `lock / read / unlock` dance this replaces did.
    /// Internal (not private) so `SnapshotCoalescer` / `PaletteApplier` share
    /// the one termination-gate read against this session's `publishLock`.
    func isTerminatedLocked() -> Bool {
        publishLock.lock()
        defer { publishLock.unlock() }
        return isTerminated
    }

    /// Run `work` on the main actor: synchronously via `assumeIsolated` when
    /// the caller is already on the main thread (no extra runloop turn — the
    /// synchronous-visibility paths rely on landing this tick), otherwise
    /// hopped via `main.async`. `work` is typed `@MainActor` so the compiler
    /// enforces the isolation the runtime assumes — a caller that mis-routes it
    /// onto a background queue fails to compile instead of trapping at runtime.
    /// One definition for the possibly-off-main paths that mutate `@MainActor`
    /// state (prompt-state reset, palette re-apply).
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    /// Push a resolved theme palette into the core + republish. The color-math
    /// + OSC-slot mapping lives in `PaletteApplier` (REFACTOR.md Finding 1
    /// peel); this is the thin public seam `ThemeManager` and `clearAll` call.
    public func applyPalette(_ palette: ThemePalette) {
        paletteApplier.apply(palette)
    }

    /// Extract text between two buffer points. Serialized through the core
    /// queue so the grid can't mutate mid-read (same discipline as other
    /// `bbterm.*` accessors).
    public func textRange(from start: BufferPoint, to end: BufferPoint, rectangular: Bool) -> String {
        // M-12 sibling: same tripwire rationale as recordPromptStart /
        // scrollToMark / resize. Public method used by selection-copy and
        // find-match extraction (both on main today). `coreQueue.sync`
        // self-deadlocks if invoked from coreQueue, so fail loud rather
        // than wedge the session if a future caller lands here off-main.
        dispatchPrecondition(condition: .notOnQueue(coreQueue))
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
        // Gate the feed path (F11): coreQueue may have queued feeds ahead
        // of us; those will run `feed(_:)` after terminate() returns and
        // would otherwise keep waking main with fresh snapshots of a grid
        // nobody is looking at. The flag is read inside `feed` under
        // `publishLock` so the store here is visible to whichever queue
        // executes the straggler.
        publishLock.lock()
        isTerminated = true
        // Drop any pending main dispatch's payload — the already-scheduled
        // work item will observe `isTerminated` and bail before assigning.
        // Same `publishLock` critical section as before the coalescer split:
        // the latch-set + slot-clear stay atomic under one lock acquisition.
        snapshotCoalescer.dropPendingSnapshotLocked()
        publishLock.unlock()
        // Bug #24: tear down the Preferences sink. Without this, a session
        // that's been terminated (window closed, child reaped) keeps a
        // strong reference into Preferences.shared.objectWillChange and
        // continues to react to pref changes — small but real per-session
        // leak that compounds across long-lived app processes that spawn
        // many tabs/windows. `preferencesSubscription` is the only Combine
        // store on this class today; `cancel()` then nil so `deinit` is
        // a no-op when terminate() ran first.
        preferencesSubscription?.cancel()
        preferencesSubscription = nil
        pty?.terminate()
        // Audit M6: explicitly tear down the Rust core BBTerm on
        // coreQueue. BBTerm.deinit otherwise runs whenever ARC drops
        // the last strong ref — possibly off coreQueue — racing the
        // single-thread-per-BBTerm contract. Calling terminate() here
        // (idempotent) on coreQueue guarantees the FFI free happens on
        // the same queue that drives `bb_term_input`.
        //
        // PS-01: re-entrancy guard. If `deinit` fires on coreQueue
        // (last strong ref dropped from inside an async block), a
        // bare `coreQueue.sync` would self-deadlock. When already on
        // coreQueue we ARE the serial owner, so a direct call is
        // safe and gives identical thread-affinity guarantees.
        if isOnCoreQueue {
            self.bbterm.terminate()
        } else {
            coreQueue.sync {
                self.bbterm.terminate()
            }
        }
    }

    // MARK: - Wiring

    private func wire() {
        // INVARIANT: every `pty` hookup in this method MUST use optional
        // chaining (`pty?.setOnBytes(…)`, `pty?.startReading()`). Headless
        // test sessions run with `pty == nil` and call `wire()` to get
        // bbterm event dispatch; a forced unwrap here will crash those
        // tests. If you need eager PTY setup, gate it with `if let pty
        // { … }` and state why in a comment — don't drop the guard.

        wireColorQueryPreference()
        wireEventAndPTY()
    }

    /// Apply the OSC 10/11/12 color-query preference to the core now (default
    /// off for security; user opt-in), and keep it in sync at runtime via a
    /// `Preferences` subscription.
    private func wireColorQueryPreference() {
        coreQueue.async { [bbterm] in
            bbterm.setColorQueryEnabled(Preferences.shared.colorQueryEnabled)
        }
        // ⚠ FEEDBACK-LOOP HAZARD — DO NOT WRITE USERDEFAULTS HERE. Any write
        // to UserDefaults from this closure fires NSUserDefaultsDidChange-
        // Notification, which SwiftUI's global UserDefaultObserver bridges
        // back into Preferences.objectWillChange, re-firing this sink
        // indefinitely and OOMing the main queue (commit 982b719). This
        // closure is safe: it only forwards the colorQueryEnabled flag into
        // the Rust core via coreQueue.async.
        preferencesSubscription = Preferences.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = Preferences.shared.colorQueryEnabled
                // L-23: weak bbterm so the inner coreQueue.async block is
                // never the last strong ref. Without this, a sink fire that
                // races terminate() can land here, dispatch its coreQueue
                // block holding the only strong bbterm, run on coreQueue,
                // and drop that ref on completion — BBTerm.deinit then
                // runs on coreQueue's thread, off the documented same-
                // thread discipline thread. Today terminate() pre-nils
                // BBTerm.handle so the deinit is a no-op, but the window
                // between isTerminated=true and the inner block firing is
                // when the path is reachable. Weak capture closes it
                // unconditionally; guard makes the post-terminate fire a
                // clean no-op.
                self.coreQueue.async { [weak bbterm = self.bbterm] in
                    guard let bbterm else { return }
                    bbterm.setColorQueryEnabled(enabled)
                }
            }
    }

    /// Wire the bbterm event handler + PTY byte/exit handlers, in the
    /// fix-#06 order: `onEvent` and `setOnExit` MUST be installed before
    /// `setOnBytes` / `startReading`, so the dispatch chain (read loop →
    /// coreQueue → feed → bbterm.input → event trampoline) is fully wired
    /// before any byte can arrive; then take the initial snapshot through the
    /// coalescer so it orders deterministically against the first real feed.
    private func wireEventAndPTY() {
        // Route PTY bytes -> core queue -> bbterm -> publish snapshot.
        // M-4 / PS-01: BOTH closures use [weak self]. The outer captures
        // weakly so a closing window can drop the session promptly; the
        // INNER also captures weakly so an in-flight `feed(data)` block
        // is never the last strong-ref-holder. If it were, completing
        // the block could drop refcount to zero and run `deinit` ON
        // coreQueue's thread; deinit calls `terminate()` which performs
        // `coreQueue.sync` — the classic same-queue-sync deadlock. With
        // both weak captures the chain is broken: when self is gone, the
        // queued block becomes a no-op.
        //
        // Audit M2: setOnBytes serialises the assignment through PTY's
        // readQueue, then startReading() launches the loop. The order
        // matters: bytes the shell emits before the loop starts cannot
        // race past the closure assignment.
        //
        // Audit fix-#06 (2026-05-11) — HANDLER-INSTALL-RACE: the bbterm
        // event handler MUST be installed before any byte path that
        // could feed bbterm.input. The read loop calls onBytes →
        // coreQueue.async → feed → bbterm.input, which fires events
        // through the C trampoline → BBTerm.dispatch. Without a handler
        // installed, BBTerm.dispatch's `guard let handler else { return }`
        // silently drops events. The shell typically emits OSC 7 / OSC
        // 0/2 / DA1 reply within 10-30 ms of spawn (zsh vcs_info,
        // starship, oh-my-zsh, fish themed prompts) — exactly the
        // window between startReading() and the original onEvent
        // assignment. Equally, the two-word Swift closure assignment
        // to BBTerm.handler is not atomic vs a concurrent trampoline
        // read on the coreQueue worker thread.
        // Fix: install bbterm.onEvent and pty.onExit BEFORE setOnBytes
        // /startReading so the dispatch chain is fully wired when bytes
        // arrive. setOnBytes and startReading also stay in order (M2)
        // so the read-loop closure is installed before the loop runs.
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
            // L-14: capture pref-driven gates at decision time, on the
            // queue the event fired on, so a pref-flip during the
            // coreQueue → main hop can't change the answer. Today the
            // only pref-gated case in the switch is OSC 52, but the
            // shape generalises: any future pref-checked branch should
            // capture into `let` here, not read `Preferences.shared`
            // again on main. That avoids the TOCTOU class entirely.
            let osc52EnabledAtDispatch = Preferences.shared.osc52Enabled
            // Audit S5-008: epoch snapshot at event-FIRE time — we are on
            // coreQueue here (events dispatch synchronously inside
            // bb_term_input on coreQueue), so this read is ordered
            // against clearAll's coreQueue.sync bump. Rides the hop so
            // the prompt-mark append can tell "event predates the
            // clear" from "genuine post-clear prompt". The epoch is
            // coreQueue-confined inside the navigator; this read stays on
            // coreQueue exactly as the field read did.
            let clearEpochAtDispatch = self.promptNavigator.currentClearEpochCore
            // SFH-005 sibling: fire the OSC 52 oversize breadcrumb on
            // coreQueue, BEFORE the main hop, so a terminating session
            // can't suppress the security log. The post-hop `guard let
            // self else { return }` would otherwise drop this diagnostic
            // on a session torn down between dispatch and main drain.
            // The static logger needs no `self`, and the gating value
            // rides through to the main hop as `osc52OversizeAtDispatch`
            // so the NSPasteboard write is skipped just like before.
            var osc52OversizeAtDispatch = false
            if case .osc52Clipboard(let text) = event,
               osc52EnabledAtDispatch,
               Self.osc52IsOversize(text.utf8.count) {
                osc52OversizeAtDispatch = true
                Self.osc52Logger.info(
                    "OSC 52 payload \(text.utf8.count, privacy: .public) bytes exceeds \(Self.osc52MaxBytes, privacy: .public) cap — dropping"
                )
            }
            // M-1: re-establish [weak self] for the main hop. The outer
            // closure's `guard let self else { return }` re-bound `self`
            // strongly inside the closure's lexical scope, and that strong
            // ref was implicitly captured here — every queued title /
            // bell / OSC 52 dispatch held a strong ref to the session
            // until main drained. Mirrors the M-4 fix at the inner
            // coreQueue.async site for `feed`.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleCoreEventOnMain(
                    event,
                    osc52EnabledAtDispatch: osc52EnabledAtDispatch,
                    osc52OversizeAtDispatch: osc52OversizeAtDispatch,
                    clearEpochAtDispatch: clearEpochAtDispatch
                )
            }
        }

        // When the child exits (natural or SIGHUP), publish the exit code.
        // Audit fix-#06: now wired BEFORE startReading() so a fast-fail
        // shell (e.g. child _exit(127) immediately on launch) can't fire
        // teardown's main hop with self.onExit == nil.
        //
        // Audit fix-#17 (2026-05-11): use setOnExit(_:) so the assignment
        // is serialised through PTY.readQueue (mirroring setOnBytes).
        // The read-loop teardown reads onExit on main via async-from-
        // readQueue, so this gives us a happens-before chain even if a
        // future caller dispatches start() off-main.
        pty?.setOnExit { [weak self] code in
            self?.exitCode = code
        }

        // Audit M2 (now subsumed under fix-#06): setOnBytes serialises the
        // assignment through PTY's readQueue, then startReading() launches
        // the loop. The bbterm event handler installed ABOVE means any
        // dispatch triggered by the first byte already has a target.
        // NOTE: `enqueueBytesForTests` mirrors this closure exactly so the
        // burst-coalescing tests exercise the production shape — keep both
        // in lockstep if preprocessing is ever added here.
        pty?.setOnBytes { [weak self] data in
            guard let self else { return }
            self.coreQueue.async { [weak self] in
                self?.snapshotCoalescer.feed(data)
            }
        }
        pty?.startReading()

        // Take an initial snapshot so observers have something on screen.
        // Routed through the coalescer so ordering against the first real
        // feed is deterministic (both go through the same single-slot +
        // single-dispatch path).
        coreQueue.async { [weak self] in
            guard let self else { return }
            // S1-007: skip the snapshot work entirely when terminate()
            // already ran. publishPendingSnapshot would gate the actual
            // @Published write, but the upstream bbterm.snapshot() FFI
            // call still allocates a BBSnap (Rust-side Arc) that the
            // wrapper would then drop unobserved. The gate also stops a
            // single trailing snapshot from landing on the @Published
            // pipeline after consumers have torn down their sinks —
            // observable in tests that race construct/terminate.
            if self.isTerminatedLocked() { return }
            if let snap = self.bbterm.snapshot() {
                self.snapshotCoalescer.publishPendingSnapshot(snap)
            }
        }
    }

    /// Apply a core event on the MAIN thread. Split out of `wire()`'s
    /// `bbterm.onEvent` handler (REFACTOR.md Area 4). The dispatch-time gates
    /// that MUST be read on coreQueue at event-fire time — the OSC 52
    /// enabled/oversize decision (L-14 / SFH-005) and the clear epoch (S5-008)
    /// — are captured before the main hop and threaded in here, so this method
    /// never re-reads `Preferences.shared` or `clearEpochCore` (which could
    /// have changed during the hop).
    private func handleCoreEventOnMain(
        _ event: BBTerm.Event,
        osc52EnabledAtDispatch: Bool,
        osc52OversizeAtDispatch: Bool,
        clearEpochAtDispatch: UInt64
    ) {
        switch event {
        case .title(let t):
            // Route through applyOscTitle so a user-set override
            // isn't trampled by a late shell OSC 0/2, and so the
            // .terminalSessionTitleDidChange notification fires.
            titleState.applyOscTitle(t)
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
            //
            // L-14: read the captured `osc52EnabledAtDispatch`
            // (snapshotted on coreQueue before the hop), not
            // `Preferences.shared` directly. A user disabling
            // OSC 52 mid-hop must NOT have the now-disabled
            // payload still land — and a user enabling it
            // mid-hop must NOT see a payload they couldn't have
            // intercepted. Either direction, the captured value
            // is the one consistent with the event-handler
            // ordering and the user's intent at dispatch time.
            guard osc52EnabledAtDispatch else { break }
            // SFH-005: oversize check + forensic breadcrumb
            // already fired on coreQueue before the main hop
            // (see osc52OversizeAtDispatch). Honour the captured
            // decision here to skip the NSPasteboard write —
            // diagnostic is in the unified log even if this hop
            // landed on a terminating session.
            if osc52OversizeAtDispatch { break }
            // Scrub + write goes through ClipboardWriter so the model
            // doesn't touch NSPasteboard directly; the symmetric
            // control/bidi scrub (dirty-enough-to-strip-on-paste-in is
            // dirty-enough-on-paste-out) lives there.
            ClipboardWriter.writeOSC52(text)
        case .cursorShape:
            // Cursor shape is pinned by `Preferences.shared.cursorShape`
            // (Settings → Cursor) and resolved into the renderer via
            // `MetalRenderer.setCursorShapeOverride`. Shell-driven
            // DECSCUSR is intentionally ignored when an override is
            // active so the user's preference wins over a TUI's
            // assumptions about the host terminal.
            break
        case .cwdChanged(let path):
            // OSC 7 ingest + fail-closed SSH-trust gate (Part I §18) +
            // the L3 drop-log latch live in `CwdTracker`. We're on main
            // (the `@Published lastKnownCwd` it drives is main-owned), so
            // the trust classification + store run here exactly as the
            // inline switch did.
            cwdTracker.handleCwdChanged(path)
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
                self.promptNavigator.recordPromptStart(eventClearEpoch: clearEpochAtDispatch)
            }
        case .fatal(let msg):
            // Surface as a title prefix for visibility — the unified
            // log carries the full message via os.Logger, but a title
            // prefix is the only diagnostic surface most users
            // notice. Fatal must display regardless of any user-set
            // override AND must not let a stale override resurface
            // later. Clear the override and route through the state
            // machine so the oscTitle / titleOverride / displayTitle
            // invariant holds — single writer, no divergence between
            // `title` and `displayTitle`.
            titleState.titleOverride = nil
            titleState.applyOscTitle("[fatal] core panic: \(msg)")
        }
    }

    // The feed / scheduleSnapshotAfterBurst / publishPendingSnapshot paths and
    // their pending-slot state moved to `SnapshotCoalescer` (REFACTOR.md Part
    // IV — Finding 2). The session reaches them via `snapshotCoalescer`; the
    // shared `publishLock` keeps every critical section byte-faithful.
}
