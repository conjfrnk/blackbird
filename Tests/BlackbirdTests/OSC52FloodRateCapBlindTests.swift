import XCTest
import AppKit
import QuartzCore
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug CL-1: OSC 52 clipboard-write events have
/// no rate cap, so a flood of them (opt-in required) freezes the main thread
/// and grows memory without bound.
///
/// Background (observable contract, from the user-facing behaviour):
///   - Settings, "Allow programs to write the clipboard (OSC 52)" is OFF by
///     default. A user turns it on for the ssh / tmux clipboard use case,
///     where the program on the other end is not necessarily trusted.
///   - With it on, ONE `ESC ] 52 ; c ; <base64> BEL` puts that text on the
///     macOS clipboard. That must keep working.
///   - A hostile or runaway program can emit tens of thousands of such
///     sequences back to back (`yes $'\e]52;c;YQ==\a'`, or `cat` of a file
///     full of them). Today every one of them becomes its own main-thread
///     work item that rewrites the system pasteboard: 2,000 sequences stall
///     the UI for about 0.3 s, 10,000 for 1.4 s, 30,000 for about 5 s, and an
///     endless stream freezes the app for good while memory climbs.
///   - A terminal must not let output it merely *displays* monopolise the UI
///     thread or hammer the system clipboard. Just as other program-driven
///     events are rate capped, the number of clipboard rewrites a flood can
///     cause has to be bounded far below the number of sequences sent, and
///     the main thread has to stay responsive while the flood is processed.
///
/// What is asserted (all through the public behaviour of a headless
/// `TerminalSession`, so it holds whether the cap lives in the Rust event
/// callback or in the Swift delivery path):
///   1. Rig liveness: with the pref on, one OSC 52 store reaches
///      `NSPasteboard.general` (so a flood result of "0 writes" can never be
///      a vacuous pass from a dead rig).
///   2. A flood of 30,000 DISTINCT stores (distinct so that "skip a write
///      whose text equals the previous write" is not a way out) causes at
///      most 5,000 clipboard rewrites (the exact cap is the fix's choice; an
///      uncapped implementation performs 30,000), and the longest main
///      thread stall while it is processed stays under one second.
///   3. A cap must not disable the feature: after a (smaller) flood has been
///      absorbed, a normal single store lands on the clipboard again.
///
/// Pre-flight cost (project rule). The flood is 30,000 sequences of at most
/// 17 bytes, about 0.5 MB of `Data`, fed as ~16 chunks of 32 KiB (the PTY
/// read-coalescing size) into ONE headless 2x2 `BBTerm` session: no PTY, no
/// window, no `MainWindowController`, never two sessions alive at once.
/// Worst case (the unfixed code) queues 30,000 tiny closures on the main
/// queue and performs 30,000 pasteboard writes, about 5 s of wall time and a
/// few MB of transient memory. With the fix it is milliseconds. Every wait
/// is bounded.
///
/// The tests share the system pasteboard and the `bb.osc52Enabled`
/// preference with the host, so each test snapshots and restores both.
final class OSC52FloodRateCapBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Tunables

    /// Sequences in the main flood. Same order as the report's bounded form
    /// (`yes ... | head -n 30000`).
    private static let floodCount = 30_000
    /// Sequences in the flood used by the recovery test (small, to keep the
    /// unfixed-code cost of that test under a second).
    private static let smallFloodCount = 5_000
    /// Upper bound on clipboard rewrites a 30,000-sequence flood may cause.
    private static let maxClipboardWritesForFlood = 5_000
    /// Longest tolerated main-thread stall while a flood is processed.
    private static let maxMainThreadStall: TimeInterval = 1.0
    /// PTY read-coalescing size used by production (`PTY.readBufferSize`).
    private static let chunkBytes = 32 * 1024

    // MARK: - Fixture hygiene (pasteboard + preference)

    private var savedItems: [NSPasteboardItem] = []
    private var savedOSC52Enabled = false

    override func setUp() {
        super.setUp()
        let pb = NSPasteboard.general
        savedItems = (pb.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        savedOSC52Enabled = Preferences.shared.osc52Enabled
        // The opt-in the bug requires. Set BEFORE any session is created so
        // the session pushes it to the core at wire time.
        Preferences.shared.osc52Enabled = true
    }

    override func tearDown() {
        Preferences.shared.osc52Enabled = savedOSC52Enabled
        let pb = NSPasteboard.general
        pb.clearContents()
        if !savedItems.isEmpty {
            pb.writeObjects(savedItems)
        }
        savedItems = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// `ESC ] 52 ; c ; base64(text) BEL`
    private static func store(_ text: String) -> Data {
        let b64 = Data(text.utf8).base64EncodedString()
        return Data("\u{1B}]52;c;\(b64)\u{07}".utf8)
    }

    /// `count` DISTINCT stores (`n0`, `n1`, ...) each followed by a newline
    /// (as `yes` would emit), split into ~32 KiB chunks.
    private static func floodChunks(count: Int) -> [Data] {
        var chunks: [Data] = []
        var current = Data()
        current.reserveCapacity(chunkBytes + 64)
        for i in 0..<count {
            current.append(store("n\(i)"))
            current.append(0x0A)
            if current.count >= chunkBytes {
                chunks.append(current)
                current = Data()
                current.reserveCapacity(chunkBytes + 64)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func makeOptedInSession() -> TerminalSession {
        let session = TerminalSession.makeHeadlessForTests()
        // Flush the coreQueue.async that applies the preference to the core,
        // so the first fed byte is parsed with OSC 52 writes enabled.
        session.waitForFeedsForTests()
        return session
    }

    /// Spin the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func spinMain(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    /// Feed one store and spin main until the clipboard shows its text.
    @discardableResult
    private func landStore(
        _ text: String, in session: TerminalSession, timeout: TimeInterval = 5
    ) -> Bool {
        session.feedBytesForTests(Self.store(text))
        return spinMain(timeout: timeout) {
            NSPasteboard.general.string(forType: .string) == text
        }
    }

    /// Spin main until `NSPasteboard.general.changeCount` has not moved for
    /// `quiet` seconds (or `timeout` passes). Returns the settled count.
    private func settledChangeCount(quiet: TimeInterval = 0.2, timeout: TimeInterval = 30) -> Int {
        let pb = NSPasteboard.general
        var last = pb.changeCount
        var lastMove = Date()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            let now = pb.changeCount
            if now != last {
                last = now
                lastMove = Date()
            } else if Date().timeIntervalSince(lastMove) >= quiet {
                break
            }
        }
        return last
    }

    /// Measures how long the main thread goes without servicing a 10 ms
    /// repeating timer. A main thread draining thousands of queued work
    /// items cannot service the timer, so the gap is the visible freeze.
    private final class MainStallMonitor {
        private(set) var maxGap: TimeInterval = 0
        private(set) var ticks = 0
        private var last = CACurrentMediaTime()
        private var timer: Timer?

        func start() {
            maxGap = 0
            ticks = 0
            last = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.maxGap = max(self.maxGap, now - self.last)
                self.last = now
                self.ticks += 1
            }
        }

        func stop() {
            // Account the stall that ended with the caller regaining control.
            maxGap = max(maxGap, CACurrentMediaTime() - last)
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - 1. Rig liveness

    func test_singleOSC52Store_reachesClipboard_whenOptedIn() {
        let pb = NSPasteboard.general
        let session = makeOptedInSession()
        defer { session.terminate() }

        let text = "bb-osc52-probe-\(UUID().uuidString)"
        let before = pb.changeCount
        landStore(text, in: session)

        XCTAssertEqual(
            pb.string(forType: .string), text,
            "with 'Allow programs to write the clipboard (OSC 52)' on, a single store must reach the system clipboard; the rig (or the feature) is dead"
        )
        XCTAssertGreaterThanOrEqual(
            pb.changeCount - before, 1,
            "a delivered OSC 52 store must advance NSPasteboard.changeCount at least once"
        )
    }

    // MARK: - 2. The flood is rate capped and does not freeze the UI

    func test_osc52Flood_isRateCapped_andDoesNotStallMainThread() {
        let pb = NSPasteboard.general
        let session = makeOptedInSession()
        defer { session.terminate() }

        // Precondition: one store lands, and calibrate how far changeCount
        // moves per delivered write (clearContents + set may bump it more
        // than once on some OS versions).
        let probe = "bb-osc52-calibrate-\(UUID().uuidString)"
        let beforeProbe = pb.changeCount
        XCTAssertTrue(landStore(probe, in: session),
                      "precondition: a single OSC 52 store must reach the clipboard before the flood is meaningful")
        let perWrite = max(1, settledChangeCount() - beforeProbe)

        // Precondition: the main-thread stall monitor actually ticks while
        // the test is waiting (otherwise a zero-tick run would report one
        // giant "stall" for a perfectly healthy fix).
        let monitor = MainStallMonitor()
        let baseline = expectation(description: "idle baseline")
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { baseline.fulfill() }
        wait(for: [baseline], timeout: 5)
        monitor.stop()
        XCTAssertGreaterThanOrEqual(
            monitor.ticks, 10,
            "precondition: the 10 ms stall monitor must tick ~30 times in 0.3 s of idle waiting; got \(monitor.ticks)"
        )

        // The flood, fed the way a PTY would (sequential 32 KiB chunks), on a
        // background thread so the main thread is free to be as responsive
        // (or unresponsive) as the implementation lets it be.
        let chunks = Self.floodChunks(count: Self.floodCount)
        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(totalBytes, 1_000_000,
                          "pre-flight: flood payload must stay under 1 MB; got \(totalBytes)")

        let beforeFlood = pb.changeCount
        let drained = expectation(description: "flood fed and every queued main-thread hop run")
        monitor.start()
        let startedAt = CACurrentMediaTime()
        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            for chunk in chunks { s.feedBytesForTests(chunk) }
            s.waitForFeedsForTests()
            // Enqueued after every event hop the feed produced, so it runs
            // only once main has worked through the whole backlog.
            DispatchQueue.main.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 120)
        monitor.stop()
        let elapsed = CACurrentMediaTime() - startedAt

        // Let any trailing-edge flush an implementation might schedule land
        // before counting (only ever adds writes, so it cannot mask the bug).
        let afterFlood = settledChangeCount()
        let delta = afterFlood - beforeFlood
        let writes = delta / perWrite

        XCTAssertLessThanOrEqual(
            writes, Self.maxClipboardWritesForFlood,
            "\(Self.floodCount) distinct OSC 52 stores caused \(writes) system-clipboard rewrites (changeCount advanced \(delta), \(perWrite) per write); a rate cap must hold this to at most \(Self.maxClipboardWritesForFlood)"
        )
        XCTAssertLessThanOrEqual(
            monitor.maxGap, Self.maxMainThreadStall,
            "main thread was unresponsive for \(String(format: "%.2f", monitor.maxGap)) s (flood took \(String(format: "%.2f", elapsed)) s end to end) while \(Self.floodCount) OSC 52 stores were processed; must stay under \(Self.maxMainThreadStall) s"
        )
    }

    // MARK: - 3. A cap must not switch the feature off

    func test_osc52_stillWorksAfterFloodHasBeenAbsorbed() {
        let session = makeOptedInSession()
        defer { session.terminate() }

        XCTAssertTrue(landStore("bb-osc52-before-flood", in: session),
                      "precondition: a single OSC 52 store must reach the clipboard before the flood")

        let chunks = Self.floodChunks(count: Self.smallFloodCount)
        let drained = expectation(description: "small flood fed and drained")
        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            for chunk in chunks { s.feedBytesForTests(chunk) }
            s.waitForFeedsForTests()
            DispatchQueue.main.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 120)
        _ = settledChangeCount()

        // A rate cap throttles; it must not latch off. Offer a normal store
        // every 250 ms for up to 10 s; some one of them has to be honoured.
        let recovered = "bb-osc52-after-flood-\(UUID().uuidString)"
        var landed = false
        let deadline = Date(timeIntervalSinceNow: 10)
        var offers = 0
        while !landed && Date() < deadline {
            offers += 1
            landed = landStore(recovered, in: session, timeout: 0.25)
        }
        XCTAssertTrue(
            landed,
            "after a \(Self.smallFloodCount)-store flood, a normal OSC 52 store was still not honoured after \(offers) offers over 10 s; the cap must throttle, not permanently disable the feature. Clipboard holds: \(NSPasteboard.general.string(forType: .string) ?? "<nil>")"
        )
    }
}
