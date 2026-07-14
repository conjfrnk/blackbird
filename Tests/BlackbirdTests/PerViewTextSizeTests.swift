import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behavior tests for per-tab / per-window text size (issue #28).
///
/// These tests are written **purely from the design contract** in
/// `docs/superpowers/specs/2026-07-13-per-tab-text-size-design.md`, WITHOUT
/// reading the implementation, so a wrong-but-plausible impl that passes for
/// the wrong reason gets no free pass. They REPLACE the old scratch
/// `Issue28ReproTests`, which pinned the pre-#28 *global* behavior that this
/// feature deliberately abandons.
///
/// ## Contract under test (all on module `Blackbird`)
///
///   - `TerminalView.makeHeadlessForTests() -> TerminalView?` — DEBUG factory
///     (nil without a Metal device; `XCTUnwrap` it).
///   - `view.metrics.font.pointSize: CGFloat` — the view's rendered text size.
///   - `view.fontSizeOverride: Double?` — NEW, read-only from outside.
///     `nil` ⇒ the view follows the global default; non-nil ⇒ a per-view size.
///   - `view.increaseFontSize(nil)` / `decreaseFontSize(nil)` — step ONLY the
///     acting view by ±1, clamped to `Preferences.fontSizeRange` (9…32), by
///     setting `fontSizeOverride`. A step that cannot change the size (already
///     at a bound) must NOT create an override. Applied synchronously to the
///     acting view.
///   - `view.resetFontSize(nil)` — clears `fontSizeOverride` so the view
///     re-follows the global default; does NOT write `Preferences.shared.fontSize`;
///     no-op when there is no override.
///   - `Preferences.shared.fontSize: Double` — the global default (the Settings
///     slider writes this). A change propagates via a Combine sink hopped to the
///     main queue to every view whose `fontSizeOverride == nil`; views WITH an
///     override keep their size. (Pump the main queue after mutating it.)
///   - `view.renderer.reconfigureFailuresForTests: Int` — DEBUG seam: while
///     `> 0`, the next internal atlas rebuild fails and the counter decrements.
///     Latch-fix contract: if a global `fontSize` change hits a view whose
///     rebuild fails, the view keeps its OLD size after that emission but must
///     CONVERGE on a later emission — even one carrying the SAME value (a
///     same-value `@AppStorage` write still emits `objectWillChange`), because
///     the dedupe key advances only after a successful apply.
///
/// ## Headless-xctest safety discipline (this project has crashed hosts)
///
/// Adopted verbatim from `TabMoverTests` / the old `Issue28ReproTests`:
///   - NEVER `orderFront` / `makeKeyAndOrderFront` / `close` / `orderOut` on any
///     window. Windows are constructed `defer: true`, `isReleasedWhenClosed = false`.
///   - Tab groups are formed via `addTabbedWindow` on never-shown windows with a
///     per-test-unique `tabbingIdentifier`; the host may refuse the headless
///     merge, so that path `XCTSkip`s.
///   - Every window created is PARKED UNTOUCHED for process lifetime in a static
///     array (no close / orderOut — the 2026-07-02 probe matrix showed either
///     poisons a deferred CoreAnimation transaction that later SEGVs the host).
///   - ≤ 3 `TerminalView`s per test; no `MainWindowController`, no PTYs, no real
///     shells.
///   - `Preferences.shared.fontSize` is saved in `setUp` and restored in
///     `tearDown` (pumped both times) so no size state leaks across suites.
@MainActor
final class PerViewTextSizeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Global default the whole suite pins to, restored on teardown.
    private var originalFontSize: Double = 13

    override func setUp() {
        super.setUp()
        originalFontSize = Preferences.shared.fontSize
        Preferences.shared.fontSize = 13
        pumpMainQueue()
    }

    override func tearDown() {
        Preferences.shared.fontSize = originalFontSize
        pumpMainQueue()
        super.tearDown()
    }

    /// One-to-a-few main-queue turns so the `objectWillChange` → `receive(on:
    /// .main)` hop delivers to background views. Same pattern as
    /// `TerminalViewTests`' encoder test. No pump is needed for the ACTING view
    /// (size actions apply synchronously); pumps matter only for global-pref
    /// propagation to OTHER views.
    private func pumpMainQueue(times: Int = 3) {
        for i in 0..<times {
            let exp = expectation(description: "main queue turn \(i)")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
    }

    // MARK: - Never-shown window / tab-group helpers

    /// Windows are parked UNTOUCHED for process lifetime — never closed / ordered
    /// out (deferred CA-transaction SEGV otherwise). They were never shown, so
    /// parking leaves nothing on screen.
    private static var parkedWindows: [NSWindow] = []

    /// A bare, NEVER-SHOWN `TerminalWindow` hosting a headless `TerminalView` as
    /// its content view. Standalone (`.disallowed`) unless a `tabId` is given,
    /// in which case it's `.preferred` so `addTabbedWindow` can merge it.
    private func makeWindowedView(tabId: String? = nil) throws -> (TerminalWindow, TerminalView) {
        let w = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.isReleasedWhenClosed = false
        if let tabId {
            w.tabbingMode = .preferred
            w.tabbingIdentifier = tabId
        } else {
            w.tabbingMode = .disallowed
        }
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        Self.parkedWindows.append(w)
        return (w, view)
    }

    /// Per-test-unique tabbing identifier so a group built here can't merge with
    /// a stale group from a sibling test.
    private func uniqueTabId(_ suffix: String) -> String {
        "bb-perviewtext.\(name).\(suffix).\(ObjectIdentifier(self).hashValue)"
    }

    // MARK: - 1. Per-view step isolates the acting view

    /// ⌘+ on the focused view A must step A ONLY. A view in a SEPARATE window and
    /// a HIDDEN native-tab-group member both stay at the global default, neither
    /// gains an override, and the global default itself is untouched — the exact
    /// property the pre-#28 behavior violated.
    func test_increaseFontSize_stepsOnlyActingView_windowAndHiddenTabMemberUnchanged() throws {
        let tabId = uniqueTabId("group")
        // A is the SELECTED tab of a 2-window group; C is the hidden member.
        let (wA, vA) = try makeWindowedView(tabId: tabId)
        let (wC, vC) = try makeWindowedView(tabId: tabId)
        wA.addTabbedWindow(wC, ordered: .above)
        guard let group = wA.tabGroup, group.windows.count == 2 else {
            throw XCTSkip("xctest host refused the headless addTabbedWindow merge")
        }
        group.selectedWindow = wA
        // B lives in a wholly separate standalone window.
        let (_, vB) = try makeWindowedView()

        XCTAssertEqual(vA.metrics.font.pointSize, 13, "A baseline follows global default")
        XCTAssertEqual(vB.metrics.font.pointSize, 13, "B baseline follows global default")
        XCTAssertEqual(vC.metrics.font.pointSize, 13, "C baseline follows global default")

        vA.increaseFontSize(nil)
        // Acting view applies immediately — no pump.
        XCTAssertEqual(vA.metrics.font.pointSize, 14, "acting view stepped synchronously")
        XCTAssertEqual(vA.fontSizeOverride, 14, "acting view gained a per-view override")

        // Give any (incorrect) global propagation a chance to land, then prove
        // the other views held.
        pumpMainQueue()
        XCTAssertEqual(vB.metrics.font.pointSize, 13, "separate-window view unchanged")
        XCTAssertNil(vB.fontSizeOverride, "separate-window view has no override")
        XCTAssertEqual(vC.metrics.font.pointSize, 13, "hidden tab-group member unchanged")
        XCTAssertNil(vC.fontSizeOverride, "hidden tab-group member has no override")
        XCTAssertEqual(Preferences.shared.fontSize, 13,
                       "a per-view step must NOT write the global default")
        XCTAssertEqual(vA.metrics.font.pointSize, 14, "acting view still stepped after pump")
    }

    // MARK: - 2. Per-view step is symmetric for shrink

    /// ⌘− on the focused view shrinks ONLY that view; a second view keeps the
    /// global size and gains no override, and the global default is untouched.
    func test_decreaseFontSize_shrinksOnlyActingView() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let vB = try XCTUnwrap(TerminalView.makeHeadlessForTests())

        vA.decreaseFontSize(nil)
        XCTAssertEqual(vA.metrics.font.pointSize, 12, "acting view shrank synchronously")
        XCTAssertEqual(vA.fontSizeOverride, 12, "acting view gained a per-view override")

        pumpMainQueue()
        XCTAssertEqual(vB.metrics.font.pointSize, 13, "non-acting view unchanged")
        XCTAssertNil(vB.fontSizeOverride, "non-acting view has no override")
        XCTAssertEqual(Preferences.shared.fontSize, 13,
                       "a per-view step must NOT write the global default")
    }

    // MARK: - 3. Reset clears the override and re-follows the global default

    /// ⌘0 clears the override so the view snaps back to the global default,
    /// WITHOUT mutating `Preferences.shared.fontSize` — and then re-follows a
    /// later global change (proving the subscription is live again).
    func test_resetFontSize_clearsOverrideAndReFollowsGlobalDefault() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())

        vA.increaseFontSize(nil)
        XCTAssertEqual(vA.metrics.font.pointSize, 14, "stepped up before reset")
        XCTAssertEqual(vA.fontSizeOverride, 14, "override present before reset")

        vA.resetFontSize(nil)
        // Applied synchronously to the acting view.
        XCTAssertNil(vA.fontSizeOverride, "reset cleared the override")
        XCTAssertEqual(vA.metrics.font.pointSize, 13, "reset snaps back to the global default")
        XCTAssertEqual(Preferences.shared.fontSize, 13,
                       "reset must NOT write the global default")

        // A later global change must now reach the view — it follows again.
        Preferences.shared.fontSize = 20
        pumpMainQueue()
        XCTAssertEqual(vA.metrics.font.pointSize, 20,
                       "after reset the view re-follows a later global change")
        XCTAssertNil(vA.fontSizeOverride, "following a global change creates no override")
    }

    // MARK: - 4. Global change moves non-overridden views; overridden views hold

    /// A global-default change moves EVERY view without an override, but a view
    /// with an override keeps its per-view size.
    func test_globalFontSizeChange_movesOnlyNonOverriddenViews() throws {
        let vOverridden = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let vFollowerA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let vFollowerB = try XCTUnwrap(TerminalView.makeHeadlessForTests())

        vOverridden.increaseFontSize(nil)          // override = 14
        XCTAssertEqual(vOverridden.fontSizeOverride, 14, "override set up")

        Preferences.shared.fontSize = 20
        pumpMainQueue()

        XCTAssertEqual(vFollowerA.metrics.font.pointSize, 20, "follower A tracked the global change")
        XCTAssertEqual(vFollowerB.metrics.font.pointSize, 20, "follower B tracked the global change")
        XCTAssertNil(vFollowerA.fontSizeOverride, "follower A still has no override")
        XCTAssertNil(vFollowerB.fontSizeOverride, "follower B still has no override")
        XCTAssertEqual(vOverridden.metrics.font.pointSize, 14, "overridden view kept its size")
        XCTAssertEqual(vOverridden.fontSizeOverride, 14, "overridden view kept its override")
    }

    // MARK: - 5. Clamp bounds on the override path

    /// Repeated ⌘+ clamps the override at exactly 32 (upper bound of
    /// `Preferences.fontSizeRange`).
    func test_increaseFontSize_clampsOverrideAt32() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        for _ in 0..<40 { vA.increaseFontSize(nil) }
        XCTAssertEqual(vA.metrics.font.pointSize, 32, "size clamps at the 32 upper bound")
        XCTAssertEqual(vA.fontSizeOverride, 32, "override clamps at the 32 upper bound")
    }

    /// Repeated ⌘− clamps the override at exactly 9 (lower bound of
    /// `Preferences.fontSizeRange`).
    func test_decreaseFontSize_clampsOverrideAt9() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        for _ in 0..<40 { vA.decreaseFontSize(nil) }
        XCTAssertEqual(vA.metrics.font.pointSize, 9, "size clamps at the 9 lower bound")
        XCTAssertEqual(vA.fontSizeOverride, 9, "override clamps at the 9 lower bound")
    }

    /// A ⌘+ whose effective size is ALREADY the maximum must not create an
    /// override — there is nothing to change, so the view stays a follower.
    func test_increaseFontSize_atGlobalMaximum_createsNoOverride() throws {
        Preferences.shared.fontSize = 32
        pumpMainQueue()
        // A fresh view follows the (now maxed) global default with no override.
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertEqual(vA.metrics.font.pointSize, 32, "fresh view starts at the global maximum")
        XCTAssertNil(vA.fontSizeOverride, "fresh view has no override")

        vA.increaseFontSize(nil)
        XCTAssertNil(vA.fontSizeOverride,
                     "a no-op step at the max must NOT create an override")
        XCTAssertEqual(vA.metrics.font.pointSize, 32, "size unchanged at the max")
    }

    // MARK: - 6. New views start at the global default, not another view's size

    /// A view created AFTER another view gained an override starts at the global
    /// default with no override — overrides are per-view, never inherited.
    func test_newView_startsAtGlobalDefault_notAnotherViewsOverride() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        vA.increaseFontSize(nil)
        vA.increaseFontSize(nil)
        XCTAssertEqual(vA.fontSizeOverride, 15, "A carries a 15 override")

        // Constructed only now, after A diverged.
        let vB = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertEqual(vB.metrics.font.pointSize, 13, "new view starts at the global default")
        XCTAssertNil(vB.fontSizeOverride, "new view has no override")
    }

    // MARK: - 7. Dedupe-latch: failed reconfigure retries and converges

    /// Folded-in bug fix: when a global change reaches a view whose atlas rebuild
    /// FAILS, the view must keep its OLD size (no half-apply) but the dedupe key
    /// must NOT advance — so a LATER emission retries and CONVERGES. The buggy
    /// pre-fix behavior stamped the key before the failed apply and stranded the
    /// view forever.
    ///
    /// Emission-count-robust: a single `@AppStorage` write fans out into SEVERAL
    /// `objectWillChange` emissions inside one main-queue pump (SwiftUI willChange
    /// + the UserDefaults-didChange bridge). With only one injected failure the
    /// FIRST emission fails but a later emission of the SAME write retries and
    /// converges before the assertion runs — so staleness after a single armed
    /// failure isn't observable at pump granularity. We therefore arm enough
    /// failures to survive every emission of one write, observe the stale state,
    /// then DISARM and fire one more emission to observe convergence.
    func test_globalChange_failedReconfigureRetriesAndConvergesOnNextEmission() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertEqual(vA.metrics.font.pointSize, 13, "baseline follows global default")
        XCTAssertNil(vA.fontSizeOverride, "no override at baseline")

        // A single @AppStorage write fans out into MANY emissions inside one
        // pump (measured: 17 reconfigure attempts — SwiftUI willChange + the
        // UserDefaults didChange bridge, times the pump's runloop drains). Arm
        // FAR above any single write's burst so EVERY attempt fails and the
        // no-half-apply staleness is deterministic; convergence below is then
        // driven by disarming, not by exhausting the seam.
        let armedFailures = 1_000_000
        vA.renderer.reconfigureFailuresForTests = armedFailures
        Preferences.shared.fontSize = 20
        pumpMainQueue()
        XCTAssertLessThan(vA.renderer.reconfigureFailuresForTests, armedFailures,
                          "at least one emission attempted the rebuild and failed")
        XCTAssertEqual(vA.metrics.font.pointSize, 13,
                       "every failed reconfigure must leave the OLD size intact (no half-apply)")
        XCTAssertNil(vA.fontSizeOverride, "a global change never sets an override")

        // Disarm, then fire one more emission (a same-value @AppStorage write
        // still emits objectWillChange). Because the dedupe key advanced only on
        // a SUCCESSFUL apply, this later emission retries and the view converges.
        vA.renderer.reconfigureFailuresForTests = 0
        Preferences.shared.fontSize = Preferences.shared.fontSize
        pumpMainQueue()
        XCTAssertEqual(vA.metrics.font.pointSize, 20,
                       "the view converges to the global size on the retry emission")
        XCTAssertNil(vA.fontSizeOverride, "convergence via the global path creates no override")
    }

    // MARK: - 8. A failed apply rolls the per-view action back atomically

    /// A per-view step whose atlas rebuild FAILS must be a complete no-op: the
    /// rendered size stays put AND no override is committed. A half-applied
    /// override at 14 while the view still renders 13 would be a silent
    /// divergence. A later step with the seam disarmed then applies normally.
    func test_increaseFontSize_failedReconfigureRollsBack_noOverrideCommitted() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertEqual(vA.metrics.font.pointSize, 13, "baseline")
        XCTAssertNil(vA.fontSizeOverride, "no override at baseline")

        vA.renderer.reconfigureFailuresForTests = 1
        vA.increaseFontSize(nil)
        XCTAssertEqual(vA.metrics.font.pointSize, 13,
                       "a failed step must leave the rendered size unchanged")
        XCTAssertNil(vA.fontSizeOverride,
                     "a failed step must NOT commit an override (no half-apply)")

        // Disarm and retry — the step now applies cleanly.
        vA.renderer.reconfigureFailuresForTests = 0
        vA.increaseFontSize(nil)
        XCTAssertEqual(vA.metrics.font.pointSize, 14, "the retried step applies")
        XCTAssertEqual(vA.fontSizeOverride, 14, "the retried step commits the override")
    }

    /// Reset rollback (symmetric): with an override present and the seam armed, a
    /// failed reset keeps the existing override and size; a disarmed retry then
    /// clears it.
    func test_resetFontSize_failedReconfigureRollsBack_overrideRetained() throws {
        let vA = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        vA.increaseFontSize(nil)                         // override = 14
        XCTAssertEqual(vA.fontSizeOverride, 14, "override established")
        XCTAssertEqual(vA.metrics.font.pointSize, 14, "size at override")

        vA.renderer.reconfigureFailuresForTests = 1
        vA.resetFontSize(nil)
        XCTAssertEqual(vA.fontSizeOverride, 14,
                       "a failed reset must retain the existing override")
        XCTAssertEqual(vA.metrics.font.pointSize, 14,
                       "a failed reset must leave the rendered size unchanged")

        // Disarm and retry — the reset now clears the override.
        vA.renderer.reconfigureFailuresForTests = 0
        vA.resetFontSize(nil)
        XCTAssertNil(vA.fontSizeOverride, "the retried reset clears the override")
        XCTAssertEqual(vA.metrics.font.pointSize, 13, "the view re-follows the global default")
    }
}
