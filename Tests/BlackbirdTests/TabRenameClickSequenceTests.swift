import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `TabStripView.isOwnDoubleClick(previous:pillIndex:
/// clickCount:timestamp:doubleClickInterval:)` — the pure predicate that
/// decides whether a `clickCount == 2` pill mousedown is the second half of
/// a double-click THIS STRIP SAW IN FULL.
///
/// Why the predicate exists (the bug it fixes): `NSEvent.clickCount` is a
/// property of the SYSTEM's click sequence, not of the view. AppKit keeps
/// counting across window and application activation boundaries and counts
/// clicks that were never delivered to the view at all. Two user-visible
/// consequences, each of which gets a dedicated test below:
///
///   1. Blackbird is not frontmost (or another Blackbird window is key).
///      The user clicks a pill: `acceptsFirstMouse` is false, so the click
///      only activates and `TabStripView` never sees it. Nothing appears to
///      happen, so the user clicks again — and THAT event carries
///      `clickCount == 2`, opening the rename field instead of selecting
///      the tab. Covered by the elapsed-beyond-interval cases (the stale
///      earlier click must not license a rename) and, in its purest form,
///      by the `previous == nil` case.
///   2. The user clicks pill B in window A's strip (window B becomes key),
///      then clicks again quickly. Window B's strip is a DIFFERENT view
///      instance that never saw a first click, but the event still carries
///      `clickCount == 2`. That view's `previous` mark is nil → must be
///      false. `test_nilPreviousMark_neverOwnDoubleClick`.
///
/// Why blind: a wrong-but-plausible implementation that simply returns
/// `clickCount == 2` passes every "genuine double-click renames" test. The
/// value here is entirely in the NEGATIVE cases — nil mark, foreign pill,
/// stale mark, non-monotonic timestamp — plus the two boundary cases that
/// pin `<=` vs `<` and `<` vs `>` on the elapsed comparison.
///
/// Memory + time budget (per `feedback_test_memory_safety`): the predicate
/// is pure and static. No `NSWindow`, no `NSEvent`, no view instances, no
/// PTYs, no `MainWindowController`. Each test allocates a handful of
/// three-field structs (< 1 KB total) and runs in microseconds.
final class TabRenameClickSequenceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// The system double-click interval used throughout. 0.5 is exactly
    /// representable in binary floating point, as are all the offsets
    /// below (0.25, 0.125, 0.5), so the boundary tests compare exact
    /// values — no epsilon slop can accidentally decide the outcome.
    private let interval: TimeInterval = 0.5

    /// An arbitrary non-zero base timestamp. Non-zero so a "timestamp
    /// before previous.timestamp" case can be expressed without going
    /// negative, and so an implementation that confuses `timestamp` with
    /// "elapsed since previous" is caught.
    private let base: TimeInterval = 100.0

    private func mark(pill: Int,
                      count: Int = 1,
                      at t: TimeInterval) -> TabStripView.ClickSequenceMark {
        TabStripView.ClickSequenceMark(pillIndex: pill,
                                       clickCount: count,
                                       timestamp: t)
    }

    /// The canonical "this strip saw the first click of the sequence on
    /// pill 1" mark: clickCount 1, at `base`.
    private var firstClickOnPill1: TabStripView.ClickSequenceMark {
        mark(pill: 1, count: 1, at: base)
    }

    // MARK: - clickCount must be exactly 2

    /// `clickCount == 1` is the FIRST click of a sequence — it selects a
    /// tab (or arms a drag); it never renames, even when a valid prior
    /// mark exists. An implementation using `clickCount >= 2` or
    /// `clickCount != 1`-style logic that leaked into the wrong branch
    /// dies here.
    func test_clickCountOne_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 1,
                timestamp: base + 0.125,
                doubleClickInterval: interval),
            "clickCount == 1 is the first click of a sequence — never a rename trigger")
    }

    /// `clickCount == 3` is the third click of a triple-click. The second
    /// click already entered rename (or was rejected); the third must not
    /// re-trigger. Only exactly 2 qualifies.
    func test_clickCountThree_isNotOwnDoubleClick() {
        // Model a real triple-click: the strip's last recorded mark is the
        // clickCount == 2 event of the same sequence, well inside the
        // interval. Still false — the predicate keys on exactly 2.
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 1, count: 2, at: base + 0.125),
                pillIndex: 1,
                clickCount: 3,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "clickCount == 3 (third click of a triple-click) must not re-enter rename")
    }

    /// `clickCount == 0` is what AppKit reports for synthesized /
    /// non-click mouse events (and for `NSEvent.mouseEvent` callers that
    /// pass 0). It is not a double-click.
    func test_clickCountZero_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 0,
                timestamp: base + 0.125,
                doubleClickInterval: interval),
            "clickCount == 0 (synthetic / non-click event) must not rename")
    }

    /// Sweep the whole neighbourhood: every clickCount except 2 is false,
    /// holding every other input at its most permissive (same pill, valid
    /// clickCount == 1 mark, elapsed well inside the interval). This pins
    /// "exactly 2", not "at least 2" and not "even".
    func test_onlyClickCountTwoQualifies() {
        for count in [-1, 0, 1, 3, 4, 5, 10] {
            XCTAssertFalse(
                TabStripView.isOwnDoubleClick(
                    previous: firstClickOnPill1,
                    pillIndex: 1,
                    clickCount: count,
                    timestamp: base + 0.125,
                    doubleClickInterval: interval),
                "clickCount == \(count) must not qualify; only exactly 2 does")
        }
        // Control: the same inputs with clickCount == 2 DO qualify, so the
        // loop above is rejecting on the count and not on some other input.
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval),
            "control: clickCount == 2 with an otherwise valid mark must qualify")
    }

    // MARK: - previous == nil (bug consequence 2)

    /// THE CROSS-WINDOW CASE. Window B's strip is a fresh view instance
    /// that never received a mousedown, so its mark is nil — but the
    /// system's click sequence, continued from window A's strip, still
    /// hands it `clickCount == 2`. Renaming here is exactly the reported
    /// bug.
    func test_nilPreviousMark_neverOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: nil,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base,
                doubleClickInterval: interval),
            "a strip that never received a mousedown must not treat an "
                + "inherited clickCount == 2 as its own double-click")
    }

    /// The nil-mark rejection cannot depend on the pill index or the
    /// timestamp — a brand-new strip has no history at any pill, at any
    /// time.
    func test_nilPreviousMark_falseForEveryPillAndTimestamp() {
        for pill in 0..<4 {
            for t in [0.0, base, base + interval, base + 10 * interval] {
                XCTAssertFalse(
                    TabStripView.isOwnDoubleClick(
                        previous: nil,
                        pillIndex: pill,
                        clickCount: 2,
                        timestamp: t,
                        doubleClickInterval: interval),
                    "nil mark at pill \(pill), t=\(t) must be false")
            }
        }
    }

    // MARK: - previous.clickCount must be 1

    /// The recorded mark must be the FIRST click of the same sequence. A
    /// mark whose own clickCount is 2 means the strip's last event was
    /// already a double-click's second half — a following `clickCount == 2`
    /// is therefore not the second half of a sequence this strip saw from
    /// the start.
    func test_previousMarkClickCountTwo_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 1, count: 2, at: base),
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval),
            "previous.clickCount == 2 is not the opening click of a sequence")
    }

    /// Same rejection for every non-1 recorded count, including the
    /// inherited-count values (2, 3) the system hands a strip that only
    /// caught the tail of a sequence.
    func test_previousMarkWithNonOneClickCount_isNotOwnDoubleClick() {
        for previousCount in [-1, 0, 2, 3, 4, 7] {
            XCTAssertFalse(
                TabStripView.isOwnDoubleClick(
                    previous: mark(pill: 1, count: previousCount, at: base),
                    pillIndex: 1,
                    clickCount: 2,
                    timestamp: base + 0.125,
                    doubleClickInterval: interval),
                "previous.clickCount == \(previousCount) must not license a rename; "
                    + "only a recorded first click (1) does")
        }
    }

    // MARK: - pill identity

    /// The first click must have landed on the SAME pill. Clicking pill 0
    /// then pill 2 in quick succession is two separate single clicks; the
    /// second must select pill 2, not rename it.
    func test_previousMarkOnDifferentPill_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 0, count: 1, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval),
            "a first click on pill 0 must not license a rename of pill 2")
    }

    /// Full same-pill / different-pill matrix over a small strip: TRUE on
    /// the diagonal, FALSE everywhere else, with time and counts held
    /// valid. Catches an implementation that forgot the pill comparison
    /// entirely (all-true) as well as one that compares the wrong pair.
    func test_pillIdentityMatrix_trueOnlyOnSamePill() {
        for markedPill in 0..<4 {
            for clickedPill in 0..<4 {
                let result = TabStripView.isOwnDoubleClick(
                    previous: mark(pill: markedPill, count: 1, at: base),
                    pillIndex: clickedPill,
                    clickCount: 2,
                    timestamp: base + 0.125,
                    doubleClickInterval: interval)
                XCTAssertEqual(
                    result, markedPill == clickedPill,
                    "mark on pill \(markedPill), click on pill \(clickedPill): "
                        + "expected \(markedPill == clickedPill)")
            }
        }
    }

    // MARK: - elapsed vs the double-click interval (bug consequence 1)

    /// THE ACTIVATION-CLICK CASE. Blackbird was in the background; the
    /// user's activating click was swallowed, they clicked again a beat
    /// later. Even if this strip happens to hold an old first-click mark
    /// on the same pill from some earlier interaction, it is far outside
    /// the double-click interval and must NOT license a rename.
    func test_elapsedBeyondInterval_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 5.0,          // 5 s later — ten intervals
                doubleClickInterval: interval),
            "a stale first-click mark (5 s old) must not license a rename")
    }

    /// One epsilon past the boundary is already too late. Pins the
    /// comparison as `elapsed <= interval` rather than something looser.
    func test_elapsedJustOverInterval_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + interval + 0.001,
                doubleClickInterval: interval),
            "elapsed just past the interval must not qualify")
    }

    /// Boundary is INCLUSIVE: elapsed exactly equal to the interval is a
    /// double-click. `base` (100.0) and `interval` (0.5) are both exactly
    /// representable, so `base + interval - base == interval` holds
    /// bit-exactly and this really is the boundary, not a near-miss.
    func test_elapsedExactlyAtInterval_isOwnDoubleClick() {
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + interval,
                doubleClickInterval: interval),
            "elapsed exactly == doubleClickInterval must qualify (inclusive boundary)")
    }

    /// The load-bearing positive case: a genuine, comfortably-fast
    /// double-click on one pill still opens rename. If this fails, the
    /// fix broke the feature.
    func test_genuineFastDoubleClick_isOwnDoubleClick() {
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 0.125,        // a quarter of the interval
                doubleClickInterval: interval),
            "a genuine double-click on one pill must still enter rename")
    }

    /// Zero elapsed: both events carry the same timestamp. Real AppKit
    /// events never do, but synthesized `NSEvent`s in tests routinely pass
    /// `timestamp: 0` for both halves of a gesture, and 0 elapsed is
    /// trivially inside any non-negative interval. Only a timestamp
    /// STRICTLY BEFORE the mark is rejected.
    func test_zeroElapsed_isOwnDoubleClick() {
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 1, count: 1, at: base),
                pillIndex: 1,
                clickCount: 2,
                timestamp: base,
                doubleClickInterval: interval),
            "identical timestamps are 0 elapsed — inside any interval, so qualifies")
    }

    /// The `doubleClickInterval` PARAMETER must actually be consulted:
    /// one fixed elapsed time flips the verdict when the interval moves
    /// around it. Catches an implementation that ignores the argument and
    /// reads `NSEvent.doubleClickInterval` (or a hardcoded constant)
    /// internally — which would make the predicate untestable and would
    /// silently ignore the user's system setting.
    func test_intervalParameterIsHonoured() {
        let elapsed: TimeInterval = 0.25
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + elapsed,
                doubleClickInterval: 1.0),
            "0.25 s elapsed is inside a 1.0 s interval → qualifies")
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + elapsed,
                doubleClickInterval: 0.125),
            "the same 0.25 s elapsed is outside a 0.125 s interval → rejected")
    }

    /// A zero interval admits only zero elapsed. Degenerate, but it pins
    /// the direction of the inclusive boundary at the extreme.
    func test_zeroInterval_admitsOnlyZeroElapsed() {
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 3, count: 1, at: base),
                pillIndex: 3,
                clickCount: 2,
                timestamp: base,
                doubleClickInterval: 0),
            "0 elapsed with a 0 interval is still inclusive → qualifies")
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 3, count: 1, at: base),
                pillIndex: 3,
                clickCount: 2,
                timestamp: base + 0.001,
                doubleClickInterval: 0),
            "any positive elapsed exceeds a 0 interval → rejected")
    }

    // MARK: - non-monotonic / stale marks

    /// A mousedown timestamped BEFORE the recorded mark cannot be that
    /// mark's follow-up. This is not hypothetical: `NSEvent` timestamps
    /// come from different sources across activation boundaries, and a
    /// synthesized or replayed event can land in the past. A naive
    /// `abs(timestamp - previous.timestamp) <= interval` would wrongly
    /// accept it.
    func test_timestampBeforeMark_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 1, count: 1, at: base),
                pillIndex: 1,
                clickCount: 2,
                timestamp: base - 0.125,        // 125 ms in the past
                doubleClickInterval: interval),
            "a mousedown earlier than the recorded mark cannot be its second click")
    }

    /// The backwards case must be rejected regardless of magnitude —
    /// including a backwards step far larger than the interval, and one
    /// barely under it (which `abs()`-style arithmetic would let through).
    func test_nonMonotonicTimestamps_rejectedAtEveryMagnitude() {
        for backwards in [0.001, 0.125, interval, interval + 0.001, 5.0, 60.0] {
            XCTAssertFalse(
                TabStripView.isOwnDoubleClick(
                    previous: mark(pill: 1, count: 1, at: base),
                    pillIndex: 1,
                    clickCount: 2,
                    timestamp: base - backwards,
                    doubleClickInterval: interval),
                "timestamp \(backwards) s BEFORE the mark must be rejected")
        }
    }

    /// A zero-timestamp click against a real-clock mark is the practical
    /// shape of the non-monotonic case (synthesized event vs. a mark taken
    /// from `NSEvent.timestamp`, which is uptime-based and large).
    func test_zeroTimestampAgainstUptimeMark_isNotOwnDoubleClick() {
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 0, count: 1, at: 123_456.75),
                pillIndex: 0,
                clickCount: 2,
                timestamp: 0,
                doubleClickInterval: interval),
            "t=0 against a large uptime-based mark is both stale and backwards")
    }

    // MARK: - one-failing-condition-at-a-time

    /// Take the fully-valid tuple and break exactly ONE condition at a
    /// time: every mutation must flip TRUE → FALSE. This is the compact
    /// statement of the whole contract, and it fails loudly against an
    /// implementation that dropped any single clause (e.g. checks the
    /// interval but forgot the pill, or vice versa).
    func test_eachConditionIsIndividuallyNecessary() {
        // Valid baseline.
        XCTAssertTrue(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 2, count: 1, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "baseline tuple must be a valid own-double-click")

        // 1. no recorded mark
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: nil,
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "breaking only `previous != nil` must flip the verdict")

        // 2. mark's own count is not 1
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 2, count: 2, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "breaking only `previous.clickCount == 1` must flip the verdict")

        // 3. mark is on another pill
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 3, count: 1, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "breaking only the pill match must flip the verdict")

        // 4. this event isn't a second click
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 2, count: 1, at: base),
                pillIndex: 2,
                clickCount: 1,
                timestamp: base + 0.25,
                doubleClickInterval: interval),
            "breaking only `clickCount == 2` must flip the verdict")

        // 5. too much time elapsed
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 2, count: 1, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base + interval + 0.25,
                doubleClickInterval: interval),
            "breaking only the elapsed bound must flip the verdict")

        // 6. time ran backwards
        XCTAssertFalse(
            TabStripView.isOwnDoubleClick(
                previous: mark(pill: 2, count: 1, at: base),
                pillIndex: 2,
                clickCount: 2,
                timestamp: base - 0.25,
                doubleClickInterval: interval),
            "breaking only monotonicity must flip the verdict")
    }

    // MARK: - ClickSequenceMark value semantics

    /// The mark is a value type recording ONE mousedown this strip
    /// actually received; its `Equatable` conformance is part of the
    /// committed contract (the strip compares marks, and tests below rely
    /// on field-wise equality). Assert equality field by field rather
    /// than merely constructing one.
    func test_clickSequenceMark_equalsFieldWise() {
        let a = TabStripView.ClickSequenceMark(pillIndex: 1,
                                               clickCount: 1,
                                               timestamp: base)
        let same = TabStripView.ClickSequenceMark(pillIndex: 1,
                                                  clickCount: 1,
                                                  timestamp: base)
        XCTAssertEqual(a, same, "identical field values must compare equal")

        XCTAssertNotEqual(
            a,
            TabStripView.ClickSequenceMark(pillIndex: 2,
                                           clickCount: 1,
                                           timestamp: base),
            "a different pillIndex must compare unequal")
        XCTAssertNotEqual(
            a,
            TabStripView.ClickSequenceMark(pillIndex: 1,
                                           clickCount: 2,
                                           timestamp: base),
            "a different clickCount must compare unequal")
        XCTAssertNotEqual(
            a,
            TabStripView.ClickSequenceMark(pillIndex: 1,
                                           clickCount: 1,
                                           timestamp: base + 0.25),
            "a different timestamp must compare unequal")

        // The stored fields are readable and hold exactly what was passed
        // in — the strip's record of the mousedown it received.
        XCTAssertEqual(a.pillIndex, 1)
        XCTAssertEqual(a.clickCount, 1)
        XCTAssertEqual(a.timestamp, base, accuracy: 0)
    }

    // MARK: - purity

    /// The predicate is static and pure: same inputs, same answer, no
    /// hidden state accumulating across calls (a first-call-only latch
    /// would be a real hazard given the strip evaluates this on every
    /// mousedown).
    func test_predicateIsPure_repeatedCallsAgree() {
        var trues = 0
        var falses = 0
        for _ in 0..<8 {
            if TabStripView.isOwnDoubleClick(
                previous: firstClickOnPill1,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval) {
                trues += 1
            }
            if TabStripView.isOwnDoubleClick(
                previous: nil,
                pillIndex: 1,
                clickCount: 2,
                timestamp: base + 0.125,
                doubleClickInterval: interval) {
                falses += 1
            }
        }
        XCTAssertEqual(trues, 8, "the valid tuple must answer true on every call")
        XCTAssertEqual(falses, 0, "the nil-mark tuple must answer false on every call")
    }
}
