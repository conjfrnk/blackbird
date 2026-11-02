import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug CL-1b: a rate-limited (coalesced) OSC 52
/// clipboard write is only delivered when the NEXT PTY chunk arrives, so it
/// can land on the clipboard arbitrarily late and overwrite a newer user copy.
///
/// Background (observable contract, from the user-facing behaviour):
///   - Settings, "Allow programs to write the clipboard (OSC 52)" is opt-in.
///     With it on, `ESC ] 52 ; c ; <base64> BEL` puts that text on the macOS
///     clipboard (the ssh / tmux "copy from the remote" use case).
///   - Clipboard writes a program can cause are rate capped (32 per second)
///     so a flood cannot freeze the UI. Stores that arrive faster than the
///     cap are coalesced: only the LATEST value is kept.
///   - A coalesced value is still the program's most recent copy request. A
///     person who ran `tmux`-yank, a vim yank, or a copy script that emitted
///     a quick burst of stores expects the LAST one to end up on the
///     clipboard, just as it would without the cap. The program then goes
///     quiet (it is waiting for the user at a prompt).
///   - So the held-back latest value has to be delivered promptly (within
///     about a second of the burst) WITHOUT needing any further PTY output,
///     and it must never be delivered "later": once the user has had time to
///     do something else (copy something in another app, for example), a
///     stale held-back value must not appear out of nowhere when the shell
///     eventually prints a prompt redraw and silently replace what the user
///     copied. At the latest it is delivered or discarded within a bounded
///     interval after the burst.
///
/// What is asserted (all through the observable behaviour of a headless
/// `TerminalSession` and `NSPasteboard.general`, so it holds whether the
/// trailing flush lives in the Rust event callback, in the Swift delivery
/// path, or in a timer in between):
///   1. Rig liveness: with the pref on, one OSC 52 store reaches the
///      clipboard (so no later "did not land" result can be a dead rig).
///   2. A burst of distinct stores, far beyond the cap, fed in one chunk and
///      followed by NO further output, ends with the burst's LAST value on
///      the clipboard within 2 s.
///   3. The same, with the burst split over several PTY-sized chunks.
///   4. A user copy made several seconds after the burst is not overwritten
///      by anything: neither by a late timer while the terminal is silent,
///      nor by the next (benign, OSC-52-free) chunk of output such as a
///      prompt redraw.
///
/// Pre-flight cost (project rule). The bursts are at most 2,500 sequences of
/// at most 17 bytes (about 45 KB of `Data`) fed into ONE headless 2x2
/// `BBTerm` session: no PTY, no window, no `MainWindowController`, never two
/// sessions alive at once. Every wait is bounded; the slowest test waits
/// roughly 8 s of wall time, spent in `RunLoop` spins that do no work.
///
/// The tests share the system pasteboard and the `bb.osc52Enabled`
/// preference with the host, so each test snapshots and restores both.
final class OSC52CoalescedTrailingFlushBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Tunables

    /// Sequences in the single-chunk burst. Far beyond 32/s, small enough
    /// (600 x ~17 B = ~10 KB) to be one PTY read.
    private static let singleChunkBurstCount = 600
    /// Sequences in the multi-chunk burst (about 2,500 x ~17 B = ~45 KB,
    /// split into 16 KiB chunks).
    private static let multiChunkBurstCount = 2_500
    private static let multiChunkBytes = 16 * 1024
    /// "Within about a second" from the contract; 2 s leaves slack for a
    /// loaded CI host without letting a deliver-on-next-output design pass.
    private static let promptDeliveryDeadline: TimeInterval = 2.0
    /// How long after the burst the user is assumed to have "done something
    /// else". Well beyond the prompt-delivery deadline.
    private static let userActionDelay: TimeInterval = 3.0

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

    /// `count` DISTINCT stores (`b0`, `b1`, ...) followed by a final store of
    /// `finalText`, as one contiguous byte run.
    private static func burstBytes(count: Int, finalText: String) -> Data {
        var data = Data()
        data.reserveCapacity(count * 20 + 128)
        for i in 0..<count {
            data.append(store("b\(i)"))
        }
        data.append(store(finalText))
        return data
    }

    /// Split `data` into pieces of at most `size` bytes. A piece boundary may
    /// fall inside an escape sequence, exactly as a real PTY read can.
    private static func split(_ data: Data, size: Int) -> [Data] {
        var pieces: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            pieces.append(data.subdata(in: offset..<end))
            offset = end
        }
        return pieces
    }

    /// What a shell prints when it redraws its prompt: no OSC 52 in it.
    private static let promptRedraw = Data("\r\nuser@host ~ % ".utf8)

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

    /// Spin the main run loop for exactly `duration` seconds (events, timers
    /// and main-queue hops all get to run).
    private func spinMain(for duration: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Feed one store and spin main until the clipboard shows its text.
    @discardableResult
    private func landStore(
        _ text: String, in session: TerminalSession, timeout: TimeInterval = 5
    ) -> Bool {
        session.feedBytesForTests(Self.store(text))
        return spinMain(timeout: timeout) { () -> Bool in
            NSPasteboard.general.string(forType: .string) == text
        }
    }

    /// Land a precondition store, then let the rate window and any trailing
    /// work of that store go quiet, so the burst that follows starts from a
    /// settled clipboard whose content is known.
    private func landPreconditionStore(in session: TerminalSession) {
        let text = "bb-osc52-precondition-\(UUID().uuidString)"
        XCTAssertTrue(
            landStore(text, in: session),
            "precondition: a single OSC 52 store must reach the clipboard before the burst is meaningful (clipboard holds: \(clipboardText() ?? "<nil>"))"
        )
        spinMain(for: 0.3)
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
            clipboardText(), text,
            "with 'Allow programs to write the clipboard (OSC 52)' on, a single store must reach the system clipboard; the rig (or the feature) is dead"
        )
        XCTAssertGreaterThanOrEqual(
            pb.changeCount - before, 1,
            "a delivered OSC 52 store must advance NSPasteboard.changeCount at least once"
        )
    }

    // MARK: - 2. Latest coalesced value lands promptly, no further output

    func test_burstBeyondRateCap_latestValueLandsWithinDeadline_withoutFurtherOutput() {
        let session = makeOptedInSession()
        defer { session.terminate() }
        landPreconditionStore(in: session)

        let finalText = "bb-osc52-burst-final-\(UUID().uuidString)"
        let burst = Self.burstBytes(count: Self.singleChunkBurstCount, finalText: finalText)
        XCTAssertLessThan(burst.count, 100_000,
                          "pre-flight: burst payload must stay small; got \(burst.count) bytes")

        // One PTY chunk, then NOTHING: the program goes quiet.
        session.feedBytesForTests(burst)
        session.waitForFeedsForTests()
        let fedAt = Date()

        let landed = spinMain(timeout: Self.promptDeliveryDeadline) { () -> Bool in
            NSPasteboard.general.string(forType: .string) == finalText
        }
        let elapsed = Date().timeIntervalSince(fedAt)

        XCTAssertTrue(
            landed,
            "after a burst of \(Self.singleChunkBurstCount + 1) OSC 52 stores (far beyond the 32/s cap) and no further output, the burst's LATEST value must be on the clipboard within \(Self.promptDeliveryDeadline) s; after \(String(format: "%.2f", elapsed)) s the clipboard holds \(clipboardText() ?? "<nil>") instead of \(finalText)"
        )
    }

    // MARK: - 3. Same, burst split across several PTY-sized chunks

    func test_multiChunkBurst_latestValueLandsWithinDeadline_withoutFurtherOutput() {
        let session = makeOptedInSession()
        defer { session.terminate() }
        landPreconditionStore(in: session)

        let finalText = "bb-osc52-multichunk-final-\(UUID().uuidString)"
        let burst = Self.burstBytes(count: Self.multiChunkBurstCount, finalText: finalText)
        let chunks = Self.split(burst, size: Self.multiChunkBytes)
        XCTAssertLessThan(burst.count, 100_000,
                          "pre-flight: burst payload must stay small; got \(burst.count) bytes")
        XCTAssertGreaterThanOrEqual(
            chunks.count, 2,
            "precondition: the burst must span at least 2 PTY chunks to exercise the multi-chunk path; got \(chunks.count) (burst \(burst.count) bytes)"
        )

        for chunk in chunks { session.feedBytesForTests(chunk) }
        session.waitForFeedsForTests()
        let fedAt = Date()

        let landed = spinMain(timeout: Self.promptDeliveryDeadline) { () -> Bool in
            NSPasteboard.general.string(forType: .string) == finalText
        }
        let elapsed = Date().timeIntervalSince(fedAt)

        XCTAssertTrue(
            landed,
            "after a \(chunks.count)-chunk burst of \(Self.multiChunkBurstCount + 1) OSC 52 stores and no further output, the burst's LATEST value must be on the clipboard within \(Self.promptDeliveryDeadline) s; after \(String(format: "%.2f", elapsed)) s the clipboard holds \(clipboardText() ?? "<nil>") instead of \(finalText)"
        )
    }

    // MARK: - 4. A held-back write must never clobber a later user copy

    func test_userCopyAfterBurst_isNotOverwrittenByLateOrNextOutputFlush() {
        let pb = NSPasteboard.general
        let session = makeOptedInSession()
        defer { session.terminate() }
        landPreconditionStore(in: session)

        let finalText = "bb-osc52-stale-final-\(UUID().uuidString)"
        let burst = Self.burstBytes(count: Self.singleChunkBurstCount, finalText: finalText)

        // Burst, then the program goes quiet while the user does other things.
        session.feedBytesForTests(burst)
        session.waitForFeedsForTests()
        spinMain(for: Self.userActionDelay)

        // The user copies something else (Cmd-C in another app).
        let userCopy = "user-copied-elsewhere-\(UUID().uuidString)"
        pb.clearContents()
        pb.setString(userCopy, forType: .string)
        let changeCountAfterUserCopy = pb.changeCount
        XCTAssertEqual(
            clipboardText(), userCopy,
            "precondition: the simulated user copy must be readable straight after it is made"
        )

        // Phase A: the terminal stays silent. Nothing (a late timer, say)
        // may touch the clipboard.
        spinMain(for: 2.0)
        XCTAssertEqual(
            clipboardText(), userCopy,
            "the user's copy was replaced by \(clipboardText() ?? "<nil>") although the terminal produced no output: a stale OSC 52 value from a burst \(Self.userActionDelay + 2.0) s earlier was delivered far too late (burst's latest was \(finalText))"
        )
        XCTAssertEqual(
            pb.changeCount, changeCountAfterUserCopy,
            "NSPasteboard.changeCount moved from \(changeCountAfterUserCopy) to \(pb.changeCount) after the user's copy, with the terminal silent: something wrote to the clipboard"
        )

        // Phase B: the shell finally redraws its prompt. Ordinary output,
        // no OSC 52 in it, must not release a stale held-back clipboard write.
        session.feedBytesForTests(Self.promptRedraw)
        session.waitForFeedsForTests()
        spinMain(for: 1.5)

        XCTAssertEqual(
            clipboardText(), userCopy,
            "a prompt redraw (plain output, no OSC 52) arriving \(Self.userActionDelay + 2.0) s after an OSC 52 burst replaced the user's newer copy with \(clipboardText() ?? "<nil>"); a held-back write must be delivered promptly or discarded, never released by unrelated later output (burst's latest was \(finalText))"
        )
        XCTAssertEqual(
            pb.changeCount, changeCountAfterUserCopy,
            "NSPasteboard.changeCount moved from \(changeCountAfterUserCopy) to \(pb.changeCount) after the prompt redraw: a stale OSC 52 write hit the clipboard"
        )
    }
}
