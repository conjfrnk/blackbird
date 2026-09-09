import XCTest
@testable import Blackbird

/// Blind behaviour tests for `TerminalNotification`, `AttentionPolicy`
/// and `NotificationPresenter`, written from the spec without sight of
/// the implementation.
///
/// Contract:
///   - `TerminalNotification` is a value type with `title` / `body`,
///     `Equatable` on both.
///   - `AttentionPolicy.needsAttention(appActive:windowKey:tabSelected:)`
///     is `false` only when all three inputs are `true`.
///   - `NotificationPresenter(systemCenterAvailable: false)` records every
///     `post` in `posted`, in order, capped at the 64 most recent, and
///     never touches `UNUserNotificationCenter` (which would crash the
///     unsigned xctest host — a clean run is the observable).
///   - `NotificationPresenter()` in the test host reports
///     `isSystemCenterAvailable == false`.
///
/// Pre-flight: no windows, no PTY, ≤ 70 tiny structs per test. < 10 ms.
final class NotificationPresenterBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - TerminalNotification

    func test_terminalNotification_storesTitleAndBody() {
        let n = TerminalNotification(title: "Deploy", body: "done in 3s")
        XCTAssertEqual(n.title, "Deploy")
        XCTAssertEqual(n.body, "done in 3s")
    }

    func test_terminalNotification_equatable_onBothFields() {
        let a = TerminalNotification(title: "T", body: "B")
        XCTAssertEqual(a, TerminalNotification(title: "T", body: "B"))
        XCTAssertNotEqual(a, TerminalNotification(title: "T2", body: "B"),
                          "title must participate in equality")
        XCTAssertNotEqual(a, TerminalNotification(title: "T", body: "B2"),
                          "body must participate in equality")
    }

    // MARK: - AttentionPolicy

    /// Enumerates all 8 combinations: attention is needed unless the app
    /// is active AND the window is key AND the tab is selected.
    func test_needsAttention_falseOnlyWhenAllThreeTrue() {
        for appActive in [false, true] {
            for windowKey in [false, true] {
                for tabSelected in [false, true] {
                    let expected = !(appActive && windowKey && tabSelected)
                    XCTAssertEqual(
                        AttentionPolicy.needsAttention(
                            appActive: appActive,
                            windowKey: windowKey,
                            tabSelected: tabSelected
                        ),
                        expected,
                        "appActive=\(appActive) windowKey=\(windowKey) "
                        + "tabSelected=\(tabSelected) → expected \(expected)"
                    )
                }
            }
        }
    }

    func test_needsAttention_allTrue_isFalse() {
        XCTAssertFalse(AttentionPolicy.needsAttention(
            appActive: true, windowKey: true, tabSelected: true))
    }

    func test_needsAttention_anySingleFalse_isTrue() {
        XCTAssertTrue(AttentionPolicy.needsAttention(
            appActive: false, windowKey: true, tabSelected: true))
        XCTAssertTrue(AttentionPolicy.needsAttention(
            appActive: true, windowKey: false, tabSelected: true))
        XCTAssertTrue(AttentionPolicy.needsAttention(
            appActive: true, windowKey: true, tabSelected: false))
    }

    // MARK: - NotificationPresenter

    func test_presenter_withoutSystemCenter_recordsPostsInOrder() {
        let presenter = NotificationPresenter(systemCenterAvailable: false)
        XCTAssertFalse(presenter.isSystemCenterAvailable)
        XCTAssertTrue(presenter.posted.isEmpty, "fresh presenter has nothing posted")

        let first = TerminalNotification(title: "one", body: "1")
        let second = TerminalNotification(title: "two", body: "2")
        let third = TerminalNotification(title: "", body: "3")
        presenter.post(first)
        presenter.post(second)
        presenter.post(third)

        XCTAssertEqual(presenter.posted, [first, second, third],
                       "posted must preserve insertion order")
    }

    func test_presenter_postedIsCappedAt64_keepingTheMostRecent() {
        let presenter = NotificationPresenter(systemCenterAvailable: false)
        let all = (1...70).map {
            TerminalNotification(title: "t\($0)", body: "b\($0)")
        }
        for n in all { presenter.post(n) }

        XCTAssertEqual(presenter.posted.count, 64,
                       "posted must be capped at 64 entries")
        // 70 posted, 64 kept → the oldest 6 dropped; first kept is #7.
        XCTAssertEqual(presenter.posted.first, all[6],
                       "the first kept entry must be the 7th posted")
        XCTAssertEqual(presenter.posted.last, all[69],
                       "the most recent post must always be kept")
        XCTAssertEqual(presenter.posted, Array(all[6...]),
                       "the cap must drop from the front, preserving order")
    }

    func test_presenter_exactly64Posts_dropsNothing() {
        let presenter = NotificationPresenter(systemCenterAvailable: false)
        let all = (1...64).map {
            TerminalNotification(title: "t\($0)", body: "b\($0)")
        }
        for n in all { presenter.post(n) }
        XCTAssertEqual(presenter.posted, all)
    }

    func test_presenter_resetForTests_emptiesPosted() {
        let presenter = NotificationPresenter(systemCenterAvailable: false)
        presenter.post(TerminalNotification(title: "x", body: "y"))
        XCTAssertEqual(presenter.posted.count, 1)
        presenter._resetForTests()
        XCTAssertTrue(presenter.posted.isEmpty)
        // Still usable after a reset.
        presenter.post(TerminalNotification(title: "a", body: "b"))
        XCTAssertEqual(presenter.posted, [TerminalNotification(title: "a", body: "b")])
    }

    func test_presenter_defaultInit_reportsNoSystemCenterInTestHost() {
        // The xctest host is not a signed app bundle; the presenter must
        // detect that and never route to UNUserNotificationCenter.
        let presenter = NotificationPresenter()
        XCTAssertFalse(presenter.isSystemCenterAvailable,
                       "xctest host must never be treated as having the system center")
        // And posting through it must be safe (recorded, not forwarded).
        let n = TerminalNotification(title: "host", body: "safe")
        presenter.post(n)
        XCTAssertEqual(presenter.posted, [n])
    }

    func test_presenter_explicitTrueOverride_isHonoredAsAFlag() {
        // Only checks the flag plumbing — we never post through a
        // presenter that claims the system center, since the xctest host
        // has no bundle proxy for UNUserNotificationCenter.
        let presenter = NotificationPresenter(systemCenterAvailable: true)
        XCTAssertTrue(presenter.isSystemCenterAvailable)
    }
}
