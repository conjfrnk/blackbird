import XCTest
import AppKit
@testable import Blackbird

/// End-to-end pin for the "click a tab pill → keystrokes ring NSBeep"
/// dogfooding bug: AppKit's `NSWindow.sendEvent` auto-promotes any
/// hit-tested view whose `acceptsFirstResponder` returns true to first
/// responder on mouseDown. `TabStripView` returns true while there are
/// tabs, so a pill / + / right-click-on-pill click parks the strip as
/// first responder. `TabStripView.insertText` only honours space (FKA
/// pill activation); every other character falls to AppKit's
/// `noResponderFor:` path and beeps.
///
/// The decision *what* counts as "parked-on-strip" is pinned by the
/// pure-function tests in `TabStripMouseFocusYieldTests`. This file
/// pins the behavior end-to-end: install a strip in a real `NSWindow`
/// with a stand-in `contentView`, simulate the AppKit auto-promotion
/// (set the strip as first responder), call the relevant entry point,
/// and assert that first responder ends up back on `contentView` —
/// the production path that pushes keystrokes to `TerminalView`.
///
/// LIMITATION (called out so a future maintainer doesn't assume
/// these tests are stronger than they are): we invoke
/// `strip.mouseDown(with:)` directly with a synthesized `NSEvent`,
/// rather than dispatching through `NSWindow.sendEvent(_:)` which is
/// what *performs* the auto-promotion in real AppKit. The test
/// stand-in for AppKit's promotion is the explicit
/// `host.makeFirstResponder(strip)` line in each test. Going through
/// the real `sendEvent` pipeline would require a key window with an
/// event tap; that's costly to set up under xctest and would push
/// us past the per-test memory budget. Net effect: these tests
/// cover "given the strip is parked, mouseDown's defer yields
/// correctly" — the *post-promotion* half. The pure-function tests
/// already cover that decision exhaustively, so the integration
/// surface is genuinely the strip-mounting + window-context shape,
/// not the auto-promote race.
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - Each test allocates 1 host `NSWindow` (~40 KB resident,
///     `defer: true`, no graphics context until first display) plus
///     2-3 stub tab `NSWindow` instances. ≤ 4 windows × 40 KB each =
///     ≤ 160 KB transient per test. No PTYs, no
///     `MainWindowController` instances, no `TerminalSession`.
///   - Wall time: < 50 ms per test on M-series hardware.
final class TabStripMouseFocusYieldIntegrationTests: XCTestCase {

    /// Stand-in for `TerminalView` as a window's content view: just
    /// enough NSResponder behaviour for `makeFirstResponder` to
    /// succeed against it. Naming is intentionally generic so an
    /// accidental search for "TerminalView" doesn't false-match this
    /// test scaffolding.
    private final class FocusableContentStub: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeHost() -> (NSWindow, FocusableContentStub, TabStripView, [NSWindow]) {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let cv = FocusableContentStub(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        cv.autoresizingMask = [.width, .height]
        host.contentView = cv

        // Add strip as a subview of contentView so its `window` property
        // resolves to `host`. In production the strip lives in the
        // titlebar accessory; for first-responder behaviour the
        // hierarchy placement is irrelevant — the responder chain only
        // requires the strip be in a window.
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        cv.addSubview(strip)

        // Two stub tab windows so `acceptsFirstResponder` returns true
        // on the strip (it's gated by `!tabs.isEmpty`) and pill frames
        // are populated for hit-testing. These windows are NOT in any
        // tab group — the strip only consults the array we hand it.
        let t1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: true)
        t1.title = "t1"
        let t2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: true)
        t2.title = "t2"
        strip.update(tabs: [t1, t2], selected: t1, width: 600)

        return (host, cv, strip, [t1, t2])
    }

    /// Synthesize a left-click event at the given location-in-window.
    /// `windowNumber: 0` is fine — the strip's `mouseDown` only reads
    /// `locationInWindow` and `clickCount`, not the window number.
    private func clickEvent(at p: NSPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: p,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )!
    }

    /// PRIMARY pin for the bug: with the strip parked as first
    /// responder (the post-AppKit-auto-promote state), mouseDown's
    /// `defer` block must yield first responder back to the host's
    /// contentView before returning.
    func test_mouseDown_withStripParked_restoresContentViewAsFirstResponder() {
        let (host, cv, strip, _) = makeHost()

        // Simulate the post-auto-promote state: strip is FR.
        XCTAssertTrue(host.makeFirstResponder(strip))
        XCTAssertTrue(host.firstResponder === strip)

        // Click on pill 0's centre: pillFrames lay out at y=4 with
        // height=24 in the strip's own (flipped) coordinate space; in
        // window coordinates the strip is at y=0..28. Pick y=14 — well
        // inside either coordinate system — and x=50 which lands in
        // the leftmost pill of a 2-tab/600-px strip.
        strip.mouseDown(with: clickEvent(at: NSPoint(x: 50, y: 14)))

        XCTAssertTrue(host.firstResponder === cv,
            "click on a pill must yield FR back to contentView")
    }

    /// Also pins the empty-area click — `hitTest` should filter most
    /// such clicks out before reaching `mouseDown`, but if `mouseDown`
    /// is reached for any reason (synthetic event injection,
    /// hit-test edge-case in a future macOS), the defer must still
    /// fire.
    func test_mouseDown_emptyAreaWithStripParked_restoresContentView() {
        let (host, cv, strip, _) = makeHost()
        XCTAssertTrue(host.makeFirstResponder(strip))

        // After the trailing-gutter removal the `+` button reaches almost the
        // full strip width, so a hardcoded far-right x now lands ON the button.
        // Target the tiny empty sliver just past the `+` button's right edge,
        // computed from the test hook rather than hardcoded — still inside the
        // strip's 600px width.
        let emptyX = strip.addButtonFrameForTesting.maxX + 2
        XCTAssertLessThan(emptyX, 600,
            "precondition: the empty sliver past the `+` button must stay within the strip width")
        strip.mouseDown(with: clickEvent(at: NSPoint(x: emptyX, y: 14)))

        XCTAssertTrue(host.firstResponder === cv,
            "empty-area click must still yield FR back to contentView")
    }

    /// When contentView is already FR (the "no-op" baseline), the
    /// defer must NOT clobber state — the function should be
    /// idempotent.
    func test_mouseDown_withContentViewAlreadyFR_isIdempotent() {
        let (host, cv, strip, _) = makeHost()
        XCTAssertTrue(host.makeFirstResponder(cv))

        strip.mouseDown(with: clickEvent(at: NSPoint(x: 50, y: 14)))

        XCTAssertTrue(host.firstResponder === cv,
            "FR already on contentView must remain on contentView")
    }

    /// Specific pin for the same-pill click case the existing
    /// `selectedWindow` KVO restore in `MainWindowController` does NOT
    /// cover — the assignment is a no-op (no value change), no KVO
    /// fires. Without the `mouseDown` defer the strip stays parked
    /// and the very next keystroke beeps. The integration setup
    /// doesn't wire an `onSelectWindow` callback, so the click is
    /// effectively a "selected an already-selected pill" simulation
    /// from the strip's point of view.
    func test_mouseDown_clickingSelectedPill_stillRestoresContentView() {
        let (host, cv, strip, _) = makeHost()
        // Click on pill 0; `selected: t1` means pill 0 is the
        // already-selected tab. No `onSelectWindow` set, so even if
        // it would fire, it wouldn't be observable here. The
        // important behaviour is the FR yield happening regardless of
        // the callback.
        XCTAssertTrue(host.makeFirstResponder(strip))

        strip.mouseDown(with: clickEvent(at: NSPoint(x: 50, y: 14)))

        XCTAssertTrue(host.firstResponder === cv,
            "clicking the already-selected pill (KVO no-op path) must still yield FR")
    }
}
