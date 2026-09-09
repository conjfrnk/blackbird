import XCTest
import Combine
@testable import Blackbird
@testable import BBCore

/// Blind behaviour tests for the Swift-side delivery of program
/// notifications (OSC 9 / 777 / 99), written from the spec without sight
/// of the implementation.
///
/// Contract:
///   - `BBTerm.Event.notification(title:body:)` decodes the core's
///     `"<title>\u{1F}<body>"` payload: OSC 777 `notify;T;B` → ("T","B");
///     OSC 9 `only body` → ("", "only body").
///   - `TerminalSession.notifications` (a `PassthroughSubject`) re-emits
///     the same values as `TerminalNotification`, on the main thread,
///     after the session's event dispatch.
///
/// Pre-flight: one 10×3 BBTerm (≤ 1 KB grid) or one 2×2 headless
/// session per test, a few dozen bytes of input, one bounded
/// `wait(for:)` ≤ 3 s (real settle time is a runloop hop). No PTY.
final class TerminalNotificationEventBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - BBTerm.Event decoding

    private func collectNotifications(feeding bytes: String) throws -> [(title: String, body: String)] {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        var seen: [(title: String, body: String)] = []
        var otherEvents: [BBTerm.Event] = []
        term.onEvent { ev in
            if case .notification(let title, let body) = ev {
                seen.append((title, body))
            } else {
                otherEvents.append(ev)
            }
        }
        term.input(bytes)
        // Events are delivered synchronously from `input`; a short spin
        // guards against a deferred-dispatch implementation.
        if seen.isEmpty {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(otherEvents.isEmpty,
                      "a notification sequence must not emit other events; got \(otherEvents)")
        return seen
    }

    func test_bbterm_osc777_decodesTitleAndBody() throws {
        let seen = try collectNotifications(feeding: "\u{1B}]777;notify;T;B\u{07}")
        XCTAssertEqual(seen.count, 1, "exactly one .notification expected")
        XCTAssertEqual(seen.first?.title, "T")
        XCTAssertEqual(seen.first?.body, "B")
    }

    func test_bbterm_osc9_decodesEmptyTitleAndBody() throws {
        let seen = try collectNotifications(feeding: "\u{1B}]9;only body\u{07}")
        XCTAssertEqual(seen.count, 1, "exactly one .notification expected")
        XCTAssertEqual(seen.first?.title, "")
        XCTAssertEqual(seen.first?.body, "only body")
    }

    func test_bbterm_osc99_titleOnly_decodesEmptyBody() throws {
        let seen = try collectNotifications(feeding: "\u{1B}]99;i=1:p=title;Just Title\u{07}")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.title, "Just Title")
        XCTAssertEqual(seen.first?.body, "")
    }

    func test_bbterm_unicodeSurvivesDecoding() throws {
        let seen = try collectNotifications(feeding: "\u{1B}]777;notify;Café;naïve → done\u{07}")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.title, "Café")
        XCTAssertEqual(seen.first?.body, "naïve → done")
    }

    // MARK: - TerminalSession.notifications

    private func sessionNotifications(
        feeding bytes: String,
        expectedCount: Int = 1
    ) -> (values: [TerminalNotification], onMain: [Bool]) {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        var values: [TerminalNotification] = []
        var onMain: [Bool] = []
        let exp = expectation(description: "notifications emitted")
        exp.expectedFulfillmentCount = expectedCount
        session.notifications
            .sink { n in
                values.append(n)
                onMain.append(Thread.isMainThread)
                exp.fulfill()
            }
            .store(in: &cancellables)

        session.feedBytesForTests(Data(bytes.utf8))
        wait(for: [exp], timeout: 3.0)
        return (values, onMain)
    }

    func test_session_osc777_emitsTerminalNotificationOnMain() {
        let (values, onMain) = sessionNotifications(feeding: "\u{1B}]777;notify;T;B\u{07}")
        XCTAssertEqual(values, [TerminalNotification(title: "T", body: "B")])
        XCTAssertEqual(onMain, [true], "notifications must be delivered on the main thread")
    }

    func test_session_osc9_emitsBodyOnlyNotificationOnMain() {
        let (values, onMain) = sessionNotifications(feeding: "\u{1B}]9;only body\u{07}")
        XCTAssertEqual(values, [TerminalNotification(title: "", body: "only body")])
        XCTAssertEqual(onMain, [true])
    }

    func test_session_twoNotifications_arriveInOrder() {
        let (values, _) = sessionNotifications(
            feeding: "\u{1B}]9;first\u{07}\u{1B}]777;notify;Second;two\u{07}",
            expectedCount: 2
        )
        XCTAssertEqual(values, [
            TerminalNotification(title: "", body: "first"),
            TerminalNotification(title: "Second", body: "two"),
        ])
    }

    func test_session_ignoredForms_emitNothing() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        var values: [TerminalNotification] = []
        session.notifications
            .sink { values.append($0) }
            .store(in: &cancellables)

        // ConEmu progress form + unknown 777 verb: neither is a notification.
        session.feedBytesForTests(Data("\u{1B}]9;4;1;50\u{07}\u{1B}]777;other;x;y\u{07}".utf8))
        // Give a wrongly-emitted value time to hop to main.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        XCTAssertTrue(values.isEmpty, "non-notification OSC forms must not emit; got \(values)")
    }
}
