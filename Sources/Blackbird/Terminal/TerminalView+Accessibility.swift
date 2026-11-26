import AppKit
import Foundation
import os
import BBCore

extension TerminalView {

    public override func isAccessibilityElement() -> Bool {
        // Always an element, find bar or not: AppKit skips a container-mode view,
        // which takes the grid text out of the accessibility tree.
        true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    public override func accessibilityLabel() -> String? { "Terminal" }

    public override func accessibilityHelp() -> String? {
        "Terminal output. Scroll back to read earlier content."
    }

    public override func accessibilityChildren() -> [Any]? {
        guard let bar = findController.findBar else { return super.accessibilityChildren() }
        // Order drives VoiceOver navigation: the bar comes first.
        var kids: [Any] = [bar]
        for sub in subviews where sub !== bar {
            kids.append(sub)
        }
        return kids
    }

    public override func accessibilityValue() -> Any? {
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
        a11yCache.store(value: computed, identity: identity)
        return computed
    }

    /// Each `.valueChanged` post makes VoiceOver re-read the grid, so posts are coalesced.
    static let valueChangedCoalesceInterval: TimeInterval = 0.25

    /// AppKit never posts `.valueChanged` for a custom view, and drops the post when
    /// no assistive client is observing.
    func scheduleAccessibilityValueChanged() {
        guard !a11yValueChangedPending else { return }
        a11yValueChangedPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.valueChangedCoalesceInterval) { [weak self] in
            guard let self else { return }
            self.a11yValueChangedPending = false
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func currentA11yValue() -> String {
        (accessibilityValue() as? String) ?? ""
    }

    // MARK: - .textArea accessors

    /// UTF-16 code units: the accessibility API is `NSRange`-based.
    public override func accessibilityNumberOfCharacters() -> Int {
        let value = currentA11yValue()
        return value.utf16.count
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    /// Decodes as UTF-16 so a surrogate pair inside the range survives.
    public override func accessibilityString(for range: NSRange) -> String? {
        let value = currentA11yValue()
        let utf16 = value.utf16
        let count = utf16.count
        // `length <= count - location`, not `location + length <= count`: the client
        // picks the range, and `{1, Int.max}` would trap on the add.
        guard range.location >= 0, range.length >= 0,
              range.location <= count, range.length <= count - range.location else {
            return nil
        }
        guard let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex) else {
            return nil
        }
        let units = Array(utf16[start..<end])
        return String(decoding: units, as: UTF16.self)
    }

    /// Excludes the trailing newline. `{NSNotFound, 0}` for a line out of range, as NSTextView does.
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        let offsets = ensureLineOffsets()
        guard line >= 0, line < offsets.count - 1 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let start = offsets[line]
        let nextStart = offsets[line + 1]
        let value = currentA11yValue()
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

    public override func accessibilityLine(for index: Int) -> Int {
        let offsets = ensureLineOffsets()
        guard offsets.count >= 2 else { return 0 }
        guard index >= 0 else { return 0 }
        if index >= offsets[offsets.count - 1] {
            return offsets.count - 2
        }
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

    /// The composed character range: `index` is a UTF-16 unit, and a fixed length of 1
    /// would split a surrogate pair.
    public override func accessibilityRange(for index: Int) -> NSRange {
        let value = currentA11yValue() as NSString
        guard index >= 0, index < value.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return value.rangeOfComposedCharacterSequence(at: index)
    }

    /// The whole view's bounds in screen coordinates, not a per-cell rectangle.
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window = window else { return .zero }
        let viewRect = convert(bounds, to: nil)
        return window.convertToScreen(viewRect)
    }

    /// Always empty: the grid selection does not map to a linear character range.
    public override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    /// A no-op that must stay overridden: AppKit logs a warning on every VoiceOver
    /// selection attempt when the setter is missing.
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        TerminalView.logSelectionSetterUnsupportedOnce()
    }

    // MARK: - Internals

    /// `offsets[i]` is the UTF-16 index of line `i`'s first character; the last entry is the past-the-end
    /// sentinel. An empty value yields `[0]`; a value ending in `\n` has an empty trailing line.
    private func ensureLineOffsets() -> [Int] {
        if let cached = a11yCache.lineOffsets { return cached }
        let value = currentA11yValue()
        let utf16 = value.utf16
        var offsets: [Int] = [0]
        var idx = 0
        for code in utf16 {
            idx += 1
            if code == 0x0A {  // '\n'
                offsets.append(idx)
            }
        }
        if !utf16.isEmpty {
            offsets.append(utf16.count)
        }
        a11yCache.lineOffsets = offsets
        return offsets
    }

    nonisolated private static let selectionLogger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "accessibility"
    )

    /// Per process, not per view.
    private static let selectionSetterLogged =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    fileprivate static func logSelectionSetterUnsupportedOnce() {
        selectionSetterLogged.withLock { fired in
            guard !fired else { return }
            fired = true
            selectionLogger.notice(
                "setAccessibilitySelectedTextRange called; v0.2 ships getter-only (F-S5-021 v0.2 cycle entry in KNOWN_ISSUES.md). v1.0 may revisit if a per-cell metrics seam is added."
            )
        }
    }

    #if DEBUG
    var accessibilityCacheStatsForTests: (computations: Int, snapshotIdentity: UnsafeRawPointer?) {
        (a11yCache.computations, a11yCache.snapshotIdentity)
    }

    func installSnapshotForTests(rows: [String]) {
        a11ySnapshotOverride = A11yFakeSnapshot(rows: rows)
        a11yCache.invalidate()
    }

    static func _resetSelectionSetterLogForTests() {
        selectionSetterLogged.withLock { $0 = false }
    }
    #endif
}
