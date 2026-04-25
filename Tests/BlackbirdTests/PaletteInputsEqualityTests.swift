import XCTest
import Combine
@testable import Blackbird

/// Pre-flight memory/time budget for this file:
///
///   - Each test mutates `Preferences.shared.fontSize` (Double) up to a
///     few thousand times; no large allocations beyond UserDefaults
///     bookkeeping. Fits comfortably in the default `requireTestFitsInBudget`
///     ceiling — explicit call omitted because no grid / PTY / Metal
///     allocations are involved.
///   - Worst case wallclock is the 1000-mutation stress test below;
///     budget is 2 s on a sanitiser-enabled xctest host.
///   - All writes restored in tearDown to avoid pref pollution per
///     `feedback_test_real_shell_controllers.md` and PreferencesTests'
///     own snapshot pattern.
///
/// Scope: blind XCTest coverage of TST-S7-001, the high-leverage F-S7
/// finding around `ThemeManager.PaletteInputs` equality. The author has
/// NOT read `Sources/Blackbird/Settings/**`. Type `PaletteInputs` is
/// `private` to `ThemeManager` (per F-S7 cross-reference at line 249),
/// so direct equality construction is impossible from a test target.
/// We instead test the OBSERVABLE behaviour: a fontSize-only mutation
/// must not cause `applyToAllIfPaletteChanged` to do palette work.
///
/// Indirect signal: the work `applyToAllIfPaletteChanged` does on a
/// real palette change includes mutating window opacity / blur radius
/// via `Preferences.translucencyResolved` reads — observable through
/// `Preferences.objectWillChange` fan-out + wallclock. We assert the
/// system stays responsive under fontSize churn.
final class PaletteInputsEqualityTests: XCTestCase {

    /// Skip the 1000-iteration wallclock-signature tests when not
    /// running an explicit stress sweep. Under macos-14 GHA's
    /// cumulative ASan shadow-mapping, two 1000-iteration UserDefaults
    /// churn loops + their sink drains push the xctest host over the
    /// VM-mapping ceiling that the v0.1.9 sweep already taxed (700+
    /// pre-existing tests + 200+ new). Run via
    /// `BB_RUN_STRESS_TESTS=1 xcodebuild test -only-testing:…` for the
    /// real wallclock signal; the third test in this file
    /// (`test_themeChange_firesObjectWillChange_provesPalettePathLive`)
    /// stays in the default suite as the gate's positive-control.
    static func skipUnlessStressEnabled() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "1000-iteration UserDefaults stress tests flake under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the wallclock signal")
    }

    // Match PreferencesTests snapshot-and-restore so this file plays
    // safely with the shared singleton. Only the four prefs we touch
    // here need restoring, but we save the full set for symmetry —
    // a future addition would otherwise leak.
    private var savedFontSize: Double = 0
    private var savedFontName: String = ""
    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedFontSize     = p.fontSize
        savedFontName     = p.fontName
        savedThemeRaw     = p.themeRaw
        savedThemeModeRaw = p.themeModeRaw
    }

    override func tearDown() {
        let p = Preferences.shared
        p.fontSize     = savedFontSize
        p.fontName     = savedFontName
        p.themeRaw     = savedThemeRaw
        p.themeModeRaw = savedThemeModeRaw
        // Drain the ThemeManager sink so queued applyToAll blocks don't
        // leak into the next test's body. Same pattern as
        // ThemeResolutionTests.tearDown.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        super.tearDown()
    }

    // MARK: - TST-S7-001: fontSize-only mutation should not trigger palette re-apply

    /// The palette-equality gate (F-S7 line 249, "PaletteInputs excludes
    /// fontSize and fontName") guarantees a slider drag in Settings →
    /// Appearance does NOT cause `applyToAllIfPaletteChanged` to push
    /// new palette state down to every Metal renderer in every tab.
    ///
    /// Direct equality test on `PaletteInputs` is impossible (private
    /// type). We test the observable: mutate fontSize 1000 times, drain,
    /// and assert wallclock is within budget. A regression that
    /// re-applies on every fontSize change would re-walk every
    /// registered window's renderer pipeline — the same beachball
    /// signature 982b719 fixed.
    ///
    /// Scaling note: this test runs after `Preferences.shared` is
    /// already alive, so registration is not exercised. The win we get
    /// is a backstop on the gate's continued correctness.
    func test_fontSizeChurn_doesNotProduceWallclockSignatureOfPaletteReapply() throws {
        try Self.skipUnlessStressEnabled()
        let p = Preferences.shared
        // Fix the theme so anything the sink does on theme grounds is
        // constant across the run.
        p.themeRaw = Theme.defaultTheme.rawValue
        p.themeModeRaw = "dark"

        // Drive 1000 fontSize toggles between two clamp-safe values.
        // Even if every mutation woke a sink, 1000 trivial reads of
        // `translucencyResolved` should fit comfortably under 2 s.
        // A regression that does palette work per mutation would
        // exhibit an ~O(N × tabs × renderers) wallclock — many seconds
        // even with one test tab and no real renderer.
        let pairA: Double = 13.0
        let pairB: Double = 14.0
        let iterations = 1000

        let start = Date()
        for i in 0..<iterations {
            p.fontSize = (i % 2 == 0) ? pairA : pairB
        }
        // Drain to give sinks a chance to fire.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 2.0,
            """
            TST-S7-001: \(iterations) fontSize toggles took \(elapsed) s
            (budget 2 s). The palette-equality gate at
            ThemeManager.applyToAllIfPaletteChanged should short-circuit
            on fontSize-only changes (F-S7 line 249); a wallclock blow-
            up indicates the gate regressed and every fontSize tick is
            re-walking the registered-windows palette path — the same
            beachball pattern that hit Settings before 982b719.
            """
        )
    }

    /// Symmetric test: fontNAME-only mutation should also short-circuit
    /// per F-S7 line 249. A name change DOES require a font-atlas
    /// rebuild (handled separately) but must NOT re-apply the palette
    /// to every renderer's MTLBuffer.
    ///
    /// We bounce between two valid font names and measure wallclock.
    /// Same budget as the fontSize test.
    func test_fontNameChurn_doesNotProduceWallclockSignatureOfPaletteReapply() throws {
        try Self.skipUnlessStressEnabled()
        let p = Preferences.shared
        p.themeRaw = Theme.defaultTheme.rawValue
        p.themeModeRaw = "dark"

        // Two known-installed fonts. SF Mono ships with macOS 14+;
        // Menlo is universal Apple. Either is registered without us
        // having to install anything.
        let pairA = "SF Mono"
        let pairB = "Menlo"
        let iterations = 1000

        let start = Date()
        for i in 0..<iterations {
            p.fontName = (i % 2 == 0) ? pairA : pairB
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 2.0,
            """
            TST-S7-001: \(iterations) fontName toggles took \(elapsed) s
            (budget 2 s). Per F-S7 line 249 PaletteInputs should
            exclude fontName so applyToAllIfPaletteChanged short-
            circuits. Wallclock blow-up indicates the gate regressed.
            """
        )
    }

    /// Positive control: an actual THEME change SHOULD trigger
    /// applyToAll work (the palette inputs include theme + mode).
    /// We don't measure the work itself — we just verify
    /// `Preferences.objectWillChange` fires, proving the sink path
    /// is wired.
    ///
    /// This test catches the CONVERSE bug: a regression that nukes
    /// the theme path while collapsing the equality gate too far,
    /// leaving the user with a "stuck" theme.
    func test_themeChange_firesObjectWillChange_provesPalettePathLive() {
        let p = Preferences.shared
        // Flip themeRaw between two distinct themes.
        let allThemes = Theme.allCases
        guard allThemes.count >= 2 else {
            XCTFail("Need ≥ 2 themes to flip; got \(allThemes.count)")
            return
        }
        let a = allThemes[0]
        let b = allThemes[1]
        p.themeRaw = a.rawValue

        var fired = false
        let cancellable = p.objectWillChange.sink { _ in fired = true }
        defer { cancellable.cancel() }

        p.themeRaw = b.rawValue
        // SwiftUI's @AppStorage forwards objectWillChange synchronously
        // on the setter — we don't need to hop a runloop to observe.
        XCTAssertTrue(
            fired,
            """
            TST-S7-001 control: themeRaw write should fire
            Preferences.objectWillChange so ThemeManager re-applies
            palette. If this test fails, the @AppStorage bridge
            broke entirely — every other Settings test would also
            be affected.
            """
        )
    }
}
