import AppKit
import Foundation
import os
import BBCore

/// Owns the find bar for `TerminalView`: ⌘F spawns a `FindBar` subview; ⌘G /
/// ⌘⇧G cycle matches; `performSearch(query:)` runs the regex / substring search
/// across the visible viewport + scrollback (the regex path is async with a
/// cooperative-cancel + ReDoS pre-gate). Find-mode toggles (⌘⌥C case-sensitive,
/// ⌘⌥R regex) round-trip through `FindBarDelegate` on `TerminalView`, which
/// forwards them here.
///
/// This type owns ALL find state (was the `find*` fields on `TerminalView`) and
/// the search/cycle/regex engine (was `TerminalView+Find.swift`). The view holds
/// it as a `lazy var` and forwards its menu actions + `FindBarDelegate`
/// conformance; `TerminalView+Accessibility` / `+ContextMenu` and the Replace
/// helpers in `TerminalView.swift` read `findController.findBar` / `.findMatches`
/// across the file boundary.
///
/// The `view` back-reference is `unowned`: the controller's lifetime is a strict
/// subset of the view's (the view owns it via `let`/`lazy var`), so it never
/// dangles for any reachable call. The async regex closures capture `[weak self]`
/// (self = this controller) — a publish/timeout that lands after the view (hence
/// this controller) is gone finds `self == nil` and returns before touching
/// `view`, exactly as the old `[weak self]` (self = the view) did. The one
/// thing a late timeout still does without `self` is set the scan's
/// `cancelFlag`, so a worker never outlives its deadline.
final class FindController {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    // MARK: - State

    /// Only `installFindBar()` and the FindBarDelegate close/open path mutate it.
    var findBar: FindBar?
    /// `line`/`startCol` are where the match starts. A match that runs across a
    /// soft wrap has an `endCol` of `cols` or more: it counts on from column 0
    /// of the `line` row, so row `line + endCol / cols` holds the last cell.
    var findMatches: [(line: Int32, startCol: Int, endCol: Int)] = []
    var findCurrentIndex: Int = 0
    var findQuery: String = ""
    /// `BBSnapshot.sequenceID` of the snapshot `findMatches` was scanned
    /// against. `nil` when no scan has run yet (or the cache was just
    /// cleared). Used by `advanceFind` / `highlightCurrentMatch` to
    /// detect that output arrived between `performSearch` and the user
    /// pressing ⌘G — in that case the stored (line, col) tuples may
    /// reference cells that now hold different text, so we re-run
    /// `performSearch` against the live snapshot before advancing.
    /// Audit findbar-selection F11.
    var findMatchesSeq: UInt64?
    /// Monotonic ID assigned to each background regex scan. The latest
    /// scan's ID is `activeRegexSearchID`; when a scan publishes
    /// results, it sets `regexSearchCompletedID = mySearchID` so the
    /// 250 ms timeout sibling task knows whether to fire its
    /// "regex too complex" banner. All three fields are touched only
    /// on the main thread, and only within this file now that the whole
    /// regex engine lives here — hence `private`. Audit findbar-selection F2.
    private var regexSearchIDCounter: UInt64 = 0
    private var activeRegexSearchID: UInt64 = 0
    private var regexSearchCompletedID: UInt64 = 0
    /// Set when ⌘G / ⌘⇧G is pressed while a regex stale-rescan is in flight
    /// (the rescan clears findMatches and repopulates asynchronously). The
    /// scan's main-thread publish honours this instead of resetting to match
    /// 1, so the cycle isn't swallowed and the user's position is preserved.
    /// `anchor` is the (line, startCol) of the match the user was on before
    /// the rescan, used to resume from the equivalent position. Audit
    /// findbar-selection: regex ⌘G swallow + reset.
    var pendingRegexAdvance: (direction: FindBar.Direction, anchor: (line: Int32, startCol: Int)?)?
    /// A user-started regex scan (typed query, option toggle) owes the viewport
    /// a reveal of match 1 when it publishes. Controller state, not a per-scan
    /// argument: the snapshot-driven refresh can start a newer scan before the
    /// user's publishes, and the stale-ID guard then drops the user's scan, so
    /// the scan that does publish must inherit the debt. Set when a
    /// non-preserving regex scan starts; consumed by the publish; cleared by
    /// anything that abandons the search (reset, timeout, a non-regex search).
    private var regexRevealOwed = false

    /// Track that a find-refresh is pending so concurrent snapshot bursts
    /// collapse to one main-queue dispatch.
    private var findRefreshPending: Bool = false
    /// A regex query whose scan hit the 250 ms deadline, and the schedule for
    /// trying it again. Re-running it on every streamed snapshot would burn up
    /// to a deadline's worth of CPU per refresh for a result that may time out
    /// again, but a miss is as likely the buffer or the machine at that instant
    /// as the query, so it is retried, at a growing interval, rather than
    /// given up on.
    private struct RegexTimeout {
        let query: String
        /// When the current run of consecutive misses began. The wait before
        /// the next retry is as long as the query has been failing, so it
        /// doubles with every failed retry.
        let since: DispatchTime
        /// The snapshot-driven refresh leaves the query alone until here. A
        /// retry pushes it past its own deadline so the refreshes that output
        /// triggers meanwhile don't start overlapping scans of it.
        var retryAt: DispatchTime
        /// The banner and selection wipe already ran for this run of misses, so
        /// a silent retry doesn't repeat them.
        var announced = false
    }
    private var regexTimedOut: RegexTimeout?
    private static let regexRetryDelayRange: ClosedRange<TimeInterval> = 2.0...60.0

    // MARK: - State mutation

    /// Drop the cached match set and reset the cycle index + label to "0/0".
    /// The Replace paths call this after a splice edits the live input line,
    /// so find-next can't scroll to a now-stale coordinate. Deliberately does
    /// NOT touch `findQuery` or `pendingRegexAdvance` — the query is still
    /// active (a re-run follows) and any deferred ⌘G is consumed on its own
    /// scan's publish/timeout, not here.
    func clearMatches() {
        findMatches.removeAll()
        findMatchesSeq = nil
        findCurrentIndex = 0
        findBar?.setMatchCount(0, of: 0)
    }

    /// Wipe ALL match state, including the query and any deferred ⌘G. Used by
    /// the find-bar close and the nil-session rebind, which both mean "no
    /// search is active any more". Unlike `clearMatches()` (the Replace-path
    /// variant that keeps the live query) this leaves nothing for a later
    /// ⌘G to cycle, and it makes any in-flight regex scan unwanted (its
    /// publish checks `findQuery`). Deliberately does NOT touch
    /// `view.selection` (F30: Esc-then-⌘C must still copy the found match)
    /// or the bar.
    func reset() {
        findMatches.removeAll()
        findMatchesSeq = nil
        findCurrentIndex = 0
        findQuery = ""
        pendingRegexAdvance = nil
        regexRevealOwed = false
    }

    // MARK: - Theming

    /// The palette most recently pushed through `applyTheme`. Cached so a
    /// bar created AFTER the theme push (⌘F is user-initiated; palettes
    /// are applied at registration + on preference changes) still comes up
    /// themed instead of wearing the system-gray default until the next
    /// theme change.
    private(set) var lastAppliedPalette: ThemePalette?

    /// Forwarded from `TerminalView.applyTheme` — the find bar rides the
    /// same push path as the renderer, so a live bar restyles immediately
    /// on theme / appearance switches.
    func applyTheme(_ palette: ThemePalette) {
        lastAppliedPalette = palette
        findBar?.applyTheme(palette)
    }

    // MARK: - Bar lifecycle

    func installFindBar() {
        let h: CGFloat = 32
        // Sit just below the titlebar, not under it.
        let top = view.titlebarOnlyTopInset
        let bar = FindBar(frame: NSRect(x: 0, y: view.bounds.height - h - top, width: view.bounds.width, height: h))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.delegate = view
        if let palette = lastAppliedPalette {
            bar.applyTheme(palette)
        }
        view.addSubview(bar)
        findBar = bar
    }

    // MARK: - Snapshot observation

    /// Called from `TerminalView.currentSnapshot.didSet`. Find-match coordinates
    /// are relative to the buffer at the time `performSearch` ran; any snapshot
    /// swap may have scrolled history, wrapped lines, or overwritten matched
    /// rows, so rerun the search against the fresh grid (debounced) when the bar
    /// is open with a live query. Audit findbar-selection F11.
    func snapshotDidChange() {
        guard findBar != nil, !findQuery.isEmpty else { return }
        scheduleFindRefresh()
    }

    /// Coalescing window for snapshot-driven reruns. One rerun per main
    /// turn (the old shape) meant a streaming build log re-searched the
    /// whole buffer up to the publish rate; 100 ms keeps the count fresh
    /// to the eye while bounding the work to ten scans a second.
    static let refreshCoalesceInterval: TimeInterval = 0.1

    private func scheduleFindRefresh() {
        guard !findRefreshPending else { return }
        findRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshCoalesceInterval) { [weak self] in
            guard let self else { return }
            self.findRefreshPending = false
            // Query could have been cleared by the time the dispatch fires
            // (FindBar closed, user cleared the field). Early-return then.
            guard !self.findQuery.isEmpty, self.findBar != nil else { return }
            // A query that timed out is left alone until its retry is due
            // (`armRegexRetry` schedules a refresh for that moment, so nothing
            // is lost by dropping the ones in between). The retry holds the
            // refresh off for its own length, so output meanwhile can't start
            // scans that overlap it.
            if var timedOut = self.regexTimedOut, timedOut.query == self.findQuery {
                let now = DispatchTime.now()
                guard timedOut.retryAt <= now else { return }
                timedOut.retryAt = now + Self.regexSearchTimeout + Self.refreshCoalesceInterval
                self.regexTimedOut = timedOut
            }
            self.performSearch(query: self.findQuery, preservingPosition: true)
        }
    }

    /// Lines per `textRange` round trip when capturing scrollback. The
    /// pre-v0.8.1 capture issued one `coreQueue.sync` per line — 100k
    /// round trips per search at the default history, each also waiting
    /// behind queued feed chunks. Rectangular extraction over the full
    /// width yields exactly one row per terminator (no wrap joins, no
    /// trailing trim) so the chunk splits back into lines 1:1; the
    /// terminator is '\r' for a row that soft-wrapped, '\n' otherwise.
    static let scrollbackChunkRows: Int32 = 4096

    /// Most grid cells one merged soft-wrapped entry may hold. A run is
    /// searched as one string so a match can straddle a wrap, but `cat` of a
    /// 10 MB one-line file is a 100k-row run: unbounded, the entry is a
    /// uselessly coarse unit for the regex scan's cancel check (it only looks
    /// between entries) and a super-linear pattern runs far past the 250 ms
    /// deadline. The run is cut at a row boundary instead; a match straddling
    /// a cut is not found, which only a logical line longer than this can hit.
    static let maxMergedRunCells = 16_384

    /// `s` without its trailing run of U+0020 (only spaces: a wide-char
    /// spacer or NBSP is content).
    static func trimmingTrailingSpaces(_ s: String) -> String {
        // UTF-8 backward scan: U+0020 is the single byte 0x20 and never a
        // continuation byte, so this avoids grapheme stepping, and the
        // common nothing-to-trim case returns `s` without a second String.
        let u = s.utf8
        var end = u.endIndex
        while end > u.startIndex {
            let prev = u.index(before: end)
            if u[prev] != 0x20 { break }
            end = prev
        }
        return end == u.endIndex ? s : String(s[..<end])
    }

    /// The haystacks the scan walks: `captureRows(joinSoftWrapped: true)` with
    /// each unit's column bookkeeping left unbuilt until a match needs it (see
    /// `SearchUnit.columnMap`).
    func captureSearchUnits(
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        session: TerminalSession,
        snap: BBSnapshot?
    ) -> [SearchUnit] {
        Self.joiningSoftWrapped(
            capturePhysicalRows(
                topLine: topLine, bottomLine: bottomLine, cols: cols, session: session, snap: snap,
                joinSoftWrapped: true),
            cols: cols)
    }

    /// Tuple view of the same rows, for the tests that pin the haystack
    /// builder: only a map that is known up front is filled in, so a
    /// scrollback-only run (merged or not) shows `nil`.
    func captureRows(
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        session: TerminalSession,
        snap: BBSnapshot?,
        joinSoftWrapped: Bool = false
    ) -> [(line: Int32, hay: String, utf16ToCol: [Int]?)] {
        let rows = capturePhysicalRows(
            topLine: topLine, bottomLine: bottomLine, cols: cols, session: session, snap: snap,
            joinSoftWrapped: joinSoftWrapped)
        guard joinSoftWrapped else { return rows.map { ($0.line, $0.hay, $0.utf16ToCol) } }
        return Self.joiningSoftWrapped(rows, cols: cols).map {
            (u: SearchUnit) -> (line: Int32, hay: String, utf16ToCol: [Int]?) in (u.line, u.hay, u.map)
        }
    }

    /// Haystacks for every buffer line in `topLine...bottomLine`: viewport
    /// rows via the snapshot's cell walker (exact UTF-16 → column map),
    /// scrollback rows in chunks of `scrollbackChunkRows` (one-cell-per-
    /// char approximation, as before; `keepTabFill` stops a tab's blank fill
    /// being collapsed, which would shift every later match left of its
    /// column). Empty rows are omitted. One entry per physical row; the
    /// soft-wrap flag each carries is what `joiningSoftWrapped` merges on.
    ///
    /// `topLine`/`bottomLine` are lines of `snap`'s frame, but the core is
    /// routinely ahead of `snap`, and every line it has scrolled since moves
    /// the scrollback a read would return. The whole capture is therefore ONE
    /// core-queue block (nothing can scroll mid-capture) whose core reads are
    /// shifted onto `snap`'s lines, so scrollback and viewport rows describe
    /// the same frame.
    private func capturePhysicalRows(
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        session: TerminalSession,
        snap: BBSnapshot?,
        joinSoftWrapped: Bool
    ) -> [PhysicalRow] {
        guard bottomLine >= topLine else { return [] }
        return session.performUserAction { () -> [PhysicalRow] in
            capturePhysicalRowsInBlock(
                topLine: topLine, bottomLine: bottomLine, cols: cols, session: session,
                snap: snap, joinSoftWrapped: joinSoftWrapped)
        }
    }

    /// Body of `capturePhysicalRows`; runs on the core queue inside
    /// `session.performUserAction`, so it reads `session.bbterm` directly.
    private func capturePhysicalRowsInBlock(
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        session: TerminalSession,
        snap: BBSnapshot?,
        joinSoftWrapped: Bool
    ) -> [PhysicalRow] {
        var rows: [PhysicalRow] = []
        rows.reserveCapacity(Int(bottomLine - topLine + 1))
        let offset = snap?.displayOffset ?? 0
        let screenRows = snap?.rows ?? 0
        func inViewport(_ ln: Int32) -> Bool {
            let screenRow = Int(ln) + offset
            return snap != nil && screenRow >= 0 && screenRow < screenRows
        }
        // Where `snap`'s lines sit in the live core. Without a frame (nil
        // `snap`) they are the core's own. A frame the core has since resized,
        // reflowed or toggled away from names different cells, so it has no
        // scrollback left to read (`oldestLine` is past every line); its
        // viewport rows still come from `snap`.
        var shift: Int64 = 0
        var oldestLine = Int32.min
        if let snap {
            if let live = session.bbterm.gridState,
               let scrolled = live.linesScrolled(since: BBTerm.GridState(snap)) {
                shift = Int64(scrolled)
                // Lines scrolled out of retention since `snap` are gone.
                oldestLine = Int32(clamping: Int64(scrolled) - Int64(live.historySize))
            } else {
                oldestLine = .max
            }
        }
        func coreText(_ a: Int32, _ b: Int32, softWrapMarks: Bool = false) -> String {
            session.bbterm.textRange(
                startLine: Int32(clamping: Int64(a) - shift), startCol: 0,
                endLine: Int32(clamping: Int64(b) - shift), endCol: max(0, cols - 1),
                rectangular: true, keepTabFill: true, softWrapMarks: softWrapMarks
            ) ?? ""
        }
        func flushChunk(_ chunkStart: Int32, _ b: Int32) {
            let a = max(chunkStart, oldestLine)
            guard a <= b else { return }
            var joined = coreText(a, b, softWrapMarks: true)
            // Byte-level split: the Character-based `split` + `String(piece)`
            // + trim cost two String allocations and grapheme stepping per
            // row, ~16x slower over a 100k-line scan on the main thread.
            // Core rows never contain CR or LF, so a terminator byte always
            // ends a row.
            let rowCount = joined.utf8.reduce(0) { $1 == 0x0A || $1 == 0x0D ? $0 + 1 : $0 }
            // History can shrink between computing `topLine` and this call
            // (RIS, ⌘K, a reflowing resize); the core then clamps the range
            // and returns fewer rows, and assigning them from `a` would shift
            // every match in the chunk. Fall back to per-row capture, which
            // can't misattribute. It has no wrap flag, so it never joins.
            if rowCount != Int(b - a + 1) {
                var ln = a
                while ln <= b {
                    let hay = Self.trimmingTrailingSpaces(coreText(ln, ln))
                    if !hay.isEmpty { rows.append((line: ln, hay: hay, utf16ToCol: nil, softWrapped: false)) }
                    if ln == Int32.max { break }
                    ln += 1
                }
                return
            }
            joined.withUTF8 { buf in
                var ln = a
                var start = 0
                let n = buf.count
                while start < n {
                    var nl = start
                    while nl < n && buf[nl] != 0x0A && buf[nl] != 0x0D { nl += 1 }
                    let softWrapped = nl < n && buf[nl] == 0x0D
                    // Rectangular extraction pads to the full width; drop the
                    // trailing run of spaces so a " " query can't hit padding.
                    // A row that soft-wrapped is full-width content: its
                    // trailing spaces sit inside the logical line.
                    var end = nl
                    if !(joinSoftWrapped && softWrapped) {
                        while end > start && buf[end - 1] == 0x20 { end -= 1 }
                    }
                    if end > start {
                        let hay = String(
                            decoding: UnsafeBufferPointer(rebasing: buf[start..<end]),
                            as: UTF8.self)
                        rows.append((line: ln, hay: hay, utf16ToCol: nil, softWrapped: softWrapped))
                    }
                    ln &+= 1
                    start = nl + 1
                }
            }
        }
        var chunkStart: Int32? = nil
        var ln = topLine
        while ln <= bottomLine {
            if inViewport(ln) {
                if let a = chunkStart { flushChunk(a, ln - 1); chunkStart = nil }
                let screenRow = Int(ln) + offset
                guard let mapped = snap?.rowTextWithUTF16ToColMap(row: screenRow) else {
                    // Snapshot had no cell text for a viewport row (should not
                    // happen; the pre-v0.8.1 loop had this fallback too): take
                    // the core's text rather than dropping the row.
                    let hay = Self.trimmingTrailingSpaces(coreText(ln, ln))
                    if !hay.isEmpty { rows.append((line: ln, hay: hay, utf16ToCol: nil, softWrapped: false)) }
                    if ln == Int32.max { break }
                    ln += 1
                    continue
                }
                do {
                    // The cell walker pads to the grid width; trim the trailing
                    // run of spaces (a prefix cut keeps `utf16ToCol` valid for
                    // every remaining index) and skip all-blank rows, matching
                    // the scrollback chunks. Except a soft-wrapped row, whose
                    // spaces are part of the logical line.
                    let softWrapped = snap?.isSoftWrapped(row: screenRow) ?? false
                    let hay = joinSoftWrapped && softWrapped
                        ? mapped.text : Self.trimmingTrailingSpaces(mapped.text)
                    if !hay.isEmpty {
                        rows.append((line: ln, hay: hay, utf16ToCol: mapped.utf16ToCol, softWrapped: softWrapped))
                    }
                }
            } else {
                if chunkStart == nil { chunkStart = ln }
                if let a = chunkStart, ln - a + 1 >= Self.scrollbackChunkRows {
                    flushChunk(a, ln); chunkStart = nil
                }
            }
            if ln == Int32.max { break }
            ln += 1
        }
        if let a = chunkStart { flushChunk(a, bottomLine) }
        return rows
    }

    /// A captured row plus whether it soft-wrapped onto the next buffer line.
    typealias PhysicalRow = (line: Int32, hay: String, utf16ToCol: [Int]?, softWrapped: Bool)

    /// One haystack for the scan: a physical row, or a run of soft-wrapped
    /// rows merged into one string (so a match can straddle the right edge),
    /// at most `maxMergedRunCells` cells. A match's offsets in `hay` turn into
    /// columns counted on from column 0 of `line` (row `n` of a run starts at
    /// `n * cols`) in one of three ways:
    ///  - `map` is set: a viewport row's exact cell-derived map, or the same
    ///    for a run that includes one;
    ///  - `columnMap()` builds it: a scrollback-only run of anything but plain
    ///    ASCII, where a column is the Character index within its row. Scrollback
    ///    rows carry no cell data, so the unit keeps only the rows (O(rows)) and
    ///    walks the Characters when a match lands in it, not for every piece of
    ///    a 100k-row run (8 bytes per UTF-16 unit, all alive at once, plus a
    ///    grapheme pass over the whole buffer);
    ///  - neither: a lone scrollback row (offsets stay on it, `rebaseCols` 0)
    ///    or a plain full-width ASCII scrollback run (a UTF-16 unit is a
    ///    column, `rebaseCols` > 0).
    struct SearchUnit: Sendable {
        /// The unit's first row (buffer line).
        let line: Int32
        let hay: String
        /// Columns per row to re-base a match with (`matchStartingOnItsRow`);
        /// 0 when offsets stay on `line`'s own row.
        let rebaseCols: Int
        /// The map known up front, if any.
        private(set) var map: [Int]?
        private var pendingRows: ArraySlice<PhysicalRow>?
        private let cols: Int

        init(line: Int32, hay: String, rebaseCols: Int, map: [Int]?, pendingRows: ArraySlice<PhysicalRow>?, cols: Int) {
            self.line = line
            self.hay = hay
            self.rebaseCols = rebaseCols
            self.map = map
            self.pendingRows = pendingRows
            self.cols = cols
        }

        /// The UTF-16 → column map, built on first use; nil when offsets are
        /// already columns.
        mutating func columnMap() -> [Int]? {
            if let rows = pendingRows {
                map = FindController.runColumnMap(rows, cols: cols)
                pendingRows = nil
            }
            return map
        }
    }

    /// Merge each run of soft-wrapped rows (each flagged row followed by the
    /// very next buffer line) into one `SearchUnit`, at most `maxMergedRunCells`
    /// cells each; see `SearchUnit` for how each gets its columns.
    private static func joiningSoftWrapped(_ rows: [PhysicalRow], cols: Int) -> [SearchUnit] {
        var out: [SearchUnit] = []
        out.reserveCapacity(rows.count)
        let maxRows = max(2, maxMergedRunCells / max(cols, 1))
        var first = 0
        while first < rows.count {
            var last = first
            while rows[last].softWrapped, last + 1 < rows.count,
                  rows[last + 1].line == rows[last].line &+ 1,
                  last - first + 1 < maxRows {
                last += 1
            }
            let head = rows[first]
            if last == first {
                out.append(SearchUnit(
                    line: head.line, hay: head.hay, rebaseCols: head.utf16ToCol == nil ? 0 : cols,
                    map: head.utf16ToCol, pendingRows: nil, cols: cols))
                first += 1
                continue
            }
            let run = rows[first...last]
            var hay = ""
            for row in run { hay += row.hay }
            if run.contains(where: { (row: PhysicalRow) -> Bool in row.utf16ToCol != nil }) {
                out.append(SearchUnit(
                    line: head.line, hay: hay, rebaseCols: cols,
                    map: runColumnMap(run, cols: cols), pendingRows: nil, cols: cols))
            } else {
                out.append(SearchUnit(
                    line: head.line, hay: hay, rebaseCols: cols, map: nil,
                    pendingRows: isPlainFullWidthASCII(run, cols: cols) ? nil : run, cols: cols))
            }
            first = last + 1
        }
        return out
    }

    /// The UTF-16 → column map of the merged `run`. A row with no map is a
    /// scrollback row: it gets the legacy one-column-per-Character columns,
    /// offset by its row's `n * cols`.
    private static func runColumnMap(_ run: ArraySlice<PhysicalRow>, cols: Int) -> [Int] {
        var map: [Int] = []
        map.reserveCapacity(run.reduce(1) { (n: Int, row: PhysicalRow) -> Int in n + row.hay.utf16.count })
        for k in run.indices {
            let base = (k - run.startIndex) * cols
            if let rowMap = run[k].utf16ToCol {
                // Every entry but the sentinel names a unit of this row.
                for col in rowMap.dropLast() { map.append(base + col) }
                if k == run.endIndex - 1 { map.append(base + (rowMap.last ?? 0)) }
            } else {
                var col = 0
                for ch in run[k].hay {
                    for _ in 0..<ch.utf16.count { map.append(base + col) }
                    col += 1
                }
                if k == run.endIndex - 1 { map.append(base + col) }
            }
        }
        return map
    }

    /// Whether the scrollback-only `run` needs no map at all: every row is
    /// plain ASCII, and all but the last fill the grid width (a soft-wrapped
    /// row is never trimmed, so it holds `cols` cells). Then unit `i` of the
    /// merged string sits at column `i` of the run.
    private static func isPlainFullWidthASCII(_ run: ArraySlice<PhysicalRow>, cols: Int) -> Bool {
        for k in run.indices {
            let hay = run[k].hay
            // ASCII has one UTF-16 unit per UTF-8 byte; any other scalar takes
            // more bytes than units. O(1) for a native ASCII string.
            guard hay.utf8.count == hay.utf16.count else { return false }
            if k != run.endIndex - 1, hay.utf8.count != cols { return false }
        }
        return true
    }

    // MARK: - Cycle (⌘G / ⌘⇧G)

    func advanceFind(direction: FindBar.Direction) {
        // Capture where the user currently is BEFORE any stale-rescan wipes
        // findMatches, so a regex re-scan can resume from the equivalent
        // position instead of jumping back to match 1.
        let priorAnchor: (line: Int32, startCol: Int)? = {
            guard findCurrentIndex >= 0, findCurrentIndex < findMatches.count else { return nil }
            let m = findMatches[findCurrentIndex]
            return (m.line, m.startCol)
        }()

        // Audit findbar-selection F11: the snapshot may have advanced
        // between performSearch and ⌘G — output arriving scrolls history
        // and overwrites rows, so the cached (line, col) tuples can now
        // reference cells holding different text. Re-scan against the live
        // snapshot before cycling. The async refresh in currentSnapshot.didSet
        // is debounced via DispatchQueue.main.async and may not have fired yet
        // when ⌘G runs in the same runloop turn.
        let willRegexRescan = regexSearchWouldRescan()
        let scanIDBeforeRefresh = activeRegexSearchID
        refreshFindMatchesIfStale()

        // Regex rescan is asynchronous: refreshFindMatchesIfStale cleared
        // findMatches and dispatched a background scan, so findMatches is empty
        // RIGHT NOW. Don't swallow the ⌘G (the old `guard !isEmpty` returned
        // here) and don't let the scan's publish reset to match 1 — defer the
        // cycle to the publish, which resumes from priorAnchor. Audit
        // findbar-selection: regex ⌘G swallow + reset-to-1.
        //
        // Defer ONLY when a scan actually started (a fresh scan ID was minted).
        // An invalid / too-complex regex makes performSearch bail before
        // starting one; deferring then would strand pendingRegexAdvance with no
        // publish to consume it (review: code-reviewer). Fall through to the
        // empty-guard return in that case.
        if willRegexRescan, findMatches.isEmpty, activeRegexSearchID != scanIDBeforeRefresh {
            pendingRegexAdvance = (direction, priorAnchor)
            return
        }

        guard !findMatches.isEmpty else { return }
        switch direction {
        case .forward:  findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        case .backward: findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    /// True when the active query is a regex whose cached matches are stale
    /// vs the live snapshot — i.e. `refreshFindMatchesIfStale()` is about to
    /// trigger an ASYNC rescan that empties `findMatches` synchronously. The
    /// substring path rescans synchronously, so it returns false there.
    func regexSearchWouldRescan() -> Bool {
        guard findBar?.options.regex ?? false else { return false }
        guard !findQuery.isEmpty, let snap = view.currentSnapshot else { return false }
        return findMatchesSeq != snap.sequenceID
    }

    /// Resolve the cycle index to land on after a deferred regex rescan
    /// publishes a fresh match set. Resumes from `anchor` (the match the user
    /// was on) plus one step in `direction`; if that exact match no longer
    /// exists, lands on the nearest match in the travel direction. With no
    /// anchor, behaves like a first cycle (first match forward, last backward).
    func resolveResumeIndex(
        anchor: (line: Int32, startCol: Int)?,
        direction: FindBar.Direction,
        in matches: [(line: Int32, startCol: Int, endCol: Int)]
    ) -> Int {
        guard !matches.isEmpty else { return 0 }
        guard let anchor else {
            switch direction {
            case .forward:  return 0
            case .backward: return matches.count - 1
            }
        }
        let a = (anchor.line, anchor.startCol)
        if let exact = matches.firstIndex(where: { ($0.line, $0.startCol) == a }) {
            switch direction {
            case .forward:  return (exact + 1) % matches.count
            case .backward: return (exact - 1 + matches.count) % matches.count
            }
        }
        // The anchored match is gone (text under it changed) — resume at the
        // nearest surviving match in the travel direction, wrapping.
        switch direction {
        case .forward:  return matches.firstIndex(where: { ($0.line, $0.startCol) > a }) ?? 0
        case .backward: return matches.lastIndex(where: { ($0.line, $0.startCol) < a }) ?? (matches.count - 1)
        }
    }

    // MARK: - Search

    /// Rerun the active search if the cached `findMatches` were computed
    /// against an earlier snapshot than the live one. No-op when the
    /// query is empty (nothing to refresh) or the snapshot's sequenceID
    /// matches the cached one (matches still valid).
    ///
    /// The substring path stamps `findMatchesSeq` synchronously inside
    /// `performSearch`; the regex path stamps it from the main-thread
    /// publish in `runRegexSearchAsync`. Either way, by the time we
    /// observe `findMatchesSeq == snap.sequenceID` the matches are
    /// known-good against `snap`.
    /// Audit findbar-selection F11.
    /// Audit fix-#18 (2026-05-11): callable by `replaceAllMatches` (in
    /// TerminalView.swift) before iterating cached col-real findMatches
    /// against a possibly newer snapshot — the wide-char DEL overcount
    /// window the audit names.
    func refreshFindMatchesIfStale() {
        guard !findQuery.isEmpty else { return }
        guard let snap = view.currentSnapshot else { return }
        if findMatchesSeq != snap.sequenceID {
            performSearch(query: findQuery, preservingPosition: true)
        }
    }

    /// Stale-refresh variant safe to call before a Replace. The substring path
    /// rescans synchronously (preserving the fix-#18 wide-char column
    /// re-derivation), so we refresh there. The REGEX path rescans
    /// asynchronously — calling `refreshFindMatchesIfStale` would clear
    /// findMatches and leave the replace operating on an empty set (a silent
    /// no-op, since the publish lands after the replace's guard). So in regex
    /// mode we skip the refresh and operate on the already-scanned matches;
    /// spliceReplacements still re-derives DEL counts against the live
    /// snapshot. Audit findbar-selection: regex Replace All / Replace no-op.
    func refreshFindMatchesIfStaleForReplace() {
        guard !(findBar?.options.regex ?? false) else { return }
        refreshFindMatchesIfStale()
    }

    /// `preservingPosition` is for rescans the user didn't ask for (the
    /// snapshot-driven refresh and the stale-cache rescan in `advanceFind`):
    /// they keep the cycle index (clamped to the new match count) and the
    /// viewport where they are. A `highlightCurrentMatch` scroll, a wheel
    /// scroll or any output publishes a snapshot, which schedules such a
    /// rescan — resetting to match 1 and re-scrolling there pinned ⌘G to the
    /// second match and yanked the view back after every scroll step.
    func performSearch(query: String, preservingPosition: Bool = false) {
        findQuery = query
        // A timed-out query stays marked across the rescans that retry it (the
        // mark carries the backoff); anything else ends the run of misses.
        if !preservingPosition || regexTimedOut?.query != query { regexTimedOut = nil }
        // A retry of a timed-out query leaves the label alone: flipping it to
        // "No matches" on every retry would announce it to VoiceOver each time.
        let retryingTimedOut = regexTimedOut != nil
        // A fresh search supersedes any ⌘G that was deferred behind an
        // in-flight regex rescan (advanceFind re-sets this AFTER calling us,
        // so its own deferral survives; a user-typed query correctly drops it).
        // A preserving rescan is the same logical search, not a new one: it
        // carries the deferral over (restored below only if a regex scan
        // really starts, so a bail-out can't strand it).
        let carriedAdvance = preservingPosition ? pendingRegexAdvance : nil
        pendingRegexAdvance = nil
        // A user-driven search also settles any reveal an abandoned regex
        // scan was owed; the regex branch re-arms it for its own scan.
        if !preservingPosition { regexRevealOwed = false }
        findMatches.removeAll()
        // Clear the seq stamp now; the substring path below stamps it
        // post-scan, and the regex async path stamps it on the main-queue
        // publish. Leaving an old seq here would let `advanceFind` skip
        // a stale-cache rerun against the new (empty) match set.
        findMatchesSeq = nil
        // Kept (not stashed and restored) when preserving: a second rescan can
        // start before a regex scan publishes, and must still see the position.
        if !preservingPosition { findCurrentIndex = 0 }
        guard let session = view.session, let snap = view.currentSnapshot, !query.isEmpty else {
            findBar?.setMatchCount(0, of: 0)
            view.selection = nil
            return
        }
        let opts = findBar?.options ?? FindBar.Options()
        // Compile the regex once. An invalid regex silently degrades to
        // zero matches (UI placeholder signals regex mode is on; bad
        // patterns just don't match anything until the user fixes them).
        let stringOptions: String.CompareOptions = {
            var s: String.CompareOptions = []
            if !opts.caseSensitive { s.insert(.caseInsensitive) }
            return s
        }()
        // Search the entire retained buffer: from -historySize through rows-1.
        let topLine: Int32 = -Int32(clamping: snap.historySize)
        let bottomLine = Int32(clamping: snap.rows - 1)
        if topLine > bottomLine { return }
        let findMatchLimit = 10_000

        if opts.regex {
            // ReDoS surface: NSRegularExpression over ICU is backtracking,
            // so nested quantifiers on overlapping alternatives (`(a+)+`,
            // `(a|a)+`, `(.*)+`) can take exponential time on a
            // well-crafted haystack. The find bar runs this pattern over
            // every row in the retained buffer on every keystroke; a
            // malicious paste into the query field could hang the main
            // thread for seconds. Three layers of defence:
            //   (1) heuristic pattern gate (cheap, catches textbook shapes)
            //   (2) length cap (keeps the field a "find this text" UI)
            //   (3) 250 ms background-execution timeout — the only
            //       backstop that's actually airtight against a determined
            //       adversary, since NSRegularExpression has no match
            //       timeout API.
            // Audit findbar-selection F2.
            guard RegexSafetyGate.isReasonable(query) else {
                findBar?.setMatchCount(0, of: 0)
                findBar?.showTransientMessage("Regex too complex")
                view.selection = nil
                return
            }
            var regexOpts: NSRegularExpression.Options = []
            if !opts.caseSensitive { regexOpts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: query, options: regexOpts) else {
                // Invalid pattern — show 0 matches, no crash. Surface a
                // transient banner so "0/0" doesn't look identical to
                // "valid pattern with no hits" (SFH-006).
                findBar?.setMatchCount(0, of: 0)
                findBar?.showTransientMessage("Invalid regex pattern")
                view.selection = nil
                return
            }
            // Reflect the cleared-match state in the label immediately
            // so users get a visible response while the background scan
            // runs. The async result will overwrite this if matches are
            // found, or the timeout will replace it with a "too complex"
            // banner if the scan exceeds 250 ms.
            if !retryingTimedOut { findBar?.setMatchCount(0, of: 0) }
            pendingRegexAdvance = carriedAdvance
            // Only a user-driven scan owes the reveal; a preserving scan that
            // takes over from one inherits the flag it already left set.
            if !preservingPosition { regexRevealOwed = true }
            runRegexSearchAsync(
                regex: regex,
                topLine: topLine,
                bottomLine: bottomLine,
                cols: snap.cols,
                limit: findMatchLimit
            )
            return
        }
        // Substring (non-regex) path stays synchronous. `String.range(of:)`
        // is bounded by the haystack length and can't catastrophic-backtrack.
        //
        // Per-row, prefer the snapshot's cell walker (`rowTextWithUTF16ToColMap`)
        // for in-viewport rows: it produces a haystack whose UTF-16 offsets
        // map back to exact grid columns, so wide CJK / emoji and non-BMP
        // scalars no longer skew the reported (startCol, endCol). For
        // scrollback rows (outside the snapshot's viewport) the snapshot
        // doesn't carry cell info; fall back to `session.textRange` and
        // accept the legacy approximation (one-cell-per-char). Audit H4.
        let captured = captureSearchUnits(
            topLine: topLine, bottomLine: bottomLine, cols: snap.cols, session: session, snap: snap
        )
        // ASCII fast path: terminal rows and find queries are overwhelmingly
        // ASCII, and Foundation's `range(of:options:)` costs ~8 us per row.
        // Pre-fold the needle once; any non-ASCII (or CR-bearing) query or
        // row falls through to the Foundation loop below, unchanged.
        let asciiNeedle = Self.asciiNeedle(query: query, caseSensitive: opts.caseSensitive)
        outer: for var row in captured {
            let ln = row.line
            let hay = row.hay
            let rebaseCols = row.rebaseCols
            if let needle = asciiNeedle,
               let ranges = Self.asciiMatchRanges(
                   hay: hay, needle: needle, caseSensitive: opts.caseSensitive,
                   limit: findMatchLimit - findMatches.count
               ) {
                // Resolve the unit's column map only if something matched in it.
                let unitMap = ranges.isEmpty ? nil : row.columnMap()
                for m in ranges {
                    let startCol: Int
                    let endCol: Int
                    if let utf16ToCol = unitMap {
                        let cols = Self.mapUTF16RangeToCols(lo: m.lo, hi: m.hi, utf16ToCol: utf16ToCol)
                        startCol = cols.startCol
                        endCol = cols.endCol
                    } else {
                        startCol = m.lo
                        endCol = m.hi - 1
                    }
                    findMatches.append(Self.matchStartingOnItsRow(
                        line: ln, startCol: startCol, endCol: endCol, cols: rebaseCols))
                }
                if findMatches.count >= findMatchLimit { break outer }
                continue
            }
            var cursor = hay.startIndex
            while let r = hay.range(of: query, options: stringOptions, range: cursor..<hay.endIndex) {
                let startCol: Int
                let endCol: Int
                let unitMap = row.columnMap()
                if unitMap != nil || rebaseCols > 0 {
                    let lo16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.lowerBound.samePosition(in: hay.utf16) ?? hay.utf16.startIndex
                    )
                    let hi16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.upperBound.samePosition(in: hay.utf16) ?? hay.utf16.endIndex
                    )
                    if let utf16ToCol = unitMap {
                        let cols = Self.mapUTF16RangeToCols(lo: lo16, hi: hi16, utf16ToCol: utf16ToCol)
                        startCol = cols.startCol
                        endCol = cols.endCol
                    } else {
                        // Plain-ASCII merged run: a UTF-16 unit is a column
                        // (and O(1) to count; Character stepping is not).
                        startCol = lo16
                        endCol = hi16 - 1
                    }
                } else {
                    // Scrollback row — legacy approximation. Off-by-N for
                    // rows containing wide chars; documented limitation.
                    startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                    endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                }
                findMatches.append(Self.matchStartingOnItsRow(
                    line: ln, startCol: startCol, endCol: endCol, cols: rebaseCols))
                cursor = r.upperBound
                if findMatches.count >= findMatchLimit { break outer }
            }
        }
        // Stamp the seq the matches were computed against; advanceFind
        // checks this before cycling so a snapshot swap between now and
        // ⌘G triggers a re-scan instead of jumping to a stale row.
        findMatchesSeq = snap.sequenceID
        findCurrentIndex = min(findCurrentIndex, max(findMatches.count - 1, 0))
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch(scroll: !preservingPosition)
    }

    /// Pre-folded needle bytes for the ASCII fast path, or nil when the query
    /// is not eligible (non-ASCII, or contains CR — a CRLF pair is a single
    /// Character to Foundation, so CR handling stays on the slow path).
    /// Case-insensitive needles are lowercased (A-Z only) once per search.
    static func asciiNeedle(query: String, caseSensitive: Bool) -> [UInt8]? {
        var bytes = Array(query.utf8)
        guard !bytes.isEmpty else { return nil }
        for b in bytes where b >= 0x80 || b == 0x0D { return nil }
        if !caseSensitive {
            for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] |= 0x20 }
        }
        return bytes
    }

    /// Non-overlapping byte-offset match ranges of `needle` in `hay`, equal to
    /// the Foundation `range(of:)` loop for pure-ASCII, CR-free haystacks.
    /// Returns nil when the row is ineligible (any byte >= 0x80 or a CR) so the
    /// caller falls back to Foundation. At most `limit` ranges are returned.
    /// Offsets are UTF-8 == UTF-16 == Character offsets for ASCII-only text.
    static func asciiMatchRanges(
        hay: String, needle: [UInt8], caseSensitive: Bool, limit: Int
    ) -> [(lo: Int, hi: Int)]? {
        var hay = hay
        return hay.withUTF8 { buf -> [(lo: Int, hi: Int)]? in
            let n = buf.count
            let m = needle.count
            for b in buf where b >= 0x80 || b == 0x0D { return nil }
            var out: [(lo: Int, hi: Int)] = []
            guard m > 0, n >= m, limit > 0 else { return out }
            let first = needle[0]
            var i = 0
            let last = n - m
            while i <= last {
                var c = buf[i]
                if !caseSensitive, c >= 0x41, c <= 0x5A { c |= 0x20 }
                if c == first {
                    var j = 1
                    while j < m {
                        var h = buf[i + j]
                        if !caseSensitive, h >= 0x41, h <= 0x5A { h |= 0x20 }
                        if h != needle[j] { break }
                        j += 1
                    }
                    if j == m {
                        out.append((lo: i, hi: i + m))
                        if out.count >= limit { return out }
                        i += m
                        continue
                    }
                }
                i += 1
            }
            return out
        }
    }

    /// Map a cell-derived UTF-16 `[lo, hi)` range to grid columns. Both ends
    /// clamp into `utf16ToCol`; `endCol` is the column of the LAST included
    /// unit (`hi - 1`) and never drops below `startCol`. The ONE viewport-row
    /// match→column mapping, shared by the substring (`performSearch`) and
    /// regex (`runRegexSearchAsync`) paths — keeping them from drifting on the
    /// wide-char / non-BMP column math (H4/H5). Scrollback rows use the legacy
    /// approximation at the call sites, not this.
    ///
    /// A match may end between a cell's base scalar and the zero-width scalars
    /// (combining marks, VS16, ...) that share its column: a regex stops on a
    /// code point, not a cell. Those trailing units belong to the last matched
    /// cell, so `hi` first advances past them to the next cell's first unit
    /// (or the sentinel); otherwise `endCol` lands one cell short.
    static func mapUTF16RangeToCols(lo: Int, hi: Int, utf16ToCol: [Int]) -> (startCol: Int, endCol: Int) {
        let loIdx = max(0, min(lo, utf16ToCol.count - 1))
        var hiIdx = max(loIdx, min(hi, utf16ToCol.count - 1))
        if hiIdx > loIdx {
            while hiIdx < utf16ToCol.count - 1, utf16ToCol[hiIdx] == utf16ToCol[hiIdx - 1] {
                hiIdx += 1
            }
        }
        let startCol = utf16ToCol[loIdx]
        let endCol = max(startCol, utf16ToCol[hiIdx] - 1)
        return (startCol, endCol)
    }

    /// A match found in a merged soft-wrapped entry has columns counted from
    /// the entry's first row, so it may start on a later row. Re-base it onto
    /// the row it starts on; `endCol` stays counted from that row (see
    /// `findMatches`). Identity for a match inside a single row.
    ///
    /// Pass `cols: 0` (identity) for a lone scrollback row (`SearchUnit.rebaseCols`):
    /// only a merged unit carries columns past the row width, while that row's
    /// offsets are raw UTF-16 / Character counts that zero-width scalars can
    /// push past `cols` without the match leaving its row.
    static func matchStartingOnItsRow(
        line: Int32, startCol: Int, endCol: Int, cols: Int
    ) -> (line: Int32, startCol: Int, endCol: Int) {
        guard cols > 0, startCol >= cols else { return (line, startCol, endCol) }
        let rows = startCol / cols
        return (line &+ Int32(clamping: rows), startCol - rows * cols, endCol - rows * cols)
    }

    // MARK: - Async regex scan

    /// Hard timeout for an async regex scan. Past this the worker is cancelled
    /// and a "too complex" banner shown. Cancellation is cooperative but also
    /// reaches into a single row's match (`scanRegexRows` asks for progress
    /// callbacks on rows where the pattern can blow up), so a polynomial-blowup
    /// row stops with the deadline instead of pinning a core until it finishes.
    private static let regexSearchTimeout: TimeInterval = 0.25

    /// Runs the regex scan on a background queue with a hard 250 ms
    /// deadline. Cancels the scan and surfaces a "Regex too complex"
    /// banner if the deadline fires. Stale results from earlier searches
    /// (user typed another keystroke before this one finished) are
    /// dropped via a monotonic search ID.
    ///
    /// The heavy work here is `enumerateMatches` over each row's text;
    /// observing the cancel flag between rows and inside each row's match
    /// lets the timeout actually take effect mid-scan instead of waiting for
    /// the regex engine to exhaust its backtracking budget. The pre-gate
    /// (`RegexSafetyGate`) can't catch every polynomial blowup
    /// (`.*.*.*.*.*x`), so this is what bounds them.
    /// Audit findbar-selection F2.
    private func runRegexSearchAsync(
        regex: NSRegularExpression,
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        limit: Int
    ) {
        guard let session = view.session else { return }
        let (rows, scanSeq) = captureRegexRows(
            topLine: topLine, bottomLine: bottomLine, cols: cols, session: session
        )

        let mySearchID = nextRegexSearchID()
        activeRegexSearchID = mySearchID
        let scanQuery = findQuery

        // Cooperative cancellation via a heap-allocated atomic-ish flag — a
        // stable reference both the timeout (writes, main) and the worker
        // (reads, off-main) can touch. Per-row checks are racy but harmless:
        // worst case we run one extra row.
        let cancelFlag = AtomicFlag()
        // Set by the worker when `scanRegexRows` returns, so the timeout can
        // tell a scan still running at the deadline from one that finished
        // but was dropped (superseded before its publish).
        let scanFinished = AtomicFlag()

        // Explicit `[weak self]` on the worker too: the nested main-queue
        // hop below re-captures `self` weakly, and Swift 6.4 warns when an
        // inner weak capture shadows an implicit strong one in the enclosing
        // closure. Nothing in the worker body needs `self`.
        let workItem = DispatchWorkItem { [weak self] in
            let matches = Self.scanRegexRows(rows, regex: regex, limit: limit, cancelFlag: cancelFlag)
            scanFinished.value = true
            // If we were cancelled, the timeout already published its banner —
            // don't overwrite it with stale results.
            if cancelFlag.value { return }
            // Hop back to main to publish — UI state + findMatches storage are
            // main-thread-only.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishRegexResults(matches, searchID: mySearchID, scanSeq: scanSeq, query: scanQuery)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regexSearchTimeout) { [weak self] in
            // The deadline owns the cancellation, not `self`: the worker holds
            // no reference to the controller, so if the view (hence this
            // controller) is gone by now, a cancel routed through `self` would
            // never happen and the scan would run on to completion. Set the
            // flag first; only the banner / timed-out mark need the controller.
            // (A scan that already published has left its loop, so this is a
            // no-op for it.)
            cancelFlag.value = true
            guard let self else { return }
            self.handleRegexTimeout(searchID: mySearchID, query: scanQuery, scanFinished: scanFinished)
        }
    }

    /// Snapshot the rows to scan, on the main thread (`session.textRange` reads
    /// the BBTerm grid, which is owned by the session's coreQueue). For in-viewport rows
    /// also capture the cell-derived UTF-16-to-col map so the worker can map
    /// `NSRange` offsets to columns without skewing across wide / non-BMP
    /// chars; scrollback rows fall back to `session.textRange` with a nil map
    /// (legacy approximation, H5). Returns the rows AND the snapshot
    /// `sequenceID` they were sourced from, snapped together (L-16 / DI-10) so
    /// a publish that swaps the snapshot mid-loop can't stamp a stale row-set
    /// with a fresher seq.
    private func captureRegexRows(
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        session: TerminalSession
    ) -> (rows: [SearchUnit], scanSeq: UInt64?) {
        let snap = view.currentSnapshot
        let scanSeq = snap?.sequenceID
        let rows = captureSearchUnits(
            topLine: topLine, bottomLine: bottomLine, cols: cols, session: session, snap: snap
        )
        return (rows, scanSeq)
    }

    /// The off-main scan core: run `regex` over each captured row, mapping
    /// match offsets to grid columns (viewport rows via the cell-derived map,
    /// scrollback via the legacy approximation). Pure — no `self`, no shared
    /// mutable state beyond the cooperative `cancelFlag` it polls — so
    /// it's safe on the worker queue and unit-testable in isolation. Stops at
    /// `limit` matches.
    private static func scanRegexRows(
        _ rows: [SearchUnit],
        regex: NSRegularExpression,
        limit: Int,
        cancelFlag: AtomicFlag
    ) -> [(line: Int32, startCol: Int, endCol: Int)] {
        var matches: [(line: Int32, startCol: Int, endCol: Int)] = []
        var callbacks = 0
        // `.reportProgress` is the only way to interrupt a match already in
        // progress: without it one polynomial-blowup row (`.*.*.*.*.*x` on an
        // 80-column line) runs for tens of seconds after the deadline, an
        // orphaned worker pinning a core. It makes ICU call the block with a
        // nil result (skipped by the guard below) at every start position,
        // which taxes a scan by ~65%, so a row asks for it only when the
        // pattern could run long on a row that wide. The flag read takes a
        // lock, so poll every 256th call.
        let plainRowLimit = RegexSafetyGate.uninterruptibleRowLimit(for: regex.pattern)
        for var row in rows {
            if cancelFlag.value { break }
            let rebaseCols = row.rebaseCols
            let ns = row.hay as NSString
            let matchingOptions: NSRegularExpression.MatchingOptions =
                ns.length > plainRowLimit ? [.reportProgress] : []
            regex.enumerateMatches(
                in: row.hay,
                options: matchingOptions,
                range: NSRange(location: 0, length: ns.length)
            ) { result, _, stop in
                callbacks &+= 1
                if callbacks & 0xFF == 0, cancelFlag.value {
                    stop.pointee = true
                    return
                }
                guard let r = result?.range, r.length > 0 else { return }
                let startCol: Int
                let endCol: Int
                if let utf16ToCol = row.columnMap() {
                    // NSRegularExpression returns UTF-16 offsets; translate via
                    // the row's parallel map so wide / non-BMP chars don't skew
                    // the column report.
                    let cols = mapUTF16RangeToCols(lo: r.location, hi: r.location + r.length, utf16ToCol: utf16ToCol)
                    startCol = cols.startCol
                    endCol = cols.endCol
                } else {
                    // Scrollback row — legacy approximation.
                    startCol = r.location
                    endCol = r.location + r.length - 1
                }
                matches.append(matchStartingOnItsRow(
                    line: row.line, startCol: startCol, endCol: endCol, cols: rebaseCols))
                if matches.count >= limit { stop.pointee = true }
            }
            if matches.count >= limit { break }
        }
        return matches
    }

    /// Whether the scan launched for `query` should still land. The search-ID
    /// guard alone misses the paths that abandon a scan WITHOUT minting a new
    /// ID (and `advanceFind` relies on the ID only changing when a scan really
    /// starts, so they can't mint one): closing the bar, clearing the field,
    /// an invalid / gate-rejected pattern edit, and toggling regex off. Each
    /// leaves the bar gone, the query changed, or regex mode off.
    private func isRegexScanStillWanted(query: String) -> Bool {
        guard let bar = findBar, bar.options.regex else { return false }
        return findQuery == query
    }

    /// Publish a completed regex scan on the main thread. Drops the batch when
    /// a newer search has started (stale-ID guard) or the scan was abandoned
    /// without one (`isRegexScanStillWanted`); stamps `findMatchesSeq`
    /// with the seq the scan ran against (NOT the live `currentSnapshot`, which
    /// may have moved on); honours a ⌘G that arrived mid-scan
    /// (`pendingRegexAdvance`) by resuming from the user's position instead of
    /// resetting to match 1; then highlights. A snapshot-driven refresh scan
    /// (nothing owed: no deferred ⌘G, no `regexRevealOwed`) keeps the clamped
    /// index and leaves the viewport alone, as in `performSearch`. What was
    /// owed is read from controller state, so it survives a newer scan taking
    /// over from the one that incurred it.
    private func publishRegexResults(
        _ matches: [(line: Int32, startCol: Int, endCol: Int)],
        searchID mySearchID: UInt64,
        scanSeq: UInt64?,
        query: String
    ) {
        guard activeRegexSearchID == mySearchID,
              isRegexScanStillWanted(query: query) else { return }
        regexSearchCompletedID = mySearchID
        regexTimedOut = nil
        findMatches = matches
        findMatchesSeq = scanSeq
        // A deferred ⌘G or a user-started search is a user action, so it
        // scrolls even when a refresh scan is the one publishing.
        var scroll = true
        if let pending = pendingRegexAdvance {
            pendingRegexAdvance = nil
            findCurrentIndex = resolveResumeIndex(
                anchor: pending.anchor,
                direction: pending.direction,
                in: matches
            )
        } else if regexRevealOwed {
            findCurrentIndex = 0
        } else {
            findCurrentIndex = min(findCurrentIndex, max(matches.count - 1, 0))
            scroll = false
        }
        regexRevealOwed = false
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch(scroll: scroll)
    }

    /// Fired `regexSearchTimeout` after a scan starts (the caller has already
    /// flipped the cancel flag, so the worker bails promptly even when this
    /// controller is gone). No-op if the scan already published. Otherwise, if
    /// this is still the active search, consume any deferred ⌘G so it can't
    /// fire a surprise delayed jump, and show the "too complex" banner. Runs on
    /// main — serialised with the success-path publish, so observing
    /// `regexSearchCompletedID == mySearchID` means it fully landed.
    /// A scan still running at the deadline (even a superseded one, which the
    /// banner guard below ignores) marks its query timed out so streamed
    /// snapshots stop restarting it until the retry is due; a newer scan
    /// having already published means the query works now, so the mark is
    /// skipped. The banner and the selection wipe belong to a scan someone is
    /// waiting on (a typed query, an option toggle, ⌘G) or the first miss of a
    /// query; a retry the output triggered fails silently, instead of wiping
    /// what the user has selected every time it comes round.
    private func handleRegexTimeout(
        searchID mySearchID: UInt64, query: String, scanFinished: AtomicFlag
    ) {
        if regexSearchCompletedID == mySearchID { return }
        if !scanFinished.value, regexSearchCompletedID < mySearchID,
           isRegexScanStillWanted(query: query) {
            armRegexRetry(query: query)
        }
        // An abandoned scan (bar closed, query edited / cleared, regex off)
        // must not show a banner or wipe the selection — F30 preserves it.
        guard activeRegexSearchID == mySearchID,
              isRegexScanStillWanted(query: query) else { return }
        // A deferred ⌘G (pendingRegexAdvance) was owed to THIS scan, which is
        // now abandoned — drop it deterministically so it isn't silently
        // stranded and can't fire a surprising delayed jump if a later re-run
        // publishes. Mirrors the success path's consume-and-clear.
        // (review: silent-failure-hunter)
        let userWaiting = pendingRegexAdvance != nil || regexRevealOwed
        pendingRegexAdvance = nil
        regexRevealOwed = false
        guard userWaiting || regexTimedOut?.announced != true else { return }
        regexTimedOut?.announced = true
        findBar?.setMatchCount(0, of: 0)
        findBar?.showTransientMessage("Regex too complex")
        view.selection = nil
    }

    /// Mark `query` timed out and schedule its retry, for the interval it has
    /// been failing (2 s the first time, then doubling to a minute). A report
    /// from a scan the refresh superseded lands in the same run of misses and
    /// only moves the retry a little later. The timer re-arms the refresh
    /// itself, so a burst of output that ends inside the interval still gets
    /// its retry, and a refresh that finds the retry not yet due can just drop.
    private func armRegexRetry(query: String) {
        let now = DispatchTime.now()
        let prior = regexTimedOut?.query == query ? regexTimedOut : nil
        let since = prior?.since ?? now
        let failingFor = TimeInterval(now.uptimeNanoseconds - since.uptimeNanoseconds) / 1e9
        let delay = min(max(failingFor, Self.regexRetryDelayRange.lowerBound), Self.regexRetryDelayRange.upperBound)
        let retryAt = now + delay
        regexTimedOut = RegexTimeout(
            query: query, since: since, retryAt: retryAt, announced: prior?.announced ?? false
        )
        DispatchQueue.main.asyncAfter(deadline: retryAt) { [weak self] in
            guard let self, self.regexTimedOut?.query == query else { return }
            self.scheduleFindRefresh()
        }
    }

    /// Heap-allocated cancellation token between the regex worker and
    /// the timeout. Writes from main (timeout); reads from a global
    /// concurrent worker (regex enumerator).
    ///
    /// M-8 / EI-03: previous shape was `var value: Bool = false` —
    /// Swift's memory model has no benign-data-race exemption, and
    /// TSan flags concurrent unsynchronised access to a plain `var`
    /// as undefined behavior. Wrapping the bool in
    /// `OSAllocatedUnfairLock` (macOS 13+, available everywhere
    /// Blackbird ships) makes the read/write pair memory-model-safe
    /// at negligible cost (one atomic compare-exchange per cell), and
    /// silences TSan on sanitised CI runs.
    private final class AtomicFlag {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var value: Bool {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    private func nextRegexSearchID() -> UInt64 {
        regexSearchIDCounter &+= 1
        return regexSearchIDCounter
    }

    // MARK: - Highlight / scroll

    /// `scroll: false` selects the match without moving the viewport, for
    /// snapshot-driven refreshes (the scroll's own snapshot would schedule
    /// another refresh, and the user may have scrolled away on purpose).
    private func highlightCurrentMatch(scroll: Bool = true) {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            view.selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
        // A match across a soft wrap ends on a later row (`endCol` runs on past
        // the last column), so the selection spans rows.
        let cols = view.currentSnapshot?.cols ?? 0
        let endRows = cols > 0 ? m.endCol / cols : 0
        view.selection = Selection(
            anchor: BufferPoint(line: m.line, col: m.startCol),
            cursor: BufferPoint(line: m.line &+ Int32(clamping: endRows), col: m.endCol - endRows * cols),
            mode: .character
        )
        guard scroll else { return }
        scrollCurrentMatchIntoView(followOffscreen: true)
    }

    /// Slack for pixel rounding when deciding how much of a row the bar covers
    /// (a row with at most this much under the bar counts as clear of it).
    static let barOverlapTolerancePoints: CGFloat = 0.5

    /// How many viewport rows an opaque strip covering the top `overlapPoints`
    /// of the grid hides. Pure so the geometry is testable without a view.
    static func rowsHidden(byOverlap overlapPoints: CGFloat, cellHeight: CGFloat) -> Int {
        guard overlapPoints.isFinite, cellHeight.isFinite, cellHeight > 0 else { return 0 }
        let uncovered = overlapPoints - barOverlapTolerancePoints
        guard uncovered > 0 else { return 0 }
        // Cap before the Int conversion: an absurd overlap must not trap.
        return Int(min((uncovered / cellHeight).rounded(.up), 1_000_000))
    }

    /// Scroll delta (positive = toward older history) that moves a match on
    /// viewport row `matchRow` clear of the find bar, or onto the screen.
    ///
    /// - A match above the first visible row (`hiddenRows` rows are under the
    ///   bar; the target row is capped so a very short grid keeps one) is
    ///   scrolled down to that row. The delta is limited to
    ///   `scrollableHistory` (how much older content is left to scroll into),
    ///   so a match near the top of the buffer that cannot be lowered any
    ///   further yields 0 instead of a no-op scroll that would still publish
    ///   a snapshot and trigger a rescan.
    /// - A match below the last row is scrolled up onto it. `spanRows` is how
    ///   many rows further down a soft-wrapped match ends; its last row is the
    ///   one that has to fit, unless that would push the start row under the bar.
    /// - `followOffscreen: false` leaves a match that is off the grid alone,
    ///   so a bar resize never drags the viewport back from where the user
    ///   scrolled it on purpose; it only rescues a match hidden under the bar.
    static func revealScrollDelta(
        matchRow: Int, hiddenRows: Int, rows: Int, scrollableHistory: Int, followOffscreen: Bool,
        spanRows: Int = 0
    ) -> Int {
        let topVisibleRow = max(0, min(hiddenRows, rows - 1))
        if matchRow < topVisibleRow {
            if matchRow < 0 && !followOffscreen { return 0 }
            return max(0, min(topVisibleRow - matchRow, scrollableHistory))
        }
        // A match across a soft wrap ends `spanRows` rows below its start and has
        // to show its last row too. One too tall for the screen keeps its start
        // row (the first below the bar) in view.
        let matchEndRow = matchRow + max(0, spanRows)
        if matchEndRow >= rows {
            guard followOffscreen else { return 0 }
            return max(rows - 1 - matchEndRow, topVisibleRow - matchRow)
        }
        return 0
    }

    /// Rows at the top of the grid the find bar paints over right now. Read
    /// from the bar's live geometry (its bottom edge against the first grid
    /// row), not its nominal height, so it stays right if the bar's placement
    /// or the grid inset changes. The renderer is not inset for the bar.
    private var barHiddenRows: Int {
        guard let bar = findBar, let parent = bar.superview else { return 0 }
        let r = view.convert(bar.frame, from: parent)
        let barBottom = view.isFlipped ? r.maxY : view.bounds.height - r.minY
        let overlap = barBottom - view.cellOriginPx(row: 0, col: 0).y
        return Self.rowsHidden(byOverlap: overlap, cellHeight: view.metrics.cellHeight)
    }

    /// Scroll the current match into view and below the find bar.
    /// displayOffset is how many lines the viewport is above the live grid;
    /// a positive delta to scroll() means "show older content" (upward).
    private func scrollCurrentMatchIntoView(followOffscreen: Bool) {
        guard findCurrentIndex >= 0, findCurrentIndex < findMatches.count,
              let snap = view.currentSnapshot else { return }
        let m = findMatches[findCurrentIndex]
        let delta = Self.revealScrollDelta(
            matchRow: Int(m.line) + snap.displayOffset,
            hiddenRows: barHiddenRows,
            rows: snap.rows,
            scrollableHistory: snap.historySize - snap.displayOffset,
            followOffscreen: followOffscreen,
            spanRows: snap.cols > 0 ? m.endCol / snap.cols : 0
        )
        if delta != 0 { view.session?.scroll(delta: Int32(clamping: delta)) }
    }

    /// The bar changed height (the replace row was shown or hidden), so a
    /// match that was placed just below the old edge may now be under it. Move
    /// it clear again. Skipped while the matches are stale against the live
    /// snapshot (their lines would point at the wrong rows).
    func barHeightDidChange() {
        guard let snap = view.currentSnapshot, findMatchesSeq == snap.sequenceID else { return }
        scrollCurrentMatchIntoView(followOffscreen: false)
    }

    // MARK: - Replace

    #if DEBUG
    /// Byte-capture closure for the replace path. When set, `spliceReplacements`
    /// / `reRunSearchAfterReplace` route bytes here instead of `session.send`,
    /// so integration tests can assert the exact DEL×N + replacement sequence
    /// without a real PTY.
    var replaceByteCapture: ((Data) -> Void)?
    /// Test-only snapshot override for the replace path.
    var replaceSnapshotForTests: BBSnapshot?
    /// Test-only find-matches override for the replace path.
    var replaceFindMatchesForTests: [(line: Int32, startCol: Int, endCol: Int)]?
    #endif

    /// F3 TUI-guard (the view's `findBarShouldAllowReplace` forwards here):
    /// refuse replace when the terminal mode indicates a full-screen TUI (vim,
    /// less, htop) — alt-screen, any mouse-reporting flag, or bracketed-paste
    /// active. In those modes the DEL+UTF-8 byte stream would be interpreted as
    /// key input by the TUI instead of readline-style erase.
    func shouldAllowReplace() -> Bool {
        guard let mode = effectiveSnapshot()?.termMode else {
            // No snapshot yet → nothing to replace anyway; err on "allow" so
            // tests that don't stub a snapshot still exercise the old path.
            return true
        }
        let tuiSignals: BBTermMode = [
            .altScreen,
            .mouseReportClick,
            .mouseMotion,
            .mouseDrag,
            .sgrMouse,
            .bracketedPaste,
        ]
        return mode.intersection(tuiSignals).isEmpty
    }

    /// Replace the current find match with `replacement`. Only works when the
    /// match is on the live input line (cursor row). Otherwise a transient
    /// warning is shown in the find bar.
    func replaceCurrentMatch(with replacement: String) {
        // Re-derive against the live snapshot before splicing — advanceFind and
        // replaceAllMatches both do this (audit fix-#18); replaceCurrentMatch
        // was missing it, so a buffer scroll since the last search could splice
        // the stale (line, startCol) of a wide-char match against a different
        // grid and corrupt the input line. Replace-safe variant: substring
        // refreshes synchronously, regex keeps the already-scanned matches
        // (its rescan is async and would empty the set).
        refreshFindMatchesIfStaleForReplace()
        let matches = effectiveFindMatches()
        guard !matches.isEmpty, findCurrentIndex < matches.count else { return }
        let m = matches[findCurrentIndex]
        guard isOnLiveInputLine(m) else {
            findBar?.showTransientMessage("Only input-line matches can be replaced")
            return
        }
        spliceReplacements(matches: [m], replacement: replacement)
        // The replacement edits the shell line; every recorded match on that
        // line has now shifted or vanished. Drop the cache so find-next doesn't
        // scroll to a stale coordinate.
        clearMatches()
        // F5: re-run the search after the byte stream has had a chance to land,
        // so the label reads the live post-replace count (standard VS Code /
        // TextEdit behaviour).
        reRunSearchAfterReplace()
    }

    /// Re-run the current find query on the next runloop tick. Called after a
    /// successful replace so the match label reflects the edited line instead of
    /// stale "0/0". Scheduled async so the shell has a moment to echo the
    /// DEL+replacement bytes back through the render pipeline; the snapshot
    /// observer also schedules a refresh, so this double-booking is harmless —
    /// `performSearch` overwrites the match array atomically. Audit
    /// findbar-selection F5.
    private func reRunSearchAfterReplace() {
        #if DEBUG
        // In tests there's no shell to echo bytes; skip the async hop so
        // assertions against `findMatches` don't race the dispatch.
        if replaceByteCapture != nil { return }
        #endif
        let query = findQuery
        guard !query.isEmpty, findBar != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.findQuery.isEmpty, self.findBar != nil else { return }
            self.performSearch(query: query)
        }
    }

    /// Replace all find matches with `replacement`, processing right-to-left so
    /// earlier column indices stay valid as the shell receives each replacement.
    /// Matches not on the live input line are skipped; if any were skipped a
    /// warning is shown in the find bar.
    ///
    /// F4 (findbar-selection): when a match sits on the row immediately above
    /// the cursor AND that row looks soft-wrap-filled (its last cell is
    /// non-blank — shells fill right up to the wrap column before wrapping),
    /// refuse with a warning. Without the wrap-flag FFI we can't be certain;
    /// erring on the side of refusal avoids emitting DEL bytes that overshoot
    /// into wrapped prior content. Rows with a trailing blank are treated as
    /// unrelated scrollback and their matches are silently skipped, preserving
    /// the documented behaviour for non-wrapped off-line matches.
    func replaceAllMatches(with replacement: String) {
        // Audit fix-#18 (2026-05-11): re-derive findMatches against the current
        // snapshot before iterating. A user who scrolls between ⌘F's
        // performSearch and clicking Replace All can have col-real findMatches
        // (cell-walked, in-viewport branch) paired with a snapshot whose cursor
        // is now off-viewport — sendReplacement's nonSpacerCellCount fallback
        // then col-spans a wide-char match and overcounts DELs by one per wide
        // glyph. advanceFind already calls refreshFindMatchesIfStale;
        // replaceAllMatches needs the same discipline. Use the replace-safe
        // variant so a stale REGEX query doesn't async-clear findMatches and
        // turn Replace All into a silent no-op.
        refreshFindMatchesIfStaleForReplace()
        let matches = effectiveFindMatches()
        guard !matches.isEmpty else { return }
        guard let snap = effectiveSnapshot() else { return }
        let cursorLine = Int32(snap.cursorRow)
        let inputLineMatches = matches.filter { $0.line == cursorLine && $0.endCol < snap.cols }

        let hadOffLine = inputLineMatches.count < matches.count
        if inputLineMatches.isEmpty {
            findBar?.showTransientMessage("No input-line matches to replace")
            return
        }
        // Wrap-ambiguity guard: a match on the row immediately above the cursor
        // *might* be a soft-wrap continuation of the input line. A shell that's
        // soft-wrapped typically fills right up to the right edge (last cell
        // non-blank); a scrollback row usually has trailing blanks. Refuse only
        // when the prior row's last cell is non-blank AND contains a match —
        // otherwise fall through to the scrollback-skip path. Audit
        // findbar-selection F4.
        //
        // Audit fix-#08 (2026-05-11): the `row` parameter on
        // BBSnapshot.character(at:row:) indexes the viewport cells array
        // (0..rows-1), NOT the buffer-line coordinate space. cursorLine is
        // live-grid-row-relative; the corresponding viewport-row when
        // displayOffset > 0 is `cursorLine + displayOffset`. Without the offset
        // addition, a scrolled-back user clicking Replace All would read a stray
        // scrollback row's last cell instead of the line physically above the
        // cursor, mis-firing the guard either way (false-negative leads to DEL
        // bytes overshooting wrapped input — the very corruption the guard
        // exists to prevent).
        let priorRow = cursorLine - 1
        let priorViewportRow = Int(priorRow) + snap.displayOffset
        if matches.contains(where: { $0.line == priorRow }),
           snap.cols > 0,
           let priorLastCell = snap.character(at: snap.cols - 1, row: priorViewportRow),
           !priorLastCell.isWhitespace {
            findBar?.showTransientMessage("Refusing: matches span a possible wrapped input line")
            return
        }
        // Process right-to-left as ONE splice: the cursor walks left match by
        // match, so each match's gap is computed against the post-replacement
        // position of the matches to its right (audit S5-003 — the old per-match
        // sends assumed DELs landed at the match columns, which they never did).
        spliceReplacements(
            matches: inputLineMatches.sorted(by: { $0.startCol > $1.startCol }),
            replacement: replacement
        )
        // All input-line matches have been spliced; invalidate the cache.
        clearMatches()
        if hadOffLine {
            findBar?.showTransientMessage("Replaced input-line matches (scrollback skipped)")
        } else {
            // F5: re-run the search so the user sees fresh match counts against
            // the newly-edited line. Without this, the label reads "No matches"
            // even though the replacement string may itself match the query.
            // `performSearch` short-circuits on an empty query; scheduling is
            // deferred to the next runloop tick so the shell has time to echo
            // the bytes back.
            reRunSearchAfterReplace()
        }
    }

    /// Splice replacements into the live input line (audit S5-003).
    ///
    /// DEL (0x7F) erases the character LEFT OF THE SHELL CURSOR — not at the
    /// match's columns. This version repositions in character space: for each
    /// match (right-to-left, all on the cursor row), emit left-arrows (CSI D)
    /// from the tracked cursor position to the match end, then DEL×len, then the
    /// replacement; finish with right-arrows (CSI C) back to the (shifted) end
    /// of line. All counts are derived from ONE snapshot in shell-character
    /// units via nonSpacerCellCount (a wide CJK glyph is one character / one DEL
    /// / one arrow even though it spans two columns — audit H6). Arrows are
    /// bound to char movement in readline/ZLE emacs AND vi-insert modes, and the
    /// replace path is already gated off TUI modes.
    ///
    /// Known residual: a match inside the PROMPT region — not the typed input —
    /// cannot be edited; readline stops cursor movement at the input start, so
    /// such a splice still misfires. OSC 133 B tracking would be the future fix.
    ///
    /// All-or-nothing: validation failures (line break / tab / multi-scalar
    /// grapheme in the replacement) refuse BEFORE any byte is emitted, so the
    /// line is never left half-spliced.
    private func spliceReplacements(
        matches: [(line: Int32, startCol: Int, endCol: Int)],
        replacement: String
    ) {
        guard !matches.isEmpty, let snap = effectiveSnapshot() else { return }
        // Scrub the replacement through the same pipeline paste uses (the
        // find-bar Replace field bypasses our paste sanitizer): a Trojan-Source
        // RLO typed/pasted there would otherwise smuggle the bidi byte straight
        // into the shell. Same C0/C1/bidi/ZWJ/tag-block set. Audit M10.
        let cleanedReplacement = PasteSanitizer.stripBidiOverrides(
            PasteSanitizer.sanitizePasteControls(Data(replacement.utf8))
        )
        switch ShellLineEditor.spliceBytes(
            matches: matches, cleanedReplacement: cleanedReplacement, snapshot: snap
        ) {
        case .failure(let reason):
            findBar?.showTransientMessage(reason.message)
        case .success(let bytes):
            guard !bytes.isEmpty else { return }
            #if DEBUG
            if let capture = replaceByteCapture {
                capture(bytes)
                return
            }
            #endif
            guard let session = view.session else { return }
            session.send(bytes)
        }
    }

    /// True when the match's buffer line equals the cursor's buffer line, i.e.
    /// the match is on the live shell input line, and it ends on that row too:
    /// the splice counts columns on one row, so a match running on across a
    /// soft wrap can't be replaced.
    private func isOnLiveInputLine(_ m: (line: Int32, startCol: Int, endCol: Int)) -> Bool {
        guard let snap = effectiveSnapshot() else { return false }
        return m.line == Int32(snap.cursorRow) && m.endCol < snap.cols
    }

    /// The snapshot to use for replace logic: test override when set, else live.
    private func effectiveSnapshot() -> BBSnapshot? {
        #if DEBUG
        if let override = replaceSnapshotForTests { return override }
        #endif
        return view.currentSnapshot
    }

    /// The find-matches array to use for replace logic: test override, else live.
    private func effectiveFindMatches() -> [(line: Int32, startCol: Int, endCol: Int)] {
        #if DEBUG
        if let override = replaceFindMatchesForTests { return override }
        #endif
        return findMatches
    }
}
