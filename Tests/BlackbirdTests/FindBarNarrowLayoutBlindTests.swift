import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for the find bar's horizontal layout in NARROW
/// windows. Spec, not implementation:
///
///  The find bar spans the full width of the terminal view, and the terminal
///  window may legitimately be made narrow (the content minimum is only about
///  20 columns, roughly 172 pt). Whatever the width, a find bar must stay
///  usable, which means every visible control satisfies three rules:
///
///   1. ON THE BAR. A control never sticks out past the bar's left or right
///      edge. A "Replace All" button that is partly or wholly off the bar is
///      clipped and unreachable.
///   2. NOT COLLIDING. Controls that share a row never overlap. The find
///      field must not run under the close (x) button; the match counter
///      ("12345 / 123456") and the 2-second transient banner ("Replace
///      unavailable while TUI is active", "Refusing: ...") must not be
///      drawn under the close button or on top of the find field.
///   3. NOT SQUASHED. The find field and replace field keep a usable width
///      (the flexible control gives way, not the others), the match counter
///      shows its whole text, and buttons keep room for their whole title.
///
///  Layout is MEASURED, never assumed: the bar is a bare `FindBar` with no
///  window; after driving it through its public API (`setReplaceVisible`,
///  `setMatchCount`, `showTransientMessage`) AppKit lays it out, and every
///  visible NSControl found by walking the view hierarchy is read back in the
///  bar's own coordinate space. Controls are identified from outside by type
///  and title (the "✕" and "Replace"/"Replace All" buttons, the one
///  non-editable text field, the editable fields ordered top to bottom).
///
///  A bar 600 pt wide is the control case: it must be sound on any
///  implementation, which proves the measurement itself is not vacuous.
///
/// Cost: one bare FindBar (a handful of subviews, well under 100 KB) per
/// scenario, no PTY, no session, no window; sub-ms each.
@MainActor
final class FindBarNarrowLayoutBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    /// A themed, collapsed bar of the given width, as `installFindBar()` builds
    /// it in the app (the app always themes the bar).
    private func makeBar(width: CGFloat) -> FindBar {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        bar.applyTheme(Theme.gruvboxDark)
        return bar
    }

    private func settle(_ bar: FindBar) {
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    // MARK: - Measurement

    private struct Item {
        let role: String
        let control: NSControl
        /// The control's frame in the bar's own coordinate space.
        let rect: NSRect
    }

    private func isEffectivelyVisible(_ view: NSView, within bar: NSView) -> Bool {
        var current: NSView? = view
        while let c = current {
            if c.isHidden { return false }
            if c === bar { return true }
            current = c.superview
        }
        return false
    }

    /// Collects the visible NSControls under `view`. Does NOT descend into a
    /// control: AppKit's own button chrome (on recent SDKs an NSButton hosts an
    /// internal NSTextField for its title) is part of that control, not a
    /// separate control of the bar.
    private func collectControls(in view: NSView, bar: FindBar, into out: inout [NSControl]) {
        for sub in view.subviews {
            if let control = sub as? NSControl {
                if isEffectivelyVisible(control, within: bar) { out.append(control) }
                continue
            }
            collectControls(in: sub, bar: bar, into: &out)
        }
    }

    private func visualTop(_ rect: NSRect, flipped: Bool) -> CGFloat {
        flipped ? -rect.minY : rect.maxY
    }

    private func buttonTitle(_ button: NSButton) -> String {
        button.attributedTitle.length > 0 ? button.attributedTitle.string : button.title
    }

    /// Every visible NSControl of the bar with an outside-in role name.
    private func measure(_ bar: FindBar) -> [Item] {
        var controls: [NSControl] = []
        collectControls(in: bar, bar: bar, into: &controls)

        var items: [Item] = []
        var editable: [Item] = []
        for control in controls {
            // The control's alignment rect, not its frame: a push button's frame
            // carries a few points of invisible bezel shadow on each side
            // (macOS 15), and the layout constraints (and what the user sees)
            // are in alignment-rect terms.
            let rect = bar.convert(control.alignmentRect(forFrame: control.bounds), from: control)
            if let button = control as? NSButton {
                let title = buttonTitle(button)
                let role: String
                switch title {
                case "✕":          role = "close"
                case "Replace":    role = "replaceButton"
                case "Replace All": role = "replaceAllButton"
                case "▸", "▾":     role = "caret"
                default:           role = "button[\(title)]"
                }
                items.append(Item(role: role, control: control, rect: rect))
            } else if let text = control as? NSTextField {
                if text.isEditable {
                    editable.append(Item(role: "field", control: control, rect: rect))
                } else {
                    items.append(Item(role: "matchLabel", control: control, rect: rect))
                }
            } else {
                items.append(Item(role: "control[\(type(of: control))]", control: control, rect: rect))
            }
        }

        // Editable fields: the one drawn highest is the find field, the next
        // one down (only present while the replace row is expanded) is the
        // replace field.
        let flipped = bar.isFlipped
        let ordered = editable.sorted { (a: Item, b: Item) -> Bool in
            visualTop(a.rect, flipped: flipped) > visualTop(b.rect, flipped: flipped)
        }
        for (index, item) in ordered.enumerated() {
            let role: String
            switch index {
            case 0:  role = "findField"
            case 1:  role = "replaceField"
            default: role = "extraField\(index)"
            }
            items.append(Item(role: role, control: item.control, rect: item.rect))
        }
        return items
    }

    private func span(_ r: NSRect) -> String {
        String(format: "[x %.1f..%.1f, w %.1f]", r.minX, r.maxX, r.width)
    }

    private func dump(_ items: [Item]) -> String {
        let sorted = items.sorted { (a: Item, b: Item) -> Bool in a.rect.minX < b.rect.minX }
        return sorted.map { "\($0.role)=\(span($0.rect))" }.joined(separator: "  ")
    }

    // MARK: - Audit

    /// Runs the whole battery against an already laid-out bar.
    ///
    /// - Parameters:
    ///   - requiredRoles: roles that must be visible (precondition; keeps a
    ///     missing control from passing vacuously).
    ///   - labelMustShowFullText: the match label's frame must be at least as
    ///     wide as its whole text (used for the match counter).
    ///   - minLabelWidth: for banners that a sane layout may truncate: the
    ///     label must still be given at least min(fullTextWidth, this) points.
    ///   - minFieldWidth: the narrowest the find / replace fields may be.
    ///     60 pt everywhere a bar has room for it; the window-minimum cases
    ///     pass a smaller floor, because there the fields are the one thing
    ///     that may give way so the replace buttons stay reachable.
    private func audit(
        _ bar: FindBar,
        width: CGFloat,
        scenario: String,
        requiredRoles: [String],
        labelMustShowFullText: Bool,
        minLabelWidth: CGFloat? = nil,
        minFieldWidth: CGFloat = 60,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let items = measure(bar)
        let layoutDump = dump(items)
        let ctx = "\(scenario) @ bar width \(width) pt -> \(layoutDump)"

        // Preconditions: the rig really laid out the bar we think it did.
        XCTAssertEqual(bar.bounds.width, width, accuracy: 0.5,
                       "precondition: bar keeps its width. \(ctx)", file: file, line: line)
        let roles = items.map { $0.role }
        let missing = requiredRoles.filter { !roles.contains($0) }
        XCTAssertEqual(missing, [],
                       "precondition: these controls must be visible on the bar but were not found. \(ctx)",
                       file: file, line: line)
        XCTAssertEqual(roles.filter { $0 == "matchLabel" }.count, 1,
                       "precondition: exactly one visible match label. \(ctx)", file: file, line: line)
        guard missing.isEmpty,
              let close = items.first(where: { $0.role == "close" }),
              let labelItem = items.first(where: { $0.role == "matchLabel" })
        else { return }
        XCTAssertGreaterThan(close.rect.width, 5,
                             "precondition: layout ran (close button has a real frame). \(ctx)",
                             file: file, line: line)

        // 1. Every control stays on the bar horizontally.
        var clipped: [String] = []
        for item in items where item.rect.minX < -0.5 || item.rect.maxX > bar.bounds.width + 0.5 {
            clipped.append("\(item.role) \(span(item.rect))")
        }
        XCTAssertEqual(clipped, [],
                       "controls hanging off the bar's edges (bar spans 0..\(width)): \(ctx)",
                       file: file, line: line)

        // 2. No two visible controls collide.
        var overlaps: [String] = []
        for i in 0..<items.count {
            for j in (i + 1)..<max(items.count, i + 1) {
                let a = items[i].rect
                let b = items[j].rect
                let dx = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let dy = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if dx > 0.5 && dy > 1 {
                    overlaps.append(
                        "\(items[i].role) \(span(a)) x \(items[j].role) \(span(b)) (overlap \(String(format: "%.1f", dx)) pt)")
                }
            }
        }
        XCTAssertEqual(overlaps, [],
                       "controls drawn on top of each other: \(ctx)", file: file, line: line)

        // 3a. Fields keep a usable width.
        var squashed: [String] = []
        for item in items where item.role == "findField" || item.role == "replaceField" {
            if item.rect.width < minFieldWidth {
                squashed.append("\(item.role) \(span(item.rect))")
            }
        }
        XCTAssertEqual(squashed, [],
                       "text fields squashed below \(minFieldWidth) pt: \(ctx)", file: file, line: line)

        // 3b. Buttons have room for their whole title.
        var cramped: [String] = []
        for item in items {
            guard let button = item.control as? NSButton else { continue }
            let needed = button.intrinsicContentSize.width
            if needed > 0 && item.rect.width + 1 < needed {
                cramped.append("\(item.role) \(span(item.rect)) needs \(String(format: "%.1f", needed)) pt")
            }
        }
        XCTAssertEqual(cramped, [],
                       "buttons narrower than their own title: \(ctx)", file: file, line: line)

        // 3c. The label shows its text.
        if let label = labelItem.control as? NSTextField {
            let textWidth = label.attributedStringValue.size().width
            if labelMustShowFullText {
                XCTAssertGreaterThanOrEqual(
                    label.frame.width + 1, textWidth,
                    "match label '\(label.stringValue)' is \(String(format: "%.1f", label.frame.width)) pt wide but its text needs \(String(format: "%.1f", textWidth)) pt (clipped): \(ctx)",
                    file: file, line: line)
            }
            if let minLabelWidth {
                let wanted = min(textWidth, minLabelWidth)
                XCTAssertGreaterThanOrEqual(
                    label.frame.width + 1, wanted,
                    "banner '\(label.stringValue)' is squeezed to \(String(format: "%.1f", label.frame.width)) pt; at least \(String(format: "%.1f", wanted)) pt of it must stay visible: \(ctx)",
                    file: file, line: line)
            }
        }
    }

    private let collapsedRoles = ["caret", "findField", "matchLabel", "close"]
    private let expandedRoles = ["caret", "findField", "matchLabel", "close",
                                 "replaceField", "replaceButton", "replaceAllButton"]

    // MARK: - Control: a wide bar is sound (proves the measurement is not vacuous)

    func test_control_wideBar_everyScenarioIsSound() {
        let width: CGFloat = 600

        let collapsed = makeBar(width: width)
        collapsed.setMatchCount(2, of: 12)
        settle(collapsed)
        XCTAssertEqual(collapsed._matchLabelStringForTests(), "3 / 12", "precondition: counter text")
        audit(collapsed, width: width, scenario: "collapsed, short count",
              requiredRoles: collapsedRoles, labelMustShowFullText: true)

        let expanded = makeBar(width: width)
        expanded.setReplaceVisible(true)
        expanded.setMatchCount(2, of: 12)
        settle(expanded)
        XCTAssertEqual(expanded.preferredHeight, 60, "precondition: replace row expanded")
        audit(expanded, width: width, scenario: "expanded, short count",
              requiredRoles: expandedRoles, labelMustShowFullText: true)

        let tui = makeBar(width: width)
        tui.showTransientMessage(FindBar.tuiActiveMessage)
        settle(tui)
        XCTAssertEqual(tui._matchLabelStringForTests(), FindBar.tuiActiveMessage,
                       "precondition: banner text is showing")
        audit(tui, width: width, scenario: "collapsed, TUI-refusal banner",
              requiredRoles: collapsedRoles, labelMustShowFullText: true)
    }

    // MARK: - Collapsed bar, 5-digit count

    /// 'Alternatively, in a collapsed bar narrower than about 360 pt, a 5-digit
    /// count runs under the x.' The counter must show in full, beside (not
    /// under) the close button, and the find field must give way.
    func test_collapsed_fiveDigitCount_narrowBars_counterFitsAndNothingCollides() {
        for width in [320, 350] as [CGFloat] {
            let bar = makeBar(width: width)
            bar.setMatchCount(12344, of: 123456)
            settle(bar)
            XCTAssertEqual(bar._matchLabelStringForTests(), "12345 / 123456",
                           "precondition: counter text at width \(width)")
            audit(bar, width: width, scenario: "collapsed, 5-digit count",
                  requiredRoles: collapsedRoles, labelMustShowFullText: true)
        }
    }

    // MARK: - Expanded replace row

    /// 'Resize the window to about 320 pt wide, press cmd-F, then expand the
    /// replace row with the caret. Replace is clipped and Replace All is off
    /// the bar.' Both replace buttons must be fully on the bar, with the
    /// replace field shrunk to make room.
    func test_expanded_replaceRow_narrowBars_replaceButtonsStayOnTheBar() {
        for width in [320, 400] as [CGFloat] {
            let bar = makeBar(width: width)
            bar.setReplaceVisible(true)
            bar.setMatchCount(0, of: 3)
            settle(bar)
            XCTAssertTrue(bar.isReplaceVisible, "precondition: replace row expanded at width \(width)")
            XCTAssertEqual(bar._matchLabelStringForTests(), "1 / 3",
                           "precondition: counter text at width \(width)")
            audit(bar, width: width, scenario: "expanded, short count",
                  requiredRoles: expandedRoles, labelMustShowFullText: true)
        }
    }

    /// Both rows at once on a narrow bar: the replace row must be reachable
    /// while the find row carries a 5-digit count.
    func test_expanded_fiveDigitCount_narrowBar_bothRowsSound() {
        let width: CGFloat = 320
        let bar = makeBar(width: width)
        bar.setReplaceVisible(true)
        bar.setMatchCount(12344, of: 123456)
        settle(bar)
        XCTAssertEqual(bar._matchLabelStringForTests(), "12345 / 123456",
                       "precondition: counter text")
        audit(bar, width: width, scenario: "expanded, 5-digit count",
              requiredRoles: expandedRoles, labelMustShowFullText: true)
    }

    // MARK: - Transient banner

    /// 'A 2 s transient banner overlaps the x in any bar under about 480 pt
    /// (TUI refusal).' The banner lives in the match label; it may be
    /// truncated on a bar this narrow, but never drawn under the close button
    /// and never squeezed to nothing.
    func test_tuiRefusalBanner_midWidthBar_doesNotRunUnderCloseButton() {
        let width: CGFloat = 450
        let bar = makeBar(width: width)
        bar.showTransientMessage(FindBar.tuiActiveMessage)
        settle(bar)
        XCTAssertEqual(bar._matchLabelStringForTests(), FindBar.tuiActiveMessage,
                       "precondition: banner text is showing")
        audit(bar, width: width, scenario: "collapsed, TUI-refusal banner",
              requiredRoles: collapsedRoles, labelMustShowFullText: false, minLabelWidth: 150)
    }

    /// The long 'Refusing: ...' banner collided up to about 560 pt.
    func test_longRefusingBanner_wideishBar_doesNotRunUnderCloseButton() {
        let width: CGFloat = 520
        let message = "Refusing: matches span a possible wrapped input line"
        let bar = makeBar(width: width)
        bar.showTransientMessage(message)
        settle(bar)
        XCTAssertEqual(bar._matchLabelStringForTests(), message,
                       "precondition: banner text is showing")
        audit(bar, width: width, scenario: "collapsed, long Refusing banner",
              requiredRoles: collapsedRoles, labelMustShowFullText: false, minLabelWidth: 150)
    }

    // MARK: - Window-minimum widths

    /// The content minimum is about 172 pt (20 cells at the default font), so a
    /// user can reach a bar that narrow. Replace All has no keyboard shortcut,
    /// so on every bar width it must stay whole and on the bar. Replace
    /// (current) has one (cmd-opt-E), so it may disappear on a bar too narrow
    /// for it, but never survive as a clipped sliver.
    private let expandedRolesReplaceAllOnly = ["caret", "findField", "matchLabel", "close",
                                               "replaceField", "replaceAllButton"]

    /// How the bar came to be `width` wide. The outcome must not depend on it.
    private enum History: String, CaseIterable {
        /// Created at `width`.
        case fresh
        /// Created wide, then narrowed in place.
        case shrunkFromWide
        /// Hosted the way the app hosts it (width-autoresizing subview of the
        /// terminal view), then the host narrowed.
        case hostedAndNarrowed
    }

    /// Hosts kept alive for the length of the test (a bar must keep its
    /// superview while it is measured).
    private var hosts: [NSView] = []

    /// A themed bar with the replace row expanded and a short count, `width`
    /// wide, reached through `history`.
    private func makeExpandedBar(width: CGFloat, history: History) -> FindBar {
        let wide: CGFloat = 600
        let bar: FindBar
        switch history {
        case .fresh:
            bar = makeBar(width: width)
            bar.setReplaceVisible(true)
            bar.setMatchCount(2, of: 12)
            settle(bar)
        case .shrunkFromWide:
            bar = makeBar(width: wide)
            bar.setReplaceVisible(true)
            bar.setMatchCount(2, of: 12)
            settle(bar)
            bar.setFrameSize(NSSize(width: width, height: bar.frame.height))
            settle(bar)
        case .hostedAndNarrowed:
            let host = NSView(frame: NSRect(x: 0, y: 0, width: wide, height: 300))
            bar = makeBar(width: wide)
            bar.frame.origin.y = 300 - bar.frame.height
            bar.autoresizingMask = [.width, .minYMargin]
            host.addSubview(bar)
            hosts.append(host)
            bar.setReplaceVisible(true)
            bar.setMatchCount(2, of: 12)
            settle(bar)
            host.setFrameSize(NSSize(width: width, height: host.frame.height))
            host.layoutSubtreeIfNeeded()
            settle(bar)
        }
        return bar
    }

    /// Replace All reachable at the window minimum (172 pt) and at a width
    /// where only one of the two buttons can fit (220 pt), in every history.
    /// Before the fix the buttons shared one squeeze priority, so which of them
    /// collapsed (down to 0 pt) depended on the history.
    func test_expanded_windowMinimumWidths_replaceAllStaysWholeInEveryHistory() {
        for width in [172, 220] as [CGFloat] {
            for history in History.allCases {
                let bar = makeExpandedBar(width: width, history: history)
                XCTAssertEqual(bar._matchLabelStringForTests(), "3 / 12",
                               "precondition: counter text (\(history.rawValue) @ \(width))")
                audit(bar, width: width,
                      scenario: "expanded, short count, \(history.rawValue)",
                      requiredRoles: expandedRolesReplaceAllOnly,
                      labelMustShowFullText: true,
                      minFieldWidth: width < 200 ? 30 : 60)
            }
        }
    }

    /// The outcome is a function of the width alone: every history gives the
    /// same Replace All frame and the same Replace visibility.
    func test_expanded_squeezedWidths_outcomeDoesNotDependOnResizeHistory() {
        for width in [172, 190, 200, 220, 250, 268] as [CGFloat] {
            var outcomes: [(History, NSRect, Bool)] = []
            for history in History.allCases {
                let items = measure(makeExpandedBar(width: width, history: history))
                guard let replaceAll = items.first(where: { $0.role == "replaceAllButton" }) else {
                    XCTFail("precondition: Replace All visible (\(history.rawValue) @ \(width)): \(dump(items))")
                    continue
                }
                outcomes.append((history, replaceAll.rect, items.contains { $0.role == "replaceButton" }))
            }
            guard let first = outcomes.first else { continue }
            for other in outcomes.dropFirst() {
                XCTAssertEqual(other.1.width, first.1.width, accuracy: 1,
                               "Replace All width differs by history @ \(width): \(first.0.rawValue) \(span(first.1)) vs \(other.0.rawValue) \(span(other.1))")
                XCTAssertEqual(other.1.minX, first.1.minX, accuracy: 1,
                               "Replace All x differs by history @ \(width): \(first.0.rawValue) \(span(first.1)) vs \(other.0.rawValue) \(span(other.1))")
                XCTAssertEqual(other.2, first.2,
                               "Replace visibility differs by history @ \(width): \(first.0.rawValue) \(first.2) vs \(other.0.rawValue) \(other.2)")
            }
        }
    }

    /// Squeeze sweep between the fully-fitting width (about 270 pt) and the
    /// window minimum: at every step Replace All is whole, Replace (if shown)
    /// is whole, nothing collides, and the fields keep their 60 pt until the
    /// bar is too narrow for 60 pt fields plus Replace All (about 197 pt).
    func test_expanded_squeezeSweep_everyStepIsSound() {
        for width in stride(from: 200, through: 268, by: 4) {
            let w = CGFloat(width)
            for history in [History.fresh, .shrunkFromWide] {
                audit(makeExpandedBar(width: w, history: history), width: w,
                      scenario: "expanded sweep, \(history.rawValue)",
                      requiredRoles: expandedRolesReplaceAllOnly,
                      labelMustShowFullText: true)
            }
        }
    }

    /// Collapsed bar at the window minimum: short count whole, a 5-digit count
    /// may truncate but never runs under the close button or vanishes.
    func test_collapsed_windowMinimum_countStaysBesideTheCloseButton() {
        let width: CGFloat = 172

        let short = makeBar(width: width)
        short.setMatchCount(2, of: 12)
        settle(short)
        audit(short, width: width, scenario: "collapsed, short count",
              requiredRoles: collapsedRoles, labelMustShowFullText: true)

        let long = makeBar(width: width)
        long.setMatchCount(12344, of: 123456)
        settle(long)
        XCTAssertEqual(long._matchLabelStringForTests(), "12345 / 123456",
                       "precondition: counter text")
        audit(long, width: width, scenario: "collapsed, 5-digit count",
              requiredRoles: collapsedRoles, labelMustShowFullText: false, minLabelWidth: 40)
    }
}
