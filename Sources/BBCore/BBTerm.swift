import Foundation
import BBCore
import os

/// Swift wrapper over the BBCore C ABI. Not Sendable: use from a single serial queue (the session's core queue).
public final class BBTerm {
    /// Mirror `MIN_DIM` / `MAX_DIM` in `core/src/lib.rs`.
    public static let MIN_DIM: UInt16 = 2
    public static let MAX_DIM: UInt16 = 1000

    /// Set while `dispatch(_:)` runs the handler. A handler that calls back into `bb_term_*` would re-enter the
    /// core while alacritty's `&mut Term` borrow is still live.
    fileprivate var isInsideEventDispatch: Bool = false

    fileprivate static let clampLogger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "bbterm"
    )
    /// The core-failure dialog sends the user to this category, so it must stay named "core".
    fileprivate static let coreLogger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "core"
    )
    /// `.public`: the default redaction would replace the whole message with `<private>`.
    private static let coreLogSink: @convention(c) (UnsafePointer<UInt8>?, UInt) -> Void = { msg, len in
        guard let msg, len > 0 else { return }
        let buf = UnsafeBufferPointer(start: msg, count: Int(len))
        let text = String(decoding: buf, as: UTF8.self)
        BBTerm.coreLogger.notice("\(text, privacy: .public)")
    }
    /// Set-once on the Rust side; must be registered before the first `bb_term_new`.
    private static let installCoreLogSink: Void = {
        bb_set_log_cb(BBTerm.coreLogSink)
    }()
    fileprivate static let didLogDimClamp = OSAllocatedUnfairLock(initialState: false)

    public struct Size: Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Event {
        case title(String)
        case bell
        case cursorShape(Int)
        case osc52Clipboard(String)
        case ptyWrite(Data)
        /// OSC 7 working directory as a decoded local path (no `file://` prefix); the core validates scheme and host.
        case cwdChanged(String)
        /// OSC 133 mark. `exitCode` is set only for kind D. For kind A, `linesScrolled` and `cursorRow` are the
        /// snapshot fields as they stood when the core parsed the mark, not when the handler runs; 0 for B/C/D.
        case promptMark(kind: PromptMarkKind, exitCode: String, linesScrolled: UInt64, cursorRow: Int)
        /// OSC 9 / 777 / 99 notification, scrubbed and capped in the core; never emitted with both halves empty.
        case notification(title: String, body: String)
        case fatal(String)
    }

    /// OSC 133 sub-kinds; mirrors `BBPromptMarkKind` in core/src/lib.rs.
    public enum PromptMarkKind: UInt8 {
        case promptStart = 1
        case commandStart = 2
        case commandOutput = 3
        case commandEnd = 4
    }

    public typealias EventHandler = (Event) -> Void

    private var handle: OpaquePointer?
    private var handler: EventHandler?
    private let ctxBox: UnsafeMutablePointer<EventCtx>

    private final class EventCtx {
        weak var owner: BBTerm?
    }

    public init?(size: Size, scrollback: UInt32 = 100_000) {
        // Dims pass through unclamped so a zero dimension still returns nil; the core clamps to [MIN_DIM, MAX_DIM].
        if size.cols != 0 && size.rows != 0 {
            let clampedCols = min(max(size.cols, Self.MIN_DIM), Self.MAX_DIM)
            let clampedRows = min(max(size.rows, Self.MIN_DIM), Self.MAX_DIM)
            if clampedCols != size.cols || clampedRows != size.rows {
                Self.didLogDimClamp.withLock { logged in
                    if !logged {
                        logged = true
                        Self.clampLogger.warning("dim clamp engaged in BBTerm.init: requested=(\(size.cols, privacy: .public),\(size.rows, privacy: .public)) clamped=(\(clampedCols, privacy: .public),\(clampedRows, privacy: .public)) bounds=[\(Self.MIN_DIM, privacy: .public),\(Self.MAX_DIM, privacy: .public)]")
                    }
                }
            }
        }
        Self.installCoreLogSink
        guard let ptr = bb_term_new(size.cols, size.rows, scrollback) else { return nil }
        self.handle = ptr

        let box = UnsafeMutablePointer<EventCtx>.allocate(capacity: 1)
        box.initialize(to: EventCtx())
        self.ctxBox = box

        box.pointee.owner = self
        bb_term_set_event_cb(ptr, BBTerm.eventTrampoline, UnsafeMutableRawPointer(box))
    }

    /// Order is safety-critical: detach the trampoline's back-reference first (a straggler trampoline then reads a
    /// nil owner), then clear the Rust callback slot, then free the handle.
    private func freeHandle(_ h: OpaquePointer) {
        ctxBox.pointee.owner = nil
        bb_term_set_event_cb(h, nil, nil)
        bb_term_free(h)
    }

    public func terminate() {
        guard let h = handle else { return }
        // Must run on the serial queue that drives `bb_term_input`. Called from inside event dispatch it returns with
        // the handle still set: the core would leak the BBTerm rather than free it under a live borrow.
        assert(
            !isInsideEventDispatch,
            "BBTerm.terminate() called from inside event dispatch — Rust core will leak the BBTerm to avoid UAF (fix-#01/#02). Defer teardown until the handler returns."
        )
        if isInsideEventDispatch {
            return
        }
        freeHandle(h)
        handle = nil
    }

    deinit {
        if let h = handle {
            freeHandle(h)
            // If this deinit runs inside an FFI callback, the core drops the two calls above and its callback slot
            // still points at ctxBox. Swift cannot tell, so leak the box; the trampoline reads owner == nil and bails.
            return
        }
        ctxBox.deinitialize(count: 1)
        ctxBox.deallocate()
    }

    public func onEvent(_ handler: @escaping EventHandler) {
        self.handler = handler
    }

    public func input(_ bytes: [UInt8]) {
        guard let h = handle else { return }
        bytes.withUnsafeBufferPointer { buf in
            bb_term_input(h, buf.baseAddress, UInt(buf.count))
        }
    }

    public func input(_ string: String) {
        input(Array(string.utf8))
    }

    /// Returns the dimensions applied after the `[MIN_DIM, MAX_DIM]` clamp; callers driving `TIOCSWINSZ` must use
    /// those. nil is the core's panic fallback: skip the ioctl, never fall back to the requested dims.
    @discardableResult
    public func resize(to size: Size) -> Size? {
        #if DEBUG
        if size.cols == 0 || size.rows == 0 {
            assertionFailure(
                "BBTerm.resize received zero dimension; got cols=\(size.cols), rows=\(size.rows). "
                + "Wrapper clamps up to MIN_DIM=\(Self.MIN_DIM) so this no longer traps in Release, "
                + "but the call site is feeding garbage — fix it."
            )
        }
        #endif
        let clampedCols = min(max(size.cols, Self.MIN_DIM), Self.MAX_DIM)
        let clampedRows = min(max(size.rows, Self.MIN_DIM), Self.MAX_DIM)
        if clampedCols != size.cols || clampedRows != size.rows {
            Self.didLogDimClamp.withLock { logged in
                if !logged {
                    logged = true
                    Self.clampLogger.warning("dim clamp engaged in BBTerm.resize: requested=(\(size.cols, privacy: .public),\(size.rows, privacy: .public)) clamped=(\(clampedCols, privacy: .public),\(clampedRows, privacy: .public)) bounds=[\(Self.MIN_DIM, privacy: .public),\(Self.MAX_DIM, privacy: .public)]")
                }
            }
        }
        guard let h = handle else { return nil }
        let result = bb_term_resize2(h, clampedCols, clampedRows)
        if result.applied_cols == 0 || result.applied_rows == 0 {
            return nil
        }
        return Size(cols: result.applied_cols, rows: result.applied_rows)
    }

    public func scroll(delta: Int32) {
        guard let h = handle else { return }
        bb_term_scroll(h, delta)
    }

    /// Live mode bits without a snapshot, for callers that need the mode now rather than as of the last frame.
    public var currentMode: BBTermMode {
        guard let h = handle else { return [] }
        return BBTermMode(rawValue: bb_term_current_mode(h))
    }

    public struct GridState: Equatable {
        public let cols: Int
        public let rows: Int
        public let historySize: Int
        public let linesScrolled: UInt64
        public let termMode: BBTermMode

        public init(_ snapshot: BBSnapshot) {
            cols = snapshot.cols
            rows = snapshot.rows
            historySize = snapshot.historySize
            linesScrolled = snapshot.linesScrolled
            termMode = snapshot.termMode
        }

        fileprivate init(_ raw: BBGridState) {
            cols = Int(raw.cols)
            rows = Int(raw.rows)
            historySize = Int(raw.history_size)
            linesScrolled = raw.lines_scrolled
            termMode = BBTermMode(rawValue: raw.mode)
        }
    }

    /// The live grid's frame facts, O(1). Unlike `snapshot()` it drains no damage and burns no sequence id.
    /// nil for a closed handle or when the core could not answer (null / re-entrant / caught panic).
    public var gridState: GridState? {
        guard let h = handle else { return nil }
        let raw = bb_term_grid_state(h)
        return raw.cols == 0 ? nil : GridState(raw)
    }

    public struct SyncUpdateStatus: Equatable {
        public let isPending: Bool
        /// The core's verdict that the update may be aborted. Never recompute it from a Swift clock: vte's timeout
        /// is a private constant in the vendored crate.
        public let isExpired: Bool
        public let remainingNanos: UInt64
        public let bufferedBytes: UInt64

        static let notPending = SyncUpdateStatus(
            isPending: false, isExpired: false, remainingNanos: 0, bufferedBytes: 0)
    }

    public var syncUpdateStatus: SyncUpdateStatus {
        guard let h = handle else { return .notPending }
        let s = bb_term_sync_status(h)
        return SyncUpdateStatus(isPending: s.pending != 0,
                                isExpired: s.expired != 0,
                                remainingNanos: s.remaining_ns,
                                bufferedBytes: s.buffered_bytes)
    }

    /// Aborts a stalled DEC 2026 synchronized update, replaying its buffered bytes; true iff one was open and is
    /// now closed. With `force == false` the core re-checks its own deadline and declines while the update is live.
    @discardableResult
    public func flushSyncUpdate(force: Bool = false) -> Bool {
        guard let h = handle else { return false }
        return bb_term_flush_sync_update(h, force ? 1 : 0) != 0
    }

    /// Re-attempts delivery of an OSC 52 write the core's rate cap held back; it arrives as `.osc52Clipboard`.
    /// Returns the seconds until the cap's window rolls while a write is still held back, nil otherwise.
    @discardableResult
    public func flushSuppressedOsc52() -> TimeInterval? {
        guard let h = handle else { return nil }
        let nanos = bb_term_flush_suppressed_osc52(h)
        return nanos == 0 ? nil : TimeInterval(nanos) / 1_000_000_000
    }

    /// `\x1b[I` on gain, `\x1b[O` on loss; nil unless mode 1004 is active (unrequested, the bytes move the cursor).
    public func focusChangeBytes(focused: Bool) -> Data? {
        guard currentMode.contains(.focusInOut) else { return nil }
        return focused ? Data([0x1b, 0x5b, 0x49]) : Data([0x1b, 0x5b, 0x4f])
    }

    public func scrollToBottom() {
        guard let h = handle else { return }
        bb_term_scroll_to_bottom(h)
    }

    public func clearAll() {
        guard let h = handle else { return }
        bb_term_clear_all(h)
    }

    /// Slot conventions are in BBCore.h. Negative and out-of-range slots are no-ops.
    public func setColor(slot: Int, rgb: UInt32) {
        guard let h = handle else { return }
        guard slot >= 0, slot <= Int(UInt16.max) else { return }
        bb_term_set_named_color(h, UInt16(slot), rgb)
    }

    /// OSC 10 / 11 / 12 `?` replies. The core starts with replies off.
    public func setColorQueryEnabled(_ enabled: Bool) {
        guard let h = handle else { return }
        bb_term_set_color_query_enabled(h, enabled ? 1 : 0)
    }

    /// True once a caught core panic poisoned this terminal; every core entry is a no-op from then on.
    public var isPoisoned: Bool {
        guard let h = handle else { return false }
        return bb_term_is_poisoned(h) != 0
    }

    /// Version string for XTVERSION (`CSI > q`) replies.
    public func setTerminalVersion(_ version: String) {
        guard let h = handle else { return }
        version.withCString { bb_term_set_terminal_version(h, $0) }
    }

    /// Lets OSC 52 clipboard writes reach `.osc52Clipboard` (reads are never answered). Off by default in the core.
    public func setOsc52WriteEnabled(_ enabled: Bool) {
        guard let h = handle else { return }
        bb_term_set_osc52_write_enabled(h, enabled ? 1 : 0)
    }

    /// UTF-8 text between two buffer points: the bounding box when `rectangular`, else a prose-style sweep.
    /// `keepTabFill` yields one character per grid cell, required when a string offset is read as a grid column.
    /// `softWrapMarks` ends every row with `\r` (soft-wrapped) or `\n`. nil on a null handle or a caught core panic.
    public func textRange(
        startLine: Int32, startCol: Int,
        endLine: Int32,   endCol: Int,
        rectangular: Bool,
        keepTabFill: Bool = false,
        softWrapMarks: Bool = false
    ) -> String? {
        guard let h = handle else { return nil }
        // Flag bits: 1 rectangular, 2 keep the tab fill, 4 report soft wraps (see `bb_term_text_range`).
        var flags: UInt8 = 0
        if rectangular { flags |= 0b001 }
        if keepTabFill { flags |= 0b010 }
        if softWrapMarks { flags |= 0b100 }
        // `UInt16(col)` traps on negative or > 65535, so saturate; the core clamps again against the grid edge.
        guard let raw = bb_term_text_range(
            h,
            startLine, UInt16(clamping: startCol),
            endLine,   UInt16(clamping: endCol),
            flags
        ) else {
            return nil
        }
        defer { bb_string_release(raw) }
        let buf = UnsafeBufferPointer(start: raw.pointee.bytes, count: Int(raw.pointee.len))
        return String(decoding: buf, as: UTF8.self)
    }

    /// Per instance, so a gap means this session took snapshots the renderer never saw. Core queue only.
    private var snapshotSequence: UInt64 = 0

    public func snapshot() -> BBSnapshot? {
        guard let h = handle else { return nil }
        guard let raw = bb_term_take_snapshot(h) else { return nil }
        snapshotSequence &+= 1
        return BBSnapshot(retaining: raw, sequenceID: snapshotSequence)
    }

    // MARK: - Event trampoline

    /// Mirrors the C `BBEventKind` ABI (BBCore.h ← core/src/event.rs).
    private enum EventKind {
        static let title: UInt32 = 1
        static let bell: UInt32 = 2
        static let cursorShape: UInt32 = 3
        static let osc52Clipboard: UInt32 = 4
        static let ptyWrite: UInt32 = 5
        static let cwdChanged: UInt32 = 6
        static let promptMark: UInt32 = 7
        static let notification: UInt32 = 8
        static let fatal: UInt32 = 99
    }

    private static let eventTrampoline: @convention(c) (BBEvent, UnsafeMutableRawPointer?) -> Void = { ev, ctx in
        guard let ctx else { return }
        let box = ctx.assumingMemoryBound(to: EventCtx.self)
        guard let owner = box.pointee.owner else { return }
        owner.dispatch(ev)
    }

    private func dispatch(_ ev: BBEvent) {
        guard let handler else { return }
        precondition(
            !isInsideEventDispatch,
            "BBTerm event handler called back into bb_term_* synchronously. "
            + "Route the call through DispatchQueue.main.async or a later "
            + "runloop tick instead. Audit M-9."
        )
        isInsideEventDispatch = true
        defer { isInsideEventDispatch = false }
        // Not the imported `BB_EVENT_KIND_*` constants: Swift 6 makes comparing them with `ev.kind` ill-typed.
        switch ev.kind {
        case EventKind.title:
            handler(.title(Self.string(from: ev)))
        case EventKind.bell:
            handler(.bell)
        case EventKind.cursorShape:
            handler(.cursorShape(Int(ev.i32_arg)))
        case EventKind.osc52Clipboard:
            handler(.osc52Clipboard(Self.string(from: ev)))
        case EventKind.ptyWrite:
            handler(.ptyWrite(Self.data(from: ev)))
        case EventKind.cwdChanged:
            handler(.cwdChanged(Self.string(from: ev)))
        case EventKind.promptMark:
            if let kind = PromptMarkKind(rawValue: UInt8(clamping: ev.i32_arg)) {
                handler(.promptMark(
                    kind: kind,
                    exitCode: Self.string(from: ev),
                    linesScrolled: ev.lines_scrolled,
                    cursorRow: Int(ev.cursor_row)
                ))
            } else {
                assertionFailure(
                    "BB_EVENT_KIND_PROMPT_MARK with unknown raw value \(ev.i32_arg). "
                    + "Swift PromptMarkKind covers 1..=4; Rust ABI has drifted. Audit L-3."
                )
            }
        case EventKind.notification:
            let joined = Self.string(from: ev)
            if let sep = joined.firstIndex(of: "\u{1F}") {
                handler(.notification(
                    title: String(joined[..<sep]),
                    body: String(joined[joined.index(after: sep)...])
                ))
            } else {
                handler(.notification(title: "", body: joined))
            }
        case EventKind.fatal:
            let message = Self.string(from: ev)
            // Logged here, on the core queue, so the entry lands even if the session's main-queue hop is delayed.
            Self.coreLogger.fault("core panic: \(message, privacy: .public)")
            handler(.fatal(message))
        default:
            assertionFailure(
                "BBTerm.dispatch saw unknown BBEventKind raw value \(ev.kind). "
                + "Swift switch covers 1..7 + 99; Rust ABI has drifted. Audit L-3."
            )
        }
    }

    private static func string(from ev: BBEvent) -> String {
        guard let ptr = ev.payload, ev.len > 0 else { return "" }
        let buf = UnsafeBufferPointer(start: ptr, count: Int(ev.len))
        return String(decoding: buf, as: UTF8.self)
    }

    private static func data(from ev: BBEvent) -> Data {
        guard let ptr = ev.payload, ev.len > 0 else { return Data() }
        return Data(bytes: ptr, count: Int(ev.len))
    }
}

/// Mirrors the Rust `bb_mode` constants; bits match `BBSnap.mode` one to one.
public struct BBTermMode: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let altScreen        = BBTermMode(rawValue: 1 << 0)
    public static let appCursor        = BBTermMode(rawValue: 1 << 1)
    public static let appKeypad        = BBTermMode(rawValue: 1 << 2)
    public static let bracketedPaste   = BBTermMode(rawValue: 1 << 3)
    public static let mouseReportClick = BBTermMode(rawValue: 1 << 4)
    public static let mouseMotion      = BBTermMode(rawValue: 1 << 5)
    public static let mouseDrag        = BBTermMode(rawValue: 1 << 6)
    public static let sgrMouse         = BBTermMode(rawValue: 1 << 7)
    public static let focusInOut       = BBTermMode(rawValue: 1 << 8)
    public static let showCursor       = BBTermMode(rawValue: 1 << 9)
    public static let lineWrap         = BBTermMode(rawValue: 1 << 10)
    public static let disambiguateEscCodes = BBTermMode(rawValue: 1 << 11)
    public static let reportEventTypes     = BBTermMode(rawValue: 1 << 12)
    public static let reportAlternateKeys  = BBTermMode(rawValue: 1 << 13)
    public static let reportAllKeysAsEsc   = BBTermMode(rawValue: 1 << 14)
    public static let reportAssociatedText = BBTermMode(rawValue: 1 << 15)
    // (bit 16 = modifyOtherKeys, declared below.)
    /// DEC 1007 alternate scroll: on by default, a TUI opts out with `CSI ? 1007 l`. With `altScreen` set and
    /// mouse reporting off, the wheel becomes ↑/↓ key presses.
    public static let alternateScroll  = BBTermMode(rawValue: 1 << 17)
    /// DEC 1005 UTF-8 mouse coordinates.
    public static let utf8Mouse        = BBTermMode(rawValue: 1 << 18)
    /// xterm `modifyOtherKeys` level ≥ 1 (`CSI > 4 ; 1 m` or `CSI > 4 ; 2 m`). Kitty flags take precedence.
    public static let modifyOtherKeys = BBTermMode(rawValue: 1 << 16)
}

public final class BBSnapshot {
    private let handle: UnsafePointer<BBSnap>

    /// Monotonic per-session id assigned by the owning `BBTerm`. Unlike the handle pointer it survives allocator
    /// address reuse, which is why `MetalRenderer.FrameKey` uses it as its dedup token.
    public let sequenceID: UInt64

    init(retaining raw: UnsafePointer<BBSnap>, sequenceID: UInt64) {
        self.handle = raw
        self.sequenceID = sequenceID
    }

    deinit {
        bb_snap_release(handle)
    }

    public var cols: Int { Int(handle.pointee.cols) }
    public var rows: Int { Int(handle.pointee.rows) }
    public var cursorCol: Int { Int(handle.pointee.cursor_col) }
    public var cursorRow: Int { Int(handle.pointee.cursor_row) }
    public var cursorVisible: Bool { handle.pointee.cursor_visible != 0 }
    /// Lines scrolled above the live grid. 0 = pinned to bottom.
    public var displayOffset: Int { Int(handle.pointee.display_offset) }
    public var historySize: Int { Int(handle.pointee.history_size) }
    /// Monotonic count of lines the primary screen pushed toward scrollback; keeps counting after `historySize`
    /// saturates. In-viewport scrolls (reverse index, IL/DL, DECSTBM regions) move content without moving it.
    /// Consumers: invalidate anchors on any resize; detect ED 3 / RIS clears by `historySize` shrinking.
    public var linesScrolled: UInt64 { handle.pointee.lines_scrolled }
    /// DECSCUSR cursor shape: 0 = block, 1 = bar/beam, 2 = underline, 3 = hidden.
    public var cursorShape: Int { Int(handle.pointee.cursor_shape) }
    /// The cursor sits on the last written cell with a wrap pending, so the logical cursor is one character past
    /// `cursorCol`; character-position math must add 1.
    public var cursorPendingWrap: Bool { handle.pointee.cursor_pending_wrap != 0 }
    public var mode: UInt32 { handle.pointee.mode }
    public var termMode: BBTermMode { BBTermMode(rawValue: mode) }

    public enum CellKind: Equatable {
        case character(Character)
        /// Wide-glyph spacer: `WIDE_CHAR_SPACER`, or `LEADING_WIDE_CHAR_SPACER` at end of line.
        case spacer
        /// Never written: alacritty's `\0` sentinel.
        case empty
    }

    public func cellKind(at col: Int, row: Int) -> CellKind {
        guard col >= 0, row >= 0, col < cols, row < rows else { return .empty }
        guard let idx = Self.flatIndex(row: row, col: col, cols: cols) else { return .empty }
        guard idx < cellCount else { return .empty }
        return Self.classify(handle.pointee.cells[idx])
    }

    /// Shared by every classifying walker; the caller owns the bounds check. Not used by `character(at:row:)`.
    static func classify(_ cell: BBCell) -> CellKind {
        let spacerMask = UInt16(WIDE_CHAR_SPACER) | UInt16(LEADING_WIDE_CHAR_SPACER)
        if cell.flags & spacerMask != 0 {
            return .spacer
        }
        let scalar = cell.ch
        guard scalar != 0 else { return .empty }
        guard let us = Unicode.Scalar(scalar) else { return .empty }
        return .character(Character(us))
    }

    /// Zero-width scalars (combining marks, VS16, ZWJ, ...) the core holds on the cell, in print order.
    fileprivate func zeroWidthScalars(col: Int, row: Int) -> [Unicode.Scalar] {
        guard col >= 0, row >= 0, col < cols, row < rows else { return [] }
        let total = Int(bb_snap_zerowidth_at(handle, UInt16(row), UInt16(col), nil, 0))
        guard total > 0 else { return [] }
        var raw = [UInt32](repeating: 0, count: total)
        let written: Int = raw.withUnsafeMutableBufferPointer { (buf: inout UnsafeMutableBufferPointer<UInt32>) -> Int in
            Int(bb_snap_zerowidth_at(handle, UInt16(row), UInt16(col), buf.baseAddress, UInt(total)))
        }
        return raw.prefix(min(written, total)).compactMap { (v: UInt32) -> Unicode.Scalar? in Unicode.Scalar(v) }
    }

    fileprivate static func flatIndex(row: Int, col: Int, cols: Int) -> Int? {
        let (product, mulOverflow) = row.multipliedReportingOverflow(by: cols)
        if mulOverflow { return nil }
        let (idx, addOverflow) = product.addingReportingOverflow(col)
        if addOverflow { return nil }
        return idx
    }

    /// Row text with spacer cells skipped, plus a UTF-16 unit → starting column map. Zero-width scalars follow their
    /// base character and map to its column. `utf16ToCol` has `text.utf16.count + 1` entries: the trailing sentinel is
    /// the column after the last character's rightmost cell, so a match `[lo, hi)` ends at column `utf16ToCol[hi] - 1`.
    public func rowTextWithUTF16ToColMap(row: Int) -> (text: String, utf16ToCol: [Int])? {
        guard row >= 0, row < rows else { return nil }
        var text = ""
        text.reserveCapacity(cols)
        var utf16ToCol: [Int] = []
        utf16ToCol.reserveCapacity(cols + 1)
        var sentinel = 0
        var c = 0
        while c < cols {
            switch cellKind(at: c, row: row) {
            case .character(let ch):
                var next = c + 1
                while next < cols, cellKind(at: next, row: row) == .spacer {
                    next += 1
                }
                for _ in 0..<ch.utf16.count {
                    utf16ToCol.append(c)
                }
                text.append(ch)
                for z in zeroWidthScalars(col: c, row: row) {
                    for _ in 0..<z.utf16.count {
                        utf16ToCol.append(c)
                    }
                    text.unicodeScalars.append(z)
                }
                sentinel = next
                c = next
            case .spacer:
                c += 1
            case .empty:
                c = cols
            }
        }
        utf16ToCol.append(sentinel)
        return (text, utf16ToCol)
    }

    /// Characters in `[startCol, endCol]`: the DEL count that erases the span via readline. A wide glyph counts once.
    public func nonSpacerCellCount(row: Int, startCol: Int, endCol: Int) -> Int? {
        guard row >= 0, row < rows else { return nil }
        guard startCol >= 0, endCol >= startCol, endCol < cols else { return nil }
        var count = 0
        for c in startCol...endCol {
            if case .character = cellKind(at: c, row: row) {
                count += 1
            }
        }
        return count
    }

    public func character(at col: Int, row: Int) -> Character? {
        // `cells` is an UnsafePointer: an out-of-range index reads arbitrary memory instead of trapping.
        guard col >= 0, row >= 0, col < cols, row < rows else { return nil }
        guard let idx = Self.flatIndex(row: row, col: col, cols: cols) else { return nil }
        guard idx < cellCount else { return nil }
        // Reads `.ch` without the spacer classification: a spacer cell holds 0x20, so this returns " " there, not nil.
        // `HyperlinkResolver.osc8AnchorText` and the URL-continuation scan depend on that.
        let scalar = handle.pointee.cells[idx].ch
        guard scalar != 0, let us = Unicode.Scalar(scalar) else { return nil }
        return Character(us)
    }

    /// The core's `WRAPLINE` bit on the row's last cell. Apps that lay rows out with cursor motion (tmux, TUIs)
    /// never set it.
    public func isSoftWrapped(row: Int) -> Bool {
        guard row >= 0, row < rows, cols > 0,
              let idx = Self.flatIndex(row: row, col: cols - 1, cols: cols),
              idx < cellCount else { return false }
        return handle.pointee.cells[idx].flags & UInt16(WRAPLINE) != 0
    }

    /// Valid for the lifetime of this BBSnapshot.
    public var cellsPointer: UnsafePointer<BBCell> {
        handle.pointee.cells
    }

    public var cellCount: Int {
        Int(handle.pointee.cells_len)
    }

    // MARK: - Damage tracking

    /// Full damage (scroll, display-offset change, ...). Treating it as "repaint everything" is always correct.
    public var damageIsFull: Bool {
        bb_snap_damage_is_full(handle) != 0
    }

    /// Changed row indices; empty when `damageIsFull`. Not cached: each read calls `bb_snap_damage_rows`.
    public var damagedRows: [Int] {
        guard !damageIsFull else { return [] }
        let cap = Int(handle.pointee.rows)
        var out = [UInt16](repeating: 0, count: cap)
        let total = out.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(bb_snap_damage_rows(handle, base, UInt(cap)))
        }
        if total <= cap {
            return out[0..<total].map { Int($0) }
        }
        // `total` exceeded the capacity: retry once at the reported size.
        var retry = [UInt16](repeating: 0, count: total)
        let written = retry.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(bb_snap_damage_rows(handle, base, UInt(total)))
        }
        let n = min(written, retry.count)
        return retry[0..<n].map { Int($0) }
    }

    // MARK: - OSC 8 hyperlink attribution

    public func linkID(row: Int, col: Int) -> UInt32 {
        guard row >= 0, col >= 0, row < rows, col < cols else { return 0 }
        return bb_snap_link_id_at(handle, UInt16(row), UInt16(col))
    }

    /// The FFI pointer is valid for the snapshot's lifetime; the bytes are copied. nil for 0 or an unknown id.
    public func linkURL(id: UInt32) -> String? {
        guard id != 0 else { return nil }
        guard let c = bb_snap_link_url(handle, id) else { return nil }
        return String(cString: c)
    }
}

// MARK: - Accessibility surface

public protocol A11ySnapshotSource: AnyObject {
    /// One String per visible row, trailing whitespace kept. Wide-glyph spacer cells are skipped.
    func visibleRowsAsText() -> [String]

    /// Equal identity means equal content.
    var a11yIdentity: UnsafeRawPointer { get }
}

extension BBSnapshot: A11ySnapshotSource {
    public func visibleRowsAsText() -> [String] {
        var out: [String] = []
        out.reserveCapacity(rows)
        let cellsPtr = cellsPointer
        let cellLen = cellCount
        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                guard let idx = Self.flatIndex(row: r, col: c, cols: cols) else { break }
                guard idx < cellLen else { break }
                // Empty cells become a space so column alignment survives for screen readers.
                switch Self.classify(cellsPtr[idx]) {
                case .character(let ch):
                    line.append(ch)
                    for z in zeroWidthScalars(col: c, row: r) {
                        line.unicodeScalars.append(z)
                    }
                case .spacer:
                    continue
                case .empty:
                    line.append(" ")
                }
            }
            out.append(line)
        }
        return out
    }

    public var a11yIdentity: UnsafeRawPointer {
        UnsafeRawPointer(handle)
    }
}

extension String {
    public func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
