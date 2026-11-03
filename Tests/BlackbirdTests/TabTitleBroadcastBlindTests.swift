import XCTest
import AppKit
@testable import Blackbird

/// Thread-safe counter for `title` reads on a probe window. AppKit may read a
/// window's title from internal paths, so the count is lock-protected rather
/// than relying on main-actor isolation.
private final class TitleReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A stand-in sibling tab that counts how often its `title` is read.
///
/// A tab's pill strip can only (re)build its pills, lay them out, size them or
/// diff them for VoiceOver by reading the title of EVERY tab in the group, so
/// every strip rebuild that happens anywhere in the group is visible here as
/// reads of this window's title. That makes the count a behaviour-level probe
/// for "was the pill strip refreshed because of that title event", without
/// reaching into how or where the refresh is triggered.
private final class TitleReadCountingWindow: NSWindow {
    let reads = TitleReadCounter()

    override var title: String {
        get {
            reads.bump()
            return super.title
        }
        set {
            super.title = newValue
        }
    }
}

/// Blind-authored regression tests for **CTL-1: a tab title event must not
/// rebuild pill strips when the title did not change.**
///
/// Written purely from the bug report and the macOS / terminal conventions,
/// WITHOUT reading the bodies of `TabGroupObserver`, `TitlebarTabBar`,
/// `MainWindowController` or `TerminalView` (CLAUDE.md "Author new behavior
/// tests blind"). Only declarations, doc comments, sibling tests used as
/// harness templates, and the NSWindow / NSAccessibility public surface were
/// consulted.
///
/// ## The bug being pinned
///
/// Every title event of one tab refreshes the pill strip of every tab in the
/// group (`.blackbirdTabTitleChanged` is documented as "fired whenever any
/// MainWindowController observes its own window's title change, so sibling tab
/// pills in the same group can redraw"). Each refresh is itself O(tabs), so a
/// single title event costs O(tabs^2) on the main thread: 20.7 ms end to end at
/// 30 tabs and 72.3 ms at 60, which saturates the UI when one tab re-sets its
/// title at 25 Hz. Programs do exactly that: shells and TUIs re-emit
/// OSC 0 / OSC 2 on every prompt and every status tick, very often with the
/// SAME string.
///
/// ## Contract
///
///   1. A title write that does not change the title is a no-op for the
///      group: nothing on any strip can look different, so no strip is rebuilt.
///      Re-sending the same OSC 2 string 20 times must cost no pill-strip work
///      at all, whether the writing tab is the group's visible tab or a
///      background tab. (Fix direction from the report: "no-op when the title
///      did not change".)
///   2. Control (must keep working): a title that really changes still reaches
///      the visible tab's pill, including right after a run of identical
///      writes, and when a previous title comes back. A fix that suppresses too
///      much (stale comparison, latched state) fails here, not in 1.
///
/// ## How "was a strip rebuilt" is observed
///
/// The stub sibling tabs are `NSWindow` subclasses that count reads of their
/// own `title`. A strip rebuild reads every tab's title (twice per
/// `refreshTabBar()` in this build), AppKit itself reads a window's title on a
/// CHANGED title (its Window-menu bookkeeping) but not on an identical one
/// (measured on a control group of stubs with no Blackbird controller in it),
/// and an idle runloop reads none. The rig asserts all three as preconditions:
///
///   - idle pumping adds zero reads (the probe is quiet);
///   - one direct `controller.refreshTabBar()` adds >= 1 read per sibling (the
///     probe sees strip rebuilds, so a zero below is not vacuous);
///   - the title events themselves took effect (`window.title` is the string
///     fed through the OSC path).
///
/// A sender with ONE sibling controller only ever refreshes its own strip, so
/// this rig measures the per-event floor. The real group multiplies that floor
/// by the number of controllers (the O(N^2) in the report), which the rule of
/// "at most one real MainWindowController per test process" keeps out of reach
/// here. The identical-title no-op is the part of the fix that is exact and
/// implementation-independent: after it, the reads below are exactly zero, no
/// matter which layer (the OSC writer, the title KVO, the observer) drops the
/// duplicate.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController`, built with
///     `makeForTesting(stubSession:)` (headless 2x2 session: no PTY, no shell),
///     plus seven stub `TitleReadCountingWindow` siblings merged headlessly with
///     `addTabbedWindow`. Title events are fed through
///     `TerminalSession.feedBytesForTests` (the real OSC parse and event hop).
///   - Nothing is ever shown, closed or ordered out. The controller and the
///     stubs are parked in statics for process lifetime (`TabMoverTests` /
///     `TabPillFramePushBlindTests` are the templates). Tab selection goes
///     through `NSWindowTabGroup.selectedWindow`. No `orderFront`, no
///     AppleScript / CGEvent / keystroke injection.
///   - Cost: 8 never-shown windows (~40 KB each) + one Metal-backed terminal
///     view (a few MB). Windows are 600 x 300 pt. Each test feeds ~25 short OSC
///     sequences (a few hundred bytes) and pumps the runloop for about 2 to
///     6 s in total (tab-selection changes and the first title write are
///     followed by a drain of at least 1 s), every wait bounded.
@MainActor
final class TabTitleBroadcastBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    private static let baseFrame = NSRect(x: 120, y: 120, width: 600, height: 300)
    /// Sibling stubs besides the real controller's tab (group size = this + 1).
    private static let siblingCount = 7
    /// Identical title writes per scenario ("several Hz" for a few seconds).
    private static let identicalWrites = 20

    // MARK: - The single parked rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let session: TerminalSession
        let siblings: [TitleReadCountingWindow]
        let group: NSWindowTabGroup
        let strip: TabStripView
    }

    private static var rigStorage: Rig?
    private static var rigAttempted = false
    private static var rigSkipReason = "rig was never built"

    /// Parked for process lifetime. NEVER closed / ordered out / shown.
    private static var parkedControllers: [MainWindowController] = []
    private static var parkedStubs: [TitleReadCountingWindow] = []
    private static var titleCounter = 0

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func makeSibling(index: Int, tabbingIdentifier: String) -> TitleReadCountingWindow {
        let w = TitleReadCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = "title-broadcast-sibling-\(index)"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        return w
    }

    /// Build (once) or reuse the rig. Skips when the host has no Metal device,
    /// refuses the headless tab merge, or does not lay the pill strip out.
    private func rig() throws -> Rig {
        if let r = Self.rigStorage { return r }
        if Self.rigAttempted { throw XCTSkip(Self.rigSkipReason) }
        Self.rigAttempted = true

        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let window = controller.window, let session = controller.session else {
            Self.rigSkipReason = "no Metal device (CI virtual display): makeForTesting returned nil"
            throw XCTSkip(Self.rigSkipReason)
        }
        // Deliberately retained forever: closing or deallocating a merged
        // window poisons a deferred CA transaction.
        Self.parkedControllers.append(controller)

        window.setFrame(Self.baseFrame, display: false)
        var siblings: [TitleReadCountingWindow] = []
        for i in 0 ..< Self.siblingCount {
            let s = makeSibling(index: i, tabbingIdentifier: window.tabbingIdentifier)
            siblings.append(s)
            Self.parkedStubs.append(s)
            window.addTabbedWindow(s, ordered: .above)
        }

        let expectedTabs = Self.siblingCount + 1
        guard let group = window.tabGroup, group.windows.count == expectedTabs else {
            Self.rigSkipReason = "xctest host refused the headless addTabbedWindow merge "
                + "(group windows: \(window.tabGroup?.windows.count ?? 0), expected \(expectedTabs))"
            throw XCTSkip(Self.rigSkipReason)
        }

        pump(0.3)
        group.selectedWindow = window
        pump(0.3)
        controller.refreshTabBar()
        pump(0.3)

        guard let strip = controller.titlebarTabBar?.view as? TabStripView else {
            Self.rigSkipReason = "controller has no TabStripView in titlebarTabBar"
            throw XCTSkip(Self.rigSkipReason)
        }
        guard strip.pillCountForTesting == expectedTabs else {
            Self.rigSkipReason = "pill strip not laid out in this headless host "
                + "(\(strip.pillCountForTesting) pills for \(expectedTabs) tabs)"
            throw XCTSkip(Self.rigSkipReason)
        }

        let r = Rig(controller: controller, window: window, session: session,
                    siblings: siblings, group: group, strip: strip)
        Self.rigStorage = r
        return r
    }

    // MARK: - Probe plumbing

    private func titleReads(_ rig: Rig) -> [Int] {
        var out: [Int] = []
        for s in rig.siblings { out.append(s.reads.value) }
        return out
    }

    private func readsDelta(_ now: [Int], since base: [Int]) -> [Int] {
        var out: [Int] = []
        for i in 0 ..< now.count { out.append(now[i] - base[i]) }
        return out
    }

    private func totalReads(_ rig: Rig) -> Int {
        var sum = 0
        for n in titleReads(rig) { sum += n }
        return sum
    }

    /// Spins the main runloop until no sibling title read has happened for
    /// `quietFor` seconds (deferred title hops, coalesced refreshes and
    /// AppKit's own bookkeeping have all landed), bounded by `timeout`.
    private func settle(_ rig: Rig, quietFor: TimeInterval = 0.25, timeout: TimeInterval = 3.0) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = totalReads(rig)
        var lastChange = Date()
        while Date() < deadline {
            pump(0.03)
            let now = totalReads(rig)
            if now != last {
                last = now
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= quietFor {
                return
            }
        }
    }

    /// Spins the main runloop until one FULL `window`-second stretch passes in
    /// which no sibling title was read, bounded by `timeout`. Returns whether
    /// such a quiet stretch was reached. Used after a tab SELECTION change,
    /// whose deferred follow-up work (AppKit tab-switch bookkeeping and the
    /// strip refreshes it triggers) lands in a burst well after the 0.25 s
    /// quiet gap `settle` stops at; the burst must be drained before a test
    /// starts counting, or it is mis-attributed to the title events under test.
    private func drainUntilQuiet(_ rig: Rig, window: TimeInterval = 1.0,
                                 timeout: TimeInterval = 8.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let base = totalReads(rig)
            pump(window)
            if totalReads(rig) == base { return true }
        }
        return false
    }

    /// Pumps until `window.title == expected` or `seconds` elapse; returns the
    /// title observed when the wait ended.
    @discardableResult
    private func waitForWindowTitle(_ expected: String, in rig: Rig,
                                    seconds: TimeInterval = 2.0) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && rig.window.title != expected {
            pump(0.01)
        }
        return rig.window.title
    }

    private func osc2(_ title: String) -> Data {
        Data("\u{1B}]2;\(title)\u{07}".utf8)
    }

    /// A title no earlier scenario used, so its first write is a real change.
    private func freshTitle(_ label: String) -> String {
        Self.titleCounter += 1
        return "bb-ctl1-\(label)-\(Self.titleCounter)"
    }

    /// The accessibility labels of the controller strip's pills ("Tab, <title>,
    /// selected" etc.) plus the trailing "New Tab" button.
    private func pillLabels(_ rig: Rig) -> [String] {
        var out: [String] = []
        let children: [Any] = rig.strip.accessibilityChildren() ?? []
        for child in children {
            if let element = child as? NSAccessibilityElement,
               let label = element.accessibilityLabel() {
                out.append(label)
            }
        }
        return out
    }

    // MARK: - Scenario preparation

    /// Puts the shared rig in a known, QUIET state with the controller's tab
    /// either selected (its strip is the visible one) or in the background
    /// (a sibling is selected), and proves the read probe is live and quiet.
    private func prepare(controllerIsSelected: Bool,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try rig()

        let want: NSWindow = controllerIsSelected ? rig.window : rig.siblings[0]
        let selectionChanges = rig.group.selectedWindow !== want
        rig.group.selectedWindow = want
        pump(0.1)
        rig.controller.refreshTabBar()
        settle(rig)

        XCTAssertTrue(rig.group.selectedWindow === want,
            "PRECONDITION: group selection should be '\(want.title)', got "
                + "'\(rig.group.selectedWindow?.title ?? "nil")'", file: file, line: line)

        // A selection switch (notably back TO the controller's tab) schedules
        // deferred title reads that arrive after `settle`'s short quiet gap.
        // Drain them, so the idle check below measures an idle rig and the
        // test's own baseline excludes the switch. A rig that never goes quiet
        // fails here, loudly, instead of being tolerated further down.
        if selectionChanges {
            let drained = drainUntilQuiet(rig)
            XCTAssertTrue(drained,
                "PRECONDITION: sibling title reads never went quiet (1.0 s windows, 8 s bound) "
                    + "after selecting '\(want.title)'; reads per sibling so far \(titleReads(rig))",
                file: file, line: line)
        }
        XCTAssertEqual(rig.group.windows.count, Self.siblingCount + 1,
            "PRECONDITION: the group must hold the controller's tab plus \(Self.siblingCount) siblings",
            file: file, line: line)

        // Probe is quiet: an idle runloop reads no sibling title.
        var base = titleReads(rig)
        pump(0.3)
        let idle = readsDelta(titleReads(rig), since: base)
        XCTAssertEqual(idle, [Int](repeating: 0, count: rig.siblings.count),
            "PRECONDITION: the title-read probe must be quiet while nothing happens; idle "
                + "reads per sibling were \(idle)", file: file, line: line)

        // Probe is live: a direct strip refresh reads every sibling's title,
        // so a zero further down cannot be a dead instrument.
        base = titleReads(rig)
        rig.controller.refreshTabBar()
        let direct = readsDelta(titleReads(rig), since: base)
        let weakest = direct.min() ?? 0
        XCTAssertGreaterThanOrEqual(weakest, 1,
            "PRECONDITION: a direct refreshTabBar() must read each sibling's title at least once "
                + "(the probe sees strip rebuilds); reads per sibling were \(direct)",
            file: file, line: line)
        settle(rig)
        return rig
    }

    // MARK: - 1. Identical title writes are a no-op

    /// Core scenario. The first write is a real change (the pill legitimately
    /// refreshes); the 20 identical writes that follow must not rebuild any
    /// strip in the group.
    private func assertIdenticalTitleWritesRebuildNothing(controllerIsSelected: Bool,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) throws {
        let rig = try prepare(controllerIsSelected: controllerIsSelected, file: file, line: line)
        let mode = controllerIsSelected ? "selected tab" : "background tab"
        let title = freshTitle(controllerIsSelected ? "sel" : "bg")

        // The first write changes the title: establishes it, rebuilds are fine.
        rig.session.feedBytesForTests(osc2(title))
        let landed = waitForWindowTitle(title, in: rig)
        XCTAssertEqual(landed, title,
            "PRECONDITION [\(mode)]: the OSC 2 title must reach the window title", file: file, line: line)
        // The first (changing) write may legitimately trigger deferred strip
        // work; drain it fully so it is not counted against the identical writes.
        let drained = drainUntilQuiet(rig)
        XCTAssertTrue(drained,
            "PRECONDITION [\(mode)]: sibling title reads never went quiet after the first, "
                + "changing title write; reads per sibling so far \(titleReads(rig))",
            file: file, line: line)

        let base = titleReads(rig)
        for _ in 0 ..< Self.identicalWrites {
            rig.session.feedBytesForTests(osc2(title))
            pump(0.01)
        }
        settle(rig)

        XCTAssertEqual(rig.window.title, title,
            "[\(mode)] re-sending the same title must leave the window title unchanged",
            file: file, line: line)

        let delta = readsDelta(titleReads(rig), since: base)
        let total = delta.reduce(0, +)
        let perEvent = Double(total) / Double(rig.siblings.count * Self.identicalWrites)
        XCTAssertEqual(delta, [Int](repeating: 0, count: rig.siblings.count),
            "[\(mode)] \(Self.identicalWrites) OSC 2 writes of the UNCHANGED title '\(title)' made "
                + "the pill strips re-read every sibling tab's title: reads per sibling \(delta) "
                + "(\(total) total, \(perEvent) per sibling per event; one full strip rebuild is 2 reads). "
                + "An identical title is a no-op for the group; with N tabs each of those events costs "
                + "N strip rebuilds of N pills (O(N^2) on the main thread).",
            file: file, line: line)
    }

    /// The visible tab re-sets its own title to the same string (the shell
    /// prompt / status-line case from the report).
    func test_identicalOscTitle_repeated_onSelectedTab_rebuildsNoPillStrip() throws {
        try assertIdenticalTitleWritesRebuildNothing(controllerIsSelected: true)
    }

    /// A background tab re-sets its title to the same string (a build log or a
    /// long-running job in a tab the user is not looking at).
    func test_identicalOscTitle_repeated_onBackgroundTab_rebuildsNoPillStrip() throws {
        try assertIdenticalTitleWritesRebuildNothing(controllerIsSelected: false)
    }

    // MARK: - 2. Control: real changes still show up

    /// Passes before and after the fix. A title that really changes reaches the
    /// visible tab's pill, also right after a run of identical writes and when
    /// an earlier title comes back (a fix with a stale or latched comparison
    /// would swallow these). Also proves the OSC feeding path of scenario 1
    /// produces real, visible title changes.
    func test_control_changedOscTitles_reachSelectedPill_afterIdenticalRepeats() throws {
        let rig = try prepare(controllerIsSelected: true)
        let a = freshTitle("ctl-a")
        let b = freshTitle("ctl-b")

        // a, a, a, b, b, b, a: every step ends with exactly the latest title
        // on the controller tab's pill and no stale copy of the previous one.
        var previous: String?
        let sequence: [String] = [a, a, a, b, b, b, a]
        for (step, title) in sequence.enumerated() {
            rig.session.feedBytesForTests(osc2(title))
            let landed = waitForWindowTitle(title, in: rig)
            XCTAssertEqual(landed, title,
                "step \(step): the OSC 2 title '\(title)' must become the window title")
            settle(rig)

            let labels = pillLabels(rig)
            var showing: [String] = []
            for label in labels where label.contains(title) { showing.append(label) }
            XCTAssertEqual(showing.count, 1,
                "step \(step): exactly one pill must show '\(title)'; pill labels were \(labels)")
            if let previous = previous, previous != title {
                var stale: [String] = []
                for label in labels where label.contains(previous) { stale.append(label) }
                XCTAssertEqual(stale, [],
                    "step \(step): the pill still shows the previous title '\(previous)' "
                        + "after the title changed to '\(title)'; pill labels were \(labels)")
            }
            previous = title
        }
    }
}
