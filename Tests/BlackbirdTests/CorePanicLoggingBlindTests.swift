import XCTest
import OSLog
@testable import Blackbird
import BBCore

/// Blind-authored regression test for **ERR-1: the core-panic dialog cites a
/// nonexistent `"core"` unified-log category; the Fatal is never logged, and
/// the panic location plus every Rust breadcrumb go only to stderr**.
///
/// Written from the bug report / contract WITHOUT reading the bodies of
/// `guard_with_term`, `TerminalSession`'s fatal path, `BBTerm.dispatch` or
/// `MainWindowController.presentCoreFailure`. Only declarations, doc
/// comments, the C header, CHANGELOG / test docs and sibling tests
/// (`CoreFailureKeepOpenBlindTests`, `LatencyHarnessTests`,
/// `FeedYieldBlindTests`, `core/tests/poisoned_terminal_blind.rs`,
/// `core/tests/osc8_link_cap_recovery.rs`) were consulted.
///
/// ## The bug being pinned
///
/// When the Rust core panics inside a guarded FFI entry, the core delivers a
/// `.fatal(message)` event; the session tears itself down and the window
/// shows "The terminal engine stopped" whose body says "The details are in
/// the unified log (category \"core\")". Nothing in the app writes to a
/// category named `core`, so that pointer is a dead end. Worse, the panic's
/// `file:line` (the only thing that makes a field panic triageable) and every
/// Rust-side `eprintln!` breadcrumb (for example the one-shot "OSC 8 intern
/// budget exhausted, hyperlinks stopped resolving" note the CHANGELOG
/// advertises) are written to fd 2, which is `/dev/null` for an app started
/// from Finder / Dock / LaunchServices.
///
/// ## Contract (macOS convention)
///
/// A diagnostic a dialog promises to be "in the unified log" must be in the
/// unified log, readable by `log show` / Console.app, under the subsystem
/// the rest of the app uses (`dev.conjfrnk.blackbird`). So, in this very
/// process, after the event that triggers it:
///
///   1. a caught core panic leaves an entry in category `core` carrying the
///      panic message that the dialog shows,
///   2. a caught core panic leaves an entry in category `core` carrying the
///      Rust source location (`<file>.rs:<line>`),
///   3. a Rust-side breadcrumb (OSC 8 intern budget exhaustion) leaves an
///      entry in category `core` that names the condition.
///
/// The test does not care which layer (Rust callback sink, `BBTerm`,
/// `TerminalSession`) does the logging, only that the entry exists.
///
/// ## How the real production sequence is reproduced
///
///   - A real, caught Rust panic: `bb_term_input` with `len > isize::MAX`
///     panics on its length check before touching the pointer (audit L-11;
///     `core/tests/poisoned_terminal_blind.rs` provokes it the same way). The
///     test-only panic symbol is not linked into the app, and this route needs
///     no test hook. The raw `BBTerm` handle is recovered from the wrapper by
///     reflection on its stored property `handle` (declared
///     `private var handle: OpaquePointer?` in BBTerm.swift), and the call is
///     made on the session's `coreQueue`, exactly where the PTY read path calls
///     it. The Fatal then travels the full production chain: Rust guard ->
///     C callback -> `BBTerm` trampoline -> `TerminalSession` handler.
///   - The session is `TerminalSession.makeHeadlessForTests()`: a real
///     `BBTerm`, no PTY, no shell, no window.
///   - The OSC 8 breadcrumb is provoked the way `osc8_link_cap_recovery.rs`
///     does it: 280 distinct 4 KiB URIs (1.1 MiB, past the 1 MiB budget)
///     followed by a snapshot, which is when URIs are interned.
///
/// ## Non-vacuity
///
///   - Before each test the unified log is proven readable in this host with
///     a control entry in a sibling category written through `os.Logger`
///     (`XCTSkip` if the host cannot read its own log: that is an environment
///     limit, not a pass).
///   - The panic tests assert the Fatal really reached the session
///     (`coreFailureMessage` published) and print it.
///   - The OSC 8 test asserts the budget really ran out (the last link cell
///     resolves to link id 0, the first one does not).
///   - Every failure message prints the entries that WERE found in category
///     `core`, so a "found a wrong-looking entry" case is visible.
///
/// ## Safety / cost budget (CLAUDE.md test rules)
///
///   - No window, no PTY, no shell, no MainWindowController. One headless
///     session (2x2 grid) per test; the OSC 8 test resizes it to 30x12 = 360
///     cells (a few KB).
///   - The OSC 8 test builds one ~1.2 MB byte array (280 x ~4.1 KB), parses it
///     once and snapshots once: ~3 MB peak, a few ms of parsing.
///   - Log polling is bounded (3 s per wait, 50 ms sleeps), typically < 0.5 s.
final class CorePanicLoggingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Unified-log reader

    private static let subsystem = "dev.conjfrnk.blackbird"
    private static let coreCategory = "core"
    private static let controlCategory = "core-blind-control"

    private struct LogLine {
        let subsystem: String
        let category: String
        let message: String
    }

    /// Entries this process wrote to `category` at or after `start`, or nil if
    /// the store cannot be opened in this host.
    private func readLines(category: String, since start: Date) -> [LogLine]? {
        // `.currentProcessIdentifier` is the test-safe scope: only entries this
        // process logged, no entitlement needed (same as LatencyHarnessTests).
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return nil
        }
        let position = store.position(date: start)
        let predicate = NSPredicate(format: "category == %@", category)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return nil
        }
        var lines: [LogLine] = []
        for entry in entries {
            if let log = entry as? OSLogEntryLog {
                lines.append(LogLine(subsystem: log.subsystem,
                                     category: log.category,
                                     message: log.composedMessage))
            }
        }
        return lines
    }

    /// Poll `category` until some line satisfies `match` or `timeout` passes.
    /// Returns the matching line (if any) and every line seen in `category`.
    private func waitForLine(
        category: String,
        since start: Date,
        timeout: TimeInterval = 3.0,
        where match: (LogLine) -> Bool
    ) -> (match: LogLine?, all: [LogLine]) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var seen: [LogLine] = []
        repeat {
            seen = readLines(category: category, since: start) ?? []
            if let hit = seen.first(where: match) { return (hit, seen) }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return (nil, seen)
    }

    /// Proves the host can read back what `os.Logger` writes, so a missing
    /// `core` entry means "never logged", not "log unreadable here".
    private func requireReadableLogStore() throws {
        let token = "core-panic-blind-control-\(UUID().uuidString)"
        let start = Date()
        let logger = Logger(subsystem: Self.subsystem, category: Self.controlCategory)
        logger.notice("\(token, privacy: .public)")
        let result = waitForLine(category: Self.controlCategory, since: start) {
            $0.message.contains(token)
        }
        if result.match == nil {
            throw XCTSkip("OSLogStore cannot read this process's own os.Logger output in this test host; cannot verify logging")
        }
    }

    private func describe(_ lines: [LogLine]) -> String {
        if lines.isEmpty { return "(no entries at all in category \"\(Self.coreCategory)\")" }
        return lines.prefix(8)
            .map { "[\($0.subsystem)/\($0.category)] \($0.message)" }
            .joined(separator: " | ")
    }

    // MARK: - Panic provocation

    /// Cause a REAL, caught Rust panic on `session`'s core and wait until the
    /// resulting Fatal has reached the session. Returns the message the
    /// session published (the text the dialog would show).
    private func provokeCaughtCorePanic(on session: TerminalSession) throws -> String {
        var rawHandle: OpaquePointer?
        for child in Mirror(reflecting: session.bbterm).children where child.label == "handle" {
            rawHandle = child.value as? OpaquePointer
        }
        let handle: OpaquePointer = try XCTUnwrap(
            rawHandle,
            "reflection lookup of BBTerm.handle failed, so a real core panic cannot be provoked"
        )

        XCTAssertEqual(session.coreFailureMessage, nil,
                       "precondition: the core must not have failed before the panic is provoked")

        // len > isize::MAX is rejected by a length check that panics before the
        // pointer is read; the 4 dummy bytes are never dereferenced.
        let badLen: UInt = UInt(Int.max) + 1
        let dummy: [UInt8] = [0, 0, 0, 0]
        session.coreQueue.sync { () -> Void in
            dummy.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> Void in
                bb_term_input(handle, buf.baseAddress, badLen)
            }
        }

        let deadline = Date(timeIntervalSinceNow: 3.0)
        while session.coreFailureMessage == nil && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let message: String = try XCTUnwrap(
            session.coreFailureMessage,
            "the caught panic did not surface as a core failure on the session within 3 s; "
                + "the oversized-length route no longer provokes a Fatal"
        )
        XCTAssertEqual(message.isEmpty, false,
                       "precondition: the Fatal message must not be empty")
        return message
    }

    /// The first non-empty line of the Fatal message, capped, used as the
    /// needle for "the log carries the message the dialog shows".
    private func needle(from message: String) -> String {
        var firstLine: String = message
        if let head = message.split(separator: "\n", omittingEmptySubsequences: true).first {
            firstLine = String(head)
        }
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    // MARK: - Tests

    /// The dialog says "details are in the unified log (category \"core\")".
    /// After a caught panic that category must hold the panic message.
    func test_caughtCorePanic_messageIsLoggedUnderCoreCategory() throws {
        try requireReadableLogStore()
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let start = Date()
        let fatalMessage = try provokeCaughtCorePanic(on: session)
        let key = needle(from: fatalMessage)

        let result = waitForLine(category: Self.coreCategory, since: start) {
            $0.message.contains(key)
        }
        XCTAssertEqual(
            result.match?.subsystem, Self.subsystem,
            "a caught core panic must log its message under subsystem \(Self.subsystem), "
                + "category \"\(Self.coreCategory)\" (the category the dialog tells the user to look in). "
                + "Fatal message shown to the user: \"\(fatalMessage)\". "
                + "Entries found: \(describe(result.all))"
        )
    }

    /// The panic location is the single most useful triage fact and used to
    /// reach only fd 2. It must be in the unified log now.
    func test_caughtCorePanic_sourceLocationIsLoggedUnderCoreCategory() throws {
        try requireReadableLogStore()
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let start = Date()
        let fatalMessage = try provokeCaughtCorePanic(on: session)

        // Rust's Location Display is `<file>.rs:<line>:<col>`; accept any
        // path form that ends in `.rs:<digits>`.
        let locationPattern = "[A-Za-z0-9_./\\-]+\\.rs:[0-9]+"
        let result = waitForLine(category: Self.coreCategory, since: start) {
            $0.message.range(of: locationPattern, options: .regularExpression) != nil
        }
        var matched = ""
        if let line = result.match,
           let range = line.message.range(of: locationPattern, options: .regularExpression) {
            matched = String(line.message[range])
        }
        XCTAssertEqual(
            matched.isEmpty, false,
            "a caught core panic must log its Rust source location (`<file>.rs:<line>`) under category "
                + "\"\(Self.coreCategory)\"; without it a field panic cannot be triaged. "
                + "Fatal message shown to the user: \"\(fatalMessage)\". "
                + "Entries found: \(describe(result.all))"
        )
    }

    /// A Rust-side breadcrumb (CHANGELOG: "one-shot log breadcrumb when the
    /// 1 MiB OSC 8 intern budget is exhausted and new hyperlinks silently stop
    /// resolving") must reach the unified log, not just stderr.
    func test_osc8InternBudgetExhaustion_breadcrumbIsLoggedUnderCoreCategory() throws {
        try requireReadableLogStore()
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let columns = 30
        let linkCount = 280
        let start = Date()
        var firstLinkID: UInt32 = 0
        var lastLinkID: UInt32 = UInt32.max

        session.coreQueue.sync { () -> Void in
            _ = session.bbterm.resize(to: .init(cols: UInt16(columns), rows: 12))
            // Distinct 4096-byte URIs: 256 fill the 1 MiB budget exactly, the
            // rest are dropped to link id 0. Each is `OSC 8 ; ; URI ST X OSC 8 ; ; ST`,
            // so link i owns grid cell i (30 columns, no scrolling for 280 cells).
            var bytes: [UInt8] = []
            bytes.reserveCapacity(linkCount * 4112)
            for index in 0..<linkCount {
                let prefix = String(format: "https://x.test/%06d/", index)
                let uri = prefix + String(repeating: "a", count: 4096 - prefix.count)
                bytes.append(contentsOf: Array("\u{1B}]8;;".utf8))
                bytes.append(contentsOf: Array(uri.utf8))
                bytes.append(contentsOf: Array("\u{1B}\\X\u{1B}]8;;\u{1B}\\".utf8))
            }
            session.bbterm.input(bytes)

            // URIs are interned at snapshot time.
            if let snap = session.bbterm.snapshot() {
                firstLinkID = snap.linkID(row: 0, col: 0)
                let last = linkCount - 1
                lastLinkID = snap.linkID(row: last / columns, col: last % columns)
            }
        }

        XCTAssertNotEqual(firstLinkID, 0,
                          "precondition: the first OSC 8 link must resolve (got link id \(firstLinkID))")
        XCTAssertEqual(lastLinkID, 0,
                       "precondition: the 280th distinct 4 KiB URI must have been dropped by the 1 MiB "
                           + "intern budget (got link id \(lastLinkID)); otherwise the breadcrumb was never due")

        let needles = ["osc 8", "osc8", "intern", "link"]
        let result = waitForLine(category: Self.coreCategory, since: start) { line in
            let lowered = line.message.lowercased()
            return needles.contains { lowered.contains($0) }
        }
        XCTAssertEqual(
            result.match?.subsystem, Self.subsystem,
            "exhausting the OSC 8 intern budget must leave a breadcrumb under subsystem \(Self.subsystem), "
                + "category \"\(Self.coreCategory)\" naming the condition (one of \(needles)); "
                + "today it goes only to stderr, which is /dev/null for a Finder launch. "
                + "Entries found: \(describe(result.all))"
        )
    }
}
