import XCTest
import AppKit
@testable import Blackbird

final class DragDropTests: XCTestCase {
    /// `shellQuote` wraps a path in single quotes and escapes embedded singles.
    func testShellQuoteSimple() {
        XCTAssertEqual(TerminalView.shellQuote("/Users/foo/bar.png"),
                       "'/Users/foo/bar.png'")
    }

    func testShellQuoteWithSpaces() {
        XCTAssertEqual(TerminalView.shellQuote("/Users/foo/my image.png"),
                       "'/Users/foo/my image.png'")
    }

    func testShellQuoteWithEmbeddedSingleQuote() {
        // Classic POSIX recipe: close quote, escaped single, reopen.
        XCTAssertEqual(TerminalView.shellQuote("/tmp/don't.txt"),
                       "'/tmp/don'\\''t.txt'")
    }

    func testJoinedMultiFile() {
        let joined = TerminalView.joinedDroppedPaths([
            "/a/one.png",
            "/b/two three.png",
        ])
        XCTAssertEqual(joined, "'/a/one.png' '/b/two three.png'")
    }
}
