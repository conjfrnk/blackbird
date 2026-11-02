import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for bug pty-1: a paste of roughly 4 MiB or more is
/// silently truncated on its way to the child, and with bracketed paste on the
/// closing `ESC [ 201 ~` marker is what gets cut off.
///
/// Contract under test (observable, end to end): whatever text the user pastes
/// is delivered to the foreground program byte for byte, in order, with nothing
/// dropped and nothing split, however large it is. A bracketed paste must
/// arrive as `ESC[200~` + body + `ESC[201~`. If the end marker is lost, a
/// shell or readline that received `ESC[200~` stays in its paste-capture
/// widget and treats every later keystroke as pasted text.
///
/// Why drive `TerminalView.pasteText` and not `PTY.write` directly: the paste
/// is the user-visible operation. Going through the view pins the behaviour
/// regardless of which layer (paste pipeline, session, PTY writer) owns the
/// delivery guarantee.
///
/// Rig. One real `TerminalSession` running `/bin/sh` that switches its tty to
/// raw / no-echo (no canonical line limit, no echo traffic), optionally turns
/// on DECSET 2004 (so the view's snapshot really reports bracketed paste),
/// drops a "ready" file, then `exec cat > received.bin`. The test reads that
/// file back, so the oracle is exactly the bytes the child's stdin produced.
/// The child never exits by itself, so "fully delivered" is judged on the
/// byte count reaching the expected total, and a lost tail is judged by the
/// received count going silent short of it.
///
/// Pre-flight cost (project rule, per `feedback_test_memory_safety`):
///  - Payloads are 4 MiB + 1 byte, 4.5 MiB and 4 MiB + 64 KiB. Peak transient copies (String,
///    the pipeline's Data stages, the writer's pending buffer, the expected
///    frame, the received file read back) are roughly a dozen buffers of
///    4.5 MiB, about 55 MB, under the 256 MB budget gate below.
///  - One live `/bin/sh` + `cat` per test, torn down before the test returns;
///    never two sessions at once. One temp directory per test holding at most
///    a 4.5 MiB file, removed on exit. No window, no `MainWindowController`.
///  - Wall time is dominated by the child draining the pty at the kernel's
///    ~1 KiB-per-read rate: roughly 4 to 15 s per test depending on build
///    flavour. The loss path ends via the stall detector (8 s of silence),
///    never an unbounded wait; the hard cap is 120 s.
final class PTYLargePasteBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    /// The writer's documented buffer bound (`pendingBacklogCap`) as stated in
    /// the bug report: 4 MiB. Used only to size payloads just past it.
    private static let fourMiB = 4 * 1024 * 1024

    private static let bracketOpen: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC [ 2 0 0 ~
    private static let bracketClose: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let directory: URL
        let received: URL
    }

    private var cleanupDirectories: [URL] = []

    override func tearDown() {
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
    }

    /// Starts the child and waits until it is provably ready to read raw
    /// bytes (and, when `bracketed`, until the VIEW's snapshot reports
    /// bracketed-paste mode, which is what `pasteText` consults).
    private func makeRig(bracketed: Bool, file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-largepaste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let received = dir.appendingPathComponent("received.bin")
        let ready = dir.appendingPathComponent("ready")

        // $1 = output file, $2 = ready file, $3 = "1" to enable DECSET 2004.
        // `stty raw -echo` first so the line discipline never sees the paste
        // in cooked mode; the ready file is created only after that.
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

    /// Deterministic printable-ASCII filler with no whitespace, no control
    /// bytes and no ESC, so the paste sanitizers have nothing to touch. The
    /// period (62 with a drifting offset) is not a power of two, so a block
    /// delivered twice or out of place cannot compare equal.
    private static func filler(count: Int, seed: Int = 0) -> [UInt8] {
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

    struct Delivery {
        var bytes: Data
        var completed: Bool
        var elapsed: TimeInterval
    }

    /// Waits until the child has received `expectedCount` bytes, or the
    /// stream goes silent for `stallSeconds` short of it (bytes lost), or the
    /// hard cap passes. Then returns whatever the child received.
    private func awaitDelivery(_ rig: Rig, expectedCount: Int, stallSeconds: TimeInterval = 8,
                               hardCap: TimeInterval = 120) -> Delivery {
        let start = Date()
        var lastSize = -1
        var lastChange = Date()
        let completed = spin(timeout: hardCap) {
            let size = receivedSize(rig.received)
            if size != lastSize {
                lastSize = size
                lastChange = Date()
            }
            if size >= expectedCount { return true }
            return Date().timeIntervalSince(lastChange) > stallSeconds
        }
        _ = completed
        // Give an over-delivery (duplicates) a moment to show up in the size.
        Thread.sleep(forTimeInterval: 0.3)
        let data = (try? Data(contentsOf: rig.received)) ?? Data()
        return Delivery(bytes: data, completed: data.count >= expectedCount,
                        elapsed: Date().timeIntervalSince(start))
    }

    /// Index of the first differing byte, or -1 when `a` and `b` are equal.
    private func firstMismatch(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        let idx: Int? = a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                for i in 0..<n where pa[i] != pb[i] { return i }
                return nil
            }
        }
        if let idx { return idx }
        return a.count == b.count ? -1 : n
    }

    private func assertDelivered(
        _ delivery: Delivery, expected: Data, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let got = delivery.bytes.count
        XCTAssertEqual(
            got, expected.count,
            "\(label): child received \(got) of \(expected.count) bytes "
            + "(\(expected.count - got) lost) after \(String(format: "%.1f", delivery.elapsed)) s; "
            + "a paste must be delivered whole, never silently truncated",
            file: file, line: line
        )
        XCTAssertEqual(
            firstMismatch(delivery.bytes, expected), -1,
            "\(label): received stream diverges from the pasted bytes at offset "
            + "\(firstMismatch(delivery.bytes, expected)) (received \(got), expected \(expected.count))",
            file: file, line: line
        )
    }

    // MARK: - Tests

    /// The headline case from the report: a clipboard body of 4 MiB - 11
    /// bytes, which bracketed paste frames to exactly 4 MiB + 1 bytes. Only
    /// the very last byte (the `~` of `ESC[201~`) is over the 4 MiB mark, yet
    /// losing it leaves the shell inside its paste-capture widget.
    func test_bracketedPaste_bodyOf4MiBMinus11_deliversWholeFrameIncludingEndMarker() throws {
        try requireTestFitsInBudget(estimatedBytes: 64 * 1024 * 1024)
        let rig = try makeRig(bracketed: true)
        defer { rig.session.terminate() }

        let body = Self.filler(count: Self.fourMiB - 11)
        var expected = Data(Self.bracketOpen)
        expected.append(contentsOf: body)
        expected.append(contentsOf: Self.bracketClose)
        XCTAssertEqual(expected.count, Self.fourMiB + 1,
                       "fixture: framed paste must be exactly 4 MiB + 1 bytes")

        rig.view.pasteText(String(decoding: body, as: UTF8.self))
        let delivery = awaitDelivery(rig, expectedCount: expected.count)

        assertDelivered(delivery, expected: expected, label: "bracketed paste, body 4 MiB - 11")
        XCTAssertEqual(
            hex([UInt8](delivery.bytes.suffix(6))), hex(Self.bracketClose),
            "bracketed-paste end marker ESC[201~ must be the last 6 bytes the child sees; "
            + "tail was \(hex([UInt8](delivery.bytes.suffix(6)))) (a lost marker leaves the shell "
            + "treating all later typing as pasted text)"
        )
    }

    /// Well past the 4 MiB mark (4.5 MiB), bracketing OFF, with a two-byte
    /// UTF-8 scalar ("é", C3 A9) straddling the 4 MiB boundary so a cut there
    /// would also split a character. Guards against a "fix" that only nudges
    /// the limit by the 12 marker bytes, and covers the non-bracketed path.
    func test_plainPaste_4_5MiBWithMultibyteAtTheBoundary_deliversEveryByte() throws {
        try requireTestFitsInBudget(estimatedBytes: 64 * 1024 * 1024)
        let rig = try makeRig(bracketed: false)
        defer { rig.session.terminate() }

        // 4 MiB - 1 ASCII bytes, then "é" occupying offsets 4 MiB - 1 and
        // 4 MiB, then 512 KiB of ASCII. No LF/CR, so no multi-line confirm.
        var expectedBytes = Self.filler(count: Self.fourMiB - 1)
        expectedBytes.append(contentsOf: [0xC3, 0xA9])
        expectedBytes.append(contentsOf: Self.filler(count: 512 * 1024, seed: 17))
        let text = String(decoding: expectedBytes, as: UTF8.self)
        let expected = Data(expectedBytes)
        XCTAssertEqual(Array(text.utf8).count, expected.count,
                       "fixture: the pasted String must round-trip to the expected UTF-8 bytes")
        XCTAssertEqual(expected.count, Self.fourMiB + 1 + 512 * 1024,
                       "fixture: payload must be 4 MiB + 512 KiB + 1 bytes")

        rig.view.pasteText(text)
        let delivery = awaitDelivery(rig, expectedCount: expected.count)

        assertDelivered(delivery, expected: expected, label: "plain paste, 4.5 MiB")
    }

    /// Input typed right after an oversized paste must queue behind it, not
    /// be discarded. The paste is just over the 4 MiB mark, so the writer
    /// holds well over the cap in undelivered bytes for the ~11 s the child
    /// needs to drain it; a keystroke, a Return and a Ctrl-C-style
    /// immediate write issued in that window (all of them tiny, none of
    /// them able to push the writer's memory anywhere near the cap) must
    /// still reach the child, in order, after the last pasted byte.
    func test_inputTypedAfterOversizedPaste_isQueuedBehindItNotDropped() throws {
        try requireTestFitsInBudget(estimatedBytes: 64 * 1024 * 1024)
        let rig = try makeRig(bracketed: false)
        defer { rig.session.terminate() }

        let body = Self.filler(count: Self.fourMiB + 64 * 1024, seed: 5)
        let typed: [UInt8] = Array("abc".utf8) + [0x0D]   // "abc" + Return
        let interrupt: [UInt8] = [0x03]                   // Ctrl-C byte; raw tty, so just data
        var expected = Data(body)
        expected.append(contentsOf: typed)
        expected.append(contentsOf: interrupt)

        rig.view.pasteText(String(decoding: body, as: UTF8.self))
        rig.session.send(Data(typed))
        rig.session.sendImmediate(Data(interrupt))
        let delivery = awaitDelivery(rig, expectedCount: expected.count)

        assertDelivered(delivery, expected: expected, label: "oversized paste then typed input")
        XCTAssertEqual(
            hex([UInt8](delivery.bytes.suffix(5))), hex(typed + interrupt),
            "input typed after the paste must arrive, in order, right behind the last pasted byte; "
            + "tail was \(hex([UInt8](delivery.bytes.suffix(5))))"
        )
    }
}
