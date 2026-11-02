import XCTest
import AppKit
@testable import Blackbird

/// Blind regression tests for bug mpe-3: the default VISUAL bell flash and the
/// scroll-position thumb are white-at-25%-alpha overlays, which are invisible
/// when composited over the near-white background of every LIGHT theme
/// (Default, Gruvbox, Solarized, Catppuccin in their light variants).
///
/// Written WITHOUT reading `BellController` / `ScrollIndicator` bodies. The
/// contract comes from the documented behaviour: a visual bell must be a
/// perceptible cue on the terminal grid, and the scroll thumb is the only
/// scrollback-position indicator, so both must be visible on whatever theme
/// background the user is looking at.
///
/// Method (observable behaviour only, no private-state introspection):
///   1. Pick a theme + mode via `Preferences` (the same inputs
///      `ThemeManager.resolvedPalette` consumes) and give the view the
///      matching window appearance (the app pins `window.appearance` to the
///      theme's lightness, so aqua for light themes / darkAqua for dark).
///   2. Drive the component through its public entry point
///      (`BellController.attach(to:)` + `handleBellCounter(_:)`, or
///      `ScrollIndicator.update(displayOffset:historySize:rows:)` with
///      `displayOffset > 0`).
///   3. Fill a bitmap with the resolved theme background (what the Metal grid
///      shows underneath the overlay), render the component's layer tree on
///      top with `CALayer.render(in:)`, and measure the largest per-pixel
///      luma change versus the plain background.
///   4. Assert the change is at least `minimumVisibleLumaDelta`.
///
/// Anti-vacuity: the DARK-theme control tests run the identical rig and must
/// measure a clearly visible overlay (white-on-dark is the case that already
/// works), and every test asserts that the bitmap fill really equals the
/// theme background and that the theme resolves to the expected light/dark
/// side before measuring. A rig that cannot see overlays at all fails the
/// controls instead of letting the light-theme checks pass or fail for the
/// wrong reason.
///
/// Pre-flight cost: bitmaps are 200x100 / 12x200 RGBA8 (<= 80 KB), at most
/// 4 themes x 3 modes x 2 components of work, one layer-backed view per
/// measurement (no windows, no sessions, no PTY). Well under 1 s total.
@MainActor
final class LightThemeBellAndThumbBlindTests: XCTestCase {

    // MARK: - Tunables

    /// Smallest acceptable change of the brightest-changed pixel's luma
    /// (Rec. 709 weights on sRGB-encoded bytes, normalised to 0...1) versus
    /// the bare theme background. A bare white-25% overlay on a dark theme
    /// moves luma by about 0.19-0.24, so 0.08 asks for roughly a third of
    /// what dark themes already get while still being far above the ~0.01 the
    /// buggy overlay manages on a near-white background.
    private static let minimumVisibleLumaDelta: Double = 0.08

    // MARK: - Fixture state

    private var savedBellRaw: String = ""
    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedAppAppearance: NSAppearance?

    /// Views/controllers built during a test, kept alive until teardown so an
    /// in-flight flash animation never outlives its owner.
    private var keepAlive: [AnyObject] = []

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedBellRaw = p.bellRaw
        savedThemeRaw = p.themeRaw
        savedThemeModeRaw = p.themeModeRaw
        savedAppAppearance = NSApp?.appearance
    }

    override func tearDown() {
        if !keepAlive.isEmpty {
            // Let any queued flash animation / completion run while its
            // owner is still alive.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            keepAlive.removeAll()
        }
        let p = Preferences.shared
        p.bellRaw = savedBellRaw
        p.themeRaw = savedThemeRaw
        p.themeModeRaw = savedThemeModeRaw
        NSApp?.appearance = savedAppAppearance
        // Drain the ThemeManager applyToAll blocks queued by the Preferences
        // writes above (same rationale as ThemeManagerBlindTests).
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        super.tearDown()
    }

    // MARK: - Measurement

    private struct Measurement {
        /// Theme background the overlay was composited over (0xRRGGBB).
        let background: UInt32
        /// Largest |luma(pixel) - luma(background)| over the whole bitmap.
        let peakLumaDelta: Double
    }

    private static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
    }

    private static func hex(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Fill a bitmap with `background`, render `layer`'s tree over it, and
    /// return the largest luma deviation from the plain background. Returns
    /// nil (after XCTFail) when the rig itself is broken.
    private func peakLumaDeviation(of layer: CALayer, over background: UInt32, what: String) -> Double? {
        let width = Int(layer.bounds.width.rounded(.up))
        let height = Int(layer.bounds.height.rounded(.up))
        guard width > 0, height > 0, width * height <= 100_000 else {
            XCTFail("\(what): unusable layer size \(layer.bounds.size); the measuring rig is broken")
            return nil
        }
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        buffer.initialize(repeating: 0, count: byteCount)
        defer { buffer.deallocate() }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            XCTFail("\(what): could not create the sRGB bitmap context; the measuring rig is broken")
            return nil
        }

        let red = CGFloat((background >> 16) & 0xFF) / 255.0
        let green = CGFloat((background >> 8) & 0xFF) / 255.0
        let blue = CGFloat(background & 0xFF) / 255.0
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Rig precondition: the fill really is the theme background.
        let expectedLuma = Self.luma(
            UInt8((background >> 16) & 0xFF),
            UInt8((background >> 8) & 0xFF),
            UInt8(background & 0xFF)
        )
        let baseline = Self.luma(buffer[0], buffer[1], buffer[2])
        XCTAssertEqual(
            baseline, expectedLuma, accuracy: 0.005,
            "\(what): bitmap fill luma \(Self.fmt(baseline)) != theme background \(Self.hex(background)) luma \(Self.fmt(expectedLuma))"
        )

        layer.render(in: ctx)

        var peak = 0.0
        var offset = 0
        for _ in 0..<(width * height) {
            let l = Self.luma(buffer[offset], buffer[offset + 1], buffer[offset + 2])
            peak = max(peak, abs(l - baseline))
            offset += 4
        }
        return peak
    }

    /// Fire one visual bell through `BellController` on a layer-backed host
    /// and measure how far the overlay moves the pixels off the theme
    /// background. `expectDark` is the side the theme must resolve to.
    private func measureVisualBell(
        theme: Theme,
        mode: Preferences.ThemeMode,
        hostAppearance: NSAppearance.Name,
        expectDark: Bool
    ) -> Measurement? {
        let p = Preferences.shared
        p.bellRaw = Preferences.BellStyle.visual.rawValue
        p.themeRaw = theme.rawValue
        p.themeModeRaw = mode.rawValue

        let label = "visual bell, theme \(theme.rawValue), mode \(mode.rawValue)"
        let palette = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(
            palette, theme.palette(dark: expectDark),
            "\(label): ThemeManager resolved the wrong palette (isDark=\(palette.isDark), expected dark=\(expectDark)); the rig does not select the intended theme side"
        )
        XCTAssertEqual(
            palette.isDark, expectDark,
            "\(label): resolved background \(Self.hex(palette.background)) has isDark=\(palette.isDark), expected \(expectDark)"
        )

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.wantsLayer = true
        host.appearance = NSAppearance(named: hostAppearance)
        let controller = BellController()
        controller.attach(to: host)
        keepAlive.append(host)
        keepAlive.append(controller)

        // Precondition: attach(to:) installs exactly one overlay subview. The
        // host is not in a window, so AppKit has not yet stitched subview
        // layers into `host.layer.sublayers`; the overlay is measured through
        // its own backing layer instead.
        XCTAssertEqual(
            host.subviews.count, 1,
            "\(label): attach(to:) must install exactly one flash overlay subview, found \(host.subviews.count)"
        )
        guard host.subviews.count == 1 else { return nil }
        let overlay = host.subviews[0]
        overlay.wantsLayer = true

        controller.handleBellCounter(1)

        guard let overlayLayer = overlay.layer else {
            XCTFail("\(label): the flash overlay has no backing layer; the measuring rig is broken")
            return nil
        }
        guard let peak = peakLumaDeviation(of: overlayLayer, over: palette.background, what: label) else {
            return nil
        }
        return Measurement(background: palette.background, peakLumaDelta: peak)
    }

    /// Scroll the indicator back (displayOffset > 0, thumb at full opacity)
    /// and measure how far the thumb moves the pixels off the theme
    /// background.
    private func measureScrollThumb(
        theme: Theme,
        mode: Preferences.ThemeMode,
        hostAppearance: NSAppearance.Name,
        expectDark: Bool
    ) -> Measurement? {
        let p = Preferences.shared
        p.themeRaw = theme.rawValue
        p.themeModeRaw = mode.rawValue

        let label = "scroll thumb, theme \(theme.rawValue), mode \(mode.rawValue)"
        let palette = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(
            palette, theme.palette(dark: expectDark),
            "\(label): ThemeManager resolved the wrong palette (isDark=\(palette.isDark), expected dark=\(expectDark)); the rig does not select the intended theme side"
        )
        XCTAssertEqual(
            palette.isDark, expectDark,
            "\(label): resolved background \(Self.hex(palette.background)) has isDark=\(palette.isDark), expected \(expectDark)"
        )

        let indicator = ScrollIndicator(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        indicator.wantsLayer = true
        indicator.appearance = NSAppearance(named: hostAppearance)
        keepAlive.append(indicator)

        // Scrolled back into history: the documented "thumb visible at full
        // opacity" state.
        indicator.update(displayOffset: 100, historySize: 1000, rows: 24)

        guard let indicatorLayer = indicator.layer else {
            XCTFail("\(label): layer-backed indicator has no layer; the measuring rig is broken")
            return nil
        }
        guard let peak = peakLumaDeviation(of: indicatorLayer, over: palette.background, what: label) else {
            return nil
        }
        return Measurement(background: palette.background, peakLumaDelta: peak)
    }

    // MARK: - Visual bell

    /// THE BUG: with the default bell style and any light theme, a BEL must
    /// still be visible. Today the overlay is white@25% over a near-white
    /// background, so the brightest-changed pixel moves by ~0.01 luma.
    func test_visualBell_isPerceptibleOnEveryLightTheme() {
        for theme in Theme.allCases {
            guard let m = measureVisualBell(
                theme: theme, mode: .light, hostAppearance: .aqua, expectDark: false
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "default Visual bell on light theme \(theme.rawValue) (background \(Self.hex(m.background))) changes the brightest-changed pixel's luma by only \(Self.fmt(m.peakLumaDelta)), below the \(Self.fmt(Self.minimumVisibleLumaDelta)) needed to be perceptible; the flash is invisible on this theme"
            )
        }
    }

    /// The same rig on a light theme reached through Auto mode with macOS in
    /// Light appearance (the second trigger in the bug report).
    func test_visualBell_isPerceptibleInAutoModeUnderLightSystemAppearance() {
        guard let app = NSApp else {
            XCTFail("NSApp must be alive in the xctest host")
            return
        }
        app.appearance = NSAppearance(named: .aqua)
        for theme in Theme.allCases {
            guard let m = measureVisualBell(
                theme: theme, mode: .auto, hostAppearance: .aqua, expectDark: false
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "default Visual bell on theme \(theme.rawValue) in Auto mode under a Light system appearance (background \(Self.hex(m.background))) changes the brightest-changed pixel's luma by only \(Self.fmt(m.peakLumaDelta)), below the \(Self.fmt(Self.minimumVisibleLumaDelta)) needed to be perceptible; the flash is invisible"
            )
        }
    }

    /// CONTROL (passes before and after the fix): dark themes already get a
    /// clearly visible flash. Proves the rig can see an overlay at all, so a
    /// light-theme shortfall is the overlay colour and not the measurement.
    func test_visualBell_controlIsPerceptibleOnEveryDarkTheme() {
        for theme in Theme.allCases {
            guard let m = measureVisualBell(
                theme: theme, mode: .dark, hostAppearance: .darkAqua, expectDark: true
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "control: Visual bell on dark theme \(theme.rawValue) (background \(Self.hex(m.background))) changes luma by only \(Self.fmt(m.peakLumaDelta)); the measuring rig cannot see the flash overlay, so the light-theme results are not trustworthy"
            )
        }
    }

    // MARK: - Scroll thumb

    /// THE BUG (second half): the scroll thumb is the only scrollback
    /// position indicator and must be visible against a light theme.
    func test_scrollThumb_isPerceptibleOnEveryLightTheme() {
        for theme in Theme.allCases {
            guard let m = measureScrollThumb(
                theme: theme, mode: .light, hostAppearance: .aqua, expectDark: false
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "scroll thumb (displayOffset 100 of 1000) on light theme \(theme.rawValue) (background \(Self.hex(m.background))) changes the brightest-changed pixel's luma by only \(Self.fmt(m.peakLumaDelta)), below the \(Self.fmt(Self.minimumVisibleLumaDelta)) needed to be perceptible; the thumb is invisible on this theme"
            )
        }
    }

    /// Auto mode with macOS in Light appearance must also show the thumb.
    func test_scrollThumb_isPerceptibleInAutoModeUnderLightSystemAppearance() {
        guard let app = NSApp else {
            XCTFail("NSApp must be alive in the xctest host")
            return
        }
        app.appearance = NSAppearance(named: .aqua)
        for theme in Theme.allCases {
            guard let m = measureScrollThumb(
                theme: theme, mode: .auto, hostAppearance: .aqua, expectDark: false
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "scroll thumb on theme \(theme.rawValue) in Auto mode under a Light system appearance (background \(Self.hex(m.background))) changes the brightest-changed pixel's luma by only \(Self.fmt(m.peakLumaDelta)), below the \(Self.fmt(Self.minimumVisibleLumaDelta)) needed to be perceptible; the thumb is invisible"
            )
        }
    }

    /// CONTROL (passes before and after the fix): the thumb is visible on
    /// every dark theme with the same rig.
    func test_scrollThumb_controlIsPerceptibleOnEveryDarkTheme() {
        for theme in Theme.allCases {
            guard let m = measureScrollThumb(
                theme: theme, mode: .dark, hostAppearance: .darkAqua, expectDark: true
            ) else { continue }
            XCTAssertGreaterThanOrEqual(
                m.peakLumaDelta, Self.minimumVisibleLumaDelta,
                "control: scroll thumb on dark theme \(theme.rawValue) (background \(Self.hex(m.background))) changes luma by only \(Self.fmt(m.peakLumaDelta)); the measuring rig cannot see the thumb, so the light-theme results are not trustworthy"
            )
        }
    }
}
