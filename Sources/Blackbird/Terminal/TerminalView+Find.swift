import AppKit
import Foundation
import os
import BBCore

/// The find bar for `TerminalView`: ⌘F spawns a `FindBar` subview; ⌘G / ⌘⇧G
/// cycle matches; `performSearch(query:)` runs the regex / substring search
/// across the visible viewport + scrollback (the regex path is async with a
/// cooperative-cancel + ReDoS pre-gate). Find-mode toggles (⌘⌥C case-sensitive,
/// ⌘⌥R regex) round-trip through `FindBarDelegate` on the main class. The
/// sibling responder concerns moved to their own files: macOS Services + Look
/// Up → `TerminalView+Services.swift`; right-click menu + `validateMenuItem`
/// → `TerminalView+ContextMenu.swift`.
///
/// Stored state (`findMatches`, `findCurrentIndex`, `findQuery`)
/// lives on the class body and is bumped from `private` to internal
/// so this extension can read/write across the file boundary.
extension TerminalView {

    func installFindBar() {
        let h: CGFloat = 32
        // Sit just below the titlebar, not under it.
        let top = titlebarOnlyTopInset
        let bar = FindBar(frame: NSRect(x: 0, y: bounds.height - h - top, width: bounds.width, height: h))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.delegate = self
        addSubview(bar)
        findBar = bar
    }

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
        guard !findQuery.isEmpty, let snap = currentSnapshot else { return false }
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
    /// Audit fix-#18 (2026-05-11): promoted from private to internal so
    /// replaceAllMatches (in TerminalView.swift) can call it before
    /// iterating cached col-real findMatches against a possibly newer
    /// snapshot — the wide-char DEL overcount window the audit names.
    func refreshFindMatchesIfStale() {
        guard !findQuery.isEmpty else { return }
        guard let snap = currentSnapshot else { return }
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
        guard let session, let snap = currentSnapshot, !query.isEmpty else {
            findBar?.setMatchCount(0, of: 0)
            selection = nil
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
                selection = nil
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
                selection = nil
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
                    let loIdx = max(0, min(lo16, utf16ToCol.count - 1))
                    let hiIdx = max(loIdx, min(hi16, utf16ToCol.count - 1))
                    startCol = utf16ToCol[loIdx]
                    endCol   = max(startCol, utf16ToCol[hiIdx] - 1)
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
    /// `isReasonableRegexPattern` keeps that bounded in practice.
    /// Audit findbar-selection F2.
    private func runRegexSearchAsync(
        regex: NSRegularExpression,
        topLine: Int32,
        bottomLine: Int32,
        cols: Int,
        limit: Int
    ) {
        guard let session else { return }
        // Snapshot rows on the main thread — `session.textRange` reads
        // from the BBTerm grid which lives on the main actor. For
        // in-viewport rows, also capture the cell-derived UTF-16-to-col
        // map so the worker thread can translate `NSRange` offsets back
        // to grid columns without skewing across wide / non-BMP chars.
        // Scrollback rows fall back to `session.textRange` with a nil
        // map (legacy approximation). Audit H5.
        let snap = currentSnapshot
        // L-16 / DI-10: snap the seq BEFORE the row-build loop, against
        // the same snapshot the rows are about to be sourced from. The
        // earlier shape captured `currentSnapshot?.sequenceID` AFTER
        // the loop — if a publish swapped the snapshot during the loop,
        // the rows came from snap[N] but the seq stamped was snap[N+1],
        // and the publish gate downstream would think a stale-seq
        // result was current. Tying the seq to `snap` (the locally-held
        // reference) makes them snap atomically.
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

        let mySearchID = nextRegexSearchID()
        activeRegexSearchID = mySearchID

        // Cooperative cancellation via a heap-allocated atomic-ish flag.
        // We can't use `DispatchWorkItem.isCancelled` from inside the
        // work item closure without forming a self-referential capture
        // dance; a class wrapping a Bool gives us a stable reference
        // both the timeout and the worker can read/write. Reads in the
        // worker happen on a single thread; writes from the timeout
        // happen on the main thread. Per-row checks are racy but
        // harmless — worst case we run one extra row.
        let cancelFlag = AtomicFlag()

        let workItem = DispatchWorkItem { [weak self] in
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
                        // NSRegularExpression returns UTF-16 offsets;
                        // translate via the row's parallel map so wide
                        // / non-BMP chars don't skew the column report.
                        let loIdx = max(0, min(r.location, utf16ToCol.count - 1))
                        let hiIdx = max(loIdx, min(r.location + r.length, utf16ToCol.count - 1))
                        startCol = utf16ToCol[loIdx]
                        endCol   = max(startCol, utf16ToCol[hiIdx] - 1)
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
            // If we were cancelled, the timeout already published its
            // banner — don't overwrite it with stale results.
            if cancelFlag.value { return }
            // Hop back to main to publish results — UI state and
            // findMatches storage are main-thread-only.
            DispatchQueue.main.async {
                guard let self else { return }
                // Stale-result guard: a newer search has started (user
                // typed another character, or toggled options); drop
                // this batch so it doesn't overwrite the live scan.
                guard self.activeRegexSearchID == mySearchID else { return }
                self.regexSearchCompletedID = mySearchID
                self.findMatches = matches
                // Stamp the seq the regex scanned against (NOT the live
                // currentSnapshot at publish time, which may have moved
                // on while the scan ran). On the next ⌘G, advanceFind
                // sees the cached seq trail the live one and re-runs the
                // search before cycling.
                self.findMatchesSeq = scanSeq
                // If a ⌘G arrived while this scan was in flight, honour it
                // here (resume from the user's position + one step) instead of
                // resetting to match 1 — otherwise the press is lost and the
                // cycle jumps back to the top during live output.
                if let pending = self.pendingRegexAdvance {
                    self.pendingRegexAdvance = nil
                    self.findCurrentIndex = self.resolveResumeIndex(
                        anchor: pending.anchor,
                        direction: pending.direction,
                        in: matches
                    )
                } else {
                    self.findCurrentIndex = 0
                }
                self.findBar?.setMatchCount(self.findCurrentIndex, of: self.findMatches.count)
                self.highlightCurrentMatch()
            }
        }

        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(execute: workItem)

        // Hard timeout. If the work item hasn't finished in 250 ms,
        // flip the cancel flag and surface a banner. Cancellation is
        // cooperative — the per-row loop re-checks `cancelFlag.value`
        // so a long-running enumerateMatches on a single row can still
        // run to completion, but it can't block subsequent rows.
        //
        // The success path sets `regexSearchCompletedID = mySearchID`
        // when it publishes results on the main queue. Because both the
        // success-path publish AND this timeout fire on the main queue,
        // they're serialised: by the time we observe
        // `regexSearchCompletedID == mySearchID` the publish has fully
        // landed and there's nothing for us to do.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            // Already published successfully — nothing to do.
            if self.regexSearchCompletedID == mySearchID { return }
            // Stale (newer search started) — let the in-flight work
            // item finish on its own; its results are discarded by the
            // search ID guard at publish time. Still flip the flag so
            // the worker bails out promptly rather than scanning the
            // whole buffer for a result that will be discarded.
            cancelFlag.value = true
            guard self.activeRegexSearchID == mySearchID else { return }
            // A deferred ⌘G (pendingRegexAdvance) was owed to THIS scan, which
            // is now abandoned — drop it deterministically so it isn't silently
            // stranded and can't fire a surprising delayed jump if a later
            // re-run of the same query publishes. Mirrors the success path's
            // consume-and-clear. (review: silent-failure-hunter)
            self.pendingRegexAdvance = nil
            self.findBar?.setMatchCount(0, of: 0)
            self.findBar?.showTransientMessage("Regex too complex")
            self.selection = nil
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

    private func highlightCurrentMatch() {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
        selection = Selection(
            anchor: BufferPoint(line: m.line, col: m.startCol),
            cursor: BufferPoint(line: m.line, col: m.endCol),
            mode: .character
        )
        // Scroll the match into view. displayOffset is how many lines
        // the viewport is above the live grid; positive delta to scroll()
        // means "show older content" (upward).
        guard let snap = currentSnapshot else { return }
        let displayRowForMatch = Int(m.line) + snap.displayOffset
        if displayRowForMatch < 0 {
            session?.scroll(delta: Int32(clamping: -displayRowForMatch))
        } else if displayRowForMatch >= snap.rows {
            session?.scroll(delta: Int32(clamping: snap.rows - 1 - displayRowForMatch))
        }
    }

}
