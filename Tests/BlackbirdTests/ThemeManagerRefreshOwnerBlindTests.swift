import XCTest
import AppKit
@testable import Blackbird

/// Blind XCTest coverage of the targeted, single-owner theme refresh:
/// `ThemeManager.shared.refresh(owner:)`.
///
/// Contract pinned (written without reading the implementation):
///   - `refresh(owner:)` re-applies the theme to ONLY that owner's view
///     (invokes that owner's `viewProvider` once per call) and does NOT
///     re-push the session palette (its `sessionProvider` is not invoked).
///   - No other registration's providers are invoked.
///   - An owner that was never registered is a silent no-op.
///   - Re-registering the same owner replaces the providers used.
///   - There is no dedup: every call re-applies (first-show blur wiring
///     needs an unconditional apply).
///   - The no-arg `refresh()` keeps its all-registrations semantics
///     (each live registration's session AND view provider once), also
///     after `refresh(owner:)` has been used.
///
/// Memory/time pre-flight: only `NSObject` stubs and nil-returning provider
/// closures; no windows, no PTY, no Metal. Each test is well under 50 ms.
/// No test spins the run loop (the tearDown drain mirrors
/// `ThemeManagerBlindTests`), so queued Preferences sinks cannot run inside
/// a test body and perturb the counters.
@MainActor
final class ThemeManagerRefreshOwnerBlindTests: XCTestCase {

    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedTranslucency: Double = 0
    private var savedCursorBlink: Bool = false
    private var savedCursorShapeRaw: String = ""

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw       = p.themeRaw
        savedThemeModeRaw   = p.themeModeRaw
        savedTranslucency   = p.translucency
        savedCursorBlink    = p.cursorBlink
        savedCursorShapeRaw = p.cursorShapeRaw
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw       = savedThemeRaw
        p.themeModeRaw   = savedThemeModeRaw
        p.translucency   = savedTranslucency
        p.cursorBlink    = savedCursorBlink
        p.cursorShapeRaw = savedCursorShapeRaw
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        super.tearDown()
    }

    private final class StubOwner: NSObject {}

    /// Per-owner provider-call counters.
    private final class Counters {
        var session = 0
        var view = 0
    }

    private func register(_ owner: StubOwner, _ c: Counters) {
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { c.session += 1; return nil },
            viewProvider:    { c.view    += 1; return nil }
        )
    }

    // MARK: - 1. Only the targeted owner's view is re-applied

    func test_refreshOwner_invokesOnlyThatOwnersViewProvider() {
        let a = StubOwner(), b = StubOwner(), c = StubOwner()
        let ca = Counters(), cb = Counters(), cc = Counters()
        register(a, ca); register(b, cb); register(c, cc)
        // register() applies inline once (session + view). Measure only
        // what refresh(owner:) adds.
        XCTAssertEqual([ca.session, ca.view, cb.session, cb.view, cc.session, cc.view],
                       [1, 1, 1, 1, 1, 1],
                       "Precondition: register() applies once inline per owner")

        ThemeManager.shared.refresh(owner: b)

        XCTAssertEqual(cb.view, 2, "Targeted owner's viewProvider must fire exactly once more")
        XCTAssertEqual(cb.session, 1,
                       "Targeted refresh must NOT re-push the session palette (sessionProvider untouched)")
        XCTAssertEqual([ca.session, ca.view], [1, 1],
                       "Non-targeted owner A must not be touched by refresh(owner: B)")
        XCTAssertEqual([cc.session, cc.view], [1, 1],
                       "Non-targeted owner C must not be touched by refresh(owner: B)")
        withExtendedLifetime((a, b, c)) {}
    }

    // MARK: - 2. No dedup: every call re-applies the view

    func test_refreshOwner_isUnconditional_eachCallReappliesView() {
        let a = StubOwner(), other = StubOwner()
        let ca = Counters(), co = Counters()
        register(a, ca); register(other, co)

        ThemeManager.shared.refresh(owner: a)
        ThemeManager.shared.refresh(owner: a)
        ThemeManager.shared.refresh(owner: a)

        XCTAssertEqual(ca.view, 1 + 3,
                       "Three targeted refreshes with unchanged prefs must still each re-apply the view (blur wiring needs the unconditional push)")
        XCTAssertEqual(ca.session, 1, "Session palette never re-pushed by targeted refresh")
        XCTAssertEqual([co.session, co.view], [1, 1], "Other owner untouched across repeated targeted refreshes")
        withExtendedLifetime((a, other)) {}
    }

    // MARK: - 3. Unregistered owner is a no-op

    func test_refreshOwner_unregisteredOwner_isNoOp() {
        let registered = StubOwner()
        let cr = Counters()
        register(registered, cr)

        let stranger = StubOwner()
        ThemeManager.shared.refresh(owner: stranger)

        XCTAssertEqual([cr.session, cr.view], [1, 1],
                       "refresh(owner:) for an unregistered owner must not fall back to refreshing everyone")
        withExtendedLifetime(registered) {}
    }

    // MARK: - 4. Re-registration replaces the providers used

    func test_refreshOwner_afterReRegister_usesReplacementProvidersOnly() {
        let owner = StubOwner()
        let first = Counters(), second = Counters()
        register(owner, first)
        register(owner, second)
        let firstViewBefore = first.view
        let firstSessionBefore = first.session

        ThemeManager.shared.refresh(owner: owner)

        XCTAssertEqual(first.view, firstViewBefore, "Replaced viewProvider must not fire")
        XCTAssertEqual(first.session, firstSessionBefore, "Replaced sessionProvider must not fire")
        XCTAssertEqual(second.view, 2, "Replacement viewProvider: inline register apply + targeted refresh")
        XCTAssertEqual(second.session, 1, "Replacement sessionProvider: inline register apply only")
        withExtendedLifetime(owner) {}
    }

    // MARK: - 5. A dead sibling is not resurrected / does not disturb a live owner

    func test_refreshOwner_withDeadSiblingRegistration_stillRefreshesLiveOwnerOnly() {
        let live = StubOwner()
        let cl = Counters()
        let dead = Counters()
        register(live, cl)
        autoreleasepool {
            let ephemeral = StubOwner()
            register(ephemeral, dead)
        }
        let deadView = dead.view, deadSession = dead.session

        ThemeManager.shared.refresh(owner: live)

        XCTAssertEqual(cl.view, 2, "Live owner's view refreshed once")
        XCTAssertEqual(cl.session, 1, "Live owner's session not re-pushed")
        XCTAssertEqual([dead.view, dead.session], [deadView, deadSession],
                       "A deallocated owner's providers must never fire from a targeted refresh")
        withExtendedLifetime(live) {}
    }

    // MARK: - 6. No-arg refresh() semantics unchanged (alongside targeted use)

    func test_noArgRefresh_stillAppliesToAllRegistrations_afterTargetedRefresh() {
        let a = StubOwner(), b = StubOwner()
        let ca = Counters(), cb = Counters()
        register(a, ca); register(b, cb)

        ThemeManager.shared.refresh(owner: a)
        ThemeManager.shared.refresh()

        // a: register(1,1) + targeted(view +1) + all(1,1)
        XCTAssertEqual([ca.session, ca.view], [2, 3],
                       "No-arg refresh() must still push session + view for owner A after a targeted refresh")
        // b: register(1,1) + all(1,1)
        XCTAssertEqual([cb.session, cb.view], [2, 2],
                       "No-arg refresh() must still push session + view for owner B")
        withExtendedLifetime((a, b)) {}
    }

    // MARK: - 7. No-arg refresh() invoked first does not suppress a targeted one

    func test_refreshOwner_afterNoArgRefresh_stillAppliesView() {
        let a = StubOwner()
        let ca = Counters()
        register(a, ca)
        ThemeManager.shared.refresh()
        XCTAssertEqual([ca.session, ca.view], [2, 2], "Precondition: no-arg refresh applied both")

        ThemeManager.shared.refresh(owner: a)

        XCTAssertEqual(ca.view, 3,
                       "Targeted refresh must not be deduped by the all-registrations input cache")
        XCTAssertEqual(ca.session, 2, "Targeted refresh must not push the session")
        withExtendedLifetime(a) {}
    }

    // MARK: - 8. Targeted refresh does not poison the palette-change gate

    /// After a targeted refresh, a genuine palette-relevant preference
    /// change must still propagate to every registration (session AND view)
    /// via the Preferences sink. Guards against the targeted path stamping
    /// the dedup cache with inputs the other registrations never received.
    func test_refreshOwner_doesNotSuppressLaterPreferenceDrivenApplyToAll() {
        let a = StubOwner(), b = StubOwner()
        let ca = Counters(), cb = Counters()
        let p = Preferences.shared
        p.themeRaw = Theme.gruvbox.rawValue
        p.themeModeRaw = Preferences.ThemeMode.dark.rawValue
        // Let the sink for the pref writes above settle BEFORE registering.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        register(a, ca); register(b, cb)

        ThemeManager.shared.refresh(owner: a)

        let sessionBeforeB = cb.session
        p.themeRaw = Theme.solarized.rawValue
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertGreaterThan(cb.session, sessionBeforeB,
                             "A real theme change after a targeted refresh must still reach other registrations' sessions")
        withExtendedLifetime((a, b)) {}
    }
}
