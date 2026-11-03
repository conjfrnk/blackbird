import XCTest
import AppKit
import ApplicationServices
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for: VoiceOver cannot reach the terminal grid
/// while the find bar is open, and the terminal never tells VoiceOver that
/// its text changed.
///
/// Spec (observable behaviour, independent of how the fix is built):
///
///  1. Reachability. The terminal grid is the thing a VoiceOver user reads;
///     opening the find bar (Cmd-F, Cmd-E "Use Selection for Find", or the
///     case / regex toggles, which open the bar when it is closed) must not
///     remove the grid text from the accessibility tree. The user hears
///     "n of m" from the bar and must still be able to read the matching
///     line. So: starting at the `TerminalView` and walking the accessibility
///     tree (an element's `accessibilityValue`, descending through
///     `accessibilityChildren` / subviews), some accessibility ELEMENT, not
///     inside the find bar, must expose exactly the grid text that
///     `accessibilityValue()` produces with the bar closed. Either shape of
///     fix satisfies this: the view stays a text-area element, or it becomes
///     a container that hands out a text-bearing child. The query text typed
///     into the bar's own field never counts (the grid carries a marker the
///     query does not contain).
///  2. Freshness. Output that arrives while the bar is open is part of the
///     reachable text too.
///  3. Notifications. When the grid text changes (new output, or the
///     viewport moving into scrollback), VoiceOver is told: the terminal
///     posts `NSAccessibility.Notification.valueChanged` on its own
///     element, with the bar open or closed. Observed with a real
///     in-process `AXObserver` (the only way to see an
///     `NSAccessibility.post`: AppKit calls nothing on the element when no
///     observer is registered). Registration and delivery need no
///     Accessibility trust; attribute reads do, so the posting element is
///     identified by `CFEqual` against a reference `AXUIElement` captured
///     from a deliberate post by the (closed-bar) `TerminalView` itself. A
///     post from any other element (the find bar's label, a stub) can't
///     satisfy the assertion.
///
/// Control tests (pass before and after the fix) pin that the reachability
/// walk finds the grid when the bar is closed or has been closed again, so a
/// failure of the open-bar tests is the bar's doing and not the walker's.
///
/// Notification rig preconditions, checked before every notification test
/// (`XCTSkip` with the reason, never a vacuous pass/fail, if one doesn't
/// hold): the observer registers; a stub element's post is delivered; the
/// closed-bar terminal's own post is delivered; and the stub's and the
/// terminal's `AXUIElement`s are not `CFEqual`.
///
/// Fixture: headless `TerminalView` inside a parked, never-shown, non-tabbed
/// `NSWindow` (an unwindowed view delivers no AX notifications), bound to a
/// headless `TerminalSession` (real BBTerm, no PTY, no shell). Output goes
/// through the real feed -> coalesced publish -> `render(snapshot:)` path.
/// At most ~80 short lines per test; wall time <= ~10 s worst case (waits
/// are bounded polls), typically ~3 s. Memory trivial.
final class VoiceOverFindBarGridAccessBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Windows are parked for the process lifetime and never closed or
    /// ordered out (CLAUDE.md: closing windows in this host can poison a
    /// deferred CoreAnimation flush).
    private static var parkedWindows: [NSWindow] = []

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let window: NSWindow
        let container: NSView
        /// Unique per rig; appended to every grid line so a value that
        /// contains it is the terminal's, and the find query (which never
        /// contains it) can't masquerade as grid text.
        let marker: String
        var fc: FindController { view.findController }
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "bb-vo-find-blind-\(UUID().uuidString)"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        Self.parkedWindows.append(window)

        let marker = "GRIDMARK-" + String(UUID().uuidString.prefix(8))
        let rig = Rig(view: view, session: session, window: window, container: container, marker: marker)
        settle(0.3) // let the attach / layout publishes land before the test acts
        return rig
    }

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    private func visibleRows(_ rig: Rig) -> [String] {
        rig.view.currentSnapshot?.visibleRowsAsText() ?? []
    }

    /// Feed `lines` (each followed by CRLF) and wait until the last one is
    /// on the view's current snapshot.
    private func feed(_ rig: Rig, lines: [String],
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let last = lines.last else { return }
        rig.session.feedBytesForTests(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        let landed = pump(until: 3.0) {
            self.visibleRows(rig).contains(where: { (row: String) -> Bool in row.hasPrefix(last) })
        }
        XCTAssertTrue(landed,
                      "fixture: the published snapshot must show '\(last)' within 3 s; rows=\(visibleRows(rig))",
                      file: file, line: line)
    }

    /// A short, non-scrolling grid: row 0 plain, row 1 starts with "needle",
    /// row 2 plain. Every line carries the rig marker.
    private func seedShortGrid(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        feed(rig, lines: [
            "alpha \(rig.marker)",
            "needle \(rig.marker)",
            "omega \(rig.marker)",
        ], file: file, line: line)
    }

    private func gridValue(_ rig: Rig) -> String {
        (rig.view.accessibilityValue() as? String) ?? ""
    }

    // MARK: - Accessibility-tree walk

    /// Values of every accessibility ELEMENT reachable from `root`, not
    /// counting anything inside `bar` (so the find field's own text can
    /// never be mistaken for grid text). Non-element nodes (containers) are
    /// walked through but contribute no value, as in AppKit's tree.
    private func reachableElementValues(from root: NSObject, excluding bar: NSView?) -> [String] {
        var values: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ any: Any, depth: Int) {
            guard depth < 10, let node = any as? NSObject, let ax = node as? NSAccessibilityProtocol else { return }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let bar = bar, let v = node as? NSView, v === bar || v.isDescendant(of: bar) { return }
            if ax.isAccessibilityElement(), let s = ax.accessibilityValue() as? String {
                values.append(s)
            }
            let kids: [Any] = ax.accessibilityChildren() ?? ((node as? NSView)?.subviews ?? [])
            for child in kids { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return values
    }

    private func brief(_ values: [String]) -> String {
        "[" + values.map { (s: String) -> String in "\"" + String(s.prefix(48)).replacingOccurrences(of: "\n", with: "\\n") + "\"" }
            .joined(separator: ", ") + "]"
    }

    /// The accessibility tree under the terminal must expose exactly
    /// `expected` as the text of some element outside the find bar.
    private func assertGridReachable(_ rig: Rig, expected: String, _ context: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let bar = rig.fc.findBar
        let values = reachableElementValues(from: rig.view, excluding: bar)
        let gridText = values.first(where: { (v: String) -> Bool in v.contains(rig.marker) })
        XCTAssertEqual(gridText, expected,
                       "\(context): the grid text must be reachable as an accessibility element's value. "
                       + "find bar open=\(bar != nil), view.isAccessibilityElement()=\(rig.view.isAccessibilityElement()), "
                       + "reachable element values outside the bar=\(brief(values))",
                       file: file, line: line)
    }

    // MARK: - Reachability: controls (pass before and after the fix)

    func test_control_gridReachable_whileFindBarClosed() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)
        XCTAssertTrue(expected.contains(rig.marker), "precondition: the grid value carries the marker; value=\(expected.debugDescription)")
        XCTAssertEqual(rig.fc.findBar == nil, true, "precondition: the find bar is closed")
        assertGridReachable(rig, expected: expected, "bar closed")
        withExtendedLifetime(rig) {}
    }

    func test_control_gridReachable_againAfterFindBarCloses() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)
        rig.view.performFindPanelAction(nil)
        let bar = try XCTUnwrap(rig.fc.findBar, "precondition: Cmd-F opened the bar")
        rig.view.findBarDidClose(bar)
        XCTAssertEqual(rig.fc.findBar == nil, true, "precondition: Esc closed the bar")
        assertGridReachable(rig, expected: expected, "bar closed again after Esc")
        withExtendedLifetime(rig) {}
    }

    // MARK: - Reachability: the bug (fail before the fix)

    /// Cmd-F.
    func test_cmdF_gridStaysReachableInAXTree() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)
        XCTAssertTrue(expected.contains(rig.marker), "precondition: the grid value carries the marker; value=\(expected.debugDescription)")

        rig.view.performFindPanelAction(nil)

        XCTAssertEqual(rig.fc.findBar == nil, false, "precondition: Cmd-F opened the find bar")
        assertGridReachable(rig, expected: expected, "after Cmd-F")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-E (Use Selection for Find): select "needle" on row 1, press it.
    func test_cmdE_gridStaysReachableInAXTree() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)
        rig.view.selection = Selection(
            anchor: BufferPoint(line: 1, col: 0),
            cursor: BufferPoint(line: 1, col: 5),
            mode: .character)
        XCTAssertEqual(rig.view.selectedStringForServices(), "needle",
                       "precondition: the selection under test is the word 'needle'")

        rig.view.useSelectionForFind(nil)

        XCTAssertEqual(rig.fc.findQuery, "needle", "precondition: Cmd-E seeded the query with the selection")
        XCTAssertEqual(rig.fc.findBar == nil, false, "precondition: Cmd-E opened the find bar")
        assertGridReachable(rig, expected: expected, "after Cmd-E")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-Opt-C opens the bar when closed and turns case-sensitivity on.
    func test_caseToggle_gridStaysReachableInAXTree() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)

        rig.view.toggleFindCaseSensitive(nil)

        let bar = try XCTUnwrap(rig.fc.findBar, "precondition: the case toggle opened the find bar")
        XCTAssertEqual(bar.options.caseSensitive, true, "precondition: case-sensitive is now on")
        assertGridReachable(rig, expected: expected, "after the case toggle")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-Opt-R opens the bar when closed and turns regex on.
    func test_regexToggle_gridStaysReachableInAXTree() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let expected = gridValue(rig)

        rig.view.toggleFindRegex(nil)

        let bar = try XCTUnwrap(rig.fc.findBar, "precondition: the regex toggle opened the find bar")
        XCTAssertEqual(bar.options.regex, true, "precondition: regex is now on")
        assertGridReachable(rig, expected: expected, "after the regex toggle")
        withExtendedLifetime(rig) {}
    }

    /// The bar is open with a live query; new output lands. The reachable
    /// text must be the new grid, not absent and not stale.
    func test_outputWhileFindBarOpen_isInReachableText() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        rig.view.performFindPanelAction(nil)
        rig.fc.findBar?.setQuery("needle")
        XCTAssertEqual(rig.fc.findBar == nil, false, "precondition: the bar is open")

        let freshLine = "fresh-\(UUID().uuidString.prefix(6)) \(rig.marker)"
        feed(rig, lines: [freshLine])
        let expected = gridValue(rig)
        XCTAssertTrue(expected.contains(String(freshLine.prefix(12))),
                      "precondition: the grid value includes the new line; value=\(expected.debugDescription)")

        assertGridReachable(rig, expected: expected, "output arriving while the bar is open")
        withExtendedLifetime(rig) {}
    }

    // MARK: - valueChanged notifications: AX observer rig

    /// Stand-in element used only to prove the observer rig works and that
    /// element identity discriminates: an accessibility element in the same
    /// window that is not the terminal.
    private final class ControlStub: NSView {
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? { "AX-CONTROL-STUB-VALUE" }
    }

    /// Records every `AXValueChanged` the process delivers to its own
    /// observer. Registration and delivery work without Accessibility trust
    /// (attribute reads do not, so elements are identified by `CFEqual`
    /// against a reference captured from the terminal itself).
    private final class ValueChangedProbe {
        var observer: AXObserver?
        /// The AX element of the `TerminalView`, captured by the rig's
        /// reference post while the find bar is closed.
        var terminalElement: AXUIElement?
        private(set) var recorded: [AXUIElement] = []
        func record(_ element: AXUIElement) { recorded.append(element) }
        func reset() { recorded.removeAll() }

        /// How many recorded posts came from the terminal's own element.
        var postsFromTerminal: Int {
            guard let ref = terminalElement else { return 0 }
            return recorded.filter { (e: AXUIElement) -> Bool in CFEqual(e, ref) }.count
        }
    }

    /// Plain C callback: no captures, the probe arrives through `refcon`.
    private static let valueChangedCallback: AXObserverCallback = {
        (_: AXObserver, element: AXUIElement, _: CFString, refcon: UnsafeMutableRawPointer?) -> Void in
        guard let refcon = refcon else { return }
        Unmanaged<ValueChangedProbe>.fromOpaque(refcon).takeUnretainedValue().record(element)
    }

    /// Thread-safe cell for results produced on a background queue.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ initial: Value) { stored = initial }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// AX requests to our own process are answered on the main thread, so a
    /// blocking AX call made from main would deadlock until it times out.
    /// Run `work` on a background queue while main keeps pumping its
    /// runloop. Returns false if it didn't finish in time.
    private func runOffMain(timeout: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = Locked<Bool>(false)
        DispatchQueue.global().async {
            work()
            done.value = true
        }
        return pump(until: timeout) { done.value }
    }

    /// Register an in-process observer for `AXValueChanged` on this app and
    /// prove the rig works before any bug-dependent assertion:
    ///  - a stub element posting `valueChanged` is delivered (observer live);
    ///  - the terminal itself, while its find bar is CLOSED (the state in
    ///    which it is a plain text-area element), posting `valueChanged` is
    ///    delivered and yields the reference element the tests compare
    ///    against;
    ///  - the stub's element and the terminal's element are not `CFEqual`
    ///    (identity discriminates).
    /// Must be called with the find bar closed. Throws `XCTSkip` (never
    /// passes or fails vacuously) if the host can't observe itself.
    private func makeLiveProbe(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> ValueChangedProbe {
        XCTAssertEqual(rig.fc.findBar == nil, true, "rig precondition: probe is armed with the find bar closed",
                       file: file, line: line)
        let probe = ValueChangedProbe()
        let pid: pid_t = ProcessInfo.processInfo.processIdentifier
        var created: AXObserver?
        let createErr: AXError = AXObserverCreate(pid, Self.valueChangedCallback, &created)
        guard createErr == .success, let observer = created else {
            throw XCTSkip("AXObserverCreate failed with AXError \(createErr.rawValue)")
        }
        probe.observer = observer
        let app: AXUIElement = AXUIElementCreateApplication(pid)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
        addTeardownBlock {
            CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observer))
        }

        // The refcon travels as an integer so the @Sendable closure captures
        // a Sendable value; the probe outlives the observer (see below).
        let refconBits: UInt = UInt(bitPattern: Unmanaged.passUnretained(probe).toOpaque())
        let addErr = Locked<Int32>(-1)
        let added = runOffMain(timeout: 3.0) {
            let e: AXError = AXObserverAddNotification(observer, app, kAXValueChangedNotification as CFString,
                                                       UnsafeMutableRawPointer(bitPattern: refconBits))
            addErr.value = e.rawValue
        }
        guard added, addErr.value == 0 else {
            throw XCTSkip("AXObserverAddNotification did not succeed (finished=\(added), AXError=\(addErr.value))")
        }

        // Control 1: a non-terminal element's post is delivered.
        let stub = ControlStub(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        rig.container.addSubview(stub)
        probe.reset()
        NSAccessibility.post(element: stub, notification: .valueChanged)
        let sawStub = pump(until: 3.0) { !probe.recorded.isEmpty }
        let stubElement = probe.recorded.first
        stub.removeFromSuperview()
        guard sawStub, let stubRef = stubElement else {
            throw XCTSkip("AX observer rig cannot see an in-process post from a stub element (delivered=\(sawStub))")
        }

        // Control 2: the terminal's own post is delivered and identifiable.
        probe.reset()
        NSAccessibility.post(element: rig.view, notification: .valueChanged)
        let sawTerminal = pump(until: 3.0) { !probe.recorded.isEmpty }
        guard sawTerminal, let terminalRef = probe.recorded.first else {
            throw XCTSkip("AX observer rig cannot see a post from the closed-bar TerminalView (delivered=\(sawTerminal))")
        }
        guard !CFEqual(stubRef, terminalRef) else {
            throw XCTSkip("AX element identity does not discriminate the stub from the TerminalView; cannot attribute posts")
        }
        probe.terminalElement = terminalRef
        // Let anything the control posts may have provoked land, then start clean.
        settle(0.3)
        probe.reset()
        return probe
    }

    /// Wait (bounded) for the terminal to post `valueChanged`.
    private func waitForTerminalPost(_ probe: ValueChangedProbe) {
        pump(until: 3.0) { probe.postsFromTerminal > 0 }
        settle(0.2) // let any further post from the same change land
    }

    // MARK: - valueChanged notifications (fail before the fix)

    /// New output with the find bar closed: the terminal tells VoiceOver.
    func test_newOutput_postsValueChanged_whileFindBarClosed() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let probe = try makeLiveProbe(rig)
        settle(1.0) // any throttled post from the seed output lands before we start counting

        probe.reset()
        feed(rig, lines: ["newout-\(UUID().uuidString.prefix(6)) \(rig.marker)"])
        waitForTerminalPost(probe)

        XCTAssertGreaterThan(probe.postsFromTerminal, 0,
                             "new output must make the terminal post AXValueChanged; delivered posts after the output: "
                             + "\(probe.recorded.count) total, \(probe.postsFromTerminal) from the TerminalView's element")
        withExtendedLifetime(probe) {}
        withExtendedLifetime(rig) {}
    }

    /// Same, with the find bar open (the bar must not suppress it).
    func test_newOutput_postsValueChanged_whileFindBarOpen() throws {
        let rig = try makeRig()
        seedShortGrid(rig)
        let probe = try makeLiveProbe(rig)

        rig.view.performFindPanelAction(nil)
        rig.fc.findBar?.setQuery("needle") // matches row 1 only; the new line below won't change the count
        XCTAssertEqual(rig.fc.findBar == nil, false, "precondition: the find bar is open")
        settle(1.0)

        probe.reset()
        feed(rig, lines: ["newout-\(UUID().uuidString.prefix(6)) \(rig.marker)"])
        waitForTerminalPost(probe)

        XCTAssertGreaterThan(probe.postsFromTerminal, 0,
                             "new output with the find bar open must make the terminal post AXValueChanged; delivered posts after the output: "
                             + "\(probe.recorded.count) total, \(probe.postsFromTerminal) from the TerminalView's element")
        withExtendedLifetime(probe) {}
        withExtendedLifetime(rig) {}
    }

    /// The viewport moving into scrollback changes the grid text with no new
    /// output at all; VoiceOver must be told that too.
    func test_viewportScrollIntoHistory_postsValueChanged() throws {
        let rig = try makeRig()
        let lines: [String] = (0..<60).map { (i: Int) -> String in
            String(format: "L%02d ", i) + rig.marker
        }
        feed(rig, lines: lines)
        XCTAssertGreaterThan(rig.view.currentSnapshot?.historySize ?? 0, 0,
                             "fixture: output must have scrolled into history; rows=\(visibleRows(rig))")
        let probe = try makeLiveProbe(rig)
        settle(1.0)
        let before = gridValue(rig)
        XCTAssertTrue(before.contains("L59"), "precondition: the live bottom is showing; value=\(before.debugDescription)")

        probe.reset()
        rig.session.scroll(delta: 10) // positive = back into history
        let moved = pump(until: 3.0) { self.gridValue(rig) != before }
        let after = gridValue(rig)
        XCTAssertTrue(moved && !after.contains("L59"),
                      "precondition: scrolling back must change the visible grid; after=\(after.debugDescription)")
        waitForTerminalPost(probe)

        XCTAssertGreaterThan(probe.postsFromTerminal, 0,
                             "a viewport change must make the terminal post AXValueChanged; delivered posts after the scroll: "
                             + "\(probe.recorded.count) total, \(probe.postsFromTerminal) from the TerminalView's element")
        withExtendedLifetime(probe) {}
        withExtendedLifetime(rig) {}
    }
}
