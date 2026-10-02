import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for the tab strip's traffic-light vertical alignment.
///
/// Contract: the strip's pills (24 pt) sit with their vertical midline on the
/// midline of the window's close button, because the OS decides where the
/// strip lands in the titlebar and a hard-coded offset drifted by 4 pt on a
/// newer macOS.
///
///   1. `TabStripLayout.pillOriginY(stripHeight:pillHeight:trafficLightMidY:fallback:)`
///      is a pure function: nil / non-finite mid -> `fallback` untouched;
///      otherwise `mid - pillHeight/2` clamped into
///      `[0, max(0, stripHeight - pillHeight)]`.
///   2. Integration through `TabStripView` hosted in a real (never shown)
///      `NSWindow`.
///
/// Safety budget (CLAUDE.md test rules): exactly ONE plain titled NSWindow for
/// the whole class, parked untouched for process lifetime (never ordered
/// front / out, never closed), no sleeps, no PTYs, no controllers.
@MainActor
final class TabStripTrafficLightAlignmentTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - The single parked window

    /// Parked for process lifetime. Never shown, never closed. The style mask
    /// matches the production window (`MainWindowController`): without
    /// `.closable` AppKit hands back no close button to align against.
    private static let hostWindow: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.tabbingMode = .disallowed
        w.title = "traffic-light-alignment"
        return w
    }()

    private static let stripHeight: CGFloat = 28
    private static let pillHeight: CGFloat = 24
    private static let tolerance: CGFloat = 0.5

    // MARK: - Pure function: pillOriginY

    private func originY(
        strip: CGFloat = 28, pill: CGFloat = 24,
        mid: CGFloat?, fallback: CGFloat = 99
    ) -> CGFloat {
        TabStripLayout.pillOriginY(
            stripHeight: strip, pillHeight: pill,
            trafficLightMidY: mid, fallback: fallback)
    }

    func test_pillOriginY_centresPillOnMid_exact() {
        // mid 14 in a 28 strip with a 24 pill -> origin 2 (pill spans 2...26).
        XCTAssertEqual(originY(mid: 14), 2, accuracy: 0.0001)
        // Mid at 13 -> origin 1, still in range.
        XCTAssertEqual(originY(mid: 13), 1, accuracy: 0.0001)
        // Fractional mid is not rounded.
        XCTAssertEqual(originY(mid: 14.25), 2.25, accuracy: 0.0001)
    }

    func test_pillOriginY_exactClampBoundaries_areNotShifted() {
        // mid 12 -> origin 0 exactly; mid 16 -> origin 4 exactly (28 - 24).
        XCTAssertEqual(originY(mid: 12), 0, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: 16), 4, accuracy: 0.0001)
    }

    func test_pillOriginY_clampsToLowerEdge_whenMidTooHigh() {
        XCTAssertEqual(originY(mid: 5), 0, accuracy: 0.0001,
            "mid 5 would need origin -7; must clamp to 0")
        XCTAssertEqual(originY(mid: 0), 0, accuracy: 0.0001)
    }

    func test_pillOriginY_clampsToUpperEdge_whenMidTooLow() {
        XCTAssertEqual(originY(mid: 30), 4, accuracy: 0.0001,
            "mid 30 would need origin 18; must clamp to 28 - 24 = 4")
        XCTAssertEqual(originY(mid: 1000), 4, accuracy: 0.0001)
    }

    func test_pillOriginY_negativeMid_clampsToZero() {
        XCTAssertEqual(originY(mid: -5), 0, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: -1000), 0, accuracy: 0.0001)
    }

    func test_pillOriginY_nilMid_returnsFallbackUnchanged() {
        XCTAssertEqual(originY(mid: nil, fallback: 3), 3, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: nil, fallback: 0), 0, accuracy: 0.0001)
    }

    func test_pillOriginY_nilMid_fallbackOutsideStrip_isNotClamped() {
        XCTAssertEqual(originY(mid: nil, fallback: -7), -7, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: nil, fallback: 100), 100, accuracy: 0.0001)
    }

    func test_pillOriginY_nanMid_returnsFallback() {
        XCTAssertEqual(originY(mid: .nan, fallback: 3), 3, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: .nan, fallback: -7), -7, accuracy: 0.0001,
            "fallback is returned unclamped for NaN too")
    }

    func test_pillOriginY_infiniteMid_returnsFallback() {
        XCTAssertEqual(originY(mid: .infinity, fallback: 3), 3, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: -.infinity, fallback: 3), 3, accuracy: 0.0001)
        XCTAssertEqual(originY(mid: .infinity, fallback: 100), 100, accuracy: 0.0001)
    }

    func test_pillOriginY_pillTallerThanStrip_resultIsZero() {
        XCTAssertEqual(originY(strip: 20, pill: 24, mid: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(originY(strip: 20, pill: 24, mid: 500), 0, accuracy: 0.0001)
        XCTAssertEqual(originY(strip: 20, pill: 24, mid: -500), 0, accuracy: 0.0001)
    }

    func test_pillOriginY_pillEqualsStrip_resultIsZero() {
        XCTAssertEqual(originY(strip: 24, pill: 24, mid: 12), 0, accuracy: 0.0001)
        XCTAssertEqual(originY(strip: 24, pill: 24, mid: 40), 0, accuracy: 0.0001)
    }

    func test_pillOriginY_pillTallerThanStrip_nilMid_stillReturnsFallback() {
        XCTAssertEqual(originY(strip: 20, pill: 24, mid: nil, fallback: 2), 2,
                       accuracy: 0.0001)
    }

    // MARK: - Integration helpers

    private func makeHostedStrip() throws -> (strip: TabStripView, closeButton: NSButton) {
        let window = Self.hostWindow
        let content = try XCTUnwrap(window.contentView, "window has a content view")
        let closeButton = try XCTUnwrap(
            window.standardWindowButton(.closeButton),
            "a titled window has a close button")

        let strip = TabStripView(frame: NSRect(
            x: 0, y: 0, width: 300, height: Self.stripHeight))
        content.addSubview(strip)
        addTeardownBlock { strip.removeFromSuperview() }

        strip.update(tabs: [window], selected: window, width: 300)
        return (strip, closeButton)
    }

    /// Close button's vertical midline expressed in the strip's own
    /// (flipped) coordinates.
    private func closeMidY(_ strip: TabStripView, _ button: NSButton) -> CGFloat {
        strip.convert(button.bounds, from: button).midY
    }

    /// Slides the strip vertically (in its superview) until the close
    /// button's midline, in strip coordinates, equals `target`. The strip's
    /// absolute position inside the content view is arbitrary in a headless
    /// test, so we measure the current midline and shift the frame by the
    /// difference. Moving the frame's y by +d changes the converted midY by
    /// the same d (the relation is linear with slope 1 whichever way the
    /// superview is flipped, up to sign); we probe the sign rather than assume
    /// it.
    private func positionStrip(
        _ strip: TabStripView, button: NSButton, closeMidYTarget target: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<2 {
            let before = closeMidY(strip, button)
            let probeDelta: CGFloat = 1
            strip.frame.origin.y += probeDelta
            let slope = closeMidY(strip, button) - before   // +1 or -1
            strip.frame.origin.y -= probeDelta
            guard abs(slope) > 0.5 else {
                XCTFail("strip move did not affect converted close midY", file: file, line: line)
                return
            }
            strip.frame.origin.y += (target - before) / slope
        }
        XCTAssertEqual(closeMidY(strip, button), target, accuracy: 0.01,
            "test precondition: strip positioned so close midY == \(target)",
            file: file, line: line)
    }

    private func assertPillsCentred(
        _ strip: TabStripView, onMidY mid: CGFloat, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frames = strip.pillFramesForTesting
        XCTAssertEqual(frames.count, 1, "one tab -> one pill", file: file, line: line)
        for f in frames {
            XCTAssertEqual(f.height, Self.pillHeight, accuracy: 0.01,
                "pill height", file: file, line: line)
            XCTAssertEqual(f.midY, mid, accuracy: Self.tolerance, message,
                           file: file, line: line)
        }
    }

    // MARK: - Integration: pills track the close button

    func test_pills_centreOnCloseButtonMidline_whenInRange() throws {
        let (strip, button) = try makeHostedStrip()
        // Choose the strip's origin so the close button's midline lands at
        // 13 pt in strip coordinates: pill origin 1, comfortably inside the
        // clamp range 0...4 (midY range 12...16).
        positionStrip(strip, button: button, closeMidYTarget: 13)

        strip.viewWillDraw()

        let expected = closeMidY(strip, button)
        assertPillsCentred(strip, onMidY: expected,
            "pill midY must equal the close button midY in strip coords")
        XCTAssertEqual(strip.pillFramesForTesting[0].minY, 1, accuracy: Self.tolerance,
            "13 pt midline with a 24 pt pill -> origin y 1")
    }

    func test_addButton_sharesPillRow_whenHostedInWindow() throws {
        let (strip, button) = try makeHostedStrip()
        positionStrip(strip, button: button, closeMidYTarget: 14)

        strip.viewWillDraw()

        let pill = try XCTUnwrap(strip.pillFramesForTesting.first)
        let add = strip.addButtonFrameForTesting
        XCTAssertEqual(add.minY, pill.minY, accuracy: Self.tolerance,
            "+ button must be placed on the same y as the pills")
        XCTAssertEqual(pill.midY, 14, accuracy: Self.tolerance,
            "pill midline on the close button midline")
    }

    func test_pills_followTitlebar_whenStripMoves() throws {
        let (strip, button) = try makeHostedStrip()
        // Start at midline 12.5 and move to 15.5: both inside the clamp range
        // (12...16), so neither position is clamped and the 3 pt shift must
        // be reproduced exactly by the pills.
        positionStrip(strip, button: button, closeMidYTarget: 12.5)
        strip.viewWillDraw()
        let firstExpected = closeMidY(strip, button)
        let firstMid = try XCTUnwrap(strip.pillFramesForTesting.first).midY
        XCTAssertEqual(firstMid, firstExpected, accuracy: Self.tolerance,
            "precondition: pills centred at the first position")

        // Move the strip by 3 pt in its superview (frame.origin.y += 3 or -= 3
        // depending on flipping, picked so the converted midline goes 12.5 -> 15.5).
        let before = closeMidY(strip, button)
        strip.frame.origin.y += 3
        let moved = closeMidY(strip, button) - before
        if moved < 0 { strip.frame.origin.y -= 6 }
        let secondExpected = closeMidY(strip, button)
        XCTAssertEqual(secondExpected - firstExpected, 3, accuracy: 0.01,
            "test precondition: the close button midline moved +3 in strip coordinates")
        XCTAssertGreaterThanOrEqual(secondExpected, 12,
            "test precondition: second position inside the clamp range")
        XCTAssertLessThanOrEqual(secondExpected, 16,
            "test precondition: second position inside the clamp range")

        strip.viewWillDraw()

        let secondMid = try XCTUnwrap(strip.pillFramesForTesting.first).midY
        XCTAssertEqual(secondMid, secondExpected, accuracy: Self.tolerance,
            "pills must re-centre on the close button after the strip moves")
        XCTAssertEqual(secondMid - firstMid, 3, accuracy: Self.tolerance,
            "pills follow the titlebar by the same 3 pt, not a fixed offset")
    }

    func test_pills_clampToTopEdge_whenCloseButtonAboveStrip() throws {
        let (strip, button) = try makeHostedStrip()
        // Settle the pills mid-range first, so reaching the clamp below has to
        // come from `viewWillDraw` re-placing them (not from the initial layout).
        positionStrip(strip, button: button, closeMidYTarget: 14)
        strip.viewWillDraw()
        let settled = try XCTUnwrap(strip.pillFramesForTesting.first).minY
        XCTAssertEqual(settled, 2, accuracy: Self.tolerance, "precondition: mid-range, not clamped")

        // Midline at -20 would need a negative origin: pills clamp to y = 0.
        positionStrip(strip, button: button, closeMidYTarget: -20)

        strip.viewWillDraw()

        let f = try XCTUnwrap(strip.pillFramesForTesting.first)
        XCTAssertEqual(f.minY, 0, accuracy: Self.tolerance, "clamped to the strip's top")
        XCTAssertGreaterThanOrEqual(f.minY, -Self.tolerance)
        XCTAssertLessThanOrEqual(f.maxY, Self.stripHeight + Self.tolerance)
    }

    func test_pills_clampToBottomEdge_whenCloseButtonBelowStrip() throws {
        let (strip, button) = try makeHostedStrip()
        positionStrip(strip, button: button, closeMidYTarget: 14)
        strip.viewWillDraw()
        let settled = try XCTUnwrap(strip.pillFramesForTesting.first).minY
        XCTAssertEqual(settled, 2, accuracy: Self.tolerance, "precondition: mid-range, not clamped")

        positionStrip(strip, button: button, closeMidYTarget: 60)

        strip.viewWillDraw()

        let f = try XCTUnwrap(strip.pillFramesForTesting.first)
        XCTAssertEqual(f.minY, Self.stripHeight - Self.pillHeight, accuracy: Self.tolerance,
            "clamped to the strip's bottom (origin 4)")
        XCTAssertLessThanOrEqual(f.maxY, Self.stripHeight + Self.tolerance)
        XCTAssertGreaterThanOrEqual(f.minY, -Self.tolerance)
    }

    // MARK: - Integration: detached strip

    func test_detachedStrip_usesFallbackRow_pillsAndAddButtonAligned() {
        // Never added to any view hierarchy, so there is no close button to
        // follow. The host window is only used as the tab model object.
        let strip = TabStripView(frame: NSRect(
            x: 0, y: 0, width: 300, height: Self.stripHeight))
        let window = Self.hostWindow
        strip.update(tabs: [window], selected: window, width: 300)

        let frames = strip.pillFramesForTesting
        XCTAssertEqual(frames.count, 1, "one tab -> one pill")
        let pill = frames[0]
        XCTAssertEqual(pill.height, Self.pillHeight, accuracy: 0.01)
        XCTAssertEqual(pill.minY, Self.stripHeight - Self.pillHeight, accuracy: Self.tolerance,
            "no traffic light to follow: pills sit on the documented fallback row (flush with the bottom)")
        XCTAssertEqual(strip.addButtonFrameForTesting.minY, pill.minY, accuracy: Self.tolerance,
            "+ button shares the pills' y in the detached fallback layout")
    }
}
