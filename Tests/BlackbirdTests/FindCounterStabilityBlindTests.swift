import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's match counter ("3 / 12",
/// "No matches"). Spec, not implementation:
///
///  The counter is a status line that a sighted user reads and that
///  VoiceOver speaks EVERY time its text changes. It is therefore a piece of
///  the user's state that may only change when the truth changes:
///
///   1. While the bar holds a query that has matches, and the match set does
///      not change, the counter must not change either. A snapshot swap that
///      the user did not ask to be searched again (one more line of output, a
///      wheel scroll, a Cmd-G that scrolls the viewport) makes the find bar
///      re-search about 100 ms later (`FindController.refreshCoalesceInterval`)
///      - that internal housekeeping must not be visible. In particular the
///      counter must NEVER read "No matches" for a query that has matches,
///      not even for the few milliseconds a re-scan takes (with a large
///      scrollback: the whole scan time), because every flip is announced:
///      "N / M" -> "No matches" -> "N / M" speaks a lie and then the truth.
///      This is the regex-mode (asynchronous scan) behaviour; the
///      substring mode is the already-correct control.
///
///   2. An EMPTY query is not a search, so it has no result to report. The
///      counter must read exactly what a freshly opened bar reads (blank),
///      not "No matches", both when the user clears a query they had typed
///      and when they toggle case-sensitivity / regex with an empty field.
///
///   3. Control: a query that genuinely matches nothing still reads
///      "No matches" (in both modes). The fix must not silence the real
///      message.
///
///   4. A pattern the bar cannot run (invalid regex, or one the safety gate
///      refuses) has no result to report either: the counter shows the error
///      banner, and the re-search a snapshot swap schedules must not put a
///      false "No matches" in front of it (the same announcement problem as
///      in 1, and the only thing VoiceOver would otherwise hear). A regex
///      that keeps matching nothing while the user edits it stays "No matches"
///      without blinking.
///
///  Observation: the counter's text field is located in the bar's view tree
///  (the bar's only non-editable text field) and every value it ever takes is
///  recorded through KVO (`stringValue`, `attributedStringValue`) plus a
///  sample after every 5 ms runloop slice, so a transient value that lasts
///  only until the next runloop turn is still caught. Consecutive duplicates
///  are collapsed: re-writing the same text is not a change. Transient
///  VoiceOver announcements themselves are not observable in-process; the
///  counter's text changes are what trigger them.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY, no window, no MainWindowController), grid 40x6. Scrollback
/// fixture: 34 short lines (~29 history rows). Cost: a few KB of cells; each
/// test pumps the main runloop for ~1-3 s of wall time (the refresh debounce
/// is 100 ms; every action is followed by several multiples of it).
final class FindCounterStabilityBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        var fc: FindController { view.findController }
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session
        return Rig(view: view, session: session)
    }

    /// Records every distinct text the counter label takes, from construction
    /// on. Consecutive duplicates are collapsed.
    private final class CounterRecorder {
        private(set) var states: [String]
        private let label: NSTextField
        private var tokens: [NSKeyValueObservation] = []

        init(label: NSTextField) {
            self.label = label
            self.states = [label.stringValue]
            let plain = label.observe(\.stringValue, options: [.new]) {
                [weak self] (field: NSTextField, _: NSKeyValueObservedChange<String>) -> Void in
                self?.record(field.stringValue)
            }
            let attributed = label.observe(\.attributedStringValue, options: [.new]) {
                [weak self] (field: NSTextField, _: NSKeyValueObservedChange<NSAttributedString>) -> Void in
                self?.record(field.stringValue)
            }
            tokens = [plain, attributed]
        }

        /// Poll the label (covers any write path KVO would not announce).
        func sample() { record(label.stringValue) }

        func stop() {
            for token in tokens { token.invalidate() }
            tokens = []
        }

        private func record(_ text: String) {
            if states.last != text { states.append(text) }
        }
    }

    /// The match-counter text field: the bar's only non-editable text field.
    /// (Never descends into a control: on recent SDKs an NSButton hosts an
    /// internal title text field that is part of the button.)
    private func collectStaticFields(in view: NSView, into out: inout [NSTextField]) {
        for sub in view.subviews {
            if let field = sub as? NSTextField {
                if !field.isEditable { out.append(field) }
                continue
            }
            if sub is NSControl { continue }
            collectStaticFields(in: sub, into: &out)
        }
    }

    private func makeRecorder(for bar: FindBar,
                              file: StaticString = #filePath, line: UInt = #line) throws -> CounterRecorder {
        var fields: [NSTextField] = []
        collectStaticFields(in: bar, into: &fields)
        XCTAssertEqual(fields.count, 1,
                       "fixture: the bar must have exactly one static text field (the counter); found \(fields.count)",
                       file: file, line: line)
        let field = try XCTUnwrap(fields.first, "fixture: counter label not found in the bar's view tree", file: file, line: line)
        XCTAssertEqual(field.stringValue, bar._matchLabelStringForTests(),
                       "fixture: the located text field must be the counter", file: file, line: line)
        return CounterRecorder(label: field)
    }

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses, sampling the recorder after every slice.
    @discardableResult
    private func pump(until timeout: TimeInterval, recording recorder: CounterRecorder? = nil,
                      _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            recorder?.sample()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        recorder?.sample()
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds`. The refresh
    /// debounce is 100 ms; the default is several multiples of it plus room
    /// for an async regex scan to publish.
    private func settle(_ seconds: TimeInterval = 0.6, recording recorder: CounterRecorder? = nil) {
        pump(until: seconds, recording: recorder) { false }
    }

    /// Feed lines and wait until the view's snapshot SHOWS the last one.
    private func feed(_ rig: Rig, lines: [String],
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let last = lines.last else { return }
        rig.session.feedBytesForTests(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        let landed = pump(until: 3.0) { () -> Bool in
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { (row: String) -> Bool in row.hasPrefix(last) }
        }
        XCTAssertTrue(landed, "publish showing '\(last)' must reach the view within 3 s", file: file, line: line)
    }

    private static let alphaLines: [String] = ["alpha one", "beta", "alpha two"]

    /// Three "needle" matches, each separated from the next by 11 filler
    /// lines (about two screens), and 9 trailing fillers, so on a 6-row grid
    /// ALL three live in scrollback and every Cmd-G must scroll.
    private static let farLines: [String] = {
        var l = ["needle one"]
        l += (1...11).map { "filler a\($0)" }
        l += ["needle two"]
        l += (1...11).map { "filler b\($0)" }
        l += ["needle three"]
        l += (1...9).map { "filler c\($0)" }
        return l
    }()

    private func label(_ rig: Rig) -> String {
        rig.fc.findBar?._matchLabelStringForTests() ?? "<no bar>"
    }

    private func displayOffset(_ rig: Rig) -> Int {
        rig.view.currentSnapshot?.displayOffset ?? -1
    }

    private func isOnScreen(_ rig: Rig, matchIndex index: Int) -> Bool {
        guard let snap = rig.view.currentSnapshot, index >= 0, index < rig.fc.findMatches.count else { return false }
        let row = Int(rig.fc.findMatches[index].line) + snap.displayOffset
        return row >= 0 && row < snap.rows
    }

    private func openBar(_ rig: Rig, regex: Bool,
                         file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        fc.installFindBar()
        let bar = try XCTUnwrap(fc.findBar, "find bar must open", file: file, line: line)
        if regex {
            bar.toggleRegexMode(nil)
            XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        }
        return bar
    }

    /// Type `query`, wait for its results to publish and the counter to read
    /// `expected`, then let the refresh window elapse and assert the match
    /// cache is fresh against the live snapshot.
    private func typeAndSettle(_ rig: Rig, bar: FindBar, query: String, expected: String, matchCount: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        bar.setQuery(query)
        let published = pump(until: 3.0) { () -> Bool in
            rig.fc.findMatches.count == matchCount && self.label(rig) == expected
        }
        XCTAssertTrue(published,
                      "fixture: '\(query)' must publish \(matchCount) matches and the counter must read '\(expected)'; "
                      + "matches=\(rig.fc.findMatches.count) counter='\(label(rig))'", file: file, line: line)
        settle(0.5)
        let fresh = pump(until: 3.0) { rig.fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID }
        XCTAssertTrue(fresh, "fixture: matches must be fresh vs the live snapshot before the test acts",
                      file: file, line: line)
        XCTAssertEqual(label(rig), expected, "fixture: counter after settling", file: file, line: line)
    }

    private func assertCounterNeverFlipped(_ states: [String], stable: [String], context: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(states.contains("No matches"),
                       "\(context): the counter must never read 'No matches' for a query that has matches (each flip is announced); "
                       + "observed counter values in order: \(states.debugDescription)", file: file, line: line)
        XCTAssertEqual(states, stable,
                       "\(context): the match set did not change, so the counter must not change; "
                       + "observed counter values in order: \(states.debugDescription)", file: file, line: line)
    }

    // MARK: - 1a. One more line of output, regex mode vs substring control

    private func runOutputRefreshScenario(regex: Bool,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try makeRig(file: file, line: line)
        let fc = rig.fc
        feed(rig, lines: Self.alphaLines, file: file, line: line)
        let bar = try openBar(rig, regex: regex, file: file, line: line)
        typeAndSettle(rig, bar: bar, query: "alpha", expected: "1 / 2", matchCount: 2, file: file, line: line)
        let recorder = try makeRecorder(for: bar, file: file, line: line)
        defer { recorder.stop() }

        // One more line of output that does not contain the query and does not
        // scroll the 6-row grid (4 content rows + the cursor row).
        let seqBefore = rig.view.currentSnapshot?.sequenceID
        let matchSeqBefore = fc.findMatchesSeq
        rig.session.feedBytesForTests(Data("gamma\r\n".utf8))
        let landed = pump(until: 3.0, recording: recorder) { () -> Bool in
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { (row: String) -> Bool in row.hasPrefix("gamma") }
        }
        XCTAssertTrue(landed, "precondition: the output must reach the view", file: file, line: line)
        XCTAssertNotEqual(rig.view.currentSnapshot?.sequenceID, seqBefore,
                          "precondition: the output published a new snapshot", file: file, line: line)

        // The debounced re-search must run (non-vacuity: otherwise a stable
        // counter proves nothing) ...
        let refreshed = pump(until: 3.0, recording: recorder) { () -> Bool in
            fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && fc.findMatchesSeq != matchSeqBefore
        }
        XCTAssertTrue(refreshed,
                      "precondition: the snapshot-driven re-search must re-stamp the matches against the new snapshot "
                      + "(findMatchesSeq \(String(describing: fc.findMatchesSeq)), was \(String(describing: matchSeqBefore)), "
                      + "snapshot \(String(describing: rig.view.currentSnapshot?.sequenceID)))", file: file, line: line)
        // ... and anything it does to the counter must have happened by now.
        settle(0.4, recording: recorder)

        XCTAssertEqual(fc.findMatches.count, 2, "the match set is unchanged by the unrelated output", file: file, line: line)
        assertCounterNeverFlipped(recorder.states, stable: ["1 / 2"],
                                  context: "\(regex ? "regex" : "substring") mode, one line of unrelated output",
                                  file: file, line: line)
        withExtendedLifetime(rig) {}
    }

    func test_regexMode_unrelatedOutput_counterNeverFlipsToNoMatches() throws {
        try runOutputRefreshScenario(regex: true)
    }

    /// Control: the substring mode (synchronous scan) already behaves.
    func test_control_substringMode_unrelatedOutput_counterIsStable() throws {
        try runOutputRefreshScenario(regex: false)
    }

    // MARK: - 1b. Cmd-G that scrolls the viewport, regex mode

    func test_regexMode_cmdGScrollsViewport_counterGoesStraightFromOneToTwoOfThree() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        XCTAssertGreaterThanOrEqual(rig.view.currentSnapshot?.historySize ?? 0, 24,
                                    "fixture: all three matches must be in scrollback")
        let bar = try openBar(rig, regex: true)
        typeAndSettle(rig, bar: bar, query: "needle", expected: "1 / 3", matchCount: 3)
        let onScreen = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 0) }
        XCTAssertTrue(onScreen, "fixture: the first search must have revealed match 1 (displayOffset \(displayOffset(rig)))")
        settle(0.5)
        let fresh = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID }
        XCTAssertTrue(fresh, "fixture: matches must be fresh vs the live snapshot before Cmd-G")
        XCTAssertEqual(label(rig), "1 / 3", "fixture: counter before Cmd-G")

        let recorder = try makeRecorder(for: bar)
        defer { recorder.stop() }
        let offsetBefore = displayOffset(rig)
        let matchSeqBefore = fc.findMatchesSeq

        rig.view.performFindNextAction(nil)   // Cmd-G
        recorder.sample()
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G advances from match 1 to match 2")
        let landed = pump(until: 3.0, recording: recorder) { self.isOnScreen(rig, matchIndex: 1) }
        XCTAssertTrue(landed, "precondition: Cmd-G must scroll the viewport to match 2 (displayOffset \(displayOffset(rig)))")
        XCTAssertNotEqual(displayOffset(rig), offsetBefore,
                          "precondition: match 2 is far from match 1, so the viewport scrolled (both at displayOffset \(offsetBefore))")

        // The scroll published a new snapshot: the debounced re-search must run.
        let refreshed = pump(until: 3.0, recording: recorder) { () -> Bool in
            fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && fc.findMatchesSeq != matchSeqBefore
        }
        XCTAssertTrue(refreshed,
                      "precondition: the scroll's snapshot swap must trigger a re-search "
                      + "(findMatchesSeq \(String(describing: fc.findMatchesSeq)), was \(String(describing: matchSeqBefore)))")
        settle(0.5, recording: recorder)

        XCTAssertEqual(fc.findCurrentIndex, 1, "the cycle position survives the refresh; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertFalse(recorder.states.contains("No matches"),
                       "the counter must never read 'No matches' for a query that has matches; "
                       + "observed counter values in order: \(recorder.states.debugDescription)")
        XCTAssertEqual(recorder.states, ["1 / 3", "2 / 3"],
                       "one Cmd-G is one counter change (1 / 3 -> 2 / 3), nothing in between or after; "
                       + "observed counter values in order: \(recorder.states.debugDescription)")
        withExtendedLifetime(rig) {}
    }

    // MARK: - 1c. A wheel scroll, regex mode

    func test_regexMode_wheelScroll_counterNeverFlipsToNoMatches() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        let bar = try openBar(rig, regex: true)
        typeAndSettle(rig, bar: bar, query: "needle", expected: "1 / 3", matchCount: 3)
        let onScreen = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 0) }
        XCTAssertTrue(onScreen, "fixture: the first search must have revealed match 1 (displayOffset \(displayOffset(rig)))")
        settle(0.5)
        let fresh = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID }
        XCTAssertTrue(fresh, "fixture: matches must be fresh vs the live snapshot before scrolling")
        XCTAssertEqual(label(rig), "1 / 3", "fixture: counter before scrolling")

        let recorder = try makeRecorder(for: bar)
        defer { recorder.stop() }
        let before = displayOffset(rig)
        let matchSeqBefore = fc.findMatchesSeq

        rig.session.scroll(delta: -4)   // negative = toward newer content / live bottom
        let moved = pump(until: 3.0, recording: recorder) { self.displayOffset(rig) == before - 4 }
        XCTAssertTrue(moved, "precondition: the wheel step must move the viewport from displayOffset \(before) to \(before - 4); at \(displayOffset(rig))")
        let refreshed = pump(until: 3.0, recording: recorder) { () -> Bool in
            fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && fc.findMatchesSeq != matchSeqBefore
        }
        XCTAssertTrue(refreshed,
                      "precondition: the scroll's snapshot swap must trigger a re-search "
                      + "(findMatchesSeq \(String(describing: fc.findMatchesSeq)), was \(String(describing: matchSeqBefore)))")
        settle(0.5, recording: recorder)

        XCTAssertEqual(fc.findMatches.count, 3, "the match set is unchanged by scrolling")
        assertCounterNeverFlipped(recorder.states, stable: ["1 / 3"], context: "regex mode, wheel scroll")
        withExtendedLifetime(rig) {}
    }

    // MARK: - 1d. One static search whose reveal scrolls the viewport, regex mode

    /// The user types a regex once and touches nothing else. The first match
    /// lives in scrollback, so revealing it scrolls the viewport, which swaps
    /// the snapshot and makes the bar re-search. From the moment the results
    /// first publish the counter must read "1 / 3" and stay that way.
    func test_regexMode_singleStaticSearchWithScrollingReveal_counterReadsOneOfThreeOnce() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        XCTAssertEqual(displayOffset(rig), 0, "fixture: the viewport starts at the live bottom, away from every match")
        let bar = try openBar(rig, regex: true)

        bar.setQuery("needle")
        let published = pump(until: 3.0) { () -> Bool in
            fc.findMatches.count == 3 && self.label(rig) == "1 / 3"
        }
        XCTAssertTrue(published, "fixture: the scan must publish 3 matches and the counter must read '1 / 3'; "
                      + "matches=\(fc.findMatches.count) counter='\(label(rig))'")
        let recorder = try makeRecorder(for: bar)
        defer { recorder.stop() }
        let matchSeqAtPublish = fc.findMatchesSeq

        // The reveal scrolls the viewport to match 1 (a snapshot swap), then
        // the debounced re-search runs.
        let revealed = pump(until: 3.0, recording: recorder) { self.isOnScreen(rig, matchIndex: 0) }
        XCTAssertTrue(revealed, "precondition: the first match must be scrolled into view (displayOffset \(displayOffset(rig)))")
        XCTAssertNotEqual(displayOffset(rig), 0, "precondition: revealing match 1 scrolled the viewport")
        let refreshed = pump(until: 3.0, recording: recorder) { () -> Bool in
            fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && fc.findMatchesSeq != matchSeqAtPublish
        }
        XCTAssertTrue(refreshed,
                      "precondition: the reveal's snapshot swap must trigger a re-search "
                      + "(findMatchesSeq \(String(describing: fc.findMatchesSeq)), was \(String(describing: matchSeqAtPublish)))")
        settle(0.5, recording: recorder)

        XCTAssertEqual(fc.findMatches.count, 3, "the match set is unchanged by the reveal's re-search")
        assertCounterNeverFlipped(recorder.states, stable: ["1 / 3"], context: "regex mode, one static search with a scrolling reveal")
        withExtendedLifetime(rig) {}
    }

    // MARK: - 2. Empty query

    /// What a freshly opened, empty bar's counter reads.
    private func blankCounter(_ rig: Rig, bar: FindBar,
                              file: StaticString = #filePath, line: UInt = #line) -> String {
        let blank = bar._matchLabelStringForTests()
        XCTAssertNotEqual(blank, "No matches", "fixture: a freshly opened bar must not claim 'No matches'", file: file, line: line)
        XCTAssertFalse(blank.contains("/"), "fixture: a freshly opened bar shows no 'k / n' count; got '\(blank)'", file: file, line: line)
        return blank
    }

    private func runClearQueryScenario(regex: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try makeRig(file: file, line: line)
        feed(rig, lines: Self.alphaLines, file: file, line: line)
        // Measure the blank counter on the freshly opened bar BEFORE touching
        // any option (toggling regex with an empty field is itself under test).
        let bar = try openBar(rig, regex: false, file: file, line: line)
        let blank = blankCounter(rig, bar: bar, file: file, line: line)
        if regex {
            bar.toggleRegexMode(nil)
            XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        }
        typeAndSettle(rig, bar: bar, query: "alpha", expected: "1 / 2", matchCount: 2, file: file, line: line)
        let recorder = try makeRecorder(for: bar, file: file, line: line)
        defer { recorder.stop() }

        bar.setQuery("")   // the user clears the field
        recorder.sample()
        XCTAssertEqual(rig.fc.findQuery, "", "precondition: the controller saw the cleared query", file: file, line: line)
        settle(0.6, recording: recorder)

        XCTAssertEqual(rig.fc.findMatches.count, 0, "precondition: an empty query has no matches", file: file, line: line)
        XCTAssertFalse(recorder.states.contains("No matches"),
                       "\(regex ? "regex" : "substring") mode: clearing the field must not report 'No matches' (an empty query is not a search); "
                       + "observed counter values in order: \(recorder.states.debugDescription)", file: file, line: line)
        XCTAssertEqual(label(rig), blank,
                       "\(regex ? "regex" : "substring") mode: after clearing the field the counter must read what a freshly opened bar reads "
                       + "(\(blank.debugDescription)); observed counter values in order: \(recorder.states.debugDescription)",
                       file: file, line: line)
        withExtendedLifetime(rig) {}
    }

    func test_substringMode_clearingTheField_counterIsBlankNotNoMatches() throws {
        try runClearQueryScenario(regex: false)
    }

    func test_regexMode_clearingTheField_counterIsBlankNotNoMatches() throws {
        try runClearQueryScenario(regex: true)
    }

    /// Toggling Aa or regex with nothing typed re-runs the (empty) search.
    /// There is nothing to report, so the counter must not change at all.
    func test_togglingOptionsWithEmptyField_counterStaysBlank() throws {
        let rig = try makeRig()
        feed(rig, lines: Self.alphaLines)
        let bar = try openBar(rig, regex: false)
        let blank = blankCounter(rig, bar: bar)
        XCTAssertEqual(rig.fc.findQuery, "", "fixture: the field is empty")
        let recorder = try makeRecorder(for: bar)
        defer { recorder.stop() }

        var steps: [String] = []
        bar.toggleCaseSensitive(nil)
        recorder.sample()
        settle(0.3, recording: recorder)
        steps.append("Aa on -> '\(label(rig))'")
        bar.toggleRegexMode(nil)
        recorder.sample()
        settle(0.3, recording: recorder)
        steps.append("regex on -> '\(label(rig))'")
        bar.toggleRegexMode(nil)
        recorder.sample()
        settle(0.3, recording: recorder)
        steps.append("regex off -> '\(label(rig))'")
        bar.toggleCaseSensitive(nil)
        recorder.sample()
        settle(0.3, recording: recorder)
        steps.append("Aa off -> '\(label(rig))'")

        XCTAssertEqual(bar.options, FindBar.Options(caseSensitive: false, regex: false),
                       "precondition: the four toggles returned the options to their defaults")
        XCTAssertFalse(recorder.states.contains("No matches"),
                       "toggling options with an empty field must not report 'No matches'; steps: \(steps); "
                       + "observed counter values in order: \(recorder.states.debugDescription)")
        XCTAssertEqual(recorder.states, [blank],
                       "toggling options with an empty field must leave the counter untouched; steps: \(steps); "
                       + "observed counter values in order: \(recorder.states.debugDescription)")
        withExtendedLifetime(rig) {}
    }

    // MARK: - 3. Control: a query with no matches still says so

    private func runNoMatchesControl(regex: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try makeRig(file: file, line: line)
        feed(rig, lines: Self.alphaLines, file: file, line: line)
        let bar = try openBar(rig, regex: regex, file: file, line: line)
        bar.setQuery("zzz")
        let said = pump(until: 3.0) { self.label(rig) == "No matches" }
        XCTAssertTrue(said,
                      "\(regex ? "regex" : "substring") mode: a query that matches nothing must still read 'No matches'; got '\(label(rig))'",
                      file: file, line: line)
        XCTAssertEqual(rig.fc.findMatches.count, 0, "fixture: 'zzz' matches nothing", file: file, line: line)
        settle(0.4)
        XCTAssertEqual(label(rig), "No matches",
                       "\(regex ? "regex" : "substring") mode: the genuine 'No matches' must survive the refresh window; got '\(label(rig))'",
                       file: file, line: line)
        withExtendedLifetime(rig) {}
    }

    func test_control_substringMode_queryWithNoMatches_stillReadsNoMatches() throws {
        try runNoMatchesControl(regex: false)
    }

    func test_control_regexMode_queryWithNoMatches_stillReadsNoMatches() throws {
        try runNoMatchesControl(regex: true)
    }

    // MARK: - 4. Patterns that cannot run, and a regex that keeps matching nothing

    /// Types `pattern` (which the bar refuses with `banner`), waits for the
    /// banner's own 2 s clear, then feeds one line of output. The refresh that
    /// output schedules re-shows the banner (that is the non-vacuity proof that
    /// the re-search ran); the counter must go "" -> banner with nothing in
    /// between.
    private func runUnrunnablePatternRefreshScenario(pattern: String, banner: String,
                                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try makeRig(file: file, line: line)
        feed(rig, lines: Self.alphaLines, file: file, line: line)
        let bar = try openBar(rig, regex: true, file: file, line: line)

        bar.setQuery(pattern)
        let shown = pump(until: 3.0) { self.label(rig) == banner }
        XCTAssertTrue(shown, "fixture: '\(pattern)' must read '\(banner)'; got '\(label(rig))'", file: file, line: line)
        let cleared = pump(until: 4.0) { self.label(rig) == "" }
        XCTAssertTrue(cleared, "fixture: the banner clears itself after about 2 s; got '\(label(rig))'", file: file, line: line)

        let recorder = try makeRecorder(for: bar, file: file, line: line)
        defer { recorder.stop() }
        feed(rig, lines: ["gamma"], file: file, line: line)
        let reshown = pump(until: 3.0, recording: recorder) { self.label(rig) == banner }
        XCTAssertTrue(reshown,
                      "precondition: the snapshot-driven re-search must run and re-show '\(banner)'; "
                      + "observed counter values in order: \(recorder.states.debugDescription)", file: file, line: line)
        settle(0.4, recording: recorder)

        XCTAssertFalse(recorder.states.contains("No matches"),
                       "'\(pattern)' cannot run, so the counter must never claim 'No matches' (each flip is announced); "
                       + "observed counter values in order: \(recorder.states.debugDescription)", file: file, line: line)
        XCTAssertEqual(recorder.states, ["", banner],
                       "the refresh must take the counter straight from blank to '\(banner)'; "
                       + "observed counter values in order: \(recorder.states.debugDescription)", file: file, line: line)
        withExtendedLifetime(rig) {}
    }

    func test_regexMode_invalidPattern_refreshNeverPutsNoMatchesBeforeTheBanner() throws {
        try runUnrunnablePatternRefreshScenario(pattern: "(", banner: "Invalid regex pattern")
    }

    func test_regexMode_gateRejectedPattern_refreshNeverPutsNoMatchesBeforeTheBanner() throws {
        try runUnrunnablePatternRefreshScenario(pattern: "(a+)+", banner: "Regex too complex")
    }

    /// Editing a regex that matches nothing keeps reading "No matches" the
    /// whole time: the counter does not blink blank and back (a re-announcement
    /// of the same news on every keystroke).
    func test_regexMode_editingAQueryThatKeepsMatchingNothing_counterStaysNoMatches() throws {
        let rig = try makeRig()
        feed(rig, lines: Self.alphaLines)
        let bar = try openBar(rig, regex: true)
        bar.setQuery("zzz")
        let said = pump(until: 3.0) { self.label(rig) == "No matches" }
        XCTAssertTrue(said, "fixture: 'zzz' must read 'No matches'; got '\(label(rig))'")
        settle(0.3)

        let recorder = try makeRecorder(for: bar)
        defer { recorder.stop() }
        bar.setQuery("zzzz")
        recorder.sample()
        settle(0.6, recording: recorder)
        bar.setQuery("zzzzz")
        recorder.sample()
        settle(0.6, recording: recorder)

        XCTAssertEqual(rig.fc.findMatches.count, 0, "fixture: neither edit matches anything")
        XCTAssertEqual(recorder.states, ["No matches"],
                       "a regex that keeps matching nothing must not blink; "
                       + "observed counter values in order: \(recorder.states.debugDescription)")
        withExtendedLifetime(rig) {}
    }
}
