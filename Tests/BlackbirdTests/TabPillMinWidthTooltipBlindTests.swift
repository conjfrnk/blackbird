import XCTest
import AppKit
import ObjectiveC
@testable import Blackbird

/// Blind-authored regression tests for **tab pills must keep a usable minimum
/// width, tell the user which tab is which (tooltip), and offer a usable
/// inline-rename field, however many tabs are open**.
///
/// Written purely from the bug report and from the declarations of
/// `TabStripView` (`update(tabs:selected:width:)`, `beginEditing(pillIndex:)`,
/// the DEBUG `pillFramesForTesting` / `isEditingForTesting` /
/// `cancelEditForTesting` hooks) and `TabStripLayout.titleArea`. The bodies of
/// `layoutPills`, `drawPill`, `applyHover`, `TabRenameController.fieldRect`
/// were NOT read (CLAUDE.md "Author new behavior tests blind").
///
/// ## The bug being pinned
///
/// The strip divides its width equally among the pills with no lower bound.
/// With 30 tabs on a 1400 pt strip each pill is ~46 pt wide, its title region
/// ~20 pt, so every title is truncated to nothing (the truncation helper
/// returns a bare "" at <= 20 pt) and the selected pill is blank too. 20 tabs
/// read "cl...", 15 tabs on a 1000 pt strip read "claud...". Nothing else
/// identifies a pill either: there is no tooltip, so the user cannot tell
/// which tab runs which session before clicking (and the hover close-x makes
/// closing the wrong live session easy). Double-clicking a pill opens a
/// rename field that is about 19 pt wide.
///
/// ## Contract (derived from tab-bar conventions, not from the current code)
///
/// Every mainstream tab bar (Firefox `tabMinWidth` 76 pt, Safari, Terminal.app,
/// iTerm2) has a minimum tab width and falls back to overflow handling past
/// it, instead of shrinking tabs into blank stubs; and a truncated tab title is
/// always available in full as a tooltip. So:
///
///   1. PILL MINIMUM. At 30 tabs / 1400 pt, 21 tabs / 1000 pt and 15 tabs /
///      1000 pt (the three situations the report lists) every pill's title
///      region must be wide enough to show the first six characters of a title
///      plus the ellipsis ("claude..."), which is what it takes to tell a
///      `claude` session from a `zsh` or `vim` one. That works out to a pill of
///      roughly 72 pt. How the surplus is handled (scrolling, clipping,
///      overflow menu) is deliberately NOT pinned.
///   2. TOOLTIP. Hovering a pill shows that tab's full, untruncated title as
///      a tooltip. Pinned for every pill that is on-screen at 30 tabs /
///      1400 pt. HOW the tooltip is registered (`NSView.toolTip` set on hover,
///      `addToolTip(_:owner:userData:)` per pill, a tooltip on an overlay
///      subview) is not pinned: the probe below reads whatever AppKit has
///      registered over the pill's centre.
///   3. RENAME FIELD. Double-clicking (`beginEditing`) a pill at 30 tabs /
///      1400 pt opens a field at least as wide as the text "claude" (the same
///      six characters), so a new name can actually be seen while typed.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - No `MainWindowController`, no PTY, no shell, no tab-group merge: stub
///     `NSWindow`s with `tabbingMode = .disallowed` stand in for tabs
///     (`TabStripDragTests` / `InlineRenameTests` pattern).
///   - ONE plain titled window is parked in a static for process lifetime and
///     hosts the strip (`TabStripTrafficLightAlignmentTests` pattern). It is
///     never shown, ordered, or closed; strips are only removed from it.
///   - Cost: <= 30 stub windows (~40 KB each, ~1.2 MB) per test, 5 tests; the
///     strip is 1400 x 28 pt. No sleeps, no runloop pumping. < 100 ms each.
///   - Events are built with `NSEvent.mouseEvent` and delivered by direct
///     method call (no CGEvent / AppleScript injection).
///
/// ## About the tooltip probe
///
/// AppKit exposes no public query for registered tooltips. They are however
/// installed as `NSTrackingArea`s owned by an `NSToolTipManager`, and each
/// area's private `userInfo` ivar holds an `NSToolTip` object whose `_string`,
/// `owner`, `trackingNum` and `_weakData` ivars are exactly what AppKit itself
/// passes to `view(_:stringForToolTip:point:userData:)`. The probe reads those
/// through the ObjC runtime. Because that is private layout, the tests first
/// run a POSITIVE CONTROL (a scratch view with a known `toolTip` string and a
/// known owner-based tooltip); if the probe cannot read the control back on
/// this OS the tooltip tests skip with that reason rather than reporting a
/// false failure. On the unfixed code the control passes and the strip has no
/// tooltip areas at all, so the tooltip test fails for exactly the bug.
@MainActor
final class TabPillMinWidthTooltipBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    /// Title font of a pill (system 12 pt regular).
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    /// Side of the leading close hotspot that precedes the title region.
    private static let closeWidth: CGFloat = 14
    /// The title region of a pill must fit this much text.
    private static let legiblePillText = "claude\u{2026}"
    /// The rename field must fit this much text.
    private static let legibleFieldText = "claude"

    private static func textWidth(_ s: String) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: titleFont]).size().width
    }

    // MARK: - The single parked host window

    /// Parked for process lifetime. Never shown, never closed.
    private static let hostWindow: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.tabbingMode = .disallowed
        w.title = "tab-pill-min-width-host"
        return w
    }()

    // MARK: - Rig helpers

    private func title(_ i: Int) -> String {
        String(format: "claude-session-%02d (repo-%02d)", i, i)
    }

    private func makeStubTabs(_ count: Int) -> [NSWindow] {
        (0..<count).map { (i: Int) -> NSWindow in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            // Never merge into a real tab group (see TabStripDragTests).
            w.tabbingMode = .disallowed
            w.title = title(i)
            return w
        }
    }

    private struct Rig {
        let strip: TabStripView
        let tabs: [NSWindow]
    }

    /// A strip of `tabCount` stub tabs hosted in the parked window and laid
    /// out at `stripWidth` through the production `update` path.
    private func makeHostedStrip(tabCount: Int, stripWidth: CGFloat,
                                 selectedIndex: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let content = try XCTUnwrap(Self.hostWindow.contentView, "host window has a content view",
                                    file: file, line: line)
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: stripWidth,
                                               height: TabStripView.height))
        content.addSubview(strip)
        let tabs = makeStubTabs(tabCount)
        addTeardownBlock {
            strip.cancelEditForTesting()
            strip.removeFromSuperview()
            strip.detachTabs()
        }
        strip.update(tabs: tabs, selected: tabs[selectedIndex], width: stripWidth)

        XCTAssertEqual(strip.pillCountForTesting, tabCount,
            "PRECONDITION: one pill per tab (got \(strip.pillCountForTesting) for \(tabCount) tabs)",
            file: file, line: line)
        XCTAssertEqual(strip.frame.width, stripWidth, accuracy: 0.5,
            "PRECONDITION: strip laid out at the requested width", file: file, line: line)
        return Rig(strip: strip, tabs: tabs)
    }

    private func makeMouseMovedEvent(in strip: TabStripView, atStripPoint p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: strip.convert(p, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: Self.hostWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    // MARK: - 1. Pill minimum width

    /// Every pill's title region must fit "claude..." in the given situation.
    private func assertPillTitleRegionsLegible(tabCount: Int, stripWidth: CGFloat,
                                               selectedIndex: Int,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let rig = try makeHostedStrip(tabCount: tabCount, stripWidth: stripWidth,
                                      selectedIndex: selectedIndex, file: file, line: line)
        let frames = rig.strip.pillFramesForTesting
        let needed = Self.textWidth(Self.legiblePillText)
        XCTAssertGreaterThan(needed, 20,
            "PRECONDITION: the reference text must be wider than a bare-ellipsis stub",
            file: file, line: line)

        let regions: [CGFloat] = frames.map { (f: CGRect) -> CGFloat in
            TabStripLayout.titleArea(in: f, closeWidth: Self.closeWidth).width
        }
        var tooNarrow: [Int] = []
        for (i, region) in regions.enumerated() where region < needed {
            tooNarrow.append(i)
        }
        let narrowest = frames.map { $0.width }.min() ?? -1
        let narrowestRegion = regions.min() ?? -1
        let selectedFrame = selectedIndex < frames.count ? frames[selectedIndex] : .zero
        let selectedRegion = selectedIndex < regions.count ? regions[selectedIndex] : -1
        XCTAssertEqual(tooNarrow, [],
            "[\(tabCount) tabs @ \(stripWidth) pt strip] \(tooNarrow.count) of \(frames.count) "
                + "pills have a title region too narrow to show '\(Self.legiblePillText)' "
                + "(needs \(needed) pt). Narrowest pill \(narrowest) pt wide / title region "
                + "\(narrowestRegion) pt; the selected pill #\(selectedIndex) is "
                + "\(selectedFrame.width) pt wide / title region \(selectedRegion) pt. "
                + "Pills must keep a minimum width instead of dividing the strip equally.",
            file: file, line: line)
    }

    func test_pillMinimumWidth_30tabsOn1400Strip_everyTitleRegionFitsAReadablePrefix() throws {
        try assertPillTitleRegionsLegible(tabCount: 30, stripWidth: 1400, selectedIndex: 14)
    }

    func test_pillMinimumWidth_21tabsOn1000Strip_everyTitleRegionFitsAReadablePrefix() throws {
        try assertPillTitleRegionsLegible(tabCount: 21, stripWidth: 1000, selectedIndex: 20)
    }

    func test_pillMinimumWidth_15tabsOn1000Strip_everyTitleRegionFitsAReadablePrefix() throws {
        try assertPillTitleRegionsLegible(tabCount: 15, stripWidth: 1000, selectedIndex: 0)
    }

    // MARK: - 3. Inline rename field

    func test_inlineRename_30tabsOn1400Strip_fieldIsWideEnoughToSeeTheName() throws {
        let rig = try makeHostedStrip(tabCount: 30, stripWidth: 1400, selectedIndex: 0)
        let content = try XCTUnwrap(Self.hostWindow.contentView, "host window has a content view")
        let needed = Self.textWidth(Self.legibleFieldText)

        var failures: [String] = []
        // Early, middle and late pills: the field must not depend on position.
        for index in [2, 14, 27] {
            rig.strip.beginEditing(pillIndex: index)
            XCTAssertTrue(rig.strip.isEditingForTesting,
                "PRECONDITION: beginEditing(pillIndex: \(index)) must enter rename mode")

            let fields: [NSTextField] = TooltipProbe.allViews(content).compactMap {
                (v: NSView) -> NSTextField? in v as? NSTextField
            }
            XCTAssertEqual(fields.count, 1,
                "PRECONDITION: exactly one rename NSTextField while editing pill \(index)")
            if let field = fields.first {
                let width = field.frame.width
                let pillWidth = rig.strip.pillFramesForTesting[index].width
                if width < needed {
                    failures.append("pill #\(index) (\(pillWidth) pt wide): rename field is "
                        + "\(width) pt wide, needs >= \(needed) pt to show '\(Self.legibleFieldText)'")
                }
            }
            rig.strip.cancelEditForTesting()
            XCTAssertFalse(rig.strip.isEditingForTesting,
                "PRECONDITION: cancel must leave rename mode before the next pill")
        }
        XCTAssertEqual(failures, [],
            "[30 tabs @ 1400 pt strip] the inline-rename field must be usable, not a ~19 pt sliver")
    }

    // MARK: - 2. Tooltip with the full title

    /// Runs the positive control for the tooltip probe; skips when this OS's
    /// AppKit hides tooltips from it (see the class doc).
    private func requireWorkingTooltipProbe() throws {
        let content = try XCTUnwrap(Self.hostWindow.contentView, "host window has a content view")

        let propertyView = NSView(frame: NSRect(x: 0, y: 100, width: 80, height: 20))
        propertyView.toolTip = ControlToolTipOwner.propertyText
        let ownerView = NSView(frame: NSRect(x: 100, y: 100, width: 80, height: 20))
        let owner = ControlToolTipOwner()
        _ = ownerView.addToolTip(ownerView.bounds, owner: owner, userData: nil)
        content.addSubview(propertyView)
        content.addSubview(ownerView)
        defer {
            propertyView.removeFromSuperview()
            ownerView.removeFromSuperview()
        }

        let viaProperty = TooltipProbe.texts(in: propertyView, at: NSPoint(x: 40, y: 10))
        let viaOwner = TooltipProbe.texts(in: ownerView, at: NSPoint(x: 40, y: 10))
        withExtendedLifetime(owner) {}
        guard viaProperty == [ControlToolTipOwner.propertyText],
              viaOwner == [ControlToolTipOwner.ownerText] else {
            throw XCTSkip("tooltip probe could not read back its own control on this OS "
                + "(NSToolTip internals changed?): toolTip property -> \(viaProperty), "
                + "owner tooltip -> \(viaOwner)")
        }
    }

    func test_hover_30tabsOn1400Strip_everyVisiblePillShowsItsFullTitleAsTooltip() throws {
        try requireWorkingTooltipProbe()
        let rig = try makeHostedStrip(tabCount: 30, stripWidth: 1400, selectedIndex: 14)
        // Registration may happen at layout or at updateTrackingAreas time;
        // an unshown window never calls the latter by itself.
        rig.strip.updateTrackingAreas()

        let frames = rig.strip.pillFramesForTesting
        var checked = 0
        var problems: [String] = []
        for (i, frame) in frames.enumerated() {
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            // Only pills the user can actually hover (an overflow design may
            // park the rest off-strip).
            guard rig.strip.bounds.contains(centre) else { continue }
            checked += 1
            // A hover-driven implementation sets its tooltip on mouseMoved.
            rig.strip.mouseMoved(with: makeMouseMovedEvent(in: rig.strip, atStripPoint: centre))
            let texts = TooltipProbe.texts(in: rig.strip, at: centre)
            let full = title(i)
            if !texts.contains(where: { (t: String) -> Bool in t.contains(full) }) {
                problems.append("pill #\(i) (\(frame.width) pt wide): tooltip texts \(texts), "
                    + "expected one containing '\(full)'")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5,
            "PRECONDITION: at least 5 pills must be hoverable inside the strip (checked \(checked))")
        XCTAssertEqual(problems, [],
            "[30 tabs @ 1400 pt strip] hovering a pill must show that tab's full title as a "
                + "tooltip; \(problems.count) of \(checked) hovered pills had none or the wrong one")
    }
}

// MARK: - Tooltip probe

/// Known-text tooltip owner for the probe's positive control.
@MainActor
private final class ControlToolTipOwner: NSObject, NSViewToolTipOwner {
    static let propertyText = "control-tooltip-via-toolTip-property"
    static let ownerText = "control-tooltip-via-owner"

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        Self.ownerText
    }
}

/// Reads the tooltips AppKit has registered on a view tree (see the class doc
/// of `TabPillMinWidthTooltipBlindTests` for why this goes through the ObjC
/// runtime).
@MainActor
private enum TooltipProbe {

    static func allViews(_ root: NSView) -> [NSView] {
        var out: [NSView] = [root]
        for sub in root.subviews {
            out.append(contentsOf: allViews(sub))
        }
        return out
    }

    /// Every tooltip string registered over `point` (expressed in `root`'s
    /// coordinates) anywhere in `root`'s subtree.
    static func texts(in root: NSView, at point: NSPoint) -> [String] {
        var out: [String] = []
        for view in allViews(root) {
            for area in view.trackingAreas where isToolTipArea(area) {
                let rectInRoot = view.convert(area.rect, to: root)
                guard rectInRoot.contains(point) else { continue }
                guard let tip = objectIvar(area, "_userInfo") else { continue }

                if let s = objectIvar(tip, "_string") as? String {
                    out.append(s)
                } else if let owner = objectIvar(tip, "owner") {
                    if let tipOwner = owner as? NSViewToolTipOwner {
                        let tag: NSView.ToolTipTag = intIvar(tip, "trackingNum") ?? 0
                        let data: UnsafeMutableRawPointer? = pointerIvar(tip, "_weakData")
                        out.append(tipOwner.view(view, stringForToolTip: tag,
                                                 point: view.convert(point, from: root),
                                                 userData: data))
                    } else if let s = owner as? String {
                        out.append(s)
                    }
                }
            }
        }
        return out
    }

    private static func isToolTipArea(_ area: NSTrackingArea) -> Bool {
        guard let owner = area.owner else { return false }
        return String(describing: type(of: owner)).contains("ToolTip")
    }

    private static func objectIvar(_ obj: AnyObject, _ name: String) -> AnyObject? {
        guard let iv = class_getInstanceVariable(type(of: obj), name) else { return nil }
        return object_getIvar(obj, iv) as AnyObject?
    }

    private static func intIvar(_ obj: AnyObject, _ name: String) -> Int? {
        guard let iv = class_getInstanceVariable(type(of: obj), name) else { return nil }
        let base = UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
        return base.load(fromByteOffset: ivar_getOffset(iv), as: Int.self)
    }

    private static func pointerIvar(_ obj: AnyObject, _ name: String) -> UnsafeMutableRawPointer? {
        guard let iv = class_getInstanceVariable(type(of: obj), name) else { return nil }
        let base = UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
        return base.load(fromByteOffset: ivar_getOffset(iv), as: UnsafeMutableRawPointer?.self)
    }
}
