import Foundation
import Combine
import QuartzCore
import os

/// `coreQueue` is the single owner of `bbterm`; snapshots publish on main.
public final class TerminalSession: ObservableObject {

    public typealias Size = PTY.Size

    public static let osc52MaxBytes: Int = 1 * 1024 * 1024

    internal static func osc52IsOversize(_ utf8Count: Int) -> Bool {
        utf8Count > osc52MaxBytes
    }

    private static let osc52Logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "osc52")

    static let sessionLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                      category: "session")

    private static var startupLogger: Logger { StartupTelemetry.logger }
    let spawnedAt: CFTimeInterval

    @Published public private(set) var snapshot: BBSnapshot?

    /// The only write site for `snapshot`. Called on the main thread by `SnapshotCoalescer`.
    func publish(_ snap: BBSnapshot) {
        self.snapshot = snap
    }
    public let titleState = SessionTitleState()
    @Published public private(set) var bellCounter: UInt64 = 0
    public let notifications = PassthroughSubject<TerminalNotification, Never>()
    /// -1 for abnormal termination.
    @Published public private(set) var exitCode: Int32?

    @Published public internal(set) var lastKnownCwd: String?

    /// True when the trust gate dropped an OSC 7 after the last one it accepted. Written by `CwdTracker` on main.
    internal var lastKnownCwdIsStale = false

    @Published public internal(set) var lastPromptMark: (kind: BBTerm.PromptMarkKind, exitCode: String)?

    @Published public internal(set) var promptMarks: [PromptMark] = []

    private(set) var promptNavigator: PromptNavigator!

    public typealias PromptMark = PromptNavigator.PromptMark

    /// Touched only on `coreQueue`; the single-owner rule is kept by discipline, not access control.
    let bbterm: BBTerm
    /// nil only for headless test sessions.
    let pty: PTY?
    /// Lets a sync-entry helper detect it is already on `coreQueue` and avoid a `coreQueue.sync` self-deadlock.
    private let coreQueueToken: ObjectIdentifier
    let coreQueue: DispatchQueue
    private static let coreQueueKey = DispatchSpecificKey<ObjectIdentifier>()
    private var isOnCoreQueue: Bool {
        DispatchQueue.getSpecific(key: Self.coreQueueKey) == coreQueueToken
    }
    private var preferencesSubscription: AnyCancellable?

    // MARK: - Main-publish coalescer
    // Shared with `SnapshotCoalescer`: every publish and `terminate()` serialize on this one lock.
    let publishLock = NSLock()
    /// Byte budget between the PTY read loop and `coreQueue`; the reader blocks past it.
    let feedBudget = FeedBudget()

    // MARK: - Feed deferral
    // A queued feed block that sees a user action waiting defers its chunk instead of parsing it.

    /// Written from the calling thread, read by feed blocks on `coreQueue`.
    private let pendingUserActions = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// coreQueue-confined, as is `feedYieldCount`.
    private var deferredFeeds = DeferredFeedQueue()
    private var feedYieldCount = 0

    /// Every main-thread `coreQueue.sync` a user is waiting on goes through here; queued feed blocks yield to it.
    func performUserAction<T>(_ body: () throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .notOnQueue(coreQueue))
        // The count goes up before `sync` enqueues the block, so a running drain can see it and yield.
        // The decrement runs inside the block, so the drain it schedules never sees a stale count.
        pendingUserActions.withLock { $0 += 1 }
        return try coreQueue.sync {
            defer {
                pendingUserActions.withLock { $0 -= 1 }
                if !deferredFeeds.isEmpty {
                    coreQueue.async { [weak self] in self?.drainDeferredFeeds() }
                }
            }
            return try body()
        }
    }

    private func enqueueFeed(_ data: Data) {
        // Blocks the read loop while over budget; false only after `terminate()` cancelled the budget.
        guard feedBudget.acquire(data.count) else { return }
        coreQueue.async { [weak self] in
            guard let self else { return }
            // Always append first: every block appends before deciding, so the byte stream is never reordered.
            self.deferredFeeds.append(data)
            if self.pendingUserActions.withLock({ $0 }) > 0 {
                self.feedYieldCount &+= 1
                return  // the waiting action's block drains us on its way out
            }
            self.drainDeferredFeeds()
        }
    }

    /// coreQueue only. Always parses at least one chunk per entry: under a sustained stream of user
    /// actions progress must be guaranteed, or the budget fills and the child stalls.
    private func drainDeferredFeeds(yieldingToUserActions: Bool = true) {
        while let chunk = deferredFeeds.popFirst() {
            snapshotCoalescer.feed(chunk)
            feedBudget.release(chunk.count)
            if yieldingToUserActions, !deferredFeeds.isEmpty,
               pendingUserActions.withLock({ $0 }) > 0 {
                feedYieldCount &+= 1
                coreQueue.async { [weak self] in self?.drainDeferredFeeds() }
                return
            }
        }
    }

    /// coreQueue only. Runs at the head of the async resize paths so a reflow never precedes earlier output.
    func drainDeferredFeedsBeforeCoreWork() {
        dispatchPrecondition(condition: .onQueue(coreQueue))
        drainDeferredFeeds(yieldingToUserActions: false)
    }
    /// Guarded by `publishLock`; only `terminate()` sets it.
    private(set) var isTerminated: Bool = false
    /// Set under `publishLock` on the first `.fatal` event: the core has poisoned itself after a caught panic.
    private(set) var coreFailed: Bool = false
    @Published public private(set) var coreFailureMessage: String?

    private(set) var snapshotCoalescer: SnapshotCoalescer!

    private var paletteApplier: PaletteApplier!

    private var cwdTracker: CwdTracker!

    private var focusEmitter: FocusEmitter!

    private var resizeController: ResizeController!

    private(set) var syncUpdateWatchdog: SyncUpdateWatchdog!

    private(set) var osc52TrailingFlush: Osc52TrailingFlush!

    public static func start(
        shell: String,
        arguments: [String],
        size: Size,
        initialWorkingDirectory: String? = nil,
        envOverrides: [String: String] = [:]
    ) throws -> TerminalSession {
        let t0 = CACurrentMediaTime()
        guard let bb = BBTerm(
            size: .init(cols: size.cols, rows: size.rows),
            scrollback: Preferences.shared.scrollbackLinesClamped
        ) else {
            throw SessionError.coreInitFailed
        }
        let tCore = CACurrentMediaTime()
        let pty = try PTY.spawn(
            executable: shell,
            arguments: arguments,
            envOverrides: envOverrides,
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

    public enum SessionError: Error, LocalizedError {
        case coreInitFailed

        public var errorDescription: String? {
            switch self {
            case .coreInitFailed:
                return "The terminal engine failed to initialize."
            }
        }
    }

    private init(bbterm: BBTerm, pty: PTY?, spawnedAt: CFTimeInterval) {
        self.bbterm = bbterm
        self.pty = pty
        self.spawnedAt = spawnedAt
        // Explicit `.userInitiated` (matches `PTY.readQueue`): `resizeCoalesced` reaches this queue
        // without the priority boost a `coreQueue.sync` from main gives.
        let q = DispatchQueue(label: "blackbird.core", qos: .userInitiated)
        let token = ObjectIdentifier(bbterm)
        q.setSpecific(key: Self.coreQueueKey, value: token)
        self.coreQueue = q
        self.coreQueueToken = token
        // Assigned before `wire()` so the async closures it schedules never observe these IUO collaborators as nil.
        self.snapshotCoalescer = SnapshotCoalescer(session: self)
        self.paletteApplier = PaletteApplier(session: self)
        self.promptNavigator = PromptNavigator(session: self)
        self.cwdTracker = CwdTracker(session: self)
        self.focusEmitter = FocusEmitter(session: self)
        self.resizeController = ResizeController(session: self)
        self.syncUpdateWatchdog = SyncUpdateWatchdog(session: self)
        self.osc52TrailingFlush = Osc52TrailingFlush(session: self)
        wire()
    }

    #if DEBUG
    static func makeHeadlessForTests() -> TerminalSession {
        guard let bb = BBTerm(size: .init(cols: 2, rows: 2)) else {
            fatalError("BBTerm.init(size:) returned nil for 2×2 headless test session")
        }
        return TerminalSession(bbterm: bb, pty: nil, spawnedAt: CACurrentMediaTime())
    }

    func feedBytesForTests(_ bytes: Data) {
        guard feedBudget.acquire(bytes.count) else { return }
        coreQueue.sync {
            // Never yields: the caller expects the bytes parsed on return.
            self.deferredFeeds.append(bytes)
            self.drainDeferredFeeds(yieldingToUserActions: false)
        }
    }

    func enqueueBytesForTests(_ bytes: Data) {
        enqueueFeed(bytes)
    }

    var feedYieldsForTests: Int {
        coreQueue.sync { feedYieldCount }
    }

    func waitForFeedsForTests() {
        while coreQueue.sync(execute: {
            snapshotCoalescer.snapshotWorkQueued || !deferredFeeds.isEmpty
        }) {
            // Each pass queues behind whatever is currently in flight.
        }
    }

    var snapshotsTakenForTests: Int {
        coreQueue.sync { snapshotCoalescer.snapshotsTakenCount }
    }

    var syncAbortsForTests: Int {
        coreQueue.sync { syncUpdateWatchdog.abortCount }
    }

    var syncWatchdogArmedForTests: Bool {
        coreQueue.sync { syncUpdateWatchdog.isArmedForTesting }
    }

    func takeSnapshotForTests() -> BBSnapshot? {
        return coreQueue.sync { self.bbterm.snapshot() }
    }

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

    /// Synchronous write that bypasses the async write queue, for urgent control characters.
    public func sendImmediate(_ data: Data) {
        pty?.writeImmediate(data)
    }

    public func hasForegroundChild() -> Bool {
        #if DEBUG
        if let override = _testForegroundChildOverride {
            return override
        }
        #endif
        return pty?.hasForegroundChild() ?? false
    }

    #if DEBUG
    var _testForegroundChildOverride: Bool?
    #endif

    public func foregroundWorkingDirectory() -> String? {
        pty?.foregroundWorkingDirectory()
    }

    public func shellWorkingDirectory() -> String? {
        pty?.shellWorkingDirectory()
    }

    /// A headless session (`pty == nil`) deliberately defaults to `.local`, not `.unknown`.
    public func classifyForegroundNamespace() -> ForegroundNamespace {
        #if DEBUG
        if let override = _testForegroundNamespaceOverride {
            return override
        }
        #endif
        return pty?.classifyForegroundNamespace() ?? .local
    }

    #if DEBUG
    var _testForegroundNamespaceOverride: ForegroundNamespace?
    #endif

    public func sendSignalToForeground(_ sig: Int32) {
        pty?.sendSignalToForeground(sig)
    }

    public func focusChanged(_ focused: Bool) {
        focusEmitter.emit(focused)
    }

    // MARK: - Prompt navigation

    @discardableResult
    public func jumpToPreviousPrompt() -> Bool {
        promptNavigator.jumpToPreviousPrompt()
    }

    @discardableResult
    public func jumpToNextPrompt() -> Bool {
        promptNavigator.jumpToNextPrompt()
    }

    // MARK: - Test-only access

    #if DEBUG
    internal func _testAppendMark(_ mark: PromptMark) {
        promptNavigator._testAppendMark(mark)
    }

    internal var _testPromptCursor: Int? { promptNavigator._testPromptCursor }

    internal var _testLoggedUnknownNamespaceDrop: Bool {
        get { cwdTracker.loggedUnknownNamespaceDrop }
        set { cwdTracker.loggedUnknownNamespaceDrop = newValue }
    }

    internal var _testPreferencesSubscription: AnyCancellable? {
        preferencesSubscription
    }
    #endif

    public func resize(to size: Size) {
        resizeController.resize(to: size)
    }

    public func resizeAsync(to size: Size) {
        resizeController.resizeAsync(to: size)
    }

    public func resizeCoalesced(to size: Size) {
        resizeController.resizeCoalesced(to: size)
    }

    /// While true, the view must not take the blocking `resize` path behind it.
    var hasPendingCoalescedResize: Bool {
        resizeController.hasPendingCoalescedResize
    }

    internal static func clampResize(_ size: Size) -> Size {
        let cols = min(1000, max(2, size.cols))
        let rows = min(1000, max(2, size.rows))
        return Size(cols: cols, rows: rows)
    }

    public func scroll(delta: Int32) {
        let snap = performUserAction {
            bbterm.scroll(delta: delta)
            return bbterm.snapshot()
        }
        if let snap { snapshotCoalescer.publishImmediate(snap) }
    }

    public func scrollToBottom() {
        let snap = performUserAction {
            bbterm.scrollToBottom()
            return bbterm.snapshot()
        }
        if let snap { snapshotCoalescer.publishImmediate(snap) }
    }

    public func clearAll() {
        let s = performUserAction {
            bbterm.clearAll()
            // Events fired before this bump carry the old epoch; their prompt-mark appends self-discard on main.
            promptNavigator.bumpClearEpochCore()
            return bbterm.snapshot()
        }
        // Prompt marks encode buffer positions the clear just deleted.
        let resetPromptState: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.promptNavigator.resetForClear()
        }
        onMain(resetPromptState)
        if let s { snapshotCoalescer.publishImmediate(s) }
        // `bb_term_clear_all` preserves OSC 4 palette mutations by design; re-apply the theme
        // so a remote's recolouring does not survive the clear.
        let applyResolved: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let palette = ThemeManager.shared.resolvedPalette
            self.applyPalette(palette)
        }
        onMain(applyResolved)
    }

    /// Reads the latch under `publishLock`, which pairs with the store in `terminate()`.
    func isTerminatedLocked() -> Bool {
        publishLock.lock()
        defer { publishLock.unlock() }
        return isTerminated
    }

    /// Synchronous when already on main: the synchronous-visibility paths rely on landing this tick.
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    public func applyPalette(_ palette: ThemePalette) {
        paletteApplier.apply(palette)
    }

    /// `keepTabFill` is for callers that treat a string offset as a grid column (Find).
    /// `softWrapMarks` terminates every row with `\r` (soft-wrapped) or `\n`.
    public func textRange(
        from start: BufferPoint, to end: BufferPoint, rectangular: Bool,
        keepTabFill: Bool = false, softWrapMarks: Bool = false
    ) -> String {
        return performUserAction {
            bbterm.textRange(
                startLine: start.line, startCol: start.col,
                endLine: end.line, endCol: end.col,
                rectangular: rectangular, keepTabFill: keepTabFill,
                softWrapMarks: softWrapMarks
            ) ?? ""
        }
    }

    /// `sel` is in the frame of `displayed`. nil means it no longer names live cells; "" means they are blank.
    func selectedText(_ sel: Selection, displayedIn displayed: BBSnapshot) -> String? {
        return performUserAction { () -> String? in
            // Read `gridState`, never a snapshot: a snapshot drains the core's damage set and burns
            // a sequence id even when it is not published, leaving changed rows stale on screen.
            guard let live = bbterm.gridState else {
                Self.sessionLogger.error("selectedText: the live grid state is unreadable")
                return nil
            }
            let reconciled = SelectionReconciler.reconciled(
                selection: sel, wordDragAnchor: nil,
                prev: BBTerm.GridState(displayed), next: live
            )
            guard let current = reconciled.selection else {
                Self.sessionLogger.info("selectedText: the selection no longer names live cells (resize, alt-screen toggle, history clear or scrolled out of retention)")
                return nil
            }
            let (start, end) = current.copyRange(cols: live.cols)
            return bbterm.textRange(
                startLine: start.line, startCol: start.col,
                endLine: end.line, endCol: end.col,
                rectangular: current.mode == .rectangular
            )
        }
    }

    public func terminate() {
        // Wake a read loop parked on the feed budget before tearing the PTY down, or
        // `pty.terminate()`'s join waits on a thread that is waiting on us.
        feedBudget.cancel()
        publishLock.lock()
        isTerminated = true
        snapshotCoalescer.dropPendingSnapshotLocked()
        publishLock.unlock()
        preferencesSubscription?.cancel()
        preferencesSubscription = nil
        pty?.terminate()
        // Free the core on coreQueue, the queue that drives `bb_term_input`. If `deinit` fired on
        // coreQueue, `coreQueue.sync` would self-deadlock, so call directly there.
        if isOnCoreQueue {
            self.deferredFeeds.removeAll()
            self.bbterm.terminate()
        } else {
            coreQueue.sync {
                self.deferredFeeds.removeAll()
                self.bbterm.terminate()
            }
        }
    }

    // MARK: - Wiring

    private func wire() {
        // Every `pty` hookup must use optional chaining: headless test sessions call `wire()` with `pty == nil`.

        wireColorQueryPreference()
        wireEventAndPTY()
    }

    /// One @AppStorage write is about 17 `objectWillChange` emissions; these make the sink re-send only on change.
    private var lastSentColorQueryEnabled: Bool?
    private var lastSentOsc52WriteEnabled: Bool?

    private func wireColorQueryPreference() {
        let colorQuery = Preferences.shared.colorQueryEnabled
        let osc52 = Preferences.shared.osc52Enabled
        lastSentColorQueryEnabled = colorQuery
        lastSentOsc52WriteEnabled = osc52
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        coreQueue.async { [bbterm] in
            bbterm.setColorQueryEnabled(colorQuery)
            bbterm.setOsc52WriteEnabled(osc52)
            bbterm.setTerminalVersion(version)
        }
        // Never write UserDefaults in this sink: SwiftUI bridges the change notification back into
        // `Preferences.objectWillChange`, which re-fires the sink indefinitely.
        preferencesSubscription = Preferences.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = Preferences.shared.colorQueryEnabled
                let osc52 = Preferences.shared.osc52Enabled
                let colorChanged = enabled != self.lastSentColorQueryEnabled
                let osc52Changed = osc52 != self.lastSentOsc52WriteEnabled
                guard colorChanged || osc52Changed else { return }
                self.lastSentColorQueryEnabled = enabled
                self.lastSentOsc52WriteEnabled = osc52
                // Weak bbterm so this block is never the last strong reference to it.
                self.coreQueue.async { [weak bbterm = self.bbterm] in
                    guard let bbterm else { return }
                    if colorChanged { bbterm.setColorQueryEnabled(enabled) }
                    if osc52Changed { bbterm.setOsc52WriteEnabled(osc52) }
                }
            }
    }

    /// `onEvent` and `setOnExit` must be installed before `setOnBytes` / `startReading`:
    /// `BBTerm.dispatch` silently drops events fired while no handler is installed.
    private func wireEventAndPTY() {
        bbterm.onEvent { [weak self] event in
            guard let self else { return }
            // Terminal replies (DSR, DA1, DA2, DECRPM) go straight to the PTY from coreQueue, skipping the main hop.
            if case .ptyWrite(let data) = event {
                self.send(data)
                return
            }
            // Capture pref-driven gates on the queue the event fired on; never re-read `Preferences.shared` on main.
            let osc52EnabledAtDispatch = Preferences.shared.osc52Enabled
            // Read on coreQueue at event-fire time, so it is ordered against `clearAll`'s bump.
            let clearEpochAtDispatch = self.promptNavigator.currentClearEpochCore
            // Logged before the main hop so a session torn down mid-hop cannot suppress it.
            var osc52OversizeAtDispatch = false
            if case .osc52Clipboard(let text) = event,
               osc52EnabledAtDispatch,
               Self.osc52IsOversize(text.utf8.count) {
                osc52OversizeAtDispatch = true
                Self.osc52Logger.info(
                    "OSC 52 payload \(text.utf8.count, privacy: .public) bytes exceeds \(Self.osc52MaxBytes, privacy: .public) cap — dropping"
                )
            }
            // Re-establish `[weak self]`: the `guard let self` above re-bound it strongly.
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

        pty?.setOnExit { [weak self] code in
            self?.exitCode = code
        }

        // Both this closure and the queued feed block capture `self` weakly: a feed block holding the last
        // strong reference would run `deinit` on coreQueue, where `terminate()`'s `coreQueue.sync` deadlocks.
        pty?.setOnBytes { [weak self] data in
            self?.enqueueFeed(data)
        }
        pty?.startReading()

        coreQueue.async { [weak self] in
            guard let self else { return }
            if self.isTerminatedLocked() { return }
            if let snap = self.bbterm.snapshot() {
                self.snapshotCoalescer.publishPendingSnapshot(snap)
            }
        }
    }

    /// Runs on main. The gates are captured on coreQueue before the hop; never re-read them here.
    private func handleCoreEventOnMain(
        _ event: BBTerm.Event,
        osc52EnabledAtDispatch: Bool,
        osc52OversizeAtDispatch: Bool,
        clearEpochAtDispatch: UInt64
    ) {
        switch event {
        case .title(let t):
            titleState.applyOscTitle(t)
        case .bell:
            self.bellCounter &+= 1
        case .notification(let title, let body):
            notifications.send(TerminalNotification(title: title, body: body))
        case .ptyWrite:
            break  // handled before the main hop
        case .osc52Clipboard(let text):
            // The payload is already decoded plaintext, not `target;base64`. An empty payload clears the clipboard.
            guard osc52EnabledAtDispatch else { break }
            if osc52OversizeAtDispatch { break }
            ClipboardWriter.writeOSC52(text)
        case .cursorShape:
            // Shell-driven DECSCUSR is ignored: the cursor shape comes from `Preferences.shared.cursorShape`.
            break
        case .cwdChanged(let path):
            cwdTracker.handleCwdChanged(path)
        case .promptMark(let kind, let exitCode, let linesScrolled, let cursorRow):
            // OSC 133: A = prompt start, B = command start, C = output start, D = command end (with exit code).
            self.lastPromptMark = (kind, exitCode)
            // Use the position the core stamped when it parsed the mark: a snapshot taken here
            // comes after every chunk queued behind the mark.
            if kind == .promptStart {
                self.promptNavigator.recordPromptStart(
                    linesScrolled: linesScrolled,
                    gridRow: cursorRow,
                    eventClearEpoch: clearEpochAtDispatch
                )
            }
        case .fatal(let msg):
            // Clear the override first so the fatal title always displays and a stale override cannot resurface.
            titleState.titleOverride = nil
            titleState.applyOscTitle("[fatal] core panic — close this tab: \(msg)")
            publishLock.lock()
            let firstFailure = !coreFailed
            coreFailed = true
            publishLock.unlock()
            // Every core entry is now a no-op: tear down so keystrokes do not reach a child nobody can see.
            if firstFailure {
                coreFailureMessage = msg
                terminate()
            }
        }
    }
}
