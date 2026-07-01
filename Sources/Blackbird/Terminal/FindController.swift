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
/// `view`, exactly as the old `[weak self]` (self = the view) did.
final class FindController {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    // MARK: - State

    /// Only `installFindBar()` and the FindBarDelegate close/open path mutate it.
    var findBar: FindBar?
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

    /// Track that a find-refresh is pending so concurrent snapshot bursts
    /// collapse to one main-queue dispatch.
    private var findRefreshPending: Bool = false

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

    // MARK: - Bar lifecycle

    func installFindBar() {
        let h: CGFloat = 32
        // Sit just below the titlebar, not under it.
        let top = view.titlebarOnlyTopInset
        let bar = FindBar(frame: NSRect(x: 0, y: view.bounds.height - h - top, width: view.bounds.width, height: h))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.delegate = view
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

    private func scheduleFindRefresh() {
        guard !findRefreshPending else { return }
        findRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.findRefreshPending = false
            // Query could have been cleared by the time the dispatch fires
            // (FindBar closed, user cleared the field). Early-return then.
            guard !self.findQuery.isEmpty, self.findBar != nil else { return }
            self.performSearch(query: self.findQuery)
        }
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
            performSearch(query: findQuery)
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

    func performSearch(query: String) {
        findQuery = query
        // A fresh search supersedes any ⌘G that was deferred behind an
        // in-flight regex rescan (advanceFind re-sets this AFTER calling us,
        // so its own deferral survives; a user-typed query correctly drops it).
        pendingRegexAdvance = nil
        findMatches.removeAll()
        // Clear the seq stamp now; the substring path below stamps it
        // post-scan, and the regex async path stamps it on the main-queue
        // publish. Leaving an old seq here would let `advanceFind` skip
        // a stale-cache rerun against the new (empty) match set.
        findMatchesSeq = nil
        findCurrentIndex = 0
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
            findBar?.setMatchCount(0, of: 0)
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
        outer: for ln in topLine...bottomLine {
            let screenRow = Int(ln) + snap.displayOffset
            let mapped = snap.rowTextWithUTF16ToColMap(row: screenRow)
            let hay = mapped?.text ?? session.textRange(
                from: BufferPoint(line: ln, col: 0),
                to:   BufferPoint(line: ln, col: snap.cols - 1),
                rectangular: false
            )
            guard !hay.isEmpty else { continue }
            var cursor = hay.startIndex
            while let r = hay.range(of: query, options: stringOptions, range: cursor..<hay.endIndex) {
                let startCol: Int
                let endCol: Int
                if let utf16ToCol = mapped?.utf16ToCol {
                    let lo16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.lowerBound.samePosition(in: hay.utf16) ?? hay.utf16.startIndex
                    )
                    let hi16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.upperBound.samePosition(in: hay.utf16) ?? hay.utf16.endIndex
                    )
                    let cols = Self.mapUTF16RangeToCols(lo: lo16, hi: hi16, utf16ToCol: utf16ToCol)
                    startCol = cols.startCol
                    endCol = cols.endCol
                } else {
                    // Scrollback row — legacy approximation. Off-by-N for
                    // rows containing wide chars; documented limitation.
                    startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                    endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                }
                findMatches.append((line: ln, startCol: startCol, endCol: endCol))
                cursor = r.upperBound
                if findMatches.count >= findMatchLimit { break outer }
            }
        }
        // Stamp the seq the matches were computed against; advanceFind
        // checks this before cycling so a snapshot swap between now and
        // ⌘G triggers a re-scan instead of jumping to a stale row.
        findMatchesSeq = snap.sequenceID
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    /// Map a cell-derived UTF-16 `[lo, hi)` range to grid columns. Both ends
    /// clamp into `utf16ToCol`; `endCol` is the column of the LAST included
    /// unit (`hi - 1`) and never drops below `startCol`. The ONE viewport-row
    /// match→column mapping, shared by the substring (`performSearch`) and
    /// regex (`runRegexSearchAsync`) paths — keeping them from drifting on the
    /// wide-char / non-BMP column math (H4/H5). Scrollback rows use the legacy
    /// approximation at the call sites, not this.
    static func mapUTF16RangeToCols(lo: Int, hi: Int, utf16ToCol: [Int]) -> (startCol: Int, endCol: Int) {
        let loIdx = max(0, min(lo, utf16ToCol.count - 1))
        let hiIdx = max(loIdx, min(hi, utf16ToCol.count - 1))
        let startCol = utf16ToCol[loIdx]
        let endCol = max(startCol, utf16ToCol[hiIdx] - 1)
        return (startCol, endCol)
    }

    // MARK: - Async regex scan

    /// Hard timeout for an async regex scan. Past this the worker is cancelled
    /// and a "too complex" banner shown. Cancellation is cooperative — a long
    /// `enumerateMatches` on a single row still runs to completion, but it
    /// can't block subsequent rows.
    private static let regexSearchTimeout: TimeInterval = 0.25

    /// Runs the regex scan on a background queue with a hard 250 ms
    /// deadline. Cancels the scan and surfaces a "Regex too complex"
    /// banner if the deadline fires. Stale results from earlier searches
    /// (user typed another keystroke before this one finished) are
    /// dropped via a monotonic search ID.
    ///
    /// The heavy work here is `enumerateMatches` over each row's text;
    /// observing the cancel flag inside the per-row loop lets the
    /// timeout actually take effect mid-scan instead of waiting for the
    /// regex engine to exhaust its backtracking budget on every row.
    /// Worst-case latency on a single row is still bounded by
    /// NSRegularExpression's own per-row work, but pre-gating with
    /// `RegexSafetyGate` keeps that bounded in practice.
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

        // Cooperative cancellation via a heap-allocated atomic-ish flag — a
        // stable reference both the timeout (writes, main) and the worker
        // (reads, off-main) can touch. Per-row checks are racy but harmless:
        // worst case we run one extra row.
        let cancelFlag = AtomicFlag()

        let workItem = DispatchWorkItem {
            let matches = Self.scanRegexRows(rows, regex: regex, limit: limit, cancelFlag: cancelFlag)
            // If we were cancelled, the timeout already published its banner —
            // don't overwrite it with stale results.
            if cancelFlag.value { return }
            // Hop back to main to publish — UI state + findMatches storage are
            // main-thread-only.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishRegexResults(matches, searchID: mySearchID, scanSeq: scanSeq)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regexSearchTimeout) { [weak self] in
            guard let self else { return }
            self.handleRegexTimeout(searchID: mySearchID, cancelFlag: cancelFlag)
        }
    }

    /// Snapshot the rows to scan, on the main thread (`session.textRange` reads
    /// the BBTerm grid which lives on the main actor). For in-viewport rows
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
    ) -> (rows: [(line: Int32, hay: String, utf16ToCol: [Int]?)], scanSeq: UInt64?) {
        let snap = view.currentSnapshot
        let scanSeq = snap?.sequenceID
        var rows: [(line: Int32, hay: String, utf16ToCol: [Int]?)] = []
        rows.reserveCapacity(Int(bottomLine - topLine + 1))
        for ln in topLine...bottomLine {
            let screenRow = Int(ln) + (snap?.displayOffset ?? 0)
            if let mapped = snap?.rowTextWithUTF16ToColMap(row: screenRow) {
                if !mapped.text.isEmpty {
                    rows.append((line: ln, hay: mapped.text, utf16ToCol: mapped.utf16ToCol))
                }
            } else {
                let hay = session.textRange(
                    from: BufferPoint(line: ln, col: 0),
                    to:   BufferPoint(line: ln, col: cols - 1),
                    rectangular: false
                )
                if !hay.isEmpty {
                    rows.append((line: ln, hay: hay, utf16ToCol: nil))
                }
            }
        }
        return (rows, scanSeq)
    }

    /// The off-main scan core: run `regex` over each captured row, mapping
    /// match offsets to grid columns (viewport rows via the cell-derived map,
    /// scrollback via the legacy approximation). Pure — no `self`, no shared
    /// mutable state beyond the cooperative `cancelFlag` it polls per row — so
    /// it's safe on the worker queue and unit-testable in isolation. Stops at
    /// `limit` matches.
    private static func scanRegexRows(
        _ rows: [(line: Int32, hay: String, utf16ToCol: [Int]?)],
        regex: NSRegularExpression,
        limit: Int,
        cancelFlag: AtomicFlag
    ) -> [(line: Int32, startCol: Int, endCol: Int)] {
        var matches: [(line: Int32, startCol: Int, endCol: Int)] = []
        for row in rows {
            if cancelFlag.value { break }
            let ns = row.hay as NSString
            regex.enumerateMatches(
                in: row.hay,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) { result, _, stop in
                guard let r = result?.range, r.length > 0 else { return }
                let startCol: Int
                let endCol: Int
                if let utf16ToCol = row.utf16ToCol {
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
                matches.append((line: row.line, startCol: startCol, endCol: endCol))
                if matches.count >= limit { stop.pointee = true }
            }
            if matches.count >= limit { break }
        }
        return matches
    }

    /// Publish a completed regex scan on the main thread. Drops the batch when
    /// a newer search has started (stale-ID guard); stamps `findMatchesSeq`
    /// with the seq the scan ran against (NOT the live `currentSnapshot`, which
    /// may have moved on); honours a ⌘G that arrived mid-scan
    /// (`pendingRegexAdvance`) by resuming from the user's position instead of
    /// resetting to match 1; then highlights.
    private func publishRegexResults(
        _ matches: [(line: Int32, startCol: Int, endCol: Int)],
        searchID mySearchID: UInt64,
        scanSeq: UInt64?
    ) {
        guard activeRegexSearchID == mySearchID else { return }
        regexSearchCompletedID = mySearchID
        findMatches = matches
        findMatchesSeq = scanSeq
        if let pending = pendingRegexAdvance {
            pendingRegexAdvance = nil
            findCurrentIndex = resolveResumeIndex(
                anchor: pending.anchor,
                direction: pending.direction,
                in: matches
            )
        } else {
            findCurrentIndex = 0
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    /// Fired `regexSearchTimeout` after a scan starts. No-op if the scan
    /// already published. Otherwise flip the cancel flag so the worker bails
    /// promptly; then, if this is still the active search, consume any deferred
    /// ⌘G so it can't fire a surprise delayed jump, and show the "too complex"
    /// banner. Runs on main — serialised with the success-path publish, so
    /// observing `regexSearchCompletedID == mySearchID` means it fully landed.
    private func handleRegexTimeout(searchID mySearchID: UInt64, cancelFlag: AtomicFlag) {
        if regexSearchCompletedID == mySearchID { return }
        cancelFlag.value = true
        guard activeRegexSearchID == mySearchID else { return }
        // A deferred ⌘G (pendingRegexAdvance) was owed to THIS scan, which is
        // now abandoned — drop it deterministically so it isn't silently
        // stranded and can't fire a surprising delayed jump if a later re-run
        // publishes. Mirrors the success path's consume-and-clear.
        // (review: silent-failure-hunter)
        pendingRegexAdvance = nil
        findBar?.setMatchCount(0, of: 0)
        findBar?.showTransientMessage("Regex too complex")
        view.selection = nil
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

    private func highlightCurrentMatch() {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            view.selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
        view.selection = Selection(
            anchor: BufferPoint(line: m.line, col: m.startCol),
            cursor: BufferPoint(line: m.line, col: m.endCol),
            mode: .character
        )
        // Scroll the match into view. displayOffset is how many lines
        // the viewport is above the live grid; positive delta to scroll()
        // means "show older content" (upward).
        guard let snap = view.currentSnapshot else { return }
        let displayRowForMatch = Int(m.line) + snap.displayOffset
        if displayRowForMatch < 0 {
            view.session?.scroll(delta: Int32(clamping: -displayRowForMatch))
        } else if displayRowForMatch >= snap.rows {
            view.session?.scroll(delta: Int32(clamping: snap.rows - 1 - displayRowForMatch))
        }
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
        let inputLineMatches = matches.filter { $0.line == cursorLine }

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
    /// the match is on the live shell input line.
    private func isOnLiveInputLine(_ m: (line: Int32, startCol: Int, endCol: Int)) -> Bool {
        guard let snap = effectiveSnapshot() else { return false }
        return m.line == Int32(snap.cursorRow)
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
