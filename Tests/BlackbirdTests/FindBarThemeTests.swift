import XCTest
import AppKit
@testable import Blackbird

/// Behaviour coverage for `FindBar.applyTheme(_:)` — the path that recolours
/// the find bar's chrome (bar layer, find field, match-counter label) from a
/// `ThemePalette` via `FindBarColorScheme`. Structural only: a bare
/// `FindBar(frame:)` with no PTY / session / window.
///
/// Colour comparison strategy: every themed colour is constructed from a
/// 0xRRGGBB channel triple divided by 255 in the sRGB space (matching how the
/// app builds NSColors from packed theme ints). We convert each observed
/// colour to `.sRGB` and compare components with a 1/255 tolerance, which is
/// robust to whichever colour-space representation AppKit hands back.
///
/// The expected hex constants below are the hand-computed
/// `FindBarColorScheme` field values for each palette (see
/// FindBarColorSchemeTests for the per-channel arithmetic):
///   Gruvbox dark   (bg 0x282828 fg 0xEBDBB2): bar 0x363532 field 0x413F3A text 0xEBDBB2
///   Solarized light(bg 0xFDF6E3 fg 0x657B83): bar 0xF2EDDC field 0xE9E6D7 text 0x657B83
///
/// Memory/time: each test builds one 600×32 FindBar (a few subviews, < 100 KB);
/// no grids, no PTY. Sub-ms per test.
final class FindBarThemeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures / helpers

    private func makeBar() -> FindBar {
        FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
    }

    /// Component-wise sRGB comparison of an observed `NSColor?` against a
    /// packed 0xRRGGBB triple + alpha. Tolerant to colour-space wrapping.
    private func assertColor(
        _ got: NSColor?,
        equalsHex hex: UInt32,
        alpha: CGFloat = 1.0,
        accuracy: CGFloat = 1.0 / 255.0,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let got else {
            XCTFail("expected a colour but got nil. \(message)", file: file, line: line)
            return
        }
        guard let s = got.usingColorSpace(.sRGB) else {
            XCTFail("colour could not be converted to sRGB. \(message)", file: file, line: line)
            return
        }
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        XCTAssertEqual(s.redComponent,   r, accuracy: accuracy, "red \(message)",   file: file, line: line)
        XCTAssertEqual(s.greenComponent, g, accuracy: accuracy, "green \(message)", file: file, line: line)
        XCTAssertEqual(s.blueComponent,  b, accuracy: accuracy, "blue \(message)",  file: file, line: line)
        XCTAssertEqual(s.alphaComponent, alpha, accuracy: accuracy, "alpha \(message)", file: file, line: line)
    }

    /// Same comparison against a CGColor (the bar's layer background).
    private func assertLayerColor(
        _ cg: CGColor?,
        equalsHex hex: UInt32,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let cg else {
            XCTFail("expected a layer background but got nil. \(message)", file: file, line: line)
            return
        }
        assertColor(NSColor(cgColor: cg), equalsHex: hex, alpha: 1.0,
                    message, file: file, line: line)
    }

    // MARK: - Pre-apply state (legacy system colours)

    /// Before the first `applyTheme`, no scheme has been derived.
    func test_beforeApplyTheme_schemeIsNil() {
        let bar = makeBar()
        XCTAssertNil(bar._appliedSchemeForTests(),
                     "no scheme must be recorded until applyTheme(_:) is called")
    }

    /// Before the first `applyTheme`, the bar keeps the legacy
    /// `windowBackgroundColor` its initializer set.
    func test_beforeApplyTheme_layerIsWindowBackgroundColor() {
        let bar = makeBar()
        guard let layer = bar._barLayerBackgroundForTests() else {
            XCTFail("bar layer background must be set at init")
            return
        }
        let expected = NSColor.windowBackgroundColor.cgColor
        XCTAssertTrue(
            layer == expected,
            "pre-theme bar layer background must be the windowBackgroundColor set at init")
    }

    // MARK: - applyTheme derives + applies (Gruvbox dark)

    func test_applyTheme_recordsDerivedScheme() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.gruvboxDark),
                       "applyTheme must record the scheme derived from the palette")
    }

    func test_applyTheme_gruvboxDark_barLayerBackground() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        // barBackground = blend(0x282828 → 0xEBDBB2, 0.07) = 0x363532, opaque.
        assertLayerColor(bar._barLayerBackgroundForTests(), equalsHex: 0x363532,
                         "bar layer must take the opaque barBackground colour")
    }

    func test_applyTheme_gruvboxDark_findFieldBackgroundAndText() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        let field = bar._findFieldColorsForTests()
        // fieldBackground = blend(0x282828 → 0xEBDBB2, 0.13) = 0x413F3A.
        assertColor(field.background, equalsHex: 0x413F3A,
                    "find field background = fieldBackground")
        // field text = palette foreground = 0xEBDBB2.
        assertColor(field.text, equalsHex: 0xEBDBB2,
                    "find field text = palette foreground")
    }

    func test_applyTheme_gruvboxDark_matchLabelIsForegroundAt65Percent() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        // matchLabel = text (foreground 0xEBDBB2) at 0.65 alpha.
        assertColor(bar._matchLabelTextColorForTests(), equalsHex: 0xEBDBB2, alpha: 0.65,
                    "match label = foreground at 0.65 alpha")
    }

    // MARK: - Re-derivation on a second, different palette (Solarized light)

    func test_applyTheme_secondPalette_reDerivesScheme() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        bar.applyTheme(Theme.solarizedLight)
        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.solarizedLight),
                       "a second applyTheme must replace the recorded scheme")
    }

    func test_applyTheme_secondPalette_reColoursEverything() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        bar.applyTheme(Theme.solarizedLight)
        // Solarized-light derived values (negative per-channel deltas).
        assertLayerColor(bar._barLayerBackgroundForTests(), equalsHex: 0xF2EDDC,
                         "bar layer must track the second palette")
        let field = bar._findFieldColorsForTests()
        assertColor(field.background, equalsHex: 0xE9E6D7,
                    "field background must track the second palette")
        assertColor(field.text, equalsHex: 0x657B83,
                    "field text must track the second palette foreground")
        assertColor(bar._matchLabelTextColorForTests(), equalsHex: 0x657B83, alpha: 0.65,
                    "match label must track the second palette foreground at 0.65 alpha")
    }

    // MARK: - Themed chrome survives the replace-row toggle
    //
    // Expanding/collapsing the replace row must not disturb the applied
    // theme. There is no direct caret-tint hook, so this is asserted at the
    // observable level: scheme + bar/field/label colours are unchanged after
    // setReplaceVisible(true) and after a subsequent setReplaceVisible(false).

    func test_setReplaceVisibleTrue_preservesAppliedScheme() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        bar.setReplaceVisible(true)
        XCTAssertTrue(bar.isReplaceVisible, "test setup: replace row must be visible")
        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.gruvboxDark),
                       "expanding the replace row must not drop the applied scheme")
    }

    func test_setReplaceVisibleTrue_preservesThemedColours() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        bar.setReplaceVisible(true)
        assertLayerColor(bar._barLayerBackgroundForTests(), equalsHex: 0x363532,
                         "bar colour must survive replace-row expansion")
        let field = bar._findFieldColorsForTests()
        assertColor(field.background, equalsHex: 0x413F3A,
                    "field background must survive replace-row expansion")
        assertColor(field.text, equalsHex: 0xEBDBB2,
                    "field text must survive replace-row expansion")
        assertColor(bar._matchLabelTextColorForTests(), equalsHex: 0xEBDBB2, alpha: 0.65,
                    "match label must survive replace-row expansion")
    }

    func test_toggleReplaceVisibleBothWays_preservesThemedColours() {
        let bar = makeBar()
        bar.applyTheme(Theme.gruvboxDark)
        bar.setReplaceVisible(true)
        bar.setReplaceVisible(false)
        XCTAssertFalse(bar.isReplaceVisible, "test setup: replace row must be collapsed")
        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.gruvboxDark),
                       "collapsing the replace row must not drop the applied scheme")
        assertLayerColor(bar._barLayerBackgroundForTests(), equalsHex: 0x363532,
                         "bar colour must survive an expand→collapse cycle")
        let field = bar._findFieldColorsForTests()
        assertColor(field.background, equalsHex: 0x413F3A,
                    "field background must survive an expand→collapse cycle")
        assertColor(bar._matchLabelTextColorForTests(), equalsHex: 0xEBDBB2, alpha: 0.65,
                    "match label must survive an expand→collapse cycle")
    }

    /// The reverse ordering: theming a bar that is ALREADY expanded must apply
    /// just the same (the replace row being open first must not block theming).
    func test_applyThemeWhileExpanded_appliesScheme() {
        let bar = makeBar()
        bar.setReplaceVisible(true)
        bar.applyTheme(Theme.gruvboxDark)
        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.gruvboxDark),
                       "theming an already-expanded bar must still record the scheme")
        assertLayerColor(bar._barLayerBackgroundForTests(), equalsHex: 0x363532,
                         "theming an already-expanded bar must colour the bar layer")
    }
}

/// Coverage for `FindController.applyTheme(_:)` — the layer that caches the
/// last-applied palette and forwards it to whatever `FindBar` is currently
/// live. Uses the same headless `TerminalView` fixture the other
/// FindController tests use (no PTY, no session, < a few MB).
///
/// NOTE: `installFindBar()`'s "apply the cached palette to a freshly created
/// bar" contract is intentionally NOT exercised here — the sibling
/// FindController tests set `findBar` directly rather than calling the install
/// path, so driving it headlessly (it may reach for a window) is out of scope
/// for a unit test. The caching + forwarding contract below is the safe,
/// observable core.
final class FindControllerThemeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Headless TerminalView — no PTY / session. The FindController it owns is
    /// the unit under test; its `findBar` is settable (as the sibling
    /// FindReplace tests rely on).
    private func makeView() throws -> TerminalView {
        try XCTUnwrap(TerminalView.makeHeadlessForTests())
    }

    /// applyTheme must record the palette even when no bar is live yet, so a
    /// later `installFindBar()` can colour the freshly created bar.
    func test_applyTheme_cachesPalette() throws {
        let view = try makeView()
        view.findController.applyTheme(Theme.gruvboxDark)
        XCTAssertEqual(view.findController.lastAppliedPalette, Theme.gruvboxDark,
                       "applyTheme must cache the palette in lastAppliedPalette")
    }

    /// A second applyTheme must replace the cached palette.
    func test_applyTheme_secondCall_replacesCachedPalette() throws {
        let view = try makeView()
        view.findController.applyTheme(Theme.gruvboxDark)
        view.findController.applyTheme(Theme.solarizedLight)
        XCTAssertEqual(view.findController.lastAppliedPalette, Theme.solarizedLight,
                       "the most recent applyTheme palette must win")
    }

    /// When a bar is live, applyTheme must forward to it — the bar ends up with
    /// the scheme derived from the palette.
    func test_applyTheme_forwardsToLiveBar() throws {
        let view = try makeView()
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        view.findController.findBar = bar

        view.findController.applyTheme(Theme.gruvboxDark)

        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.gruvboxDark),
                       "applyTheme must forward the palette to the live bar")
        XCTAssertEqual(view.findController.lastAppliedPalette, Theme.gruvboxDark,
                       "applyTheme must still cache while forwarding")
    }

    /// Re-theming with a different palette must re-forward to the live bar.
    func test_applyTheme_reForwardsToLiveBarOnChange() throws {
        let view = try makeView()
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        view.findController.findBar = bar

        view.findController.applyTheme(Theme.gruvboxDark)
        view.findController.applyTheme(Theme.solarizedLight)

        XCTAssertEqual(bar._appliedSchemeForTests(),
                       FindBarColorScheme(palette: Theme.solarizedLight),
                       "a second applyTheme must re-forward the new palette to the live bar")
    }
}
