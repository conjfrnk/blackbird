import AppKit
import Foundation
import BBCore

/// macOS Services + Find-bar + context-menu integration for
/// `TerminalView`. Three loosely-related responder-chain concerns
/// kept together because they share the same FindBar / selection
/// state:
///
///   - **Services menu** — `validRequestor(forSendType:returnType:)`
///     exposes the current selection to the Services submenu, Look
///     Up (three-finger tap, Ctrl-⌘-D), and QuickLook. Without these
///     overrides NSResponder's default returns `nil` and macOS
///     hides the entire Services submenu for this view.
///   - **Find bar** — ⌘F spawns a `FindBar` subview; ⌘G / ⌘⇧G cycle
///     matches; `performSearch(query:)` runs the regex / substring
///     search across the visible viewport + scrollback. Find-mode
///     toggles (⌘⌥C case-sensitive, ⌘⌥R regex) round-trip through
///     FindBarDelegate on the main class.
///   - **Context menu** — `menu(for:)` produces the right-click
///     menu, with Open-Link / Copy-Link items when a URL was
///     resolved at the click position (OSC 8 first, regex fallback).
///
/// Stored state (`findMatches`, `findCurrentIndex`, `findQuery`)
/// lives on the class body and is bumped from `private` to internal
/// so this extension can read/write across the file boundary.
extension TerminalView {

    // MARK: - macOS Services + Look Up

    /// Expose the current selection to the Services menu and Look Up
    /// (three-finger tap, Ctrl-⌘-D). Without this override, NSResponder's
    /// default returns nil for our view and macOS hides the Services
    /// submenu entirely. Accepts string-type sends; we never accept
    /// pasteboard-originated changes here (paste still routes through
    /// `paste(_:)` so the TUI's bracketed-paste / sanitizer stays in play).
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == .string, returnType == nil, selectedStringForServices() != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Called by the Services infrastructure when the user picks
    /// "Services → …" on a selection; writes the selection text onto the
    /// supplied pasteboard so the chosen service can read it.
    /// Part of the informal `NSServicesMenuRequestor` protocol — not an
    /// `NSResponder` override, so no `override` keyword.
    @objc public func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = selectedStringForServices() else {
            return false
        }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    /// Three-finger tap / Force Touch on the trackpad triggers
    /// `quickLook(with:)` on the responder chain. Preview the current
    /// selection (or the hovered OSC-8 link URL when no selection) in an
    /// NSPopover anchored under the pointer — Ghostty / Safari / Xcode
    /// idiom. Falls back to `super` when nothing useful is under the
    /// pointer so macOS can still offer dictionary lookup / media preview
    /// for other responder hits.
    public override func quickLook(with event: NSEvent) {
        // Priority: selection wins (user picked it explicitly) > hovered
        // OSC-8 URL (already highlighted). Nothing actionable → defer
        // to AppKit's default behaviour (dictionary / None).
        let text: String? = {
            if let sel = selectedStringForServices(), !sel.isEmpty {
                return sel
            }
            if let snap = currentSnapshot, hoveredLinkID != 0,
               let url = snap.linkURL(id: hoveredLinkID) {
                return url
            }
            return nil
        }()
        guard let text else {
            super.quickLook(with: event)
            return
        }

        // Pointer position for the popover anchor. event.locationInWindow
        // is in window space; convert to view space for the popover's
        // positioning rect.
        let pointInView = convert(event.locationInWindow, from: nil)
        // Anchor a 1-pt rect at the pointer so the popover arrows find
        // a precise spot. AppKit expands as needed to place the popover.
        let anchor = NSRect(origin: pointInView, size: NSSize(width: 1, height: 1))

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 6
        label.preferredMaxLayoutWidth = 420
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = {
            let vc = NSViewController()
            vc.view = container
            return vc
        }()
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    /// Selection → String without the clipboard scrubbing step. Services
    /// and Look Up get the raw text: the downstream app may legitimately
    /// want formatting characters the clipboard-sanitizer would strip,
    /// and any bidi overrides won't reach Safari/Mail via this path (it
    /// goes through an NSPasteboard the service owns, then a UI chosen
    /// by the user — we never copy onto the general pasteboard here).
    private func selectedStringForServices() -> String? {
        guard let sel = selection, let session, let snap = currentSnapshot else {
            return nil
        }
        let (start, end) = Self.copyRange(for: sel, cols: snap.cols)
        let text = session.textRange(from: start, to: end, rectangular: sel.mode == .rectangular)
        return text.isEmpty ? nil : text
    }

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
        // Audit findbar-selection F11: the snapshot may have advanced
        // between performSearch and ⌘G — output arriving scrolls history
        // and overwrites rows, so the cached (line, col) tuples can now
        // reference cells holding different text. Re-scan synchronously
        // against the live snapshot before cycling. The async refresh in
        // currentSnapshot.didSet is debounced via DispatchQueue.main.async
        // and may not have fired yet when ⌘G runs in the same runloop turn.
        refreshFindMatchesIfStale()
        guard !findMatches.isEmpty else { return }
        switch direction {
        case .forward:  findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        case .backward: findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
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
    private func refreshFindMatchesIfStale() {
        guard !findQuery.isEmpty else { return }
        guard let snap = currentSnapshot else { return }
        if findMatchesSeq != snap.sequenceID {
            performSearch(query: findQuery)
        }
    }

    func performSearch(query: String) {
        findQuery = query
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
            guard Self.isReasonableRegexPattern(query) else {
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
        outer: for ln in topLine...bottomLine {
            let hay = session.textRange(
                from: BufferPoint(line: ln, col: 0),
                to:   BufferPoint(line: ln, col: snap.cols - 1),
                rectangular: false
            )
            guard !hay.isEmpty else { continue }
            var cursor = hay.startIndex
            while let r = hay.range(of: query, options: stringOptions, range: cursor..<hay.endIndex) {
                let startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                let endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
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
        // from the BBTerm grid which lives on the main actor.
        var rows: [(line: Int32, hay: String)] = []
        rows.reserveCapacity(Int(bottomLine - topLine + 1))
        for ln in topLine...bottomLine {
            let hay = session.textRange(
                from: BufferPoint(line: ln, col: 0),
                to:   BufferPoint(line: ln, col: cols - 1),
                rectangular: false
            )
            if !hay.isEmpty {
                rows.append((line: ln, hay: hay))
            }
        }
        // Capture the snapshot's seq at scan-submit time so the publish
        // can stamp `findMatchesSeq` with the snapshot the rows actually
        // came from — even if `currentSnapshot` advances during the scan.
        let scanSeq = currentSnapshot?.sequenceID

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
                    let startCol = r.location
                    let endCol = r.location + r.length - 1
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
                self.findCurrentIndex = 0
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
            self.findBar?.setMatchCount(0, of: 0)
            self.findBar?.showTransientMessage("Regex too complex")
            self.selection = nil
        }
    }

    /// Heap-allocated mutable Bool used as a poor man's cancellation
    /// token between the regex worker and the timeout. Writes are
    /// confined to the main thread (timeout); reads happen on a
    /// background thread (worker). Reading a stale value just delays
    /// cancellation by one row, which is acceptable.
    private final class AtomicFlag {
        var value: Bool = false
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

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):                      return selection != nil
        case #selector(selectAll(_:)):                 return currentSnapshot != nil
        case #selector(paste(_:)):
            // Paste needs BOTH a session to receive the bytes AND string
            // content on the pasteboard. Before this check, a paste on a
            // view with no session silently dropped the clipboard content
            // instead of clearly disabling the menu item.
            // Audit terminal-view-2 F13.
            return session != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(performFindPanelAction(_:)):    return currentSnapshot != nil
        case #selector(performFindNextAction(_:)):     return !findMatches.isEmpty
        case #selector(performFindPreviousAction(_:)): return !findMatches.isEmpty
        case #selector(toggleFindCaseSensitive(_:)):
            item.state = (findBar?.options.caseSensitive == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(toggleFindRegex(_:)):
            item.state = (findBar?.options.regex == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(clearBufferAndScrollback(_:)):  return session != nil
        case #selector(jumpToPreviousPrompt(_:)),
             #selector(jumpToNextPrompt(_:)):
            // Same pattern: disabling until OSC 133 marks exist is more
            // honest than beeping on every press.
            return (session?.promptMarks.isEmpty == false)
        case #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)): return session != nil
        default:                                       return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        // Surface "Open Link" / "Copy Link" when the right-click lands on
        // a resolvable URL (OSC 8 hyperlink or regex-detected). Safari-
        // parity affordance; without it users can only reach URLs via
        // ⌘-click which is hidden UI. Audit terminal-view-2 F27.
        let p = bufferPointFromEvent(event)
        let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
        if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
            let openItem = NSMenuItem(title: "Open Link",
                                      action: #selector(openResolvedLink(_:)),
                                      keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = url
            let copyLinkItem = NSMenuItem(title: "Copy Link",
                                          action: #selector(copyResolvedLink(_:)),
                                          keyEquivalent: "")
            copyLinkItem.target = self
            copyLinkItem.representedObject = url
            m.addItem(openItem)
            m.addItem(copyLinkItem)
            m.addItem(NSMenuItem.separator())
        }
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        copyItem.target = self
        pasteItem.target = self
        m.addItem(copyItem)
        m.addItem(pasteItem)
        return m
    }

    @objc private func openResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        urlOpener.open(url)
    }

    @objc private func copyResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

}
