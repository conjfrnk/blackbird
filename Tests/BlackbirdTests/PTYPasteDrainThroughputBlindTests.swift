import XCTest
import Foundation
@testable import Blackbird

/// Blind regression tests for bug PP-3: a large paste or drop is delivered to
/// a child that IS reading, but at a small fraction of the speed the child can
/// read, so a few-MiB paste takes seconds before the program (or the
/// bracketed-paste end marker) finally sees all of it.
///
/// Scenario. The user pastes (or drops) a few hundred KiB or more. Blackbird
/// hands it to the PTY writer as ONE write. The foreground program is in raw
/// mode and reads promptly: `cat`, a `head -c N`, an Ink-style raw stdin
/// reader. The kernel's tty input queue only accepts about 1 KiB at a time, so
/// the rest of the paste has to wait in the app until the child has drained
/// the queue. Each time the child reads, there is room for the next ~1 KiB.
///
/// Contract under test (observable, end to end, no knowledge of the fix): the
/// backlog drains at the speed the child consumes it. A reader that can take
/// many MiB/s must see a 1 MiB paste complete in a fraction of a second, not
/// at a fixed few-hundred-KiB-per-second rate set by how often the app polls
/// for room. The report measured the current drain at about 0.5 to 0.6 MiB/s
/// (2 MiB in 3.3 to 4.0 s) against 0.16 to 0.6 s for 2 MiB when the writer
/// reacts to the pty becoming writable.
///
/// Reference numbers measured on the dev host with a bare `openpty` pair, a
/// non-blocking master and a `poll(POLLOUT)` loop, no app code involved: 1 MiB
/// into `cat` in raw mode takes 0.075 to 0.08 s, 12 to 13 MiB/s. The same
/// loop driven by a `sleep(1 ms)` timer instead of poll managed only 2.3 MiB/s
/// in the best case. So a drain that is limited by a short fixed timer cannot
/// reach the speed asserted here, and a drain that follows the child can reach
/// it with an order of magnitude to spare.
///
/// Why the bar is where it is: `requiredRate` is 1.5 MiB/s, which is a 1 MiB
/// write finishing inside `deadline` (0.7 s). That is about 2.5x faster than
/// the reported timer-driven rate and roughly 5x to 10x slower than what an
/// event-driven drain reaches on a busy dev host. The test is best-of-3
/// (stops at the first attempt inside the deadline), the same "best of up to
/// N attempts" discipline the CI throughput floors use, so one scheduling
/// hiccup on a loaded runner cannot fail a correct implementation, while a
/// drain that is capped by a timer misses the deadline on every attempt.
///
/// Rig. One real child (`/bin/sh`) that switches its tty to raw / no-echo (so
/// there is no canonical-mode line limit and no echo traffic to read back),
/// drops a "ready" file, then `exec cat > received.bin`. The oracle is the size
/// and content of that file. Raw mode matters: it makes the child a pure
/// consumer, so the only slow part left in the pipeline is the writer's drain.
///
/// Rig honesty.
///  - A 64-byte control write goes in first and must arrive within 5 s. That
///    proves the child is reading and the file oracle works, so a slow big
///    write can only be the drain.
///  - The received file must equal the bytes written, in order, after the
///    last attempt. A "fast" drain that drops or reorders data does not pass.
///  - Each attempt waits for the previous backlog to be fully delivered, so
///    attempts never overlap and each one is timed on an empty writer.
///
/// Two tests, same rig, different entry points: `PTY.write` directly, and
/// `TerminalSession.send` carrying a complete bracketed-paste frame (which is
/// what the paste pipeline hands the PTY), asserting the frame's closing
/// `ESC[201~` is the last thing the child sees within the deadline.
///
/// Pre-flight cost (project rule, per `feedback_test_memory_safety`):
///  - Payload is 1 MiB per attempt, at most 3 attempts. Transient copies
///    (payload, expected stream, file read back) are about 10 MiB in total.
///  - One live `/bin/sh` + `cat` per test, torn down before the test returns,
///    never two at once. No window, no `MainWindowController`, no tab group.
///    One temp directory per test holding at most a 3 MiB file, removed in
///    tearDown.
///  - Wall time: about 1 s with a correct drain; on the buggy drain each
///    attempt takes about 1.7 to 2 s, so about 6 s for the three. Every wait
///    has a hard cap (25 s per attempt).
///
/// Written blind: no body of `PTY`, `TerminalSession` or `TerminalView` was
/// read; only declarations, doc comments, sibling tests and the terminal
/// conventions above.
final class PTYPasteDrainThroughputBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    private static let oneMiB = 1024 * 1024

    /// A 1 MiB write must complete within this long (see the type doc).
    private static let deadline: TimeInterval = 0.7

    /// The same bar expressed as a rate, for failure messages.
    private static let requiredRate: Double = 1.5  // MiB/s

    private static let maxAttempts = 3

    /// Hard cap on a single attempt, so a stalled child ends the test.
    private static let attemptCap: TimeInterval = 25

    private static let bracketOpen: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC [ 2 0 0 ~
    private static let bracketClose: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~

    // MARK: - Rig

    private struct Rig {
        let write: (Data) -> Void
        let terminate: () -> Void
        let received: URL
    }

    private enum EntryPoint {
        case pty
        case session
    }

    private var cleanupDirectories: [URL] = []

    override func tearDown() {
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
    }

    /// Starts the raw-mode `cat` child through the requested entry point and
    /// waits until it has provably reached its read loop.
    private func makeRig(_ entry: EntryPoint, file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-pastedrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let received = dir.appendingPathComponent("received.bin")
        let ready = dir.appendingPathComponent("ready")

        // $1 = output file, $2 = ready file. `stty raw -echo` first so the
        // line discipline never queues the paste as canonical-mode lines and
        // nothing is echoed back; the ready file appears only after that.
        let script = """
        stty raw -echo || exit 3
        : > "$2"
        exec cat > "$1"
        """
        let arguments: [String] = ["-c", script, "sh", received.path, ready.path]

        let rig: Rig
        switch entry {
        case .pty:
            let pty = try PTY.spawn(
                executable: "/bin/sh",
                arguments: arguments,
                envOverrides: [:],
                size: .init(cols: 80, rows: 24)
            )
            // Same wiring the app has: a live read loop on the master.
            pty.setOnBytes { (_: Data) -> Void in }
            pty.startReading()
            rig = Rig(write: { (data: Data) -> Void in pty.write(data) },
                      terminate: { pty.terminate() },
                      received: received)
        case .session:
            let session = try TerminalSession.start(
                shell: "/bin/sh",
                arguments: arguments,
                size: .init(cols: 80, rows: 24)
            )
            rig = Rig(write: { (data: Data) -> Void in session.send(data) },
                      terminate: { session.terminate() },
                      received: received)
        }

        let readyInTime = spin(timeout: 15) { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(readyInTime,
                      "precondition: child never reached its read loop (ready file missing after 15 s)",
                      file: file, line: line)
        guard readyInTime else {
            rig.terminate()
            throw XCTSkip("rig failed to start; see precondition failure above")
        }
        return rig
    }

    // MARK: - Helpers

    /// Pumps the main run loop until `condition` holds or `timeout` passes.
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

    /// Deterministic printable-ASCII filler with no whitespace, control bytes
    /// or ESC. The period is not a power of two, so a block delivered twice
    /// or out of place cannot compare equal.
    private static func filler(count: Int, seed: Int) -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = alphabet[(i &+ seed &+ i / 4099) % alphabet.count]
        }
        return out
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Size of the received file right now (0 if absent).
    private func receivedSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Index of the first differing byte, or -1 when `a` and `b` are equal.
    private func firstMismatch(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        // Explicit closure types: the macOS 26 SDK's compiler cannot always
        // infer which withUnsafeBytes overload is meant.
        let idx: Int? = a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) -> Int? in
            b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) -> Int? in
                for i in 0..<n where pa[i] != pb[i] { return i }
                return nil
            }
        }
        if let idx { return idx }
        return a.count == b.count ? -1 : n
    }

    private struct Attempt {
        var elapsed: TimeInterval
        var receivedAfter: Int
        var completed: Bool
        /// MiB/s, for a payload that is always exactly 1 MiB.
        var rate: Double { 1.0 / max(elapsed, 0.000_001) }
    }

    /// Hands `payload` to the rig as one write and returns how long the child
    /// took to have received `alreadyReceived + payload.count` bytes in total.
    private func timedDelivery(_ rig: Rig, payload: Data, alreadyReceived: Int) -> Attempt {
        let target = alreadyReceived + payload.count
        let start = ProcessInfo.processInfo.systemUptime
        rig.write(payload)
        var size = 0
        var elapsed: TimeInterval = 0
        while true {
            size = receivedSize(rig.received)
            elapsed = ProcessInfo.processInfo.systemUptime - start
            if size >= target || elapsed > Self.attemptCap { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return Attempt(elapsed: elapsed, receivedAfter: size, completed: size >= target)
    }

    /// Proves the child is reading and the file oracle works, with a write
    /// far below the kernel queue size. Returns the control bytes written.
    private func sendControl(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let control = Data(Self.filler(count: 64, seed: 3))
        rig.write(control)
        let arrived = spin(timeout: 5) { receivedSize(rig.received) >= control.count }
        XCTAssertTrue(arrived,
                      "precondition: a 64-byte control write never reached the raw-mode cat within 5 s "
                      + "(file size \(receivedSize(rig.received))); the rig itself is not working",
                      file: file, line: line)
        guard arrived else {
            rig.terminate()
            throw XCTSkip("rig cannot deliver even 64 bytes; see precondition failure above")
        }
        return control
    }

    private func describe(_ attempts: [Attempt]) -> String {
        attempts.enumerated().map { (i: Int, a: Attempt) -> String in
            "#\(i + 1): " + String(format: "%.2f s (%.2f MiB/s)", a.elapsed, a.rate)
                + (a.completed ? "" : " INCOMPLETE")
        }.joined(separator: ", ")
    }

    /// Runs up to `maxAttempts` timed 1 MiB deliveries, stopping at the first
    /// one inside the deadline. `makePayload` builds the (distinct) payload
    /// of each attempt. Returns all attempts and the expected file content.
    private func runAttempts(
        _ rig: Rig, control: Data, makePayload: (Int) -> Data
    ) -> (attempts: [Attempt], expected: Data) {
        var expected = control
        var attempts: [Attempt] = []
        for k in 0..<Self.maxAttempts {
            let payload = makePayload(k)
            let attempt = timedDelivery(rig, payload: payload, alreadyReceived: expected.count)
            expected.append(payload)
            attempts.append(attempt)
            if !attempt.completed || attempt.elapsed <= Self.deadline { break }
        }
        return (attempts, expected)
    }

    private func assertFastAndIntact(
        _ rig: Rig, attempts: [Attempt], expected: Data, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Let any (wrongly) duplicated tail show up before reading back.
        Thread.sleep(forTimeInterval: 0.2)
        let got = (try? Data(contentsOf: rig.received)) ?? Data()

        XCTAssertEqual(
            got.count, expected.count,
            "\(label): child received \(got.count) of \(expected.count) bytes; every write must be delivered whole",
            file: file, line: line
        )
        XCTAssertEqual(
            firstMismatch(got, expected), -1,
            "\(label): received stream diverges from the written bytes at offset "
            + "\(firstMismatch(got, expected)) (received \(got.count), expected \(expected.count))",
            file: file, line: line
        )

        let best = attempts.map { (a: Attempt) -> TimeInterval in a.elapsed }.min() ?? .infinity
        XCTAssertLessThanOrEqual(
            best, Self.deadline,
            "\(label): a single 1 MiB write into a child that reads far faster must be fully delivered "
            + "within \(Self.deadline) s (>= \(Self.requiredRate) MiB/s). Best of \(attempts.count) attempts took "
            + String(format: "%.2f", best) + " s [\(describe(attempts))]. An event-driven drain finishes this in "
            + "roughly 0.1 s; a backlog drained on a fixed 1 ms timer manages about 0.5 MiB/s, so a "
            + "few-MiB paste takes seconds",
            file: file, line: line
        )
    }

    // MARK: - Tests

    /// `PTY.write` of one 1 MiB buffer into a raw-mode `cat`: the exact trigger
    /// from the report, measured at the PTY layer.
    func test_singleWriteOf1MiB_toRawModeReader_drainsAtChildSpeedNotTimerSpeed() throws {
        try requireTestFitsInBudget(estimatedBytes: 32 * 1024 * 1024)
        let rig = try makeRig(.pty)
        defer { rig.terminate() }
        let control = try sendControl(rig)

        let result = runAttempts(rig, control: control) { (k: Int) -> Data in
            Data(Self.filler(count: Self.oneMiB, seed: 17 &+ k &* 101))
        }
        assertFastAndIntact(rig, attempts: result.attempts, expected: result.expected,
                            label: "PTY.write of 1 MiB into raw-mode cat")
    }

    /// The paste path: `TerminalSession.send` of a complete bracketed-paste
    /// frame (`ESC[200~` + body + `ESC[201~`, 1 MiB in total). The program (and
    /// the shell's paste widget) only finishes when the end marker arrives, so
    /// the marker has to be the last thing the child sees, inside the deadline.
    func test_bracketedPasteFrameOf1MiB_viaSession_endMarkerArrivesWithinDeadline() throws {
        try requireTestFitsInBudget(estimatedBytes: 32 * 1024 * 1024)
        let rig = try makeRig(.session)
        defer { rig.terminate() }
        let control = try sendControl(rig)

        let framedBodyCount = Self.oneMiB - Self.bracketOpen.count - Self.bracketClose.count
        let result = runAttempts(rig, control: control) { (k: Int) -> Data in
            var frame = Data(Self.bracketOpen)
            frame.append(contentsOf: Self.filler(count: framedBodyCount, seed: 29 &+ k &* 97))
            frame.append(contentsOf: Self.bracketClose)
            return frame
        }
        XCTAssertEqual(result.expected.count - control.count,
                       result.attempts.count * Self.oneMiB,
                       "fixture: every attempt must write exactly 1 MiB")
        assertFastAndIntact(rig, attempts: result.attempts, expected: result.expected,
                            label: "bracketed paste frame of 1 MiB via TerminalSession.send")

        let tail = [UInt8]((try? Data(contentsOf: rig.received))?.suffix(Self.bracketClose.count) ?? Data())
        XCTAssertEqual(
            hex(tail), hex(Self.bracketClose),
            "the bracketed-paste end marker ESC[201~ must be the last 6 bytes the child sees; "
            + "tail was \(hex(tail))"
        )
    }
}
