import XCTest
import AppKit
import Metal
@testable import Blackbird

/// Blind regression tests for bug PP-1: Ctrl-C (and Ctrl-Z, Ctrl-\) are
/// ignored after a multi-line paste of 1 KiB or more into a running program
/// that is not reading its input.
///
/// Scenario. A foreground program is running in cooked mode (ICANON and ISIG
/// on, bracketed paste off, which is the normal state while a command runs)
/// and is not reading stdin: `sleep`, `make`, a compile. The user pastes a
/// multi-line block of at least about 1 KiB. The kernel's tty input queue
/// accepts one complete line plus roughly 1022 further bytes and then rejects
/// every further write to the pty master with EAGAIN, so the terminal's
/// writer parks the rest of the paste and keeps retrying. The user then
/// presses Ctrl-C. The byte goes into the same jammed pipe behind the paste
/// and is never seen by the line discipline, so SIGINT is never raised.
///
/// Contract under test (observable, end to end, no knowledge of the fix):
///
///  1. Interrupt works. Ctrl-C pressed through the real `TerminalView.keyDown`
///     path after such a paste interrupts the foreground program promptly,
///     within seconds, not "whenever the program finally reads". Every
///     terminal behaves this way: the interrupt character is acted on by the
///     tty line discipline the moment it arrives, whatever else is queued.
///
///  2. Typed-ahead text does not survive the interrupt. With ISIG on and
///     NOFLSH off, the kernel throws away everything queued for the program
///     when it raises SIGINT. A paste is just typed-ahead input, so the part
///     of it that never made it into the kernel queue (and so is still
///     waiting in the app) must not be delivered to the shell once the
///     program has been interrupted. The report's impact paragraph says the
///     same: "the pasted-ahead lines run even though the user tried to
///     cancel." The control test below shows the kernel does exactly this for
///     a paste small enough to fit entirely in its queue.
///
/// Rig. One real `TerminalSession` (no window, no `MainWindowController`)
/// running `/bin/bash -c <script>`; bash is used rather than `/bin/sh`
/// because `read -t` is needed. The script traps SIGINT with a no-op so the
/// shell itself survives, touches a "ready" file, and runs `sleep 12` (a
/// foreground child that never reads stdin). When `sleep` returns it records
/// `rc=<status>` (130 means "killed by SIGINT"). It then waits up to 3 s for
/// any line to arrive on its stdin and records what it got, then waits for a
/// sentinel line that the test sends itself. The sentinel proves the read
/// path is alive, so an empty "leftover" really means nothing leaked rather
/// than that the reader was broken.
///
/// The paste goes through `TerminalView.pasteText` and the Ctrl-C through
/// `TerminalView.keyDown(with:)` with a synthesized key event. The tests do
/// not touch the pty, the writer or the session directly, so they pin the
/// user-visible behaviour whichever layer owns the fix.
///
/// Rig honesty.
///  - `test_control_smallMultiLinePaste_ctrlCInterruptsAndNothingLeaks` runs
///    the identical rig with a paste that fits in the kernel queue (about
///    220 bytes). It must pass on any correct implementation including the
///    current one; it proves the keyDown path really delivers Ctrl-C and the
///    shell really survives it, so a failure of the big-paste tests can only
///    be the jam.
///  - `test_premise_kernelRejectsMasterWritesOnceALineAndAKilobyteAreQueued`
///    reproduces the kernel condition with a bare `openpty` pair, with no
///    app code involved, and asserts that a Ctrl-C byte written to the
///    master gets EAGAIN. If the platform's tty ever stops behaving this
///    way, the failing premise test says the bug scenario no longer exists
///    and the big-paste tests are not exercising a jam.
///
/// Pre-flight cost (project rule, per `feedback_test_memory_safety`):
///  - Payloads are at most about 1.7 KiB of text; a few KiB of transient
///    memory per test. The premise test writes a 3 KiB payload to a pty pair.
///  - One live `/bin/bash` (+ `sleep`) per scenario, torn down before the
///    test returns, never two sessions at once. One temp directory per
///    scenario holding at most four tiny files, removed in tearDown. No
///    window, no `MainWindowController`, no tab group.
///  - Wall time per scenario: about 1 s (interrupt only), about 5 s with the
///    3 s leftover window and the sentinel step. On the buggy code the wait
///    for the interrupt is capped at 5 s, then the session is terminated,
///    which also kills the orphan `sleep` (it would exit by itself after
///    12 s). Every wait has a hard cap.
///
/// Written blind: no body of `PTY`, `TerminalSession` or `TerminalView` was
/// read; only declarations, doc comments, sibling tests and the terminal
/// conventions above.
final class PTYPasteInterruptBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// ETX as AppKit reports Ctrl+C: `characters` is the control byte,
    /// `charactersIgnoringModifiers` is the letter, key code 8 (`kVK_ANSI_C`).
    private static let ctrlCChars = "\u{03}"
    private static let ctrlCKeyCode: UInt16 = 8

    /// How long the user takes between the paste landing and pressing Ctrl-C.
    /// Also lets the writer reach its steady (jammed) state before the key.
    private static let humanPause: TimeInterval = 0.3

    /// "Promptly". The healthy path takes tens of milliseconds; the cap is
    /// generous so a slow ASan host does not flake, yet far below the 12 s
    /// the `sleep` would otherwise run.
    private static let interruptDeadline: TimeInterval = 5

    private var cleanupDirectories: [URL] = []

    override func tearDown() {
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
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

    private func readTrimmed(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A multi-line block shaped like code pasted from a README: `lineCount`
    /// lines of 55 printable characters plus LF each. Letters, digits and
    /// hyphens only, so no paste sanitizer has anything to rewrite, and each
    /// line carries its own number so a leaked fragment is identifiable.
    private static func multiLineText(lineCount: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var lines: [String] = []
        for i in 0..<lineCount {
            let number = i < 10 ? "0\(i)" : "\(i)"
            var body = [UInt8](repeating: 0, count: 40)
            for j in 0..<body.count { body[j] = alphabet[(j &+ i &* 7) % alphabet.count] }
            lines.append("pasted-line-\(number)-" + String(decoding: body, as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func ctrlCKeyDown() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: Self.ctrlCChars,
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: Self.ctrlCKeyCode
            ),
            "NSEvent.keyEvent returned nil for Ctrl+C"
        )
    }

    // MARK: - Scenario

    struct Outcome {
        var pastedBytes: Int
        /// Contents of the status file (`rc=<n>`), nil if `sleep` was still
        /// running when the interrupt deadline passed.
        var status: String?
        /// Seconds from the Ctrl-C key to the status file appearing.
        var interruptLatency: TimeInterval?
        /// `leftover=[<what the shell read in its 3 s window>]`, nil if the
        /// window was never reached or never closed.
        var leftover: String?
        /// `sentinel=[<line the test typed after the window>]`, nil if not
        /// reached.
        var sentinel: String?
    }

    /// Runs the whole scenario once and returns what the shell observed.
    /// `probeAfterInterrupt` additionally runs the leftover window and the
    /// sentinel step (about 4 s more) once the interrupt has happened.
    private func runScenario(
        pastedLineCount: Int,
        probeAfterInterrupt: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Outcome {
        let device = try requireMetalDevice(file: file, line: line)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-pasteint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let ready = dir.appendingPathComponent("ready")
        let status = dir.appendingPathComponent("status")
        let leftoverFile = dir.appendingPathComponent("leftover")
        let sentinelFile = dir.appendingPathComponent("sentinel")

        // $1 ready, $2 status, $3 leftover, $4 sentinel. Default termios: the
        // script never touches stty, so the program runs in cooked mode with
        // ISIG on exactly as a user's `sleep` / `make` would.
        let script = """
        trap ':' INT
        : > "$1"
        sleep 12
        echo "rc=$?" > "$2"
        IFS= read -r -t 3 leftover
        echo "leftover=[$leftover]" > "$3"
        IFS= read -r -t 8 sentinel
        echo "sentinel=[$sentinel]" > "$4"
        """
        let session = try TerminalSession.start(
            shell: "/bin/bash",
            arguments: ["-c", script, "bash", ready.path, status.path, leftoverFile.path, sentinelFile.path],
            size: .init(cols: 80, rows: 24)
        )
        defer { session.terminate() }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240), device: device)
        view.session = session

        let readyInTime = spin(timeout: 15) { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(readyInTime,
                      "precondition: child never reached its sleep (ready file missing after 15 s)",
                      file: file, line: line)
        guard readyInTime else { throw XCTSkip("rig failed to start; see precondition failure above") }

        // The paste, exactly as the Edit > Paste action would deliver it.
        let text = Self.multiLineText(lineCount: pastedLineCount)
        let pastedBytes = text.utf8.count
        view.pasteText(text)
        spin(timeout: Self.humanPause) { false }

        // Ctrl-C through the real key path.
        let keyStart = Date()
        view.keyDown(with: try ctrlCKeyDown())

        var outcome = Outcome(pastedBytes: pastedBytes)
        let interrupted = spin(timeout: Self.interruptDeadline) {
            FileManager.default.fileExists(atPath: status.path)
        }
        if interrupted {
            outcome.interruptLatency = Date().timeIntervalSince(keyStart)
            // A single small write; give the file a moment to be complete.
            spin(timeout: 0.2) { false }
            outcome.status = readTrimmed(status)
        }
        guard interrupted, probeAfterInterrupt else { return outcome }

        // The shell is now in its 3 s window for stray input. Wait for it to
        // close (3 s + slack).
        let windowClosed = spin(timeout: 8) { FileManager.default.fileExists(atPath: leftoverFile.path) }
        if windowClosed {
            spin(timeout: 0.2) { false }
            outcome.leftover = readTrimmed(leftoverFile)
        }
        guard windowClosed, outcome.leftover == "leftover=[]" else { return outcome }

        // Positive control for the reader: a line typed now must arrive, so
        // the empty window above is a real "nothing leaked".
        session.send(Data("sentinel-ok\r".utf8))
        let sentinelSeen = spin(timeout: 10) { FileManager.default.fileExists(atPath: sentinelFile.path) }
        if sentinelSeen {
            spin(timeout: 0.2) { false }
            outcome.sentinel = readTrimmed(sentinelFile)
        }
        return outcome
    }

    private func describe(_ o: Outcome) -> String {
        let latency = o.interruptLatency.map { String(format: "%.2f s", $0) } ?? "never (within "
            + "\(Self.interruptDeadline) s)"
        return "pasted \(o.pastedBytes) bytes, interrupt latency \(latency), status \(o.status ?? "<none>"), "
            + "leftover \(o.leftover ?? "<none>"), sentinel \(o.sentinel ?? "<none>")"
    }

    // MARK: - Tests

    /// THE BUG, headline. About 1.7 KiB over 30 lines pasted into a running
    /// `sleep`, then Ctrl-C. The program must be interrupted (killed by
    /// SIGINT, so `$?` is 130) within seconds. On the buggy code the Ctrl-C
    /// byte sits behind the paste in the writer's backlog, `sleep` keeps
    /// sleeping, and no status ever appears.
    func test_ctrlC_afterMultiLinePasteOverOneKiB_interruptsForegroundProgram() throws {
        let o = try runScenario(pastedLineCount: 30, probeAfterInterrupt: false)

        XCTAssertGreaterThanOrEqual(o.pastedBytes, 1500,
                                    "fixture: the paste must be well past the ~1 KiB threshold, was \(o.pastedBytes)")
        XCTAssertEqual(
            o.status, "rc=130",
            "Ctrl-C after a \(o.pastedBytes)-byte multi-line paste must interrupt the running program "
            + "(sleep killed by SIGINT, rc=130) within \(Self.interruptDeadline) s; \(describe(o))"
        )
    }

    /// The second half of the impact: after the user interrupts, the
    /// pasted-ahead lines that never reached the kernel must not be fed to
    /// the shell. A real terminal's typed-ahead input is discarded by the
    /// interrupt; here the shell reads for 3 s after `sleep` dies and must
    /// see nothing, and then must still be able to receive a line typed
    /// afterwards (the sentinel), so the silence is not a dead reader.
    func test_ctrlC_afterMultiLinePasteOverOneKiB_discardsThePastedAheadLines() throws {
        let o = try runScenario(pastedLineCount: 30, probeAfterInterrupt: true)

        XCTAssertEqual(
            o.status, "rc=130",
            "precondition: Ctrl-C must have interrupted the program before leftovers can be judged; \(describe(o))"
        )
        guard o.status == "rc=130" else { return }
        XCTAssertEqual(
            o.leftover, "leftover=[]",
            "after the interrupt the shell must not receive any of the pasted text (the user cancelled); \(describe(o))"
        )
        XCTAssertEqual(
            o.sentinel, "sentinel=[sentinel-ok]",
            "a line typed after the interrupt must reach the shell intact and first, "
            + "ahead of any stale pasted text; \(describe(o))"
        )
    }

    /// Control: the same rig and the same assertions with a paste of 4 lines
    /// (about 224 bytes) that fits in the kernel queue. This is the
    /// everyday case and works today. It proves the keyDown path delivers
    /// Ctrl-C, the shell survives it, the kernel flushes typed-ahead on
    /// SIGINT (empty leftover) and the sentinel reaches the reader. It must
    /// keep passing after the fix.
    func test_control_smallMultiLinePaste_ctrlCInterruptsAndNothingLeaks() throws {
        let o = try runScenario(pastedLineCount: 4, probeAfterInterrupt: true)

        XCTAssertLessThan(o.pastedBytes, 500,
                          "fixture: the control paste must stay far below the ~1 KiB jam threshold, was \(o.pastedBytes)")
        XCTAssertEqual(o.status, "rc=130",
                       "control: Ctrl-C after a small paste must interrupt the program; \(describe(o))")
        XCTAssertEqual(o.leftover, "leftover=[]",
                       "control: the interrupt flushes typed-ahead, nothing may reach the shell; \(describe(o))")
        XCTAssertEqual(o.sentinel, "sentinel=[sentinel-ok]",
                       "control: a line typed after the interrupt must reach the shell; \(describe(o))")
    }

    /// Premise, with no app code: a bare pty pair in cooked mode. Writing a
    /// short line and then more than a kilobyte to the master (non-blocking,
    /// as the app's writer does) fills the tty input queue, after which even
    /// a single Ctrl-C byte is refused with EAGAIN. This is the kernel
    /// condition PP-1 depends on; if it stops holding, the big-paste tests
    /// above no longer exercise a jam.
    func test_premise_kernelRejectsMasterWritesOnceALineAndAKilobyteAreQueued() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        let rc = openpty(&master, &slave, nil, nil, nil)
        XCTAssertEqual(rc, 0, "precondition: openpty failed (rc \(rc), errno \(errno))")
        guard rc == 0 else { throw XCTSkip("openpty unavailable; see precondition failure above") }
        defer {
            Darwin.close(master)
            Darwin.close(slave)
        }

        // Cooked mode with signals on is the default for a fresh pty; assert
        // it rather than assume it, and drop ECHO so the unread output side
        // cannot be the thing that blocks.
        var t = termios()
        XCTAssertEqual(tcgetattr(slave, &t), 0, "precondition: tcgetattr failed (errno \(errno))")
        let canonicalAndSignals = tcflag_t(ICANON) | tcflag_t(ISIG)
        XCTAssertEqual(t.c_lflag & canonicalAndSignals, canonicalAndSignals,
                       "precondition: a fresh pty must be cooked (ICANON) with ISIG on; c_lflag \(t.c_lflag)")
        t.c_lflag &= ~tcflag_t(ECHO)
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &t), 0, "precondition: tcsetattr failed (errno \(errno))")

        let flags = fcntl(master, F_GETFL, 0)
        XCTAssertEqual(fcntl(master, F_SETFL, flags | O_NONBLOCK), 0,
                       "precondition: cannot make the master non-blocking (errno \(errno))")

        // One short complete line, then 3000 bytes of the next line.
        var payload: [UInt8] = Array("first-line\n".utf8)
        payload.append(contentsOf: [UInt8](repeating: 0x61, count: 3000))

        var accepted = 0
        var lastErrno: Int32 = 0
        while accepted < payload.count {
            let offset = accepted
            let n: Int = payload.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> Int in
                guard let base = buf.baseAddress else { return -1 }
                let written = Darwin.write(master, base + offset, buf.count - offset)
                if written < 0 { lastErrno = errno }
                return written
            }
            if n < 0 { break }
            accepted += n
        }
        XCTAssertEqual(lastErrno, EAGAIN,
                       "the master must start refusing writes with EAGAIN once the queue is full "
                       + "(accepted \(accepted) of \(payload.count) bytes, errno \(lastErrno))")
        XCTAssertGreaterThanOrEqual(accepted, 1000,
                                    "the kernel should accept about a kilobyte before refusing, accepted \(accepted)")
        XCTAssertLessThan(accepted, payload.count,
                          "the 3 KiB payload must not fit in the tty input queue, accepted \(accepted)")

        // The Ctrl-C byte itself is refused as well.
        var etx: UInt8 = 0x03
        errno = 0
        let ctrlC = Darwin.write(master, &etx, 1)
        let ctrlCErrno = errno
        XCTAssertEqual(ctrlC, -1, "a Ctrl-C byte written to a jammed master must be refused, wrote \(ctrlC)")
        XCTAssertEqual(ctrlCErrno, EAGAIN, "a refused Ctrl-C byte must fail with EAGAIN, errno \(ctrlCErrno)")
    }
}
