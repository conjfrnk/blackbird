import XCTest
import AppKit
import Metal
import Combine
@testable import Blackbird

/// Integration-level tests for the replace path: verifies that
/// `replaceCurrentMatch` / `replaceAllMatches` emit the expected byte sequences
/// (DEL×N + replacement UTF-8) through the view's send path.
///
/// These tests use `#if DEBUG` hooks injected into `TerminalView`:
///   - `replaceSnapshotForTests`  — supplies cursor position without a PTY.
///   - `replaceFindMatchesForTests` — supplies pre-computed match list.
///   - `replaceByteCapture`       — captures emitted bytes instead of PTY write.
///
/// No TerminalSession is needed; no PTY is started. All allocations are tiny.
final class FindReplaceIntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    /// Build a minimal BBSnapshot via TerminalSession + /bin/cat, wait for the
    /// first snapshot, then return it. The snapshot is only needed for its
    /// `cursorRow` field; we start a real session to get a properly-typed value.
    ///
    /// Memory: a 80×24 BBTerm grid is < 1 MB. Time: < 3 s.
    private func liveSnapshot() throws -> BBSnapshot {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        defer { session.terminate() }
        let exp = expectation(description: "first snapshot")
        var snap: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot.compactMap { $0 }.sink { s in
            if snap == nil { snap = s; c?.cancel(); exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        return try XCTUnwrap(snap)
    }

    // MARK: - Replace-current: DEL×N + replacement

    func test_replaceCurrent_emitsDelNPlusReplacement() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        // "foo" sits at cols 4..6 on the cursor's row.
        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests     = snap
        view.replaceFindMatchesForTests  = [(line: cursorLine, startCol: 4, endCol: 6)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        // Inject the match index so replaceCurrentMatch picks the right entry.
        // findCurrentIndex is 0 by default which matches our single entry.
        view._invokeReplaceCurrentForTests(replacement: "baz")

        // Expect: DEL DEL DEL (3 × 0x7F) + "baz"
        let expected = Data([0x7F, 0x7F, 0x7F]) + Data("baz".utf8)
        XCTAssertEqual(captured, expected,
                       "Replace must emit DEL×matchLen then the replacement bytes")
    }

    func test_replaceCurrent_emptyReplacement_emitsOnlyDels() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 1)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "")

        XCTAssertEqual(captured, Data([0x7F, 0x7F]),
                       "Empty replacement still emits DEL bytes for the match span")
    }

    func test_replaceCurrent_offInputLine_emitsNothing() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        // Put the match on a different buffer line than the cursor.
        let offLine = Int32(snap.cursorRow) + 1
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: offLine, startCol: 0, endCol: 2)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "xyz")

        XCTAssertTrue(captured.isEmpty,
                      "Replace for off-input-line match must not emit any bytes")
    }

    // MARK: - Replace-all: right-to-left ordering

    func test_replaceAll_twoMatchesSameRow_rightToLeft() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        // Two "foo" matches: cols 0..2 and cols 10..12
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [
            (line: cursorLine, startCol: 0,  endCol: 2),
            (line: cursorLine, startCol: 10, endCol: 12),
        ]

        var allCaptures: [Data] = []
        view.replaceByteCapture = { allCaptures.append($0) }

        view._invokeReplaceAllForTests(replacement: "bar")

        // Right-to-left: cols 10..12 processed first, then 0..2.
        // Each replacement emits: DEL DEL DEL + "bar"
        let delBar = Data([0x7F, 0x7F, 0x7F]) + Data("bar".utf8)
        let expected = delBar + delBar   // twice, right-to-left
        let combined = allCaptures.reduce(Data(), +)
        XCTAssertEqual(combined, expected,
                       "Replace All must process matches right-to-left on the input line")
    }

    func test_replaceAll_mixedLines_onlyInputLineReplaced() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        let otherLine  = cursorLine - 1          // scrollback line

        // One match on the input line, one in scrollback.
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [
            (line: cursorLine, startCol: 5, endCol: 7),
            (line: otherLine,  startCol: 0, endCol: 2),
        ]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceAllForTests(replacement: "qux")

        // Only the input-line match should produce bytes.
        let expected = Data([0x7F, 0x7F, 0x7F]) + Data("qux".utf8)
        XCTAssertEqual(captured, expected,
                       "Replace All must skip off-input-line matches")
    }
}

// MARK: - Test-only TerminalView hooks

extension TerminalView {
    /// Calls replaceCurrentMatch(with:) directly — bypasses the delegate chain
    /// so tests don't need a real FindBar wired up.
    func _invokeReplaceCurrentForTests(replacement: String) {
        replaceCurrentMatch(with: replacement)
    }

    /// Calls replaceAllMatches(with:) directly.
    func _invokeReplaceAllForTests(replacement: String) {
        replaceAllMatches(with: replacement)
    }
}
