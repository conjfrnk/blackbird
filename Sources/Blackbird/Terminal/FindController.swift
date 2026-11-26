import AppKit
import Foundation
import os
import BBCore

/// `view` is unowned (the view owns this controller). The async regex closures capture `[weak self]` and
/// return before touching `view`; a late timeout still sets the scan's `cancelFlag` without `self`.
final class FindController {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    // MARK: - State

    var findBar: FindBar?
    /// A match across a soft wrap has `endCol >= cols`: it counts on from column 0 of the `line` row, so
    /// row `line + endCol / cols` holds the last cell.
    var findMatches: [(line: Int32, startCol: Int, endCol: Int)] = []
    var findCurrentIndex: Int = 0
    var findQuery: String = ""
    var findMatchesSeq: UInt64?
    private var regexSearchIDCounter: UInt64 = 0
    private var activeRegexSearchID: UInt64 = 0
    private var regexSearchCompletedID: UInt64 = 0
    /// ⌘G pressed while a regex rescan is in flight; its publish honours it instead of resetting to match 1.
    var pendingRegexAdvance: (direction: FindBar.Direction, anchor: (line: Int32, startCol: Int)?)?
    /// Controller state, not a per-scan argument: a snapshot-driven scan can supersede the user's before
    /// it publishes, and the scan that does publish must inherit the owed reveal of match 1.
    private var regexRevealOwed = false

    private var findRefreshPending: Bool = false
    /// A regex query whose scan hit the deadline is retried at a growing interval, not on every snapshot.
    private struct RegexTimeout {
        let query: String
        let since: DispatchTime
        var retryAt: DispatchTime
        var announced = false
    }
    private var regexTimedOut: RegexTimeout?
    private static let regexRetryDelayRange: ClosedRange<TimeInterval> = 2.0...60.0

    // MARK: - State mutation

    /// Keeps `findQuery` and `pendingRegexAdvance`: the query is still active and a re-run follows.
    func clearMatches() {
        findMatches.removeAll()
        findMatchesSeq = nil
        findCurrentIndex = 0
        findBar?.clearMatchLabel()
    }

    /// Does not touch `view.selection` (Esc-then-⌘C must still copy the found match) or the bar.
    func reset() {
        findMatches.removeAll()
        findMatchesSeq = nil
        findCurrentIndex = 0
        findQuery = ""
        pendingRegexAdvance = nil
        regexRevealOwed = false
    }

    // MARK: - Theming

    private(set) var lastAppliedPalette: ThemePalette?

    func applyTheme(_ palette: ThemePalette) {
        lastAppliedPalette = palette
        findBar?.applyTheme(palette)
    }

    // MARK: - Bar lifecycle

    func installFindBar() {
        let h: CGFloat = 32
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

    func snapshotDidChange() {
        guard findBar != nil, !findQuery.isEmpty else { return }
        scheduleFindRefresh()
    }

    static let refreshCoalesceInterval: TimeInterval = 0.1

    private func scheduleFindRefresh() {
        guard !findRefreshPending else { return }
        findRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshCoalesceInterval) { [weak self] in
            guard let self else { return }
            self.findRefreshPending = false
            guard !self.findQuery.isEmpty, self.findBar != nil else { return }
            // A timed-out query is left alone until its retry is due (`armRegexRetry` schedules a refresh for
            // that moment); the retry holds the refresh off for its own length so scans can't overlap it.
            if var timedOut = self.regexTimedOut, timedOut.query == self.findQuery {
                let now = DispatchTime.now()
                guard timedOut.retryAt <= now else { return }
                timedOut.retryAt = now + Self.regexSearchTimeout + Self.refreshCoalesceInterval
                self.regexTimedOut = timedOut
            }
            self.performSearch(query: self.findQuery, preservingPosition: true)
        }
    }

    /// Rectangular extraction over the full width yields exactly one row per terminator: '\r' for a row
    /// that soft-wrapped, '\n' otherwise.
    static let scrollbackChunkRows: Int32 = 4096

    /// The regex scan's cancel check only looks between entries, so a merged run is cut at a row boundary;
    /// a match straddling a cut is not found.
    static let maxMergedRunCells = 16_384

    /// Trims only U+0020 (a wide-char spacer or NBSP is content); 0x20 is never a UTF-8 continuation byte.
    static func trimmingTrailingSpaces(_ s: String) -> String {
        let u = s.utf8
        var end = u.endIndex
        while end > u.startIndex {
            let prev = u.index(before: end)
            if u[prev] != 0x20 { break }
            end = prev
        }
        return end == u.endIndex ? s : String(s[..<end])
    }

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

    /// `keepTabFill` stops a tab's blank fill being collapsed, which would shift later matches left.
    /// `topLine`/`bottomLine` are lines of `snap`'s frame, but the core is routinely ahead of `snap`: the
    /// whole capture is ONE core-queue block whose core reads are shifted onto `snap`'s lines.
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

    /// Runs on the core queue inside `session.performUserAction`, so it reads `session.bbterm` directly.
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
        // Where `snap`'s lines sit in the live core. A frame the core has since resized, reflowed or toggled
        // away from has no scrollback left to read (`oldestLine` is past every line).
        var shift: Int64 = 0
        var oldestLine = Int32.min
        if let snap {
            if let live = session.bbterm.gridState,
               let scrolled = live.linesScrolled(since: BBTerm.GridState(snap)) {
                shift = Int64(scrolled)
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
            // Byte-level split (Character-based `split` is ~16x slower here); core rows never contain CR or LF.
            let rowCount = joined.utf8.reduce(0) { $1 == 0x0A || $1 == 0x0D ? $0 + 1 : $0 }
            // History can shrink before this call (RIS, ⌘K, a reflowing resize): the core then returns fewer
            // rows, and assigning them from `a` would shift every match. Per-row capture can't misattribute.
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
                    // Rectangular extraction pads to the full width; drop trailing spaces so a " " query can't hit
                    // padding. A soft-wrapped row is full-width content: its trailing spaces are content.
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
                    let hay = Self.trimmingTrailingSpaces(coreText(ln, ln))
                    if !hay.isEmpty { rows.append((line: ln, hay: hay, utf16ToCol: nil, softWrapped: false)) }
                    if ln == Int32.max { break }
                    ln += 1
                    continue
                }
                do {
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

    typealias PhysicalRow = (line: Int32, hay: String, utf16ToCol: [Int]?, softWrapped: Bool)

    /// A physical row, or a run of soft-wrapped rows merged into one string. Match offsets in `hay` become
    /// columns counted on from column 0 of `line` (row `n` of a run starts at `n * cols`).
    struct SearchUnit: Sendable {
        let line: Int32
        let hay: String
        let rebaseCols: Int
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

        /// Built on first use: scrollback rows carry no cell data, so a column there is the Character index
        /// within its row. nil when offsets are already columns.
        mutating func columnMap() -> [Int]? {
            if let rows = pendingRows {
                map = FindController.runColumnMap(rows, cols: cols)
                pendingRows = nil
            }
            return map
        }
    }

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

    private static func isPlainFullWidthASCII(_ run: ArraySlice<PhysicalRow>, cols: Int) -> Bool {
        for k in run.indices {
            let hay = run[k].hay
            // ASCII has one UTF-16 unit per UTF-8 byte; any other scalar takes more bytes than units.
            guard hay.utf8.count == hay.utf16.count else { return false }
            if k != run.endIndex - 1, hay.utf8.count != cols { return false }
        }
        return true
    }

    // MARK: - Cycle (⌘G / ⌘⇧G)

    func advanceFind(direction: FindBar.Direction) {
        let priorAnchor: (line: Int32, startCol: Int)? = {
            guard findCurrentIndex >= 0, findCurrentIndex < findMatches.count else { return nil }
            let m = findMatches[findCurrentIndex]
            return (m.line, m.startCol)
        }()

        let willRegexRescan = regexSearchWouldRescan()
        let scanIDBeforeRefresh = activeRegexSearchID
        refreshFindMatchesIfStale()

        // A regex rescan is async and has just emptied findMatches: defer the cycle to its publish, but only
        // when a scan really started (fresh scan ID); an invalid regex starts none and would strand the deferral.
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

    func regexSearchWouldRescan() -> Bool {
        guard findBar?.options.regex ?? false else { return false }
        guard !findQuery.isEmpty, let snap = view.currentSnapshot else { return false }
        return findMatchesSeq != snap.sequenceID
    }

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
        switch direction {
        case .forward:  return matches.firstIndex(where: { ($0.line, $0.startCol) > a }) ?? 0
        case .backward: return matches.lastIndex(where: { ($0.line, $0.startCol) < a }) ?? (matches.count - 1)
        }
    }

    // MARK: - Search

    func refreshFindMatchesIfStale() {
        guard !findQuery.isEmpty else { return }
        guard let snap = view.currentSnapshot else { return }
        if findMatchesSeq != snap.sequenceID {
            performSearch(query: findQuery, preservingPosition: true)
        }
    }

    /// The regex path rescans asynchronously, so refreshing would leave Replace operating on an empty set:
    /// regex mode keeps the scanned matches, and spliceReplacements re-derives DEL counts from the live snapshot.
    func refreshFindMatchesIfStaleForReplace() {
        guard !(findBar?.options.regex ?? false) else { return }
        refreshFindMatchesIfStale()
    }

    /// `preservingPosition` is for rescans the user didn't ask for: they keep the cycle index and the
    /// viewport. Any scroll or output publishes a snapshot, which schedules such a rescan.
    func performSearch(query: String, preservingPosition: Bool = false) {
        findQuery = query
        if !preservingPosition || regexTimedOut?.query != query { regexTimedOut = nil }
        // A preserving rescan carries a deferred ⌘G over, restored only if a regex scan really starts.
        let carriedAdvance = preservingPosition ? pendingRegexAdvance : nil
        pendingRegexAdvance = nil
        if !preservingPosition { regexRevealOwed = false }
        findMatches.removeAll()
        // Leaving an old seq would let `advanceFind` skip a stale-cache rerun against the empty match set.
        findMatchesSeq = nil
        // Kept when preserving: a second rescan can start before a regex scan publishes and must still see it.
        if !preservingPosition { findCurrentIndex = 0 }
        guard let session = view.session, let snap = view.currentSnapshot, !query.isEmpty else {
            findBar?.clearMatchLabel()
            view.selection = nil
            return
        }
        let opts = findBar?.options ?? FindBar.Options()
        let stringOptions: String.CompareOptions = {
            var s: String.CompareOptions = []
            if !opts.caseSensitive { s.insert(.caseInsensitive) }
            return s
        }()
        let topLine: Int32 = -Int32(clamping: snap.historySize)
        let bottomLine = Int32(clamping: snap.rows - 1)
        if topLine > bottomLine { return }
        let findMatchLimit = 10_000

        if opts.regex {
            // NSRegularExpression (ICU) backtracks and has no match-timeout API: after the pattern gate and length
            // cap, the 250 ms background deadline is the only airtight backstop.
            guard RegexSafetyGate.isReasonable(query) else {
                findBar?.showTransientMessage("Regex too complex")
                view.selection = nil
                return
            }
            var regexOpts: NSRegularExpression.Options = []
            if !opts.caseSensitive { regexOpts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: query, options: regexOpts) else {
                findBar?.showTransientMessage("Invalid regex pattern")
                view.selection = nil
                return
            }
            if !preservingPosition { findBar?.clearMatchLabel(keepingNoMatches: true) }
            pendingRegexAdvance = carriedAdvance
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
        let captured = captureSearchUnits(
            topLine: topLine, bottomLine: bottomLine, cols: snap.cols, session: session, snap: snap
        )
        // ASCII fast path; any non-ASCII or CR-bearing query or row falls through to the Foundation loop.
        let asciiNeedle = Self.asciiNeedle(query: query, caseSensitive: opts.caseSensitive)
        var rowFilter = NonASCIIRowFilter(query: query)
        outer: for var row in captured {
            let ln = row.line
            let hay = row.hay
            let rebaseCols = row.rebaseCols
            if let needle = asciiNeedle,
               let ranges = Self.asciiMatchRanges(
                   hay: hay, needle: needle, caseSensitive: opts.caseSensitive,
                   limit: findMatchLimit - findMatches.count
               ) {
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
            if rowFilter?.mayMatch(hay) == false { continue }
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
                        startCol = lo16
                        endCol = hi16 - 1
                    }
                } else {
                    // Scrollback row: one-column-per-Character approximation, off for rows containing wide chars.
                    startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                    endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                }
                findMatches.append(Self.matchStartingOnItsRow(
                    line: ln, startCol: startCol, endCol: endCol, cols: rebaseCols))
                cursor = r.upperBound
                if findMatches.count >= findMatchLimit { break outer }
            }
        }
        findMatchesSeq = snap.sequenceID
        findCurrentIndex = min(findCurrentIndex, max(findMatches.count - 1, 0))
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch(scroll: !preservingPosition)
    }

    /// nil when ineligible: non-ASCII, or contains CR (a CRLF pair is a single Character to Foundation).
    static func asciiNeedle(query: String, caseSensitive: Bool) -> [UInt8]? {
        var bytes = Array(query.utf8)
        guard !bytes.isEmpty else { return nil }
        for b in bytes where b >= 0x80 || b == 0x0D { return nil }
        if !caseSensitive {
            for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] |= 0x20 }
        }
        return bytes
    }

    /// Must equal the Foundation `range(of:)` loop for pure-ASCII, CR-free haystacks; nil when the row is
    /// ineligible. Offsets are UTF-8 == UTF-16 == Character offsets for ASCII-only text.
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

    /// `endCol` is the column of the last included unit. A match can end between a cell's base scalar and the
    /// zero-width scalars sharing its column, so `hi` first advances past them (else `endCol` is one cell short).
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

    /// Re-bases a match found in a merged entry onto the row it starts on; `endCol` stays counted from that
    /// row. Pass `cols: 0` for a lone scrollback row: its raw offsets can exceed `cols` without leaving the row.
    static func matchStartingOnItsRow(
        line: Int32, startCol: Int, endCol: Int, cols: Int
    ) -> (line: Int32, startCol: Int, endCol: Int) {
        guard cols > 0, startCol >= cols else { return (line, startCol, endCol) }
        let rows = startCol / cols
        return (line &+ Int32(clamping: rows), startCol - rows * cols, endCol - rows * cols)
    }

    // MARK: - Async regex scan

    private static let regexSearchTimeout: TimeInterval = 0.25

    /// `RegexSafetyGate` can't catch every polynomial blowup (`.*.*.*.*.*x`); the cancel flag, observed
    /// between rows and inside each row's match, is what bounds them.
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

        let cancelFlag = AtomicFlag()
        let scanFinished = AtomicFlag()

        let workItem = DispatchWorkItem { [weak self] in
            let matches = Self.scanRegexRows(rows, regex: regex, limit: limit, cancelFlag: cancelFlag)
            scanFinished.value = true
            if cancelFlag.value { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishRegexResults(matches, searchID: mySearchID, scanSeq: scanSeq, query: scanQuery)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regexSearchTimeout) { [weak self] in
            // Set the flag before `guard let self`: the worker holds no reference to the controller, so a cancel
            // routed through `self` would never happen once the view is gone.
            cancelFlag.value = true
            guard let self else { return }
            self.handleRegexTimeout(searchID: mySearchID, query: scanQuery, scanFinished: scanFinished)
        }
    }

    /// Main thread. Rows and the snapshot `sequenceID` are captured together so a snapshot swap can't stamp
    /// a stale row-set with a fresher seq.
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

    private static func scanRegexRows(
        _ rows: [SearchUnit],
        regex: NSRegularExpression,
        limit: Int,
        cancelFlag: AtomicFlag
    ) -> [(line: Int32, startCol: Int, endCol: Int)] {
        var matches: [(line: Int32, startCol: Int, endCol: Int)] = []
        var callbacks = 0
        // `.reportProgress` is the only way to interrupt a match in progress; ICU then calls the block with nil at
        // every start position (~65% slower), so only risky rows ask. The flag read locks: poll every 256th call.
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
                    let cols = mapUTF16RangeToCols(lo: r.location, hi: r.location + r.length, utf16ToCol: utf16ToCol)
                    startCol = cols.startCol
                    endCol = cols.endCol
                } else {
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

    /// The search-ID guard alone misses scans abandoned without minting a new ID (bar closed, field cleared,
    /// invalid pattern, regex off); `advanceFind` relies on the ID changing only when a scan really starts.
    private func isRegexScanStillWanted(query: String) -> Bool {
        guard let bar = findBar, bar.options.regex else { return false }
        return findQuery == query
    }

    /// `findMatchesSeq` is stamped with the seq the scan ran against, not the live `currentSnapshot`.
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

    /// Runs on main, serialised with the publish, so `regexSearchCompletedID == mySearchID` means it fully
    /// landed. A retry the output triggered fails silently instead of wiping the user's selection each time.
    private func handleRegexTimeout(
        searchID mySearchID: UInt64, query: String, scanFinished: AtomicFlag
    ) {
        if regexSearchCompletedID == mySearchID { return }
        if !scanFinished.value, regexSearchCompletedID < mySearchID,
           isRegexScanStillWanted(query: query) {
            armRegexRetry(query: query)
        }
        guard activeRegexSearchID == mySearchID,
              isRegexScanStillWanted(query: query) else { return }
        // The deferred ⌘G was owed to this scan: drop it so it can't fire a delayed jump on a later publish.
        let userWaiting = pendingRegexAdvance != nil || regexRevealOwed
        pendingRegexAdvance = nil
        regexRevealOwed = false
        guard userWaiting || regexTimedOut?.announced != true else { return }
        regexTimedOut?.announced = true
        findBar?.showTransientMessage("Regex too complex")
        view.selection = nil
    }

    /// The timer re-arms the refresh itself, so output that ends inside the interval still gets its retry.
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

    /// Written on main (timeout), read on the regex worker; Swift has no benign-data-race exemption.
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

    private func highlightCurrentMatch(scroll: Bool = true) {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            view.selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
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

    static let barOverlapTolerancePoints: CGFloat = 0.5

    static func rowsHidden(byOverlap overlapPoints: CGFloat, cellHeight: CGFloat) -> Int {
        guard overlapPoints.isFinite, cellHeight.isFinite, cellHeight > 0 else { return 0 }
        let uncovered = overlapPoints - barOverlapTolerancePoints
        guard uncovered > 0 else { return 0 }
        // Cap before the Int conversion: an absurd overlap must not trap.
        return Int(min((uncovered / cellHeight).rounded(.up), 1_000_000))
    }

    /// Positive = toward older history. The delta is limited to `scrollableHistory`: a no-op scroll would still
    /// publish a snapshot and trigger a rescan. `followOffscreen: false` only rescues a match under the bar.
    static func revealScrollDelta(
        matchRow: Int, hiddenRows: Int, rows: Int, scrollableHistory: Int, followOffscreen: Bool,
        spanRows: Int = 0
    ) -> Int {
        let topVisibleRow = max(0, min(hiddenRows, rows - 1))
        if matchRow < topVisibleRow {
            if matchRow < 0 && !followOffscreen { return 0 }
            return max(0, min(topVisibleRow - matchRow, scrollableHistory))
        }
        let matchEndRow = matchRow + max(0, spanRows)
        if matchEndRow >= rows {
            guard followOffscreen else { return 0 }
            return max(rows - 1 - matchEndRow, topVisibleRow - matchRow)
        }
        return 0
    }

    private var barHiddenRows: Int {
        guard let bar = findBar, let parent = bar.superview else { return 0 }
        let r = view.convert(bar.frame, from: parent)
        let barBottom = view.isFlipped ? r.maxY : view.bounds.height - r.minY
        let overlap = barBottom - view.cellOriginPx(row: 0, col: 0).y
        return Self.rowsHidden(byOverlap: overlap, cellHeight: view.metrics.cellHeight)
    }

    /// displayOffset is lines above the live grid; a positive `scroll()` delta shows older content.
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

    func barHeightDidChange() {
        guard let snap = view.currentSnapshot, findMatchesSeq == snap.sequenceID else { return }
        scrollCurrentMatchIntoView(followOffscreen: false)
    }

    // MARK: - Replace

    #if DEBUG
    var replaceByteCapture: ((Data) -> Void)?
    var replaceSnapshotForTests: BBSnapshot?
    var replaceFindMatchesForTests: [(line: Int32, startCol: Int, endCol: Int)]?
    #endif

    /// In TUI modes (alt-screen, mouse reporting, bracketed paste) the DEL+UTF-8 stream is read as key input.
    func shouldAllowReplace() -> Bool {
        guard let mode = effectiveSnapshot()?.termMode else {
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

    func replaceCurrentMatch(with replacement: String) {
        // Re-derive against the live snapshot before splicing: a stale (line, startCol) corrupts the input line.
        refreshFindMatchesIfStaleForReplace()
        let matches = effectiveFindMatches()
        guard !matches.isEmpty, findCurrentIndex < matches.count else { return }
        let m = matches[findCurrentIndex]
        guard isOnLiveInputLine(m) else {
            findBar?.showTransientMessage("Only input-line matches can be replaced")
            return
        }
        spliceReplacements(matches: [m], replacement: replacement)
        clearMatches()
        reRunSearchAfterReplace()
    }

    private func reRunSearchAfterReplace() {
        #if DEBUG
        if replaceByteCapture != nil { return }
        #endif
        let query = findQuery
        guard !query.isEmpty, findBar != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.findQuery.isEmpty, self.findBar != nil else { return }
            self.performSearch(query: query)
        }
    }

    func replaceAllMatches(with replacement: String) {
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
        // Wrap-ambiguity guard: a match on the row above the cursor may be a soft-wrap continuation of the input
        // line (its last cell is non-blank); refuse rather than let DEL bytes overshoot into wrapped content.
        // `character(at:row:)` indexes viewport rows (0..rows-1), not buffer lines: add `displayOffset`.
        let priorRow = cursorLine - 1
        let priorViewportRow = Int(priorRow) + snap.displayOffset
        if matches.contains(where: { $0.line == priorRow }),
           snap.cols > 0,
           let priorLastCell = snap.character(at: snap.cols - 1, row: priorViewportRow),
           !priorLastCell.isWhitespace {
            findBar?.showTransientMessage("Refusing: matches span a possible wrapped input line")
            return
        }
        // Right-to-left as ONE splice: each match's gap is computed against the post-replacement position of
        // the matches to its right.
        spliceReplacements(
            matches: inputLineMatches.sorted(by: { $0.startCol > $1.startCol }),
            replacement: replacement
        )
        clearMatches()
        if hadOffLine {
            findBar?.showTransientMessage("Replaced input-line matches (scrollback skipped)")
        } else {
            reRunSearchAfterReplace()
        }
    }

    /// DEL (0x7F) erases the character left of the shell cursor, not at the match's columns, so arrows (CSI D /
    /// CSI C) reposition; counts are shell characters from ONE snapshot (a wide glyph is one DEL / one arrow).
    private func spliceReplacements(
        matches: [(line: Int32, startCol: Int, endCol: Int)],
        replacement: String
    ) {
        guard !matches.isEmpty, let snap = effectiveSnapshot() else { return }
        // The Replace field bypasses the paste sanitizer; scrub it through the same pipeline.
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

    /// The splice counts columns on one row, so a match running on across a soft wrap can't be replaced.
    private func isOnLiveInputLine(_ m: (line: Int32, startCol: Int, endCol: Int)) -> Bool {
        guard let snap = effectiveSnapshot() else { return false }
        return m.line == Int32(snap.cursorRow) && m.endCol < snap.cols
    }

    private func effectiveSnapshot() -> BBSnapshot? {
        #if DEBUG
        if let override = replaceSnapshotForTests { return override }
        #endif
        return view.currentSnapshot
    }

    private func effectiveFindMatches() -> [(line: Int32, startCol: Int, endCol: Int)] {
        #if DEBUG
        if let override = replaceFindMatchesForTests { return override }
        #endif
        return findMatches
    }
}
