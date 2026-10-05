import AppKit

#if DEBUG
/// Test-only snapshot source. Emits the rows it was constructed with
/// verbatim, and uses its own `ObjectIdentifier` as a stable-but-unique
/// raw-pointer identity. Living in the Blackbird module (not BBCore) keeps
/// it out of shipping binaries via the #if DEBUG guard around the whole
/// file scope.
final class A11yFakeSnapshot: A11ySnapshotSource {
    private let rows: [String]
    init(rows: [String]) { self.rows = rows }

    func visibleRowsAsText() -> [String] { rows }

    var a11yIdentity: UnsafeRawPointer {
        // ObjectIdentifier wraps the class-instance address; unwrapping
        // guarantees a non-null pointer unique for the life of this
        // instance, which is exactly the cache-key contract we need.
        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }
}

/// Test-only hyperlink resolver. Production goes through
/// `SnapshotHyperlinkResolver`, which needs a real `BBSnapshot`; this fake
/// answers both OSC 8 and regex queries from plain strings so tests can
/// exercise the ⌘-click path without starting a PTY.
final class FakeHyperlinkSnapshot: HyperlinkResolver {
    struct Span {
        let row: Int
        let cols: Range<Int>
        let url: URL?
    }

    private let rows: [String]
    private let spans: [Span]

    init(rows: [String], spans: [(row: Int, cols: Range<Int>, url: String)]) {
        self.rows = rows
        self.spans = spans.map {
            Span(row: $0.row, cols: $0.cols, url: URL(string: $0.url))
        }
    }

    func osc8URL(row: Int, col: Int) -> URL? {
        for span in spans where span.row == row && span.cols.contains(col) {
            return span.url
        }
        return nil
    }

    /// Synthesise the anchor text for the click-divergence test: walk
    /// `rows[row]` over the span's column range and slice out the
    /// substring. Tests that don't construct spans with rendered
    /// anchor text (most of them) pass `rows: []` and get the empty
    /// string here, which short-circuits divergence detection (no
    /// URL-shaped claim in the anchor).
    func osc8AnchorText(row: Int, col: Int) -> String {
        for span in spans where span.row == row && span.cols.contains(col) {
            guard row >= 0, row < rows.count else { return "" }
            let line = rows[row]
            let chars = Array(line)
            let lo = max(0, span.cols.lowerBound)
            let hi = min(chars.count, span.cols.upperBound)
            guard lo < hi else { return "" }
            return String(chars[lo..<hi])
        }
        return ""
    }

    func regexURL(row: Int, col: Int) -> URL? {
        guard row >= 0, row < rows.count else { return nil }
        let line = rows[row]
        let nsLine = line as NSString
        // Shares `URLDetector`'s compiled pattern and trailing-punctuation
        // trim so the fake can't drift from what production detects
        // (`file://` stays excluded; `%` only as `%HH`).
        var found: URL?
        URLDetector.forEachURLRange(in: line, nsLine: nsLine) { r, stop in
            guard col >= r.location && col < r.location + r.length else { return }
            if let url = URL(string: nsLine.substring(with: r)) {
                found = url
                stop.pointee = true
            }
        }
        return found
    }
}
#endif
