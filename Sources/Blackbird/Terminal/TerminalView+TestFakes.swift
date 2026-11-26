import AppKit

#if DEBUG
final class A11yFakeSnapshot: A11ySnapshotSource {
    private let rows: [String]
    init(rows: [String]) { self.rows = rows }

    func visibleRowsAsText() -> [String] { rows }

    var a11yIdentity: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }
}

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
