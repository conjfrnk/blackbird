import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored regression coverage for "the link-hover tooltip must stay on
/// screen".
///
/// The author of this file has not read the body of `TooltipController.swift`
/// (project policy, CLAUDE.md "Author new behavior tests blind"). Only the
/// declarations and doc comments were consulted:
///
///   - `TooltipController.show(text:near:)` takes a *screen-space* anchor (the
///     pointer position) and shows a borderless, non-activating `NSPanel` "just
///     below-right of `screenPoint`".
///   - The tooltip is the hover-to-verify gesture for OSC 8 hrefs: it is the
///     user's only way to see the real destination before clicking, so a tooltip
///     the user cannot read is a security regression, not a cosmetic one.
///
/// **The contract pinned here.** Whatever anchor the pointer hands in, the
/// tooltip panel must lie entirely inside the frame of the screen the pointer is
/// on, at its natural (un-shrunk) size. macOS convention for tooltips and menus
/// is to flip or slide a popup back on screen rather than let it hang over an
/// edge. A link on the last terminal row of a fullscreen window (pointer within
/// ~34 pt of the screen bottom) or near the right edge of the screen (pointer
/// within `panelWidth + 12` pt of it) is the common trigger.
///
/// What is deliberately NOT pinned: *how* the panel is repositioned (flip above
/// the pointer, slide left, clamp to `frame` or to `visibleFrame`). Any of them
/// satisfies "fully inside the screen frame", which is the weakest guarantee
/// that still lets the user read the URL.
///
/// **Rig.** `NSScreen` has no public initializer, so the test runs against the
/// real main display of the test host and builds its anchors from that screen's
/// `frame` (not `visibleFrame`): measured against the full frame the assertion
/// holds regardless of whether the Dock / menu bar is shown, auto-hidden or
/// absent, and the unclamped panel is off-screen in every one of those setups.
/// The panel itself is private to the controller, so it is located by reflecting
/// on the controller's `panel` field, falling back to a search of
/// `NSApplication.windows` for the `NSPanel` hosting our (unique) label text.
///
/// **Memory / time pre-flight** (CLAUDE.md test-authoring rule): one
/// `TooltipController` per test, one tiny borderless panel (a few hundred pt
/// wide, ~22 pt tall) reused across every `show`. A test performs at most ~10
/// shows; there is no PTY, no `TerminalView`, no `MainWindowController`, no
/// Metal. The panel is never added to a tab group. Each test is a few
/// milliseconds.
final class TooltipScreenClampBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Controllers created by a test, dismissed in `tearDown` so no tooltip
    /// panel outlives its test.
    private var controllers: [TooltipController] = []

    override func tearDown() {
        for controller in controllers {
            controller.dismiss()
        }
        controllers.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A short detected URL: the tooltip is a small panel, so only anchors
    /// within a couple hundred points of the right edge overflow it.
    private let shortURL = "https://a.io/x"

    /// A long OSC 8 href (~96 chars): a panel several hundred points wide, so
    /// anchors well inside the right half of the screen still overflow it.
    private let longURL = "https://example.com/account/security/verify-your-identity/session/"
        + "0123456789abcdef0123456789abcdef?redirect=/settings"

    private struct Rig {
        let controller: TooltipController
        /// Full frame of the screen the anchors live on, in global screen
        /// coordinates (bottom-left origin, y up).
        let screenFrame: NSRect
    }

    private func makeRig() throws -> Rig {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("No NSScreen on this host; a screen clamp is unobservable without a display.")
        }
        let controller = TooltipController()
        controllers.append(controller)
        return Rig(controller: controller, screenFrame: screen.frame)
    }

    /// Shows `text` near `anchor` and returns the resulting panel frame in
    /// global screen coordinates. Fails the test (rather than returning a bogus
    /// frame) if the panel cannot be found: a missing panel would otherwise let
    /// every assertion below pass vacuously.
    private func showAndMeasure(_ rig: Rig, text: String, at anchor: NSPoint) throws -> NSRect {
        rig.controller.show(text: text, near: anchor)
        let panel = try XCTUnwrap(
            findPanel(of: rig.controller, showing: text),
            "No tooltip NSPanel found after show(text: \(text), near: \(anchor))"
        )
        return panel.frame
    }

    private func findPanel(of controller: TooltipController, showing text: String) -> NSPanel? {
        for child in Mirror(reflecting: controller).children where child.label == "panel" {
            if let panel = child.value as? NSPanel {
                return panel
            }
        }
        for window in NSApplication.shared.windows {
            if let panel = window as? NSPanel, Self.hasLabelText(text, in: panel.contentView) {
                return panel
            }
        }
        return nil
    }

    private static func hasLabelText(_ text: String, in root: NSView?) -> Bool {
        guard let root = root else { return false }
        if let field = root as? NSTextField, field.stringValue == text {
            return true
        }
        for sub in root.subviews where hasLabelText(text, in: sub) {
            return true
        }
        return false
    }

    /// The tooltip's natural size for `text`, measured at the centre of the
    /// screen where nothing can clip it. Also asserts the preconditions every
    /// edge scenario relies on, so a broken rig fails loudly instead of letting
    /// the edge assertions pass for the wrong reason:
    ///   - the panel exists and is entirely on screen when there is room,
    ///   - it hangs below-right of the anchor (the documented placement),
    ///   - it is small enough that "fully on screen" is satisfiable.
    private func naturalSize(_ rig: Rig, text: String) throws -> NSSize {
        let sf = rig.screenFrame
        let anchor = NSPoint(x: sf.midX, y: sf.midY)
        let frame = try showAndMeasure(rig, text: text, at: anchor)

        XCTAssertTrue(
            sf.contains(frame),
            "precondition: a mid-screen tooltip must be fully on screen. panel=\(frame) screen=\(sf)"
        )
        XCTAssertGreaterThanOrEqual(
            frame.minX, anchor.x,
            "precondition: with room to spare the tooltip hangs to the right of the pointer. panel=\(frame) anchor=\(anchor)"
        )
        XCTAssertLessThanOrEqual(
            frame.maxY, anchor.y,
            "precondition: with room to spare the tooltip hangs below the pointer. panel=\(frame) anchor=\(anchor)"
        )
        XCTAssertGreaterThan(
            frame.width, 20,
            "precondition: tooltip for \"\(text)\" has a real width. panel=\(frame)"
        )
        XCTAssertLessThan(
            frame.width, sf.width - 40,
            "precondition: tooltip must be narrower than the screen for a clamp to be satisfiable. panel=\(frame) screen=\(sf)"
        )
        XCTAssertLessThan(
            frame.height, sf.height / 2,
            "precondition: tooltip must be shorter than half the screen. panel=\(frame) screen=\(sf)"
        )
        return frame.size
    }

    // MARK: - Assertions

    /// Fraction of the panel's area that lies on `screen` (1.0 = fully visible).
    private func visibleFraction(of frame: NSRect, on screen: NSRect) -> Double {
        let area = Double(frame.width * frame.height)
        guard area > 0 else { return 0 }
        let overlap = frame.intersection(screen)
        if overlap.isNull || overlap.isEmpty { return 0 }
        return Double(overlap.width * overlap.height) / area
    }

    /// Asserts `frame` lies entirely within `screen` on every side, and that it
    /// kept its natural size (the fix must move the tooltip, not truncate the
    /// URL the user is trying to verify). Every message carries the measured
    /// numbers.
    private func assertFullyOnScreen(
        _ frame: NSRect,
        on screen: NSRect,
        naturalSize: NSSize,
        anchor: NSPoint,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detail =
            "\(scenario): anchor=\(anchor) panel=\(frame) screen=\(screen) "
            + "visible=\(Int((visibleFraction(of: frame, on: screen) * 100).rounded()))%"

        let leftOverflow = max(0, screen.minX - frame.minX)
        let rightOverflow = max(0, frame.maxX - screen.maxX)
        let bottomOverflow = max(0, screen.minY - frame.minY)
        let topOverflow = max(0, frame.maxY - screen.maxY)

        XCTAssertEqual(
            bottomOverflow, 0, accuracy: 0.5,
            "tooltip hangs below the bottom of the screen by \(bottomOverflow) pt. \(detail)",
            file: file, line: line
        )
        XCTAssertEqual(
            rightOverflow, 0, accuracy: 0.5,
            "tooltip hangs past the right edge of the screen by \(rightOverflow) pt. \(detail)",
            file: file, line: line
        )
        XCTAssertEqual(
            leftOverflow, 0, accuracy: 0.5,
            "tooltip hangs past the left edge of the screen by \(leftOverflow) pt. \(detail)",
            file: file, line: line
        )
        XCTAssertEqual(
            topOverflow, 0, accuracy: 0.5,
            "tooltip hangs past the top edge of the screen by \(topOverflow) pt. \(detail)",
            file: file, line: line
        )
        XCTAssertEqual(
            frame.width, naturalSize.width, accuracy: 0.5,
            "tooltip was resized instead of moved (width). \(detail)",
            file: file, line: line
        )
        XCTAssertEqual(
            frame.height, naturalSize.height, accuracy: 0.5,
            "tooltip was resized instead of moved (height). \(detail)",
            file: file, line: line
        )
    }

    // MARK: - Bottom edge

    /// A link on the last terminal row of a fullscreen window: the pointer is a
    /// few points to a few tens of points above the bottom of the screen. The
    /// tooltip, placed below the pointer, must not fall off the bottom.
    func test_lastRowAtScreenBottom_shortURL_tooltipIsFullyOnScreen() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame
        let size = try naturalSize(rig, text: shortURL)

        for distanceFromBottom: CGFloat in [4, 10, 20, 30] {
            let anchor = NSPoint(x: sf.midX, y: sf.minY + distanceFromBottom)
            let frame = try showAndMeasure(rig, text: shortURL, at: anchor)
            assertFullyOnScreen(
                frame, on: sf, naturalSize: size, anchor: anchor,
                scenario: "short URL, pointer \(distanceFromBottom) pt above screen bottom"
            )
        }
    }

    /// Same trigger with a long OSC 8 href: the wide panel must still be fully
    /// visible vertically.
    func test_lastRowAtScreenBottom_longURL_tooltipIsFullyOnScreen() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame
        let size = try naturalSize(rig, text: longURL)

        for distanceFromBottom: CGFloat in [4, 12, 24] {
            let anchor = NSPoint(x: sf.minX + size.width / 2 + 40, y: sf.minY + distanceFromBottom)
            let frame = try showAndMeasure(rig, text: longURL, at: anchor)
            assertFullyOnScreen(
                frame, on: sf, naturalSize: size, anchor: anchor,
                scenario: "long URL, pointer \(distanceFromBottom) pt above screen bottom"
            )
        }
    }

    // MARK: - Right edge

    /// A short URL whose pointer is within `panelWidth + 12` pt of the right
    /// edge of the screen (a fullscreen terminal's right-hand columns).
    func test_nearScreenRightEdge_shortURL_tooltipIsFullyOnScreen() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame
        let size = try naturalSize(rig, text: shortURL)

        let distances: [CGFloat] = [4, 20, size.width / 2, max(size.width - 4, 4)]
        for distanceFromRight in distances {
            let anchor = NSPoint(x: sf.maxX - distanceFromRight, y: sf.midY)
            let frame = try showAndMeasure(rig, text: shortURL, at: anchor)
            assertFullyOnScreen(
                frame, on: sf, naturalSize: size, anchor: anchor,
                scenario: "short URL, pointer \(distanceFromRight) pt left of screen right edge"
            )
        }
    }

    /// A long href whose pointer is far from the right edge in absolute terms
    /// (still in the right half of the screen) but closer than the panel is
    /// wide, so the panel overhangs.
    func test_rightHalfOfScreen_longURL_tooltipIsFullyOnScreen() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame
        let size = try naturalSize(rig, text: longURL)

        let distances: [CGFloat] = [4, size.width / 4, size.width / 2, max(size.width - 4, 4)]
        for distanceFromRight in distances {
            let anchor = NSPoint(x: sf.maxX - distanceFromRight, y: sf.midY)
            let frame = try showAndMeasure(rig, text: longURL, at: anchor)
            assertFullyOnScreen(
                frame, on: sf, naturalSize: size, anchor: anchor,
                scenario: "long URL, pointer \(distanceFromRight) pt left of screen right edge"
            )
        }
    }

    // MARK: - Corner

    /// Last row, last columns: both edges clip at once. The tooltip must be
    /// fully visible on both axes simultaneously.
    func test_bottomRightCorner_tooltipIsFullyOnScreen() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame

        for text in [shortURL, longURL] {
            let size = try naturalSize(rig, text: text)
            let anchor = NSPoint(x: sf.maxX - 8, y: sf.minY + 10)
            let frame = try showAndMeasure(rig, text: text, at: anchor)
            assertFullyOnScreen(
                frame, on: sf, naturalSize: size, anchor: anchor,
                scenario: "bottom-right corner, \(text.count)-char URL"
            )
        }
    }

    // MARK: - Reuse

    /// The panel is reused across shows. After a tooltip was shown at an edge
    /// the next one, with room to spare, must hang below-right of its own
    /// anchor again; and a later edge show must be clamped again. (Guards a fix
    /// that mutates sticky panel state, e.g. leaves the panel pinned to the
    /// last clamped origin.)
    func test_reusedPanel_isRepositionedForEachShow() throws {
        let rig = try makeRig()
        let sf = rig.screenFrame
        let size = try naturalSize(rig, text: shortURL)

        let edgeAnchor = NSPoint(x: sf.maxX - 6, y: sf.minY + 8)
        let first = try showAndMeasure(rig, text: shortURL, at: edgeAnchor)
        assertFullyOnScreen(
            first, on: sf, naturalSize: size, anchor: edgeAnchor,
            scenario: "reuse step 1: bottom-right corner"
        )

        let roomyAnchor = NSPoint(x: sf.midX, y: sf.midY)
        let second = try showAndMeasure(rig, text: shortURL, at: roomyAnchor)
        XCTAssertGreaterThanOrEqual(
            second.minX, roomyAnchor.x,
            "reuse step 2: with room to spare the tooltip hangs right of the pointer. panel=\(second) anchor=\(roomyAnchor)"
        )
        XCTAssertLessThanOrEqual(
            second.maxY, roomyAnchor.y,
            "reuse step 2: with room to spare the tooltip hangs below the pointer. panel=\(second) anchor=\(roomyAnchor)"
        )

        let third = try showAndMeasure(rig, text: shortURL, at: edgeAnchor)
        assertFullyOnScreen(
            third, on: sf, naturalSize: size, anchor: edgeAnchor,
            scenario: "reuse step 3: bottom-right corner again"
        )
    }
}
