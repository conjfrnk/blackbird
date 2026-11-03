import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for bug PP-2: with bracketed paste OFF, a multi-line
/// paste reaches the foreground program with its line breaks as LF (0x0A).
/// A raw-mode program that treats ONLY CR (0x0D) as Enter, and binds ^J (0x0A)
/// to something else, then misreads every line break. The case that bites in
/// practice is the macOS built-in `/usr/bin/nano` (UW Pico 5.09), where ^J is
/// "Justify": pasting "a b\nc d\n\ne" merges the lines into one justified
/// paragraph and silently alters the user's data. Older GNU nano over ssh and
/// any other raw-mode program without `?2004h` behave the same way.
///
/// Contract under test (observable, end to end): when the foreground program
/// has NOT enabled bracketed paste, every line break in the pasted text must
/// arrive at the program as exactly one CR (0x0D), the byte a keyboard Return
/// produces in raw mode, and no LF (0x0A) may arrive for a line break. This is
/// the long-standing behaviour of Terminal.app and iTerm2 for non-bracketed
/// paste. A CRLF clipboard (Windows / web copy) is one line break, so it must
/// arrive as a single CR, not two. A lone CR in the clipboard is already a
/// line break and stays a CR. Everything that is not a line break (spaces,
/// tabs, letters) arrives untouched.
///
/// With bracketed paste ON the paste is framed by `ESC[200~` / `ESC[201~` and
/// the program knows it is paste data, so the body is left alone; the control
/// test only pins that the frame and the line structure survive, and is
/// agnostic to whether the body spells its breaks CR or LF.
///
/// Rig. One real `TerminalSession` running `/bin/sh` that switches its tty to
/// raw / no-echo (so ICRNL / INLCR cannot rewrite bytes on the way in, which
/// makes the child see exactly what the app wrote, like a Pico-style editor in
/// raw mode), optionally turns on DECSET 2004, drops a "ready" file, then
/// `exec cat > received.bin`. The test reads that file back; the oracle is the
/// byte stream the child's stdin produced. The drive point is
/// `TerminalView.pasteText`, the same function the Cmd-V action funnels
/// through, so the test does not depend on pasteboard state.
///
/// Pre-flight cost (project rule): every payload is under 64 bytes. One live
/// `/bin/sh` + `cat` per test, terminated before the test returns, never two
/// at once, no window, no `MainWindowController`. One temp directory per test
/// holding a file of at most a few dozen bytes, removed in tearDown. Wall time
/// is dominated by session start (well under a second); the failure path ends
/// via a 15 s cap, never an unbounded wait.
final class PasteNewlineEnterBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    private static let bracketOpen: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC [ 2 0 0 ~
    private static let bracketClose: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let directory: URL
        let received: URL
    }

    private var cleanupDirectories: [URL] = []
    private var savedConfirmMultiLinePaste: Bool?

    override func setUp() {
        super.setUp()
        // A user whose real defaults enable the multi-line paste confirmation
        // would get a modal alert from pasteText and hang the run. Force it
        // off for the duration of the test and restore it afterwards (write
        // only on a real change: a no-op @AppStorage write still fans out).
        let prefs = Preferences.shared
        savedConfirmMultiLinePaste = prefs.confirmMultiLinePaste
        if prefs.confirmMultiLinePaste { prefs.confirmMultiLinePaste = false }
    }

    override func tearDown() {
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        if let saved = savedConfirmMultiLinePaste, Preferences.shared.confirmMultiLinePaste != saved {
            Preferences.shared.confirmMultiLinePaste = saved
        }
        savedConfirmMultiLinePaste = nil
        super.tearDown()
    }

    /// Starts the child and waits until it is provably ready to read raw
    /// bytes (and, when `bracketed`, until the VIEW's snapshot reports
    /// bracketed-paste mode, which is what `pasteText` consults).
    private func makeRig(bracketed: Bool, file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-pastenl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let received = dir.appendingPathComponent("received.bin")
        let ready = dir.appendingPathComponent("ready")

        // $1 = output file, $2 = ready file, $3 = "1" to enable DECSET 2004.
        // `stty raw -echo` first so the line discipline never rewrites the
        // paste; the ready file is created only after that.
        let script = """
        stty raw -echo || exit 3
        if [ "$3" = "1" ]; then printf '\\033[?2004h'; fi
        : > "$2"
        exec cat > "$1"
        """
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", script, "sh", received.path, ready.path, bracketed ? "1" : "0"],
            size: .init(cols: 80, rows: 24)
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240), device: device)
        view.session = session

        let readyInTime = spin(timeout: 15) { FileManager.default.fileExists(atPath: ready.path) }
        if !readyInTime {
            session.terminate()
        }
        XCTAssertTrue(readyInTime, "precondition: child never reached its read loop (ready file missing after 15 s)",
                      file: file, line: line)
        guard readyInTime else { throw XCTSkip("rig failed to start; see precondition failure above") }

        let modeSeen = spin(timeout: 15) {
            (view.currentSnapshot?.termMode.contains(.bracketedPaste) ?? false) == bracketed
        }
        XCTAssertTrue(
            modeSeen,
            "precondition: view snapshot bracketedPaste should be \(bracketed); observed "
            + "\(view.currentSnapshot?.termMode.contains(.bracketedPaste) ?? false) after 15 s",
            file: file, line: line
        )
        guard modeSeen else {
            session.terminate()
            throw XCTSkip("rig failed to reach the requested paste mode; see precondition failure above")
        }
        return Rig(view: view, session: session, directory: dir, received: received)
    }

    // MARK: - Helpers

    /// Pumps the main run loop (the session publishes snapshots to main)
    /// until `condition` holds or `timeout` passes.
    @discardableResult
    private func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Readable rendering: printable ASCII as itself, CR as `<CR>`, LF as
    /// `<LF>`, ESC as `<ESC>`, anything else as `<XX>`.
    private func visible(_ bytes: [UInt8]) -> String {
        var out = ""
        for b in bytes {
            switch b {
            case 0x0D: out += "<CR>"
            case 0x0A: out += "<LF>"
            case 0x1B: out += "<ESC>"
            case 0x09: out += "<TAB>"
            case 0x20...0x7E: out += String(UnicodeScalar(b))
            default: out += String(format: "<%02X>", b)
            }
        }
        return out
    }

    /// Waits until the child has received `expectedCount` bytes (or 15 s
    /// pass), then lingers briefly so any over-delivery shows up, and returns
    /// everything the child's stdin produced.
    private func awaitReceived(_ rig: Rig, expectedCount: Int) -> [UInt8] {
        func size() -> Int {
            let attrs = try? FileManager.default.attributesOfItem(atPath: rig.received.path)
            return (attrs?[.size] as? NSNumber)?.intValue ?? 0
        }
        spin(timeout: 15) { size() >= expectedCount }
        // Short settle so stray extra bytes (a doubled break) are counted.
        spin(timeout: 0.3) { false }
        let data = (try? Data(contentsOf: rig.received)) ?? Data()
        return [UInt8](data)
    }

    /// Pastes `text` into a non-bracketed rig and returns the bytes the child
    /// received. `expectedCount` is the length of the correct delivery; it is
    /// also the length of the buggy delivery for every fixture here (an LF and
    /// a CR are one byte each), so the wait is the same on both sides of the fix.
    private func pasteNonBracketed(_ text: String, expectedCount: Int,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let rig = try makeRig(bracketed: false, file: file, line: line)
        defer { rig.session.terminate() }
        rig.view.pasteText(text)
        return awaitReceived(rig, expectedCount: expectedCount)
    }

    /// What a Pico-style raw-mode editor would see: only CR is Enter; each
    /// LF is ^J, the Justify command.
    private func assertNoLFAndExactBytes(
        received: [UInt8], expected: [UInt8], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let lfCount = received.filter { $0 == Self.lf }.count
        XCTAssertEqual(
            lfCount, 0,
            "\(label): \(lfCount) LF byte(s) (^J, Justify in Pico) reached a program with bracketed paste off; "
            + "every line break must be a CR. received: \(visible(received))",
            file: file, line: line
        )
        XCTAssertEqual(
            hex(received), hex(expected),
            "\(label): received \(visible(received)) but a non-bracketed paste must deliver "
            + "\(visible(expected)) (line breaks as CR, everything else verbatim)",
            file: file, line: line
        )
    }

    // MARK: - Tests

    /// The exact clipboard from the bug report: two lines, a blank line, and
    /// a last line. Each of the three line breaks must arrive as one CR.
    func test_nonBracketedPaste_multiLineText_deliversEachLineBreakAsCR() throws {
        let text = "a b\nc d\n\ne"
        let expected = Array("a b".utf8) + [Self.cr] + Array("c d".utf8) + [Self.cr, Self.cr] + Array("e".utf8)
        XCTAssertEqual(expected.count, text.utf8.count, "fixture: LF and CR are both one byte")

        let received = try pasteNonBracketed(text, expectedCount: expected.count)

        assertNoLFAndExactBytes(received: received, expected: expected,
                                label: "plain paste of \"a b\\nc d\\n\\ne\"")
    }

    /// A CRLF clipboard (Windows / web copy) is ONE line break per line. It
    /// must arrive as a single CR: not CR CR (a doubled Enter, blank line
    /// after every line) and not LF.
    func test_nonBracketedPaste_crlfText_deliversOneCRPerLineBreak() throws {
        let text = "one\r\ntwo\r\n\r\nthree"
        let expected = Array("one".utf8) + [Self.cr] + Array("two".utf8) + [Self.cr, Self.cr] + Array("three".utf8)

        // CRLF is two clipboard bytes and one delivered byte; the buggy path
        // (CRLF -> LF) is the same length as the correct one.
        let received = try pasteNonBracketed(text, expectedCount: expected.count)

        assertNoLFAndExactBytes(received: received, expected: expected,
                                label: "plain paste of CRLF text")
    }

    /// Mixed breaks in one clipboard: LF, a lone CR, and a trailing LF, with
    /// a TAB that is not a line break and must pass through untouched.
    func test_nonBracketedPaste_mixedBreaksAndTab_allBreaksBecomeCRAndTabSurvives() throws {
        let text = "x\ty\rz\nw\n"
        let expected = Array("x".utf8) + [0x09] + Array("y".utf8) + [Self.cr]
            + Array("z".utf8) + [Self.cr] + Array("w".utf8) + [Self.cr]
        XCTAssertEqual(expected.count, text.utf8.count, "fixture: one byte per original byte")

        let received = try pasteNonBracketed(text, expectedCount: expected.count)

        assertNoLFAndExactBytes(received: received, expected: expected,
                                label: "plain paste of mixed LF / lone CR / trailing LF / TAB")
    }

    /// Control, passes before and after the fix: with bracketed paste ON the
    /// body is framed by ESC[200~ ... ESC[201~ and the three line breaks are
    /// still there. The body's spelling of a break (CR or LF) is deliberately
    /// not pinned; only the frame and the line structure are.
    func test_control_bracketedPaste_keepsFrameAndLineStructure() throws {
        let text = "a b\nc d\n\ne"
        let framedCount = Self.bracketOpen.count + text.utf8.count + Self.bracketClose.count
        let rig = try makeRig(bracketed: true)
        defer { rig.session.terminate() }

        rig.view.pasteText(text)
        let received = awaitReceived(rig, expectedCount: framedCount)

        XCTAssertEqual(
            hex([UInt8](received.prefix(Self.bracketOpen.count))), hex(Self.bracketOpen),
            "bracketed paste must open with ESC[200~; received \(visible(received))"
        )
        XCTAssertEqual(
            hex([UInt8](received.suffix(Self.bracketClose.count))), hex(Self.bracketClose),
            "bracketed paste must close with ESC[201~; received \(visible(received))"
        )
        let bodyBytes = [UInt8](received.dropFirst(Self.bracketOpen.count).dropLast(Self.bracketClose.count))
        // Fold either spelling of a break to LF so the control is agnostic.
        let foldedBytes: [UInt8] = bodyBytes.map { (b: UInt8) -> UInt8 in b == Self.cr ? Self.lf : b }
        let folded = String(decoding: foldedBytes, as: UTF8.self)
        XCTAssertEqual(
            folded, text,
            "bracketed paste body must keep the same text and the same three line breaks; "
            + "body was \(visible(bodyBytes))"
        )
    }
}
