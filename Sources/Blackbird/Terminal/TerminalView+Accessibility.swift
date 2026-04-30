import AppKit
import Foundation
import os
import BBCore

/// NSAccessibility overrides for `TerminalView`. Kept in a focused
/// extension file so the a11y contract stays visible in one place:
/// role (.textArea when bare, container when the find bar is installed),
/// label ("Terminal"), value (snapshot grid joined with newlines), and
/// the line/character/range accessors VoiceOver uses to navigate by
/// line / word / character.
///
/// The stored state (`a11yCache` and the DEBUG-only
/// `a11ySnapshotOverride`) lives on the class body; see
/// `TerminalView.swift`. Swift requires stored properties on the
/// declaring type, not on extensions — they're marked `internal`
/// rather than `private` so this extension can reach them across the
/// file boundary.
///
/// Promoted from `.staticText` to `.textArea` in v0.2 (F-S5-021). The
/// view is read-only — no `accessibilityIsEditable() == true` override —
/// so VO won't try to insert text. Selection getter returns the empty
/// range (rectangular grid → character index isn't a clean mapping for
/// wrapped lines); the setter is a no-op that logs once.
///
/// Audited by terminal-view-2 F1 (cache-key identity), swift-tests-
/// view F1 (leak reap). Tests in `AccessibilityTests.swift` pin role,
/// value, cache, line/character accessors, and selection contract.
extension TerminalView {

    public override func isAccessibilityElement() -> Bool {
        // When the find bar is installed, declaring ourselves a leaf would
        // hide its text fields and buttons from VoiceOver entirely — AppKit
        // stops descending into subviews of an accessibility-leaf parent.
        // Become a container in that mode; `accessibilityChildren()` below
        // exposes the find bar (and every other subview) so VO can reach
        // them. When the bar is absent, keep the leaf behaviour so VO
        // focus lands on a single "Terminal" element.
        findBar == nil
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        // .textArea (vs .staticText prior to v0.2): VO can now navigate by
        // line / word / character via the line-offset accessors below. The
        // view is not editable (no `accessibilityIsEditable() == true`),
        // so VO won't attempt insertions. F-S5-021.
        .textArea
    }

    public override func accessibilityLabel() -> String? { "Terminal" }

    public override func accessibilityHelp() -> String? {
        "Terminal output. Scroll back to read earlier content."
    }

    public override func accessibilityChildren() -> [Any]? {
        // Only meaningful when we're in container mode (find bar visible).
        // AppKit ignores `accessibilityChildren()` on a leaf, but returning
        // the default (super) here keeps behaviour symmetric in case a
        // future tool inspects the value directly.
        guard let bar = findBar else { return super.accessibilityChildren() }
        // Order matters for VO navigation: bar on top visually, every
        // other subview below. Covers drop-highlight / bell flash / scroll
        // indicator in case any of them ever grow accessibility affordances.
        var kids: [Any] = [bar]
        for sub in subviews where sub !== bar {
            kids.append(sub)
        }
        return kids
    }

    public override func accessibilityValue() -> Any? {
        // Test overrides take precedence so headless tests can inject a
        // deterministic grid without a running BBTerm. Under production
        // builds the #if DEBUG branch compiles out entirely.
        #if DEBUG
        let source: A11ySnapshotSource? = a11ySnapshotOverride ?? currentSnapshot
        #else
        let source: A11ySnapshotSource? = currentSnapshot
        #endif
        guard let source else { return "" }
        let identity = source.a11yIdentity
        if a11yCache.snapshotIdentity == identity {
            return a11yCache.value
        }
        let computed = source.visibleRowsAsText()
            .map { $0.trimmingTrailingWhitespace() }
            .joined(separator: "\n")
        a11yCache.snapshotIdentity = identity
        a11yCache.value = computed
        // The line-offset table is keyed on `value`; invalidate it whenever
        // the value changes so the next line-related accessor rebuilds.
        a11yCache.lineOffsets = nil
        a11yCache.computations += 1
        return computed
    }

    // MARK: - .textArea accessors (F-S5-021)

    /// Total character count of `accessibilityValue()` (UTF-16 code unit
    /// count, since AppKit's a11y API is `NSRange`-based and VO reads
    /// indices in UTF-16 units). Same shape as NSTextView.
    public override func accessibilityNumberOfCharacters() -> Int {
        let value = (accessibilityValue() as? String) ?? ""
        return value.utf16.count
    }

    /// All visible characters are part of the visible range — the snapshot
    /// already exposes only what's on screen. Scrollback rows aren't
    /// included in `accessibilityValue()` here.
    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    /// Substring for `range`. Returns nil for out-of-bounds requests.
    /// Decodes via `String(decoding: as: UTF16.self)` so astral codepoints
    /// (emoji, CJK Ext-B) survive intact — the earlier
    /// `compactMap { Unicode.Scalar($0) }` shape silently dropped UTF-16
    /// surrogates and corrupted any range crossing an emoji boundary.
    public override func accessibilityString(for range: NSRange) -> String? {
        let value = (accessibilityValue() as? String) ?? ""
        let utf16 = value.utf16
        let count = utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= count, range.location + range.length <= count else {
            return nil
        }
        guard let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex) else {
            return nil
        }
        let units = Array(utf16[start..<end])
        return String(decoding: units, as: UTF16.self)
    }

    /// Range of the `line`-th line (zero-indexed) in `accessibilityValue()`,
    /// excluding the trailing newline. Returns `{NSNotFound, 0}` when
    /// `line` is out of range — matches `NSTextView`'s contract for a
    /// non-existent line.
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        let offsets = ensureLineOffsets()
        // offsets has `numLines + 1` entries; valid line indices are
        // [0, numLines).
        guard line >= 0, line < offsets.count - 1 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let start = offsets[line]
        let nextStart = offsets[line + 1]
        // `nextStart` points to the character AFTER the trailing '\n'
        // (or to the end of the value, for the last line). Strip the
        // newline from the reported range — VO line readers don't
        // include the separator.
        let value = (accessibilityValue() as? String) ?? ""
        let utf16 = value.utf16
        let endExcludingNewline: Int
        if nextStart > start, nextStart <= utf16.count,
           let prevIdx = utf16.index(utf16.startIndex, offsetBy: nextStart - 1, limitedBy: utf16.endIndex),
           prevIdx < utf16.endIndex,
           utf16[prevIdx] == 0x0A {
            endExcludingNewline = nextStart - 1
        } else {
            endExcludingNewline = nextStart
        }
        return NSRange(location: start, length: endExcludingNewline - start)
    }

    /// Line index for a character position. Binary-searched against the
    /// cached offsets table — O(log N) per call after the O(N) cache
    /// build.
    public override func accessibilityLine(for index: Int) -> Int {
        let offsets = ensureLineOffsets()
        guard offsets.count >= 2 else { return 0 }
        guard index >= 0 else { return 0 }
        if index >= offsets[offsets.count - 1] {
            return offsets.count - 2  // last valid line index
        }
        // Largest `i` such that `offsets[i] <= index`. offsets is monotone
        // non-decreasing (each line starts at or after the previous).
        var lo = 0
        var hi = offsets.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= index {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// Range of a single character at `index`. Used by VO's "speak under
    /// cursor" pass.
    public override func accessibilityRange(for index: Int) -> NSRange {
        let count = accessibilityNumberOfCharacters()
        guard index >= 0, index < count else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: index, length: 1)
    }

    /// Screen-space frame for a character range. v0.2 ships the
    /// conservative answer: the view's whole bounds in screen coords.
    /// Per-cell rectangles need renderer cell metrics which would tie
    /// the a11y extension to MetalRenderer internals; deferred to v1.0.
    /// Returns `.zero` when the view isn't yet attached to a window.
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window = window else { return .zero }
        let viewRect = convert(bounds, to: nil)
        return window.convertToScreen(viewRect)
    }

    /// Empty range — `Selection`'s grid model doesn't map cleanly to a
    /// linear character range when wrapped lines or rectangular shapes
    /// are involved. v0.2 documents the limitation in
    /// `KNOWN_ISSUES.md`; v1.0 may revisit if a per-cell metrics seam
    /// gets added.
    public override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    /// No-op + log once. VO's "VO+Shift+arrow" path expects a setter; if
    /// we omitted it entirely, AppKit would log a warning every time. A
    /// no-op + one-shot log records the unsupported attempt without
    /// flooding the unified log.
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        TerminalView.logSelectionSetterUnsupportedOnce()
    }

    // MARK: - Internals

    /// Lazily build the per-line offset table. Caller responsible for
    /// invalidation — `accessibilityValue()` clears
    /// `a11yCache.lineOffsets = nil` on snapshot identity change.
    private func ensureLineOffsets() -> [Int] {
        if let cached = a11yCache.lineOffsets { return cached }
        let value = (accessibilityValue() as? String) ?? ""
        let utf16 = value.utf16
        var offsets: [Int] = [0]
        var idx = 0
        for code in utf16 {
            idx += 1
            if code == 0x0A {  // '\n'
                offsets.append(idx)
            }
        }
        if offsets.last != utf16.count {
            offsets.append(utf16.count)
        }
        a11yCache.lineOffsets = offsets
        return offsets
    }

    private static let selectionLogger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "accessibility"
    )

    /// One-shot guard so a VO user repeatedly attempting a selection
    /// drag doesn't fill the unified log with the same notice. Scope is
    /// per-process (matches the existing `didLogOutOfRange` /
    /// `didLogBlurRC` patterns elsewhere in the project): with multiple
    /// tabs open, the FIRST view to receive an unsupported set logs;
    /// subsequent views in the same process stay silent. Trade-off
    /// chosen to minimise log spam for production users — the
    /// alternative (per-instance) would mean every new tab can re-log
    /// once even when the user hits the same gap repeatedly.
    private static let selectionSetterLogged =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    fileprivate static func logSelectionSetterUnsupportedOnce() {
        selectionSetterLogged.withLock { fired in
            guard !fired else { return }
            fired = true
            selectionLogger.notice(
                "setAccessibilitySelectedTextRange called; v0.2 ships getter-only — see KNOWN_ISSUES § 'Accessibility'"
            )
        }
    }

    #if DEBUG
    /// Test introspection for the a11y cache. Lets `AccessibilityTests`
    /// assert that `accessibilityValue()` short-circuits when the
    /// snapshot hasn't changed.
    var accessibilityCacheStatsForTests: (computations: Int, snapshotIdentity: UnsafeRawPointer?) {
        (a11yCache.computations, a11yCache.snapshotIdentity)
    }

    /// Install a fake snapshot that the a11y value path will consume.
    /// Assigns a fresh identity each call so cache invalidation is
    /// exercised.
    func installSnapshotForTests(rows: [String]) {
        a11ySnapshotOverride = A11yFakeSnapshot(rows: rows)
        // New identity ⇒ next accessibilityValue() must recompute.
        a11yCache.snapshotIdentity = nil
        a11yCache.lineOffsets = nil
    }

    /// Reset the one-shot selection-setter log latch so tests can
    /// observe the no-op contract from a known state. Keeps the latch's
    /// production behaviour (one log per process) untouched.
    static func _resetSelectionSetterLogForTests() {
        selectionSetterLogged.withLock { $0 = false }
    }
    #endif
}
