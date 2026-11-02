import XCTest
@testable import Blackbird

/// Blind regression tests for bug pty-2: the pty is created without the
/// `IUTF8` input flag, so in cooked (canonical) mode the kernel line
/// discipline treats Backspace as "erase one BYTE". Erasing a multibyte
/// character leaves its leading bytes in the line buffer and the program
/// reads invalid UTF-8.
///
/// Contract under test (observable, end to end): a program that reads a line
/// from its terminal in canonical mode receives exactly the characters the
/// user left in the line. Typing `a`, `é` (C3 A9), Backspace (7F) and Return
/// (0A) must deliver `61 0A`, not `61 C3 0A`. The same holds for three-byte
/// scalars (CJK, E6 97 A5) and four-byte scalars (emoji, F0 9F 98 80): ONE
/// Backspace removes ONE character, however many UTF-8 bytes it occupies.
///
/// Oracle. The expected bytes were cross-checked against the macOS kernel
/// line discipline directly (an `openpty` pair with `IUTF8` cleared versus
/// set, a canonical-mode `head -n 1 | od` reader): with the flag cleared
/// the reader sees `61 C3 0A`, `61 E6 97 0A` and `61 F0 9F 98 0A`; with the
/// flag set it sees `61 0A` in all three cases. The tests below assert the
/// flag-set behaviour through `PTY.spawn`, which is what the app uses.
///
/// Rig. One real `/bin/sh -c` child spawned by `PTY.spawn` that touches a
/// "ready" file, then runs `head -n 1 | od -An -tx1 > out`. `head` reads a
/// single canonical-mode line from the tty and `od` hex-dumps whatever bytes
/// the line discipline handed it, so the oracle is exactly the bytes the
/// program received. The test only types into the pty after the ready file
/// exists, never changes termios itself, and reads the hex dump from a file
/// (the child's stdout is the tty, which would mix in echo traffic). The two
/// `control` tests (ASCII Backspace, and multibyte characters typed without
/// any Backspace) pass on any correct rig; they prove the child really reads
/// a cooked-mode line and that Backspace really is the erase character, so a
/// failure in the other tests can only mean multibyte erase is wrong.
///
/// Pre-flight cost (project rule, per `feedback_test_memory_safety`): one
/// `/bin/sh` + `head` + `od` per test, at most 16 bytes typed, one temp
/// directory with two tiny files removed in tearDown, no window, no Metal
/// device, no `MainWindowController`. Children are spawned strictly one at a
/// time and terminated before the test returns. Wall time is well under a
/// second per test; the hard cap on any wait is 15 s.
final class PTYCookedModeUTF8BlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Keystrokes

    private static let backspace: [UInt8] = [0x7F]   // DEL, macOS default VERASE
    private static let enter: [UInt8] = [0x0A]
    private static let a: [UInt8] = [0x61]
    private static let b: [UInt8] = [0x62]
    private static let eAcute: [UInt8] = [0xC3, 0xA9]                // U+00E9, 2 bytes
    private static let cjk: [UInt8] = [0xE6, 0x97, 0xA5]             // U+65E5, 3 bytes
    private static let emoji: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]     // U+1F600, 4 bytes

    // MARK: - Rig

    private var cleanupDirectories: [URL] = []

    override func tearDown() {
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
    }

    private struct LineResult {
        /// Hex tokens (two lowercase digits each) the reader received.
        var received: [String]
        var exited: Bool
        var exitStatus: Int32
        /// Everything the tty echoed back, for failure messages.
        var echoed: Data
    }

    private func hex(_ bytes: [UInt8]) -> [String] {
        bytes.map { String(format: "%02x", $0) }
    }

    /// Spawns the cooked-mode line reader, types `keystrokes` (one `write`
    /// per element, in order, after the child is ready), and returns the
    /// bytes the reader received.
    private func readLine(typing keystrokes: [[UInt8]],
                          file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-iutf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let out = dir.appendingPathComponent("received.hex")
        let ready = dir.appendingPathComponent("ready")

        // $1 = hex dump output file, $2 = ready file. No termios changes:
        // the child sees the pty exactly as PTY.spawn configured it.
        let script = """
        : > "$2"
        /usr/bin/head -n 1 | /usr/bin/od -An -tx1 > "$1"
        """
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", script, "sh", out.path, ready.path],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        defer { pty.terminate() }

        let lock = NSLock()
        var echoed = Data()
        var exitStatus: Int32 = -1
        let exitedExp = expectation(description: "reader child exited")
        pty.setOnBytes { chunk in
            lock.lock(); defer { lock.unlock() }
            echoed.append(chunk)
        }
        pty.setOnExit { status in
            lock.lock()
            exitStatus = status
            lock.unlock()
            exitedExp.fulfill()
        }
        pty.startReading()

        // Wait until the child has provably reached its read.
        let readyDeadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path),
                      "precondition: child never reached its line read (ready file missing after 15 s)",
                      file: file, line: line)
        guard FileManager.default.fileExists(atPath: ready.path) else {
            throw XCTSkip("rig failed to start; see precondition failure above")
        }

        for keys in keystrokes { pty.write(Data(keys)) }

        let waitResult = XCTWaiter().wait(for: [exitedExp], timeout: 15)
        let exited = waitResult == .completed

        let dump = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        let tokens = dump.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        lock.lock(); defer { lock.unlock() }
        return LineResult(received: tokens, exited: exited, exitStatus: exitStatus, echoed: echoed)
    }

    /// Types `keystrokes`, then asserts the rig worked and the reader got
    /// exactly `expected`.
    private func assertLine(
        typing keystrokes: [[UInt8]], receives expected: [UInt8], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let result = try readLine(typing: keystrokes, file: file, line: line)
        XCTAssertTrue(result.exited,
                      "\(label): precondition: reader did not finish within 15 s (it never saw a complete line); "
                      + "tty echoed \(result.echoed as NSData)",
                      file: file, line: line)
        XCTAssertEqual(result.exitStatus, 0,
                       "\(label): precondition: reader pipeline should exit 0",
                       file: file, line: line)
        let typed = hex(keystrokes.flatMap { $0 })
        XCTAssertEqual(
            result.received, hex(expected),
            "\(label): typed bytes \(typed.joined(separator: " ")); the program must receive "
            + "\(hex(expected).joined(separator: " ")) but received "
            + "\(result.received.joined(separator: " ")). One Backspace must erase one whole "
            + "UTF-8 character; a partial sequence is invalid UTF-8 (pty needs IUTF8)",
            file: file, line: line
        )
    }

    // MARK: - Controls (pass whenever the rig is sound)

    /// ASCII Backspace removes exactly one byte. If this fails the rig, not
    /// the multibyte handling, is broken (child not in canonical mode, or
    /// 0x7F not the erase character).
    func test_control_asciiBackspace_erasesOneCharacter() throws {
        try assertLine(
            typing: [Self.a, Self.b, Self.backspace, Self.enter],
            receives: Self.a + Self.enter,
            label: "ASCII a b <BS> <CR>"
        )
    }

    /// Multibyte characters typed with no Backspace reach the program
    /// untouched (no mangling, no over-erasing, no reordering).
    func test_control_multibyteWithoutBackspace_arrivesIntact() throws {
        let expected = Self.eAcute + Self.cjk + Self.emoji + Self.enter
        try assertLine(
            typing: [Self.eAcute, Self.cjk, Self.emoji, Self.enter],
            receives: expected,
            label: "é 日 😀 <CR> (no backspace)"
        )
    }

    // MARK: - The bug

    /// The headline case: `a`, `é`, Backspace, Enter. Buggy result is
    /// `61 c3 0a` (stray lead byte).
    func test_backspaceOverTwoByteCharacter_removesTheWholeCharacter() throws {
        try assertLine(
            typing: [Self.a, Self.eAcute, Self.backspace, Self.enter],
            receives: Self.a + Self.enter,
            label: "a é <BS> <CR>"
        )
    }

    /// CJK scalar (3 bytes). Buggy result is `61 e6 97 0a`; the report says
    /// it takes 3 Backspaces per character without IUTF8.
    func test_backspaceOverThreeByteCharacter_removesTheWholeCharacter() throws {
        try assertLine(
            typing: [Self.a, Self.cjk, Self.backspace, Self.enter],
            receives: Self.a + Self.enter,
            label: "a 日 <BS> <CR>"
        )
    }

    /// Emoji scalar (4 bytes). Buggy result is `61 f0 9f 98 0a`.
    func test_backspaceOverFourByteCharacter_removesTheWholeCharacter() throws {
        try assertLine(
            typing: [Self.a, Self.emoji, Self.backspace, Self.enter],
            receives: Self.a + Self.enter,
            label: "a 😀 <BS> <CR>"
        )
    }

    /// Several Backspaces over mixed-width characters: each removes exactly
    /// one character, from the end, and the surviving `é` is left intact
    /// (no over-erase). Buggy result mangles `日` and `😀`.
    func test_repeatedBackspaceOverMixedWidthCharacters_removesOneCharacterEach() throws {
        try assertLine(
            typing: [Self.eAcute, Self.cjk, Self.emoji, Self.backspace, Self.backspace, Self.enter],
            receives: Self.eAcute + Self.enter,
            label: "é 日 😀 <BS> <BS> <CR>"
        )
    }

    /// The user-facing "fix a typo" flow: type `é`, Backspace, retype `é`.
    /// The program must see one clean `é`, not a stray lead byte glued in
    /// front of it (`c3 c3 a9`).
    func test_typoCorrection_retypeAfterBackspace_yieldsOneCleanCharacter() throws {
        try assertLine(
            typing: [Self.a, Self.eAcute, Self.backspace, Self.eAcute, Self.enter],
            receives: Self.a + Self.eAcute + Self.enter,
            label: "a é <BS> é <CR>"
        )
    }
}
