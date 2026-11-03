import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **the main window of a first launch
/// (no saved frame) must open centred, not pinned to the bottom edge of the
/// screen** (bug FR-1).
///
/// Written from the bug report / contract only, WITHOUT reading the bodies of
/// `MainWindowController.init`, `makeConfiguredWindow` or the frame-nudge
/// helpers (CLAUDE.md "Author new behavior tests blind"). Only declarations,
/// the `makeForTesting` / `sessionFactoryForTests` seam docs, and sibling tests
/// (`DisplayReconfigFrameSaveBlindTests`, `WindowFrameAutosaveTests`) as
/// harness templates were consulted.
///
/// ## The bug being pinned
///
/// A profile with no `"NSWindow Frame BlackbirdMainWindow"` default (a brand
/// new user) launches Blackbird. `MainWindowController(autosaveFrame: true)` has
/// nothing to restore, and nothing positions the window either, so it keeps
/// the constructor-default frame at the AppKit origin: `y == 0` (flush to the
/// bottom edge of the screen, overlapping the Dock when it is visible) and
/// `x == 0` (or the Stage Manager strip width). The same holds for the first
/// `autosaveFrame: false` window (`open -a Blackbird <dir>`, or Cmd-N) when no
/// frame has ever been saved. Settings, by contrast, centres itself on first
/// show, and every other macOS terminal opens its first window centred.
///
/// ## Contract (observable)
///
/// With the saved-frame default absent, the freshly constructed controller's
/// window must sit where a first window belongs on macOS:
///
///   1. fully inside the `visibleFrame` of the screen it is on;
///   2. NOT flush to the bottom edge: the gap between the window's bottom and
///      the bottom of the visible frame is at least a quarter of the free
///      vertical space (`visibleFrame.height - window.height`). A centred
///      window (AppKit's `center()` puts it exactly centred horizontally and
///      slightly above centre vertically) has more than half; a cascaded
///      top-left window has even more; a window at `y == 0` has ~0;
///   3. horizontally centred in the visible frame, within a 10% of screen
///      width slack that absorbs a cascade offset for the `autosaveFrame:
///      false` window but still rejects `x == 0` / the Stage Manager origin
///      on every real display.
///
/// A control proves the rig can read a restored placement and that the fix
/// must not over-centre: when a frame IS saved it must still win, exactly.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Each test builds ONE real `MainWindowController` through the DEBUG
///     `sessionFactoryForTests` seam (headless 2x2 stub session: no PTY, no
///     shell, no fork), exactly the path `makeForTesting` takes except that the
///     `autosaveFrame` argument is chosen by the test. Controllers are parked in
///     a static for process lifetime and are NEVER shown, closed or ordered out
///     (`DisplayReconfigFrameSaveBlindTests` / `TabPillFramePushBlindTests` are
///     the templates). No tab group is formed, no `showWindow`, no
///     `orderFront`, no AppleScript / CGEvent injection.
///   - The real defaults key is shared with the developer's installed
///     Blackbird (the xctest host runs in that defaults domain), so the key is
///     backed up in `setUp` and restored in `tearDown` of every test.
///   - Cost: three never-shown windows + three Metal-backed terminal views (a
///     few MB each) across the whole file, frames <= 900 x 512 pt, ~0.25 s of
///     runloop pumping per test.
@MainActor
final class FirstLaunchWindowPlacementBlindTests: XCTestCase {

    // MARK: - Parked controllers

    /// Process-lifetime owner of every controller this file builds, so none is
    /// ever deallocated, closed or ordered out.
    private static var parkedControllers: [MainWindowController] = []

    // MARK: - Defaults key (shared with the developer's real Blackbird)

    private static var defaultsKey: String {
        "NSWindow Frame \(MainWindowController.frameAutosaveName)"
    }

    private var originalDefaultsValue: Any?

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        originalDefaultsValue = UserDefaults.standard.object(forKey: Self.defaultsKey)
    }

    override func tearDown() {
        if let original = originalDefaultsValue {
            UserDefaults.standard.set(original, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        super.tearDown()
    }

    // MARK: - Plumbing

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Builds one real controller on the production init path with a headless
    /// stub session. Skips (rather than fails) when there is no Metal device
    /// (CI virtual display), exactly like `makeForTesting`.
    private func makeController(autosaveFrame: Bool) throws -> MainWindowController {
        let stub: TerminalSession = TerminalSession.makeHeadlessForTests()
        MainWindowController.sessionFactoryForTests = { () -> TerminalSession in stub }
        defer { MainWindowController.sessionFactoryForTests = nil }
        let controller = MainWindowController(autosaveFrame: autosaveFrame)
        guard controller.terminalView != nil, controller.session != nil else {
            throw XCTSkip("no Metal device (CI virtual display): the controller has no TerminalView")
        }
        Self.parkedControllers.append(controller)
        return controller
    }

    /// Removes the saved-frame default so the init under test sees a brand-new
    /// profile, and proves it is gone.
    private func clearSavedFrame(file: StaticString = #filePath, line: UInt = #line) {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.defaultsKey),
            "PRECONDITION: the \(Self.defaultsKey) default must be absent (first-launch profile)",
            file: file, line: line)
    }

    /// The screen holding the largest part of `frame`, or nil when the frame
    /// is entirely off every screen.
    private func screen(holding frame: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let overlap = candidate.frame.intersection(frame)
            let area: CGFloat = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = candidate
                bestArea = area
            }
        }
        return best
    }

    private func fmt(_ r: NSRect) -> String {
        "(x \(r.origin.x), y \(r.origin.y), w \(r.width), h \(r.height))"
    }

    /// The shared placement contract. `label` names the scenario in messages.
    private func assertFirstWindowPlacement(
        _ window: NSWindow, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let frame = window.frame
        guard let screen = screen(holding: frame) else {
            var screenFrames: [String] = []
            for s in NSScreen.screens { screenFrames.append(fmt(s.frame)) }
            XCTFail("\(label): window frame \(fmt(frame)) is not on any screen "
                + "(screens: \(screenFrames))", file: file, line: line)
            return
        }
        let vis = screen.visibleFrame
        let free = vis.height - frame.height
        try XCTSkipIf(free < 100 || vis.width < 900,
            "\(label): screen visibleFrame \(fmt(vis)) leaves too little room around a "
                + "\(frame.width) x \(frame.height) window to tell centred from flush")

        // 1. Fully on the visible part of its screen.
        XCTAssertTrue(vis.insetBy(dx: -1, dy: -1).contains(frame),
            "\(label): window \(fmt(frame)) is not inside the screen's visibleFrame \(fmt(vis))",
            file: file, line: line)

        // 2. Not flush to the bottom edge (the reported symptom: y == 0).
        let bottomGap = frame.minY - vis.minY
        let requiredBottomGap = free * 0.25
        XCTAssertGreaterThanOrEqual(bottomGap, requiredBottomGap,
            "\(label): window is pinned to the bottom edge of the screen. Its bottom is "
                + "\(bottomGap) pt above the visibleFrame bottom (window \(fmt(frame)), visibleFrame "
                + "\(fmt(vis))); a first window must leave at least \(requiredBottomGap) pt "
                + "(25% of the \(free) pt of free vertical space)",
            file: file, line: line)

        // 3. Horizontally centred (cascade-offset slack only).
        let slack = max(4, vis.width * 0.10)
        XCTAssertEqual(frame.midX, vis.midX, accuracy: slack,
            "\(label): window is not horizontally centred. Its midX is \(frame.midX) but the "
                + "visibleFrame midX is \(vis.midX) (window \(fmt(frame)), visibleFrame \(fmt(vis)), "
                + "allowed slack \(slack) pt)",
            file: file, line: line)
    }

    // MARK: - Control: a saved frame still wins

    /// Rig control, passing on the unfixed code and required to keep passing:
    /// when a frame IS saved, `MainWindowController(autosaveFrame: true)`
    /// restores it exactly and does not re-centre it. Without this, the
    /// first-launch tests below could be satisfied by "always centre", and a
    /// returning user's saved position would silently be thrown away.
    func test_control_savedFrame_isRestoredExactly_notRecentred() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("test host has no main NSScreen")
        }
        let vis = screen.visibleFrame
        try XCTSkipIf(vis.width < 1200 || vis.height < 800,
            "main screen visibleFrame \(fmt(vis)) too small for the control frame")

        // A deliberately off-centre frame well inside the visible frame.
        let saved = NSRect(x: vis.minX + 40, y: vis.minY + 60, width: 900, height: 420)

        let seeder = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        seeder.isReleasedWhenClosed = false
        defer { seeder.close() }
        seeder.setFrame(saved, display: false)
        seeder.saveFrame(usingName: MainWindowController.frameAutosaveName)
        let seededString: String = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        var seededNumbers: [Double] = []
        for field in seededString.split(separator: " ") {
            if let number = Double(field) { seededNumbers.append(number) }
        }
        XCTAssertEqual(Array(seededNumbers.prefix(4)),
            [Double(saved.minX), Double(saved.minY), Double(saved.width), Double(saved.height)],
            "PRECONDITION: seeding must persist the saved frame under \(Self.defaultsKey) "
                + "(stored \"\(seededString)\")")
        XCTAssertNotEqual(saved.midX, vis.midX,
            "PRECONDITION: the saved frame must be off-centre or the control proves nothing")

        let controller = try makeController(autosaveFrame: true)
        let window = try XCTUnwrap(controller.window, "controller has no window")
        pump(0.25)

        let frame = window.frame
        XCTAssertEqual(frame.origin.x, saved.origin.x, accuracy: 0.5,
            "saved frame must be restored: origin.x \(frame.origin.x), expected \(saved.origin.x) "
                + "(window \(fmt(frame)), saved \(fmt(saved)))")
        XCTAssertEqual(frame.origin.y, saved.origin.y, accuracy: 0.5,
            "saved frame must be restored: origin.y \(frame.origin.y), expected \(saved.origin.y) "
                + "(window \(fmt(frame)), saved \(fmt(saved)))")
        XCTAssertEqual(frame.width, saved.width, accuracy: 0.5,
            "saved frame must be restored: width \(frame.width), expected \(saved.width)")
        XCTAssertEqual(frame.height, saved.height, accuracy: 0.5,
            "saved frame must be restored: height \(frame.height), expected \(saved.height)")
    }

    // MARK: - The bug: first launch, autosaveFrame: true

    /// `AppDelegate.openFirstWindow()` path: `MainWindowController(autosaveFrame:
    /// true)` on a profile with no saved frame. The window must open centred,
    /// not flush to the bottom edge.
    func test_firstLaunch_autosaveTrue_noSavedFrame_windowIsCentredNotFlushToBottom() throws {
        clearSavedFrame()

        let controller = try makeController(autosaveFrame: true)
        let window = try XCTUnwrap(controller.window, "controller has no window")
        pump(0.25)

        try assertFirstWindowPlacement(window, "first launch (autosaveFrame: true, no saved frame)")
    }

    // MARK: - The bug: first window, autosaveFrame: false

    /// `open -a Blackbird <dir>` / Cmd-N path: `autosaveFrame: false` on a
    /// profile where no frame has ever been saved. Same placement contract
    /// (a cascade offset is tolerated by the horizontal slack).
    func test_firstWindow_autosaveFalse_noSavedFrame_windowIsNotFlushToBottom() throws {
        clearSavedFrame()

        let controller = try makeController(autosaveFrame: false)
        let window = try XCTUnwrap(controller.window, "controller has no window")
        pump(0.25)

        try assertFirstWindowPlacement(window, "first window (autosaveFrame: false, no saved frame)")
    }
}
