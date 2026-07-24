import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `TerminalView.effectiveClickCount(previous:clickCount:
/// timestamp:doubleClickInterval:)` — the pure function that RENUMBERS a
/// mousedown's click count into the ordinal it holds within the run of
/// mousedowns THIS VIEW actually received.
///
/// Why the function exists (BUG-3, the terminal-body twin of the tab-strip
/// rename bug): `NSEvent.clickCount` counts the SYSTEM's click sequence, not
/// the view's. No view in `Sources/` overrides `acceptsFirstMouse`, so when
/// Blackbird isn't frontmost the click that reactivates it is consumed by
/// AppKit and `TerminalView` never receives a mousedown for it — yet the
/// window server keeps counting. The consequences the selection gesture
/// classifier (`SelectionController`: 3 → `.line`, 2 → `.word`, else
/// `.character`/`.rectangular`) then gets wrong:
///
///   1. The user returns to Blackbird with one click in the terminal body
///      (swallowed), then clicks once more to place focus. That delivered
///      event carries `clickCount == 2` → a WORD is selected from a single
///      delivered click.
///   2. Worse and likelier: the user returns with one click (swallowed) and
///      then genuinely double-clicks. The two delivered events carry
///      `clickCount` 2 and 3 → a WHOLE LINE is selected instead of a word.
///
/// Renumbering (rather than a boolean gate as in `TabStripView`) is what lets
/// case 2 still produce a word: the view's own ordinal for that gesture's
/// second delivered click is 2, not 3.
///
/// Why blind: a wrong-but-plausible implementation that returns `clickCount`
/// untouched passes every "a genuine double-click still selects a word" test.
/// All the value is in the phantom-prefixed sequences (worked sequences 3–5
/// below), the sequence-gap and timing rejections, and the fact that a
/// continuation counts from `previous.effectiveClickCount` — the view's own
/// numbering — rather than from the system count.
///
/// Contract under test:
///   - `clickCount <= 1` → returned unchanged (1 stays 1; 0 and negative
///     synthesized values pass through untouched, so no caller ever sees a
///     value the system never produced).
///   - `clickCount >= 2` AND `previous != nil` AND
///     `previous.systemClickCount == clickCount - 1` AND
///     `0 <= (timestamp - previous.timestamp) <= doubleClickInterval`
///     → `previous.effectiveClickCount + 1` (this event continues a run this
///     view has been tracking).
///   - otherwise → 1 (as far as this view is concerned, a new gesture).
///
/// Memory + time budget (`feedback_test_memory_safety`): the function is
/// static and pure. No `TerminalView` instances, no Metal device, no
/// `NSEvent`s, no `NSWindow`s, no PTYs, no `TerminalSession`, no
/// `MainWindowController`. Every test allocates a handful of three-field
/// structs (< 1 KB total) and runs in microseconds.
final class TerminalClickSequenceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// The double-click interval used throughout. 0.5 is exactly
    /// representable in binary floating point, as are the offsets used in the
    /// boundary tests (0.125, 0.25, 0.5), so `base + interval - base ==
    /// interval` holds bit-exactly and the boundary cases really sit ON the
    /// boundary rather than an epsilon to one side.
    private let interval: TimeInterval = 0.5

    /// An arbitrary non-zero base timestamp, shaped like the uptime-based
    /// values `NSEvent.timestamp` reports. Non-zero so a "timestamp before
    /// the mark" case can be expressed without going negative, and so an
    /// implementation that confuses `timestamp` with "elapsed since previous"
    /// is caught.
    private let base: TimeInterval = 100.0

    private func mark(sys: Int,
                      eff: Int,
                      at t: TimeInterval) -> TerminalView.ClickSequenceMark {
        TerminalView.ClickSequenceMark(systemClickCount: sys,
                                       effectiveClickCount: eff,
                                       timestamp: t)
    }

    /// Replay a run of mousedowns THIS VIEW receives, exactly as the
    /// production call site does it: classify with the previous mark, then
    /// record a new mark carrying the raw system count, the count this view
    /// just assigned, and the event timestamp.
    ///
    /// - Parameter events: `(sys:, at:)` pairs — the `NSEvent.clickCount` and
    ///   `NSEvent.timestamp` of each mousedown the view is DELIVERED. Clicks
    ///   the window server counted but never delivered simply don't appear.
    /// - Returns: the effective (renumbered) count for each delivered event.
    private func deliver(_ events: [(sys: Int, at: TimeInterval)],
                         interval: TimeInterval) -> [Int] {
        var previous: TerminalView.ClickSequenceMark?
        var effective: [Int] = []
        for event in events {
            let count = TerminalView.effectiveClickCount(
                previous: previous,
                clickCount: event.sys,
                timestamp: event.at,
                doubleClickInterval: interval)
            effective.append(count)
            previous = TerminalView.ClickSequenceMark(
                systemClickCount: event.sys,
                effectiveClickCount: count,
                timestamp: event.at)
        }
        return effective
    }

    // MARK: - clickCount <= 1 passes through untouched

    /// A first click is a first click. `1` must come back as `1` whether or
    /// not the view holds a mark — and specifically must NOT be renumbered
    /// off a mark that happens to look like a continuation (`systemClickCount
    /// == 0 == clickCount - 1`), which would hand the classifier a word- or
    /// line-mode count for the opening click of a gesture.
    func test_clickCountOne_passesThroughUnchanged() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: nil,
                                             clickCount: 1,
                                             timestamp: base,
                                             doubleClickInterval: interval),
            1,
            "the first delivered click of a gesture is 1 → character mode")

        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 0, eff: 4, at: base),
                                             clickCount: 1,
                                             timestamp: base + 0.125,
                                             doubleClickInterval: interval),
            1,
            "clickCount == 1 short-circuits before any continuation arithmetic; "
                + "a mark with systemClickCount == 0 must not renumber it to 5")
    }

    /// `clickCount == 0` is what AppKit reports for synthesized and
    /// non-click mouse events (and what `NSEvent.mouseEvent` callers pass by
    /// default). It must survive untouched — neither promoted to 1 nor
    /// renumbered off a mark whose `systemClickCount` is -1.
    func test_clickCountZero_passesThroughUnchanged() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: nil,
                                             clickCount: 0,
                                             timestamp: base,
                                             doubleClickInterval: interval),
            0,
            "a synthetic 0 must pass through, not be normalised to 1")

        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: -1, eff: 7, at: base),
                                             clickCount: 0,
                                             timestamp: base + 0.125,
                                             doubleClickInterval: interval),
            0,
            "the <= 1 passthrough is checked first: a mark with "
                + "systemClickCount == -1 must not renumber a 0 to 8")
    }

    /// Negative counts can only come from a synthesized event; they pass
    /// through so no caller ever observes a value the system never produced.
    /// An implementation written as `max(1, clickCount)` dies here.
    func test_negativeClickCounts_passThroughUnchanged() {
        for count in [-1, -2, -3, -100] {
            XCTAssertEqual(
                TerminalView.effectiveClickCount(previous: nil,
                                                 clickCount: count,
                                                 timestamp: base,
                                                 doubleClickInterval: interval),
                count,
                "clickCount \(count) with no mark must pass through unchanged")
            XCTAssertEqual(
                TerminalView.effectiveClickCount(
                    previous: mark(sys: count - 1, eff: 2, at: base),
                    clickCount: count,
                    timestamp: base + 0.125,
                    doubleClickInterval: interval),
                count,
                "clickCount \(count) must pass through even when the mark "
                    + "forms an apparent continuation")
        }
    }

    // MARK: - Worked sequence 1 & 2: nothing was swallowed

    /// Worked sequence 1. Blackbird is already frontmost, the user
    /// double-clicks a word: the view receives system counts 1 then 2 inside
    /// the interval. Effective counts stay 1 then 2 → `.character` then
    /// `.word`. Word selection must survive the fix.
    func test_worked1_genuineDoubleClick_bothDelivered_keepsWordCount() {
        XCTAssertEqual(
            deliver([(sys: 1, at: base), (sys: 2, at: base + 0.1)],
                    interval: interval),
            [1, 2],
            "a double-click this view saw in full must still classify as 2 (word)")
    }

    /// Worked sequence 2. Genuine triple-click, all three delivered: 1, 2, 3
    /// → `.character`, `.word`, `.line`. Line selection must survive.
    func test_worked2_genuineTripleClick_bothDelivered_keepsLineCount() {
        XCTAssertEqual(
            deliver([(sys: 1, at: base),
                     (sys: 2, at: base + 0.1),
                     (sys: 3, at: base + 0.2)],
                    interval: interval),
            [1, 2, 3],
            "a triple-click this view saw in full must still classify as 3 (line)")
    }

    /// A longer uninterrupted run keeps counting up in lockstep — the
    /// renumbering adds no cap or wrap of its own for a run this view saw
    /// from the start.
    func test_longUninterruptedRun_numbersEveryDeliveredClickInOrder() {
        let events = (1...6).map { (sys: $0, at: base + Double($0) * 0.1) }
        XCTAssertEqual(deliver(events, interval: interval), [1, 2, 3, 4, 5, 6],
                       "an unbroken delivered run is renumbered to itself")
    }

    // MARK: - Worked sequence 3: the phantom activation click

    /// Worked sequence 3. Blackbird was in the background; the activating
    /// click was swallowed by AppKit, so the FIRST event this view ever
    /// receives carries `clickCount == 2`. With no mark to continue, this is
    /// the view's first click → 1 → `.character`. Pre-fix it selected a WORD
    /// from a single delivered click.
    func test_worked3_phantomSingleClick_firstDeliveredEventIsSystemTwo() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: nil,
                                             clickCount: 2,
                                             timestamp: base,
                                             doubleClickInterval: interval),
            1,
            "a clickCount == 2 with no mark is this view's first click → "
                + "character mode, not word")
    }

    /// The nil-mark rejection can't depend on how far the system's count had
    /// run, nor on the timestamp: a view with no history has no run to
    /// continue at any count, at any time.
    func test_nilPreviousMark_alwaysRestartsAtOne() {
        for count in [2, 3, 4, 5, 9] {
            for t in [0.0, base, base + interval, base + 10 * interval] {
                XCTAssertEqual(
                    TerminalView.effectiveClickCount(previous: nil,
                                                     clickCount: count,
                                                     timestamp: t,
                                                     doubleClickInterval: interval),
                    1,
                    "no mark, clickCount \(count) at t=\(t) → 1")
            }
        }
    }

    // MARK: - Worked sequence 4 & 5: phantom, then a genuine gesture

    /// Worked sequence 4 — THE CASE THE CURRENT CODE GETS WRONG. The
    /// activation click was swallowed; the user then genuinely double-clicks.
    /// The view is delivered system counts 2 and 3. Renumbered they are 1 and
    /// 2, so the user gets a WORD. Trusting the raw counter yielded 3 → a
    /// whole-line selection (fired even on a blank line, since line expansion
    /// is unconditional).
    func test_worked4_phantomThenGenuineDoubleClick_selectsWordNotLine() {
        let effective = deliver([(sys: 2, at: base), (sys: 3, at: base + 0.1)],
                                interval: interval)
        XCTAssertEqual(
            effective, [1, 2],
            "after a swallowed activation click, a genuine double-click must "
                + "renumber to 1 then 2 (word); raw counts 2,3 would select a line")
        XCTAssertNotEqual(effective[1], 3,
                          "the second delivered click must never classify as line")
    }

    /// Worked sequence 5. Same swallowed activation click, but the user
    /// triple-clicks: delivered system counts 2, 3, 4 renumber to 1, 2, 3 —
    /// the line selection the user actually asked for.
    func test_worked5_phantomThenGenuineTripleClick_selectsLine() {
        XCTAssertEqual(
            deliver([(sys: 2, at: base),
                     (sys: 3, at: base + 0.1),
                     (sys: 4, at: base + 0.2)],
                    interval: interval),
            [1, 2, 3],
            "a triple-click after a swallowed activation click must reach 3 (line)")
    }

    /// Two swallowed clicks (app activation plus a window-activation click,
    /// say) shift the system counter further still. The view's numbering is
    /// unaffected: it counts what it saw.
    func test_twoSwallowedClicks_thenGenuineDoubleClick_stillSelectsWord() {
        XCTAssertEqual(
            deliver([(sys: 3, at: base), (sys: 4, at: base + 0.1)],
                    interval: interval),
            [1, 2],
            "the view's numbering is independent of where the system's count started")
    }

    // MARK: - Worked sequence 6: the system sequence must step by exactly one

    /// Worked sequence 6. The mark says the view last saw system count 1, but
    /// the incoming event says 3 — the system counted a click this view never
    /// received, so the run is broken. Restart at 1.
    func test_worked6_gapInSystemSequence_restartsAtOne() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 3,
                                             timestamp: base + 0.1,
                                             doubleClickInterval: interval),
            1,
            "a skipped system count means a click this view never saw → new gesture")
    }

    /// Sweep the neighbourhood of the mark's system count with everything
    /// else held valid: only `previous.systemClickCount + 1` continues the
    /// run; every other incoming count restarts at 1. Pins "exactly one
    /// step", not "at least one step" and not "any later count".
    func test_onlyAnExactSystemSequenceStepContinuesTheRun() {
        let previous = mark(sys: 3, eff: 2, at: base)
        for count in [2, 3, 5, 6, 10] {
            XCTAssertEqual(
                TerminalView.effectiveClickCount(previous: previous,
                                                 clickCount: count,
                                                 timestamp: base + 0.125,
                                                 doubleClickInterval: interval),
                1,
                "mark systemClickCount 3, incoming \(count): not a one-step "
                    + "continuation → 1")
        }
        // Control: the one value that DOES continue the run, proving the loop
        // above rejects on the sequence step and not on some other input.
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: previous,
                                             clickCount: 4,
                                             timestamp: base + 0.125,
                                             doubleClickInterval: interval),
            3,
            "control: systemClickCount 3 → incoming 4 continues the run to 3")
    }

    /// A repeat of the same system count (two events reporting `clickCount
    /// == 2`) is not a continuation either — it would double-count the
    /// gesture and turn a word selection into a line selection.
    func test_repeatedSystemCount_restartsAtOne() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 2, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + 0.1,
                                             doubleClickInterval: interval),
            1,
            "the same system count twice is not a step forward in the sequence")
    }

    // MARK: - Worked sequences 7–9: timing

    /// Worked sequence 7. The mark is a valid one-step predecessor but far
    /// too old: the user clicked once, went away, came back and clicked
    /// again. Two gestures, not one.
    func test_worked7_elapsedBeyondInterval_restartsAtOne() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + 5.0,   // ten intervals
                                             doubleClickInterval: interval),
            1,
            "a 5 s old mark cannot be the first half of this gesture")
    }

    /// One millisecond past the boundary is already too late — pins the
    /// comparison at `elapsed <= interval` rather than something looser.
    func test_elapsedJustOverInterval_restartsAtOne() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + interval + 0.001,
                                             doubleClickInterval: interval),
            1,
            "elapsed just past the interval must start a new gesture")
    }

    /// Worked sequence 8. The boundary is INCLUSIVE, matching
    /// `TabStripView.isOwnDoubleClick`. `base` (100.0) and `interval` (0.5)
    /// are both exactly representable, so this really is the boundary.
    func test_worked8_elapsedExactlyAtInterval_continuesRun() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + interval,
                                             doubleClickInterval: interval),
            2,
            "elapsed exactly == doubleClickInterval continues the run (inclusive)")
    }

    /// Zero elapsed: both events carry the same timestamp. Real AppKit events
    /// never do, but synthesized `NSEvent`s in tests routinely pass
    /// `timestamp: 0` for a whole gesture, and 0 is inside any non-negative
    /// interval. Only a STRICTLY earlier timestamp is rejected.
    func test_zeroElapsed_continuesRun() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base,
                                             doubleClickInterval: interval),
            2,
            "identical timestamps are 0 elapsed — inside any interval")
    }

    /// Worked sequence 9. A mousedown timestamped BEFORE the mark cannot be
    /// that mark's follow-up. Rejected at every magnitude, including
    /// backwards steps smaller than the interval — which an
    /// `abs(timestamp - previous.timestamp) <= interval` implementation would
    /// wrongly accept.
    func test_worked9_negativeElapsed_restartsAtOne() {
        for backwards in [0.001, 0.125, interval, interval + 0.001, 5.0, 60.0] {
            XCTAssertEqual(
                TerminalView.effectiveClickCount(
                    previous: mark(sys: 1, eff: 1, at: base),
                    clickCount: 2,
                    timestamp: base - backwards,
                    doubleClickInterval: interval),
                1,
                "a mousedown \(backwards) s BEFORE the mark is not its second click")
        }
    }

    /// The practical shape of the backwards case: a `timestamp: 0`
    /// synthesized event measured against a mark taken from the real,
    /// uptime-based `NSEvent.timestamp` clock.
    func test_zeroTimestampAgainstUptimeMark_restartsAtOne() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(
                previous: mark(sys: 1, eff: 1, at: 123_456.75),
                clickCount: 2,
                timestamp: 0,
                doubleClickInterval: interval),
            1,
            "t=0 against a large uptime mark is both stale and backwards")
    }

    /// Worked sequence 10. The `doubleClickInterval` PARAMETER must actually
    /// be consulted: one fixed elapsed time flips the verdict as the interval
    /// moves around it. Catches an implementation that ignores the argument
    /// and reads `NSEvent.doubleClickInterval` (or a hardcoded constant)
    /// internally — which would silently ignore the user's system setting and
    /// make the function untestable.
    func test_worked10_doubleClickIntervalParameterIsHonoured() {
        let elapsed: TimeInterval = 0.25
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + elapsed,
                                             doubleClickInterval: 1.0),
            2,
            "0.25 s elapsed is inside a 1.0 s interval → continues the run")
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + elapsed,
                                             doubleClickInterval: 0.125),
            1,
            "the same 0.25 s elapsed is outside a 0.125 s interval → new gesture")
    }

    /// A zero interval admits only zero elapsed. Degenerate, but it pins the
    /// direction of the inclusive boundary at the extreme.
    func test_zeroInterval_admitsOnlyZeroElapsed() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base,
                                             doubleClickInterval: 0),
            2,
            "0 elapsed against a 0 interval is still inclusive → continues")
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 2,
                                             timestamp: base + 0.001,
                                             doubleClickInterval: 0),
            1,
            "any positive elapsed exceeds a 0 interval → new gesture")
    }

    // MARK: - The run is numbered by the VIEW's count, not the system's

    /// The continuation adds one to `previous.effectiveClickCount` — the
    /// view's own numbering — and never to the raw system count. With a mark
    /// of `{sys: 7, eff: 2}` and an incoming system count of 8, the answer is
    /// 3. An implementation that returned `clickCount` (8) or restarted (1)
    /// fails here; so does one that compared `previous.effectiveClickCount`
    /// rather than `previous.systemClickCount` against `clickCount - 1`.
    func test_continuationCountsFromPreviousEffectiveCount_notTheSystemCount() {
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 7, eff: 2, at: base),
                                             clickCount: 8,
                                             timestamp: base + 0.125,
                                             doubleClickInterval: interval),
            3,
            "a continuation is previous.effectiveClickCount + 1 (2 + 1), not the "
                + "system's 8 and not a restart")
    }

    /// The two counts on the mark are genuinely independent inputs: holding
    /// the system step valid and sliding `effectiveClickCount` moves the
    /// answer in lockstep.
    func test_effectiveCountOnMarkDrivesTheReturnedOrdinal() {
        for previousEffective in 1...4 {
            XCTAssertEqual(
                TerminalView.effectiveClickCount(
                    previous: mark(sys: 5, eff: previousEffective, at: base),
                    clickCount: 6,
                    timestamp: base + 0.125,
                    doubleClickInterval: interval),
                previousEffective + 1,
                "mark effectiveClickCount \(previousEffective) → "
                    + "\(previousEffective + 1)")
        }
    }

    // MARK: - Each condition is individually necessary

    /// Take the fully-valid continuation tuple and break exactly ONE
    /// condition at a time: every mutation must collapse the answer to 1.
    /// The compact statement of the whole contract — it fails loudly against
    /// an implementation that dropped any single clause.
    func test_eachContinuationConditionIsIndividuallyNecessary() {
        // Valid baseline: mark {sys 2, eff 1}, incoming system 3, 0.25 s later.
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 2, eff: 1, at: base),
                                             clickCount: 3,
                                             timestamp: base + 0.25,
                                             doubleClickInterval: interval),
            2,
            "baseline tuple must continue the run to 2")

        // 1. no mark at all
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: nil,
                                             clickCount: 3,
                                             timestamp: base + 0.25,
                                             doubleClickInterval: interval),
            1,
            "breaking only `previous != nil` must collapse to 1")

        // 2. the system sequence skipped a click this view never saw
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 1, eff: 1, at: base),
                                             clickCount: 3,
                                             timestamp: base + 0.25,
                                             doubleClickInterval: interval),
            1,
            "breaking only `previous.systemClickCount == clickCount - 1` must "
                + "collapse to 1")

        // 3. too much time elapsed
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 2, eff: 1, at: base),
                                             clickCount: 3,
                                             timestamp: base + interval + 0.25,
                                             doubleClickInterval: interval),
            1,
            "breaking only the elapsed bound must collapse to 1")

        // 4. time ran backwards
        XCTAssertEqual(
            TerminalView.effectiveClickCount(previous: mark(sys: 2, eff: 1, at: base),
                                             clickCount: 3,
                                             timestamp: base - 0.25,
                                             doubleClickInterval: interval),
            1,
            "breaking only monotonicity must collapse to 1")
    }

    // MARK: - Recovery: a broken run doesn't poison the next gesture

    /// A stale or broken run must reset cleanly, not latch. Here: a genuine
    /// double-click, a long pause during which the window server keeps
    /// counting, then another genuine double-click. The stale event restarts
    /// the view's numbering at 1 and the click after it continues from that
    /// new first click — so the second gesture is a word, not a run-on.
    func test_staleEventRestartsTheRun_andTheNextClickContinuesFromIt() {
        XCTAssertEqual(
            deliver([(sys: 1, at: base),
                     (sys: 2, at: base + 0.1),
                     (sys: 3, at: base + 5.0),      // long pause — stale
                     (sys: 4, at: base + 5.1)],
                    interval: interval),
            [1, 2, 1, 2],
            "the stale click opens a new gesture and the one after it becomes "
                + "that gesture's second click (word), not a fourth")
    }

    /// A phantom activation click must not poison the bookkeeping either: the
    /// very next genuine double-click, delivered in full, still numbers 1
    /// then 2. This is what separates "renumber to what this view saw" from
    /// "click classification is broken after any stray count".
    func test_phantomClick_thenAFullyDeliveredDoubleClick_stillSelectsWord() {
        XCTAssertEqual(
            deliver([(sys: 2, at: base),           // phantom-prefixed single click
                     (sys: 1, at: base + 5.0),     // system counter reset; new gesture
                     (sys: 2, at: base + 5.1)],
                    interval: interval),
            [1, 1, 2],
            "after the phantom click, a fresh fully-delivered double-click "
                + "still reaches 2 (word)")
    }

    // MARK: - Purity

    /// The function is static and pure: same inputs, same answer, with no
    /// hidden state accumulating across calls (a first-call-only latch would
    /// be a real hazard — the view evaluates this on every mousedown).
    func test_functionIsPure_repeatedCallsAgree() {
        var continued: [Int] = []
        var restarted: [Int] = []
        for _ in 0..<8 {
            continued.append(TerminalView.effectiveClickCount(
                previous: mark(sys: 1, eff: 1, at: base),
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval))
            restarted.append(TerminalView.effectiveClickCount(
                previous: nil,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval))
        }
        XCTAssertEqual(continued, Array(repeating: 2, count: 8),
                       "the valid continuation must answer 2 on every call")
        XCTAssertEqual(restarted, Array(repeating: 1, count: 8),
                       "the nil-mark tuple must answer 1 on every call")
    }

    // MARK: - ClickSequenceMark value semantics

    /// The mark records ONE mousedown this view actually received: the raw
    /// system count, the count this view assigned it, and when. Its
    /// `Equatable` conformance is part of the committed contract, and the two
    /// counts must be separately stored — a mark that collapsed them could
    /// not express the phantom case (`{sys: 2, eff: 1}`) at all.
    func test_clickSequenceMark_storesBothCountsAndComparesFieldWise() {
        let a = TerminalView.ClickSequenceMark(systemClickCount: 2,
                                               effectiveClickCount: 1,
                                               timestamp: base)
        XCTAssertEqual(a.systemClickCount, 2, "the raw NSEvent.clickCount is kept")
        XCTAssertEqual(a.effectiveClickCount, 1, "…alongside this view's own count")
        XCTAssertEqual(a.timestamp, base, accuracy: 0)

        XCTAssertEqual(
            a,
            TerminalView.ClickSequenceMark(systemClickCount: 2,
                                           effectiveClickCount: 1,
                                           timestamp: base),
            "identical field values must compare equal")
        XCTAssertNotEqual(
            a,
            TerminalView.ClickSequenceMark(systemClickCount: 3,
                                           effectiveClickCount: 1,
                                           timestamp: base),
            "a different systemClickCount must compare unequal")
        XCTAssertNotEqual(
            a,
            TerminalView.ClickSequenceMark(systemClickCount: 2,
                                           effectiveClickCount: 2,
                                           timestamp: base),
            "a different effectiveClickCount must compare unequal")
        XCTAssertNotEqual(
            a,
            TerminalView.ClickSequenceMark(systemClickCount: 2,
                                           effectiveClickCount: 1,
                                           timestamp: base + 0.25),
            "a different timestamp must compare unequal")
    }
}
