import XCTest
import AppKit
import SwiftUI
@testable import Blackbird

/// Blind behaviour tests for the Settings window's section selector (spec,
/// not implementation):
///
///  `SettingsView` shows four sections (Appearance, Behavior, Updates,
///  Diagnostics) chosen through a selector strip at the top of the window
///  content. On macOS 27 the strip's AppKit view collapsed to 0x0 points
///  after the first layout pass -- all four labels drew on top of each other
///  in a tiny box near the top-centre -- and only recovered after a window
///  resize. Contract pinned here: on FIRST show, with NO resize, the
///  selector has a real size, sits inside the content area, and sits near
///  its top edge; widening the window afterwards must not break that.
///
/// Black-box by construction: the selector is found by walking the live view
/// tree from the window's frame view down (any `NSSegmentedControl`, or any
/// view whose class name contains "SegmentedControl", e.g.
/// `NSTabViewSegmentedControl`, possibly nested inside SwiftUI platform-host
/// views; the OUTERMOST match is the selector). Nothing here depends on how
/// `SettingsView` builds the strip.
///
/// Coordinates: hosting views are flipped, plain `NSView`s are not, so every
/// placement check converts to WINDOW BASE coordinates via `convert(_:to: nil)`
/// (y grows upward from the window's bottom edge for every view, flipped or
/// not). "Near the top" is therefore `contentTop - rect.maxY` / `contentTop -
/// rect.minY` measured from the content view's own window-space `maxY`.
///
/// Timing: the collapse happened AFTER the first layout pass, so a read that
/// lands on the transient pre-collapse frame would pass vacuously. Every
/// check therefore pumps the runloop for the full 0.4 s of the headless
/// repro, then polls (<= 2 s) for a non-degenerate frame, then pumps a
/// further quiet period and re-reads before asserting.
///
/// Memory + time pre-flight: one 560x600 `NSWindow` + one
/// `NSHostingController(SettingsView)` per test (a few MB resident, no
/// Metal, no PTY, no `MainWindowController`, no `SettingsWindowController`
/// singleton, no frame-autosave name so the user's real Settings frame is
/// never touched). ~0.7 s of runloop pumping per test, ~1.4 s for the widen
/// test. Windows are standalone (not tab-group members), so the
/// `orderOut(nil)` teardown follows `RealLatencyProbeWindowedTests`;
/// `animationBehavior = .none` keeps AppKit from queuing an
/// `_NSWindowTransformAnimation` for the order-in / order-out.
@MainActor
final class SettingsViewLayoutBlindTests: XCTestCase {

    // MARK: - Thresholds

    /// Four labels cannot fit in less than this.
    private static let minSelectorWidth: CGFloat = 200
    private static let minSelectorHeight: CGFloat = 16
    /// The selector must lie within this many points of the content top.
    private static let nearTopBand: CGFloat = 120
    /// Sub-point slack for window-space comparisons.
    private static let tolerance: CGFloat = 1

    // MARK: - Fixture

    /// How the hosting view is mounted in the window. `.glassWrapped` mirrors
    /// what ships (plain container + `NSVisualEffectView` backing + hosting
    /// view on top); `.hostingViewIsContentView` is the minimal headless
    /// repro. The collapse must be absent in both.
    private enum Mount {
        case glassWrapped
        case hostingViewIsContentView
    }

    private struct Rig {
        let window: NSWindow
        /// Held so SwiftUI's controller lifecycle outlives the test body.
        let host: NSHostingController<SettingsView>
    }

    /// Build, mount and show the Settings window. Returns immediately after
    /// `makeKeyAndOrderFront`; callers pump the runloop themselves.
    private func showSettingsWindow(_ mount: Mount) -> Rig {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        let host = NSHostingController(rootView: SettingsView())
        switch mount {
        case .hostingViewIsContentView:
            window.contentView = host.view
        case .glassWrapped:
            let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
            container.autoresizingMask = [.width, .height]
            let blur = NSVisualEffectView(frame: container.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .sidebar
            blur.blendingMode = .behindWindow
            blur.state = .active
            container.addSubview(blur)
            host.view.frame = container.bounds
            host.view.autoresizingMask = [.width, .height]
            container.addSubview(host.view)
            window.contentView = container
        }

        // On-screen, upper-left of the main screen (fall back to a plausible
        // visible frame when no screen is attached).
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(x: visible.minX + 40,
                                      y: visible.maxY - window.frame.height - 40))
        window.makeKeyAndOrderFront(nil)
        return Rig(window: window, host: host)
    }

    /// Hide the window and keep the hosting controller alive until then.
    private func hideAndRelease(_ rig: Rig) {
        rig.window.orderOut(nil)
        withExtendedLifetime(rig.host) {}
    }

    // MARK: - Runloop helpers

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds`.
    private func pump(for seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    // MARK: - Selector discovery

    private static func isSegmentedControl(_ view: NSView) -> Bool {
        view is NSSegmentedControl
            || String(describing: type(of: view)).contains("SegmentedControl")
    }

    /// Outermost segmented-control views under `root` (pre-order; a match's
    /// own subviews are not searched, so a control that internally nests
    /// another one is counted once).
    private func outermostSelectors(under root: NSView) -> [NSView] {
        if Self.isSegmentedControl(root) { return [root] }
        return root.subviews.flatMap { outermostSelectors(under: $0) }
    }

    /// Selectors in the whole window, starting at the frame view
    /// (`contentView.superview`) so nothing hosted outside the content view
    /// is missed.
    private func findSelectors(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView?.superview ?? window.contentView else { return [] }
        return outermostSelectors(under: root)
    }

    private func hasRealSize(_ view: NSView) -> Bool {
        view.frame.width >= Self.minSelectorWidth && view.frame.height >= Self.minSelectorHeight
    }

    /// Pump until layout has settled, then return a fresh lookup. See the
    /// "Timing" note in the file header for why this is not "poll until
    /// non-zero, then assert".
    private func settledSelectors(in window: NSWindow) -> [NSView] {
        pump(for: 0.4)
        pump(until: 2.0) { self.findSelectors(in: window).first.map(self.hasRealSize) ?? false }
        pump(for: 0.2)
        return findSelectors(in: window)
    }

    // MARK: - Assertions

    private func describe(_ view: NSView) -> String {
        "\(String(describing: type(of: view))) frame=\(view.frame) "
            + "inWindow=\(view.convert(view.bounds, to: nil))"
    }

    /// Steps 1-3 of the contract against an already-settled lookup.
    private func assertSelectorLaidOut(
        _ found: [NSView], in window: NSWindow, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let all = found.map { describe($0) }.joined(separator: "; ")
        XCTAssertEqual(found.count, 1,
                       "\(label): expected exactly one section selector (NSSegmentedControl or a "
                       + "'*SegmentedControl*' view); found \(found.count): [\(all)]",
                       file: file, line: line)
        let selector = try XCTUnwrap(
            found.first,
            "\(label): no section selector found in the window's view tree -- the "
            + "segmented control the test looks for is gone or was never created",
            file: file, line: line)
        let content = try XCTUnwrap(window.contentView, "\(label): window lost its contentView",
                                    file: file, line: line)

        let diag = describe(selector)

        // 2. Real size (the bug: 0x0).
        XCTAssertGreaterThanOrEqual(
            selector.frame.width, Self.minSelectorWidth,
            "\(label): selector collapsed horizontally: \(diag)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            selector.frame.height, Self.minSelectorHeight,
            "\(label): selector collapsed vertically: \(diag)", file: file, line: line)

        // Placement, in window base coordinates (y-up for every view).
        let sel = selector.convert(selector.bounds, to: nil)
        let area = content.convert(content.bounds, to: nil)
        let tol = Self.tolerance

        // 2 (cont). Horizontally inside the content area.
        XCTAssertGreaterThanOrEqual(
            sel.minX, area.minX - tol,
            "\(label): selector pokes out of the content's left edge: \(diag), content=\(area)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            sel.maxX, area.maxX + tol,
            "\(label): selector pokes out of the content's right edge: \(diag), content=\(area)",
            file: file, line: line)

        // 3. Near the top: not above the content's top edge, and its lowest
        // edge no further than `nearTopBand` below it.
        XCTAssertLessThanOrEqual(
            sel.maxY, area.maxY + tol,
            "\(label): selector sits above the content's top edge: \(diag), content=\(area)",
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            sel.minY, area.maxY - Self.nearTopBand,
            "\(label): selector is not within the top \(Self.nearTopBand) pt of the content "
            + "(its bottom edge is \(area.maxY - sel.minY) pt below the top): \(diag), content=\(area)",
            file: file, line: line)
    }

    // MARK: - Tests

    /// The shipped mounting (glass container + hosting view): first show,
    /// no resize.
    func test_firstShow_glassWrappedHost_selectorHasRealSizeNearTop() throws {
        let rig = showSettingsWindow(.glassWrapped)
        defer { hideAndRelease(rig) }

        let found = settledSelectors(in: rig.window)
        try assertSelectorLaidOut(found, in: rig.window, label: "first show (glass-wrapped host)")
    }

    /// The minimal headless repro: hosting view as the window's contentView,
    /// first show, no resize.
    func test_firstShow_hostingViewAsContentView_selectorHasRealSizeNearTop() throws {
        let rig = showSettingsWindow(.hostingViewIsContentView)
        defer { hideAndRelease(rig) }

        let found = settledSelectors(in: rig.window)
        try assertSelectorLaidOut(found, in: rig.window,
                                  label: "first show (hosting view as contentView)")
    }

    /// Widening the window by 240 pt after the first show must leave the
    /// selector real-sized, inside the (now wider) content area and near the
    /// top.
    func test_afterWideningWindow_selectorStillHasRealSizeNearTop() throws {
        let rig = showSettingsWindow(.glassWrapped)
        defer { hideAndRelease(rig) }

        _ = settledSelectors(in: rig.window)

        let contentBefore = try XCTUnwrap(rig.window.contentView).bounds.width
        var frame = rig.window.frame
        frame.size.width += 240
        rig.window.setFrame(frame, display: true)
        let contentAfter = try XCTUnwrap(rig.window.contentView).bounds.width
        XCTAssertEqual(contentAfter, contentBefore + 240, accuracy: 1,
                       "test precondition: the window must actually have widened by 240 pt")

        let found = settledSelectors(in: rig.window)
        try assertSelectorLaidOut(found, in: rig.window, label: "after widening by 240 pt")
    }
}
