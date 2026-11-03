import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for how the find bar presents itself to assistive
/// technology (VoiceOver). Spec, not implementation:
///
///  The find bar is a row of controls: a disclosure button that shows or
///  hides the replace row, the query field, a match counter ("3 / 12"), and a
///  close button. Two of those buttons carry only a drawn glyph ("▸" / "▾" and
///  "✕"). A sighted user reads the glyph; a VoiceOver user is read the
///  glyph's Unicode name instead of what the button does, unless the button
///  also exposes an accessibility label.
///
///  The contract, as VoiceOver sees it (the elements the accessibility TREE
///  hands out, not merely the views that happen to exist):
///
///   1. The close button's spoken name says it closes ("Close find bar"), not
///      the glyph "✕".
///   2. The replace-disclosure button's spoken name says it is about the
///      replace row ("Show replace" / "Hide replace" / "Replace"), not the
///      glyph "▸" / "▾".
///   3. The disclosure STATE (replace row shown or hidden) is exposed: some
///      accessibility attribute of that button (label, help, value, expanded
///      flag, ...) differs between the collapsed and the expanded bar,
///      beyond the "▸" -> "▾" glyph swap that is only a picture.
///   4. The match counter's element carries a descriptive label ("Find
///      results") so "3 / 12" is not read bare. The label must be on the
///      element the tree exposes. (A label set only on an enclosing view that
///      the tree skips never reaches VoiceOver.)
///   5. Regex mode and case-sensitive mode are visible to the user, not only
///      while the query field is empty. With a NON-empty query (when the
///      field's placeholder is not shown) turning either mode on must change
///      something the bar exposes (a visible title/tooltip/badge or an
///      accessibility label/help/value) and the change must say which mode it
///      is; turning it off must restore exactly the previous exposure.
///
///  "Spoken name" follows VoiceOver's own preference: the accessibility
///  label (AXDescription) when it is non-empty, otherwise the title
///  (AXTitle).
///
///  Everything is MEASURED from a bare, themed `FindBar` (no window, no
///  PTY): the exposed elements are read by walking `accessibilityChildren()`
///  from the bar, and identified by ROLE and tree ORDER (buttons first to
///  last, the static-text element showing the count), never by private
///  property names. The counter, the buttons and the toggles are driven only
///  through the bar's public API (`setMatchCount`, `setReplaceVisible`,
///  `setQuery`, `toggleRegexMode`, `toggleCaseSensitive`).
///
///  Not covered here: transient `NSAccessibility.post` announcements (they
///  are not observable without a live VoiceOver session).
///
/// Cost: one bare FindBar (a handful of subviews, well under 100 KB) per
/// scenario, no PTY, no session, no window; sub-ms each.
@MainActor
final class FindBarAccessibilityBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private typealias AXNode = NSObject & NSAccessibilityProtocol

    /// A themed, collapsed bar as `installFindBar()` builds it in the app.
    private func makeBar() -> FindBar {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        bar.applyTheme(Theme.gruvboxDark)
        return bar
    }

    private func settle(_ bar: FindBar) {
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    // MARK: - Accessibility tree measurement

    private func collectExposed(_ node: AXNode, into out: inout [AXNode], depth: Int) {
        if depth > 12 { return }
        guard let children = node.accessibilityChildren() else { return }
        for child in children {
            guard let element = child as? AXNode else { continue }
            if element.isAccessibilityElement() { out.append(element) }
            collectExposed(element, into: &out, depth: depth + 1)
        }
    }

    /// Every accessibility element the bar exposes, in tree (document) order.
    private func exposedElements(of bar: FindBar) -> [AXNode] {
        var out: [AXNode] = []
        collectExposed(bar, into: &out, depth: 0)
        return out
    }

    private func isButtonLike(_ element: AXNode) -> Bool {
        guard let role = element.accessibilityRole() else { return false }
        let buttonRoles: [NSAccessibility.Role] = [
            .button, .disclosureTriangle, .checkBox, .radioButton, .popUpButton, .menuButton,
        ]
        return buttonRoles.contains(role)
    }

    private func buttons(of bar: FindBar) -> [AXNode] {
        var out: [AXNode] = []
        for element in exposedElements(of: bar) where isButtonLike(element) { out.append(element) }
        return out
    }

    private func text(of any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let a = any as? NSAttributedString { return a.string }
        return ""
    }

    private func label(of element: AXNode) -> String { text(of: element.accessibilityLabel()) }
    private func title(of element: AXNode) -> String { text(of: element.accessibilityTitle()) }

    /// What VoiceOver announces as the element's name: label first, title as
    /// the fallback.
    private func spokenName(of element: AXNode) -> String {
        let l = label(of: element)
        return l.isEmpty ? title(of: element) : l
    }

    private let glyphs: Set<String> = ["▸", "▾", "✕"]

    /// Strings that are only a drawn picture carry no state or purpose: map
    /// them to a placeholder so a glyph swap is not mistaken for exposure.
    private func neutralized(_ s: String) -> String {
        glyphs.contains(s) ? "<glyph>" : s
    }

    /// Every accessibility attribute of a button that could expose its
    /// purpose or state, as strings, with bare glyphs neutralized.
    private func attributeSnapshot(of element: AXNode) -> [String] {
        let role: String = element.accessibilityRole()?.rawValue ?? ""
        let roleDescription: String = text(of: element.accessibilityRoleDescription())
        return [
            "role=\(role)",
            "roleDescription=\(roleDescription)",
            "label=\(neutralized(label(of: element)))",
            "title=\(neutralized(title(of: element)))",
            "value=\(neutralized(text(of: element.accessibilityValue())))",
            "valueDescription=\(neutralized(text(of: element.accessibilityValueDescription())))",
            "help=\(neutralized(text(of: element.accessibilityHelp())))",
            "expanded=\(element.isAccessibilityExpanded())",
            "selected=\(element.isAccessibilitySelected())",
        ]
    }

    /// The match counter's element: the exposed static-text element whose
    /// value mentions the total (12) the test fed in.
    private func counterElement(in bar: FindBar) -> AXNode? {
        for element in exposedElements(of: bar) where element.accessibilityRole() == .staticText {
            if text(of: element.accessibilityValue()).contains("12") { return element }
        }
        return nil
    }

    // MARK: - Visible / exposed text (for mode-indicator tests)

    private func isEffectivelyVisible(_ view: NSView, within bar: NSView) -> Bool {
        var current: NSView? = view
        while let c = current {
            if c.isHidden { return false }
            if c === bar { return true }
            current = c.superview
        }
        return false
    }

    private func collectVisibleStrings(in view: NSView, bar: FindBar, into out: inout Set<String>) {
        for sub in view.subviews {
            if !isEffectivelyVisible(sub, within: bar) { continue }
            if let tip = sub.toolTip, !tip.isEmpty { out.insert("tooltip:\(tip)") }
            if let button = sub as? NSButton {
                if !button.title.isEmpty { out.insert("buttonTitle:\(button.title)") }
                if button.attributedTitle.length > 0 {
                    out.insert("buttonTitle:\(button.attributedTitle.string)")
                }
            } else if let field = sub as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
                out.insert("staticText:\(field.stringValue)")
            }
            // Do not descend into a control: on recent SDKs an NSButton hosts
            // an internal title text field that is part of the button, not a
            // separate element of the bar.
            if sub is NSControl { continue }
            collectVisibleStrings(in: sub, bar: bar, into: &out)
        }
    }

    /// Everything a user (or VoiceOver) can read off the bar while the query
    /// field holds text: visible titles / static texts / tooltips plus every
    /// exposed element's label, title, help and value. The query field's
    /// placeholder is deliberately NOT included: it is not shown once the
    /// field is non-empty, which is exactly the situation under test.
    private func exposedTexts(of bar: FindBar) -> Set<String> {
        var out: Set<String> = []
        collectVisibleStrings(in: bar, bar: bar, into: &out)
        for (index, element) in exposedElements(of: bar).enumerated() {
            let pairs: [(String, String)] = [
                ("label", label(of: element)),
                ("title", title(of: element)),
                ("help", text(of: element.accessibilityHelp())),
                ("value", text(of: element.accessibilityValue())),
                ("valueDescription", text(of: element.accessibilityValueDescription())),
            ]
            for (name, s) in pairs where !s.isEmpty {
                out.insert("ax[\(index)].\(name):\(s)")
            }
        }
        return out
    }

    private func describe(_ strings: Set<String>) -> String {
        strings.sorted().joined(separator: " | ")
    }

    // MARK: - 1. Close button

    func testCloseButtonSpokenNameSaysCloseNotTheGlyph() {
        let bar = makeBar()
        settle(bar)

        let found = buttons(of: bar)
        XCTAssertGreaterThanOrEqual(found.count, 2,
            "precondition: the collapsed bar must expose at least the disclosure and close buttons; got \(found.count)")
        guard let close = found.last else { return }

        let name = spokenName(of: close)
        XCTAssertTrue(name.lowercased().contains("close"),
            "close button must be announced as closing the find bar; spoken name=\(name.debugDescription) label=\(label(of: close).debugDescription) title=\(title(of: close).debugDescription)")
    }

    // MARK: - 2. Replace disclosure button

    func testReplaceDisclosureButtonSpokenNameSaysReplaceNotTheGlyph() {
        let bar = makeBar()
        settle(bar)

        let found = buttons(of: bar)
        XCTAssertGreaterThanOrEqual(found.count, 2,
            "precondition: the collapsed bar must expose at least the disclosure and close buttons; got \(found.count)")
        guard let caret = found.first else { return }

        let name = spokenName(of: caret)
        XCTAssertTrue(name.lowercased().contains("replace"),
            "disclosure button must be announced as being about the replace row; spoken name=\(name.debugDescription) label=\(label(of: caret).debugDescription) title=\(title(of: caret).debugDescription)")
    }

    // MARK: - 3. Disclosure state

    func testReplaceDisclosureStateIsExposedBeyondTheGlyph() {
        let bar = makeBar()
        settle(bar)

        let collapsedButtons = buttons(of: bar)
        XCTAssertGreaterThanOrEqual(collapsedButtons.count, 2,
            "precondition: collapsed bar exposes the disclosure and close buttons; got \(collapsedButtons.count)")
        guard let collapsedCaret = collapsedButtons.first else { return }
        let collapsed = attributeSnapshot(of: collapsedCaret)

        bar.setReplaceVisible(true)
        settle(bar)

        let expandedButtons = buttons(of: bar)
        XCTAssertGreaterThan(expandedButtons.count, collapsedButtons.count,
            "precondition: expanding the replace row must expose more buttons (Replace, Replace All); collapsed=\(collapsedButtons.count) expanded=\(expandedButtons.count)")
        guard let expandedCaret = expandedButtons.first else { return }
        let expanded = attributeSnapshot(of: expandedCaret)

        XCTAssertNotEqual(collapsed, expanded,
            "the disclosure button must expose whether the replace row is shown, other than by its glyph; collapsed=\(collapsed) expanded=\(expanded)")

        let expandedName = spokenName(of: expandedCaret)
        XCTAssertTrue(expandedName.lowercased().contains("replace"),
            "the expanded disclosure button must still be announced as being about the replace row; spoken name=\(expandedName.debugDescription)")
    }

    // MARK: - 4. Match counter label

    func testMatchCounterElementCarriesFindResultsLabel() {
        let bar = makeBar()
        bar.setMatchCount(2, of: 12)
        settle(bar)

        guard let counter = counterElement(in: bar) else {
            let roles = exposedElements(of: bar).map { String(describing: $0.accessibilityRole()?.rawValue) }
            XCTFail("precondition: no exposed static-text element shows the match count (value containing \"12\"); exposed roles=\(roles)")
            return
        }
        XCTAssertTrue(text(of: counter.accessibilityValue()).contains("3"),
            "precondition: the counter keeps announcing the current match (3 of 12); value=\(text(of: counter.accessibilityValue()).debugDescription)")

        let l = label(of: counter)
        XCTAssertTrue(l.lowercased().contains("result"),
            "the element VoiceOver reaches for the counter must be labelled \"Find results\" so \"3 / 12\" is not read bare; label=\(l.debugDescription) value=\(text(of: counter.accessibilityValue()).debugDescription)")
    }

    // MARK: - 5. Regex / case state with a non-empty query

    func testRegexModeIsIndicatedWhileQueryIsNonEmpty() {
        let bar = makeBar()
        bar.setQuery("foo")
        settle(bar)
        let baseline = exposedTexts(of: bar)

        bar.toggleRegexMode(nil)
        settle(bar)
        XCTAssertEqual(bar.options.regex, true, "precondition: toggleRegexMode must turn regex mode on")
        let regexOn = exposedTexts(of: bar)
        let added = regexOn.subtracting(baseline)

        var namesRegex = false
        for s in added {
            let lower = s.lowercased()
            if lower.contains("regex") || lower.contains("regular") || lower.contains(".*") { namesRegex = true }
        }
        XCTAssertTrue(namesRegex,
            "with a non-empty query, regex mode on must show up as visible text or an accessibility label/help/value naming regex; newly exposed=[\(describe(added))] baseline=[\(describe(baseline))]")

        bar.toggleRegexMode(nil)
        settle(bar)
        XCTAssertEqual(bar.options.regex, false, "precondition: second toggleRegexMode must turn regex mode off")
        XCTAssertEqual(describe(exposedTexts(of: bar)), describe(baseline),
            "turning regex mode off again must restore exactly the original exposure")
    }

    func testCaseSensitiveModeIsIndicatedWhileQueryIsNonEmpty() {
        let bar = makeBar()
        bar.setQuery("foo")
        settle(bar)
        let baseline = exposedTexts(of: bar)

        bar.toggleCaseSensitive(nil)
        settle(bar)
        XCTAssertEqual(bar.options.caseSensitive, true, "precondition: toggleCaseSensitive must turn case-sensitive mode on")
        let caseOn = exposedTexts(of: bar)
        let added = caseOn.subtracting(baseline)

        var namesCase = false
        for s in added {
            let lower = s.lowercased()
            if lower.contains("case") || lower.contains("aa") { namesCase = true }
        }
        XCTAssertTrue(namesCase,
            "with a non-empty query, case-sensitive mode on must show up as visible text or an accessibility label/help/value naming case; newly exposed=[\(describe(added))] baseline=[\(describe(baseline))]")

        bar.toggleCaseSensitive(nil)
        settle(bar)
        XCTAssertEqual(bar.options.caseSensitive, false, "precondition: second toggleCaseSensitive must turn case-sensitive mode off")
        XCTAssertEqual(describe(exposedTexts(of: bar)), describe(baseline),
            "turning case-sensitive mode off again must restore exactly the original exposure")
    }
}
