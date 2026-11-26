import XCTest
import AppKit
@testable import Blackbird

/// Menu-validation coverage for the AppDelegate's `selectTab(_:)`,
/// `closeWindow(_:)`, and the Window-menu ⌘1-9 items. Targets findings
/// F-S6-009 (selectTab unconditionally enabled regardless of tab count
/// or key window class), TST-S6-008 (selectTab not unit-tested), and
/// the implicit menu-item lifecycle in App.swift.
///
/// Per F-S6-009: ⌘1-9 are wired to `AppDelegate.selectTab(_:)` with no
/// `validateMenuItem` clause that gates on (a) keyWindow is a Blackbird
/// window and (b) `item.tag <= tab count`. The user can press ⌘5 with
/// only two tabs and either get silently ignored OR (worse) target a
/// non-Blackbird key window.
///
/// Memory + safety budget (per memory `feedback_test_memory_safety` and
/// `feedback_test_real_shell_controllers`):
///
///   - NO real `MainWindowController` instances. Every test uses
///     bare `NSWindow` stubs and a synthetic `NSMenuItem` carrying the
///     selector + tag, validating against `AppDelegate.shared` (or a
///     freshly-instantiated `AppDelegate` if the singleton seam doesn't
///     exist — see test-by-test notes).
///   - Total transient resident set <1 MB across the file.
///   - No `Thread.sleep` longer than 50 ms.
// @MainActor: AppDelegate is now @MainActor-isolated, so its init / menu
// methods must be called from a main-actor context (these tests run on main).
@MainActor
final class MenuValidationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Staged key windows are parked UNTOUCHED for process lifetime — the
    /// same discipline TabMoverTests uses for merged tab-group members,
    /// and for the same root cause on a new trigger: `makeKeyAndOrderFront`
    /// on this Tahoe host queues a deferred CoreAnimation transaction
    /// holding a `_NSWindowTransformAnimation`; a later `close()` leaves
    /// that transaction referencing dead window state, and whichever test
    /// NEXT spins the runloop through XCTWaiter flushes it and SEGVs the
    /// shared xctest host (`objc_release` inside
    /// `-[_NSWindowTransformAnimation dealloc]`, crash
    /// Blackbird-2026-07-13-214036.ips; bisected to exactly these two
    /// staged-window tests + any later runloop-pumping suite — this is
    /// also the long-mislabeled "cumulative ASan" CATransaction SEGV that
    /// got a dozen RunLoop-pumping tests in PreferencesTests /
    /// TerminalViewTests skipped). Parking keeps the window alive so the
    /// deferred transaction never dangles; the ~50 KB stubs die at
    /// process exit.
    private static var parkedStagedWindows: [NSWindow] = []

    /// Stage a bare non-Blackbird window as keyWindow and park it for
    /// process lifetime (see `parkedStagedWindows`). Never close it.
    private func stageParkedKeyWindow(title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.title = title
        w.makeKeyAndOrderFront(nil)
        Self.parkedStagedWindows.append(w)
        return w
    }

    /// A synthetic `NSMenuItem` carrying the selector + tag we want to
    /// validate. NSMenuItem itself doesn't gate; we ask AppDelegate's
    /// `validateMenuItem(_:)` via the `NSMenuItemValidation` protocol
    /// optional cast — AppDelegate may not conform, in which case the
    /// runtime falls back to "always enabled" (the F-S6-009 bug case).
    private func makeMenuItem(action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "Tab \(tag)", action: action, keyEquivalent: "")
        item.tag = tag
        return item
    }

    /// Construct a fresh AppDelegate (no @main lifecycle dance — just
    /// `init()`). Tests that need controllers state register stubs
    /// against the delegate's controllers array if it's exposed.
    /// If `AppDelegate.shared` exists, prefer that.
    private func freshAppDelegate() -> AppDelegate {
        // The runtime test host has its own NSApplicationDelegate; we
        // construct a private one here just for selector dispatch +
        // validateMenuItem testing. We do NOT set it as `NSApp.delegate`.
        AppDelegate()
    }

    /// validateMenuItem call. Returns:
    ///   - the result of `delegate.validateMenuItem(item)` when AppDelegate
    ///     conforms to NSMenuItemValidation
    ///   - `nil` when AppDelegate does NOT conform (the original F-S6-009
    ///     bug shape — no validator means the menu item defaults to enabled)
    ///
    /// Audit M-19: pre-Batch-6, AppDelegate didn't conform to
    /// NSMenuItemValidation, so this cast always returned nil and every
    /// caller that did `if let valid = validate(…) { … }` short-circuited
    /// — tests passed VACUOUSLY. After the H-9 fix landed (commit 9413aaf),
    /// the cast succeeds and the validator runs; callers must now use a
    /// `guard let` + XCTFail pattern so a future regression that re-removes
    /// the conformance is observable instead of silently green.
    private func validate(_ delegate: AppDelegate, item: NSMenuItem) -> Bool? {
        if let validator = delegate as? NSMenuItemValidation {
            return validator.validateMenuItem(item)
        }
        return nil
    }

    // MARK: - F-S6-009 / TST-S6-008: selectTab(_:) menu validation matrix

    /// Pre-flight: bare AppDelegate, no real controllers, no stubs of
    /// `controllers` array (we don't have a public seam to inject).
    /// Memory: ~10 KB. Time: <5 ms.
    ///
    /// With ZERO Blackbird windows alive, ⌘1..9 items must be DISABLED
    /// (validateMenuItem returns false). Pre-fix per F-S6-009: returns
    /// true and silently no-ops. This is the simplest cell in the
    /// validation matrix.
    func test_selectTab_validation_zeroTabs_disabled() {
        let delegate = freshAppDelegate()
        let selector = #selector(AppDelegate.selectTab(_:))

        for tag in 1...9 {
            let item = makeMenuItem(action: selector, tag: tag)
            // Audit M-19: previously this used `if let valid = validate(…)`
            // which short-circuited silently when the cast returned nil —
            // pre-H-9 every iteration fell through, so the test passed
            // vacuously. After 9413aaf the cast succeeds; if a future
            // regression removes the conformance the cast goes back to nil
            // and we'd silently regress to vacuous-pass without this guard.
            guard let valid = validate(delegate, item: item) else {
                XCTFail(
                    "AppDelegate must conform to NSMenuItemValidation (audit "
                        + "H-9, commit 9413aaf); cast returned nil for tag=\(tag). "
                        + "If conformance was removed, ⌘1-9 routes from any "
                        + "keyWindow with no count gating."
                )
                return
            }
            XCTAssertFalse(
                valid,
                "with zero Blackbird tabs alive, ⌘\(tag) must be disabled "
                    + "(F-S6-009). Got valid=true for tag=\(tag)."
            )
        }
    }

    // MARK: - F-S6-009: closeWindow against non-Blackbird keyWindow

    /// Pre-flight: NO controllers. Bare delegate + no keyWindow. Memory:
    /// ~50 KB. Time: <10 ms.
    ///
    /// Audit H-9 / M-19: ⌘⇧W routes to AppDelegate.closeWindow regardless
    /// of which window class is key. The H-9 fix gates closeWindow on
    /// `ownedKeyWindow()` BEFORE the `bypassCloseConfirm` flip, so an
    /// invocation with no Blackbird-owned key window must short-circuit
    /// without ever flipping the flag.
    ///
    /// Coverage scope (be honest about what this catches): this test
    /// asserts the validator returns false for non-Blackbird key windows
    /// AND that no static state leaks past dispatch return — i.e. the flag
    /// reads false BOTH before and AFTER `delegate.perform(...)` returns.
    /// That catches a regression where the validator stops gating, OR
    /// where a flag set before the early return doesn't get reset.
    ///
    /// What this test does NOT cover: the original leak SHAPE — a
    /// nested-modal observer that snapshots `bypassCloseConfirm`
    /// MID-call (between the flip and the `defer` reset) — is not
    /// exercised here. `defer { …= false }` runs at function exit before
    /// dispatch returns to the test, so a leak that's only observable
    /// inside a nested modal would slip past. Capturing the mid-call
    /// shape requires a stub MainWindowController with a synthetic
    /// `windowShouldClose` observer; that's deferred (per audit memo).
    func test_closeWindow_validation_nonBlackbirdKeyWindow_leavesBypassFlagFalse() {
        // Establish baseline: bypassCloseConfirm starts false (and we
        // want it false after this test runs, so other tests in the same
        // process don't observe a leaked-true flag).
        MainWindowController.setCloseConfirmBypass(false)
        defer { MainWindowController.setCloseConfirmBypass(false) }

        let delegate = freshAppDelegate()
        let selector = #selector(AppDelegate.closeWindow(_:))
        let item = makeMenuItem(action: selector, tag: 0)

        // validate() also exercises the H-9 validator branch.
        guard let valid = validate(delegate, item: item) else {
            return XCTFail(
                "AppDelegate must conform to NSMenuItemValidation (audit "
                    + "H-9). Without it, ⌘⇧W enables on any keyWindow class."
            )
        }
        XCTAssertFalse(
            valid,
            "closeWindow validator must reject when no Blackbird-owned key "
                + "window is present (audit H-9). Got valid=true."
        )

        // Dispatch the action with no keyWindow. The H-9 fix's
        // `guard let window = ownedKeyWindow() else { return }` short-
        // circuits BEFORE `bypassCloseConfirm = true`. Post-condition:
        // the static flag is still false.
        delegate.perform(selector, with: item)
        XCTAssertFalse(
            MainWindowController.bypassCloseConfirm,
            "closeWindow with no Blackbird key window must NOT flip "
                + "bypassCloseConfirm (audit H-9 leak shape). The static "
                + "flag is shared across the whole process; a leaked "
                + "true here would silently bypass per-tab close confirm "
                + "in any later windowShouldClose."
        )
    }

    // MARK: - selectTab dispatch with no controller registry

    /// Pre-flight: stage one non-Blackbird NSWindow as keyWindow. Memory:
    /// ~50 KB. Time: <100 ms (one runloop service tick to let makeKey
    /// land). Skips if xctest host refuses to honour makeKeyAndOrderFront
    /// (the assertion would be vacuous otherwise — see body).
    ///
    /// Audit H-9 / M-19: with no Blackbird-owned windows alive,
    /// `selectTab(_:)` must NOT change which window is key. The H-9
    /// hardening adds an `ownedKeyWindow()` guard before
    /// `tabs[index].makeKeyAndOrderFront`, so a runaway dispatch can't
    /// promote an arbitrary window to key. Pin the post-condition: the
    /// keyWindow before equals the keyWindow after.
    ///
    /// Why we stage: without a concrete keyWindow before dispatch,
    /// `NSApp.keyWindow` is nil and `nil === nil` passes vacuously even
    /// if H-9 were reverted. Staging a non-Blackbird key window gives us
    /// a non-nil identity to compare. If staging fails (xctest host
    /// won't honour makeKey), the test would be vacuous either way —
    /// XCTSkip rather than pretend.
    func test_selectTab_dispatch_noControllers_keyWindowUnchanged() throws {
        // Parked, never closed — see `parkedStagedWindows` for the
        // deferred-CA-transaction SEGV this avoids.
        _ = stageParkedKeyWindow(title: "non-blackbird-staged")

        // Allow one runloop service tick for makeKey to actually take
        // effect before we read NSApp.keyWindow.
        let exp = expectation(description: "makeKey-settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        guard let beforeKey = NSApp.keyWindow else {
            throw XCTSkip(
                "xctest host did not promote staged NSWindow to keyWindow; "
                    + "without a non-nil pre-state the identity check is "
                    + "vacuous (`nil === nil` passes even on H-9 revert)."
            )
        }

        let delegate = freshAppDelegate()
        let item = makeMenuItem(action: #selector(AppDelegate.selectTab(_:)), tag: 1)
        delegate.perform(#selector(AppDelegate.selectTab(_:)), with: item)

        let afterKey = NSApp.keyWindow
        XCTAssertTrue(
            beforeKey === afterKey,
            "selectTab with no controllers must not promote a different "
                + "window to key (audit H-9). Before=\(String(describing: beforeKey)) "
                + "after=\(String(describing: afterKey))."
        )
    }

    // MARK: - selectTab dispatch with negative + out-of-range tags

    /// Pre-flight: stage one non-Blackbird NSWindow as keyWindow. Memory:
    /// ~50 KB. Time: <100 ms. Skips if staging fails (see sibling test).
    ///
    /// Audit H-9 / M-19: out-of-range tags (`<= 0`, `> tabs.count`, or
    /// `Int.max`) must NOT promote an arbitrary window to key. The H-9
    /// fix adds `index >= 0, index < tabs.count` guard inside selectTab,
    /// AND the validator gates on `tag >= 1 && tag <= tabs.count` so the
    /// menu item disables out-of-range tags before they ever reach
    /// dispatch. Pin the dispatch-side post-condition: keyWindow
    /// identity stable across each out-of-range invocation.
    ///
    /// Staging a non-Blackbird key window before dispatch turns this from
    /// a vacuous `nil === nil` check into a real regression detector.
    func test_selectTab_dispatch_outOfRangeTags_keyWindowUnchanged() throws {
        // Parked, never closed — see `parkedStagedWindows` for the
        // deferred-CA-transaction SEGV this avoids.
        _ = stageParkedKeyWindow(title: "non-blackbird-staged-oor")

        let exp = expectation(description: "makeKey-settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        guard let beforeKey = NSApp.keyWindow else {
            throw XCTSkip(
                "xctest host did not promote staged NSWindow to keyWindow; "
                    + "skipping rather than passing vacuously."
            )
        }

        let delegate = freshAppDelegate()
        let selector = #selector(AppDelegate.selectTab(_:))

        for tag in [-1, 0, 99, Int.max] {
            let item = makeMenuItem(action: selector, tag: tag)
            delegate.perform(selector, with: item)
            let afterKey = NSApp.keyWindow
            XCTAssertTrue(
                beforeKey === afterKey,
                "selectTab with out-of-range tag \(tag) must not promote a "
                    + "different window to key (audit H-9). Before=\(String(describing: beforeKey)) "
                    + "after=\(String(describing: afterKey))."
            )
        }
    }
}
