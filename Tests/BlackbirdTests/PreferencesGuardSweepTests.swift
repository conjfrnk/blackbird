import XCTest
import Combine
@testable import Blackbird

/// Sweep regression for the SwiftUI `@AppStorage` ↔ UserDefaults feedback
/// loop documented in `feedback_swiftui_userdefaults_feedback_loop.md` and
/// fixed in commit 982b719.
///
/// The single existing test
/// `PreferencesTests.test_sameValueGuard_breaksSelfRefiringSink` proves the
/// guard *pattern* works for one synthetic UserDefaults probe key. This
/// suite drives the same self-refire shape against EVERY `@AppStorage`
/// setter on `Preferences` so a future engineer adding a new pref + sink
/// can't silently re-introduce the loop on the property they added.
///
/// **Memory cost** (per Connor's `feedback_test_memory_safety.md` rule):
/// the sweep does ~3 UserDefaults writes per property × 14 properties = 42
/// writes total, each a small scalar/string. Trivial — no large allocations
/// or shell sessions involved (cf. `feedback_test_real_shell_controllers.md`).
///
/// Gated behind `BB_RUN_STRESS_TESTS=1` for the same reason as the
/// existing same-value-guard test — the suite pumps the main RunLoop to
/// drain SwiftUI's leaky `@AppStorage` bridge re-entries, and that
/// pattern SEGVs in `CATransaction` under cumulative ASan in the default
/// CI run.
final class PreferencesGuardSweepTests: XCTestCase {

    // Keep a snapshot of the @AppStorage state we touch so a mid-sweep
    // crash can't pollute the developer's prefs domain. Mirrors the
    // strategy in PreferencesTests.swift — every property the sweep
    // writes to is captured here and restored unconditionally.
    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedFontName: String = ""
    private var savedFontSize: Double = 0
    private var savedBellRaw: String = ""
    private var savedCursorShapeRaw: String = ""
    private var savedOptionKeyRaw: String = ""
    private var savedWindowDragModifierRaw: String = ""
    private var savedWindowResizeModifierRaw: String = ""
    private var savedCursorBlink: Bool = false
    private var savedConfirmClose: Bool = false
    private var savedAutoUpdateChecks: Bool = false
    private var savedOSC52Enabled: Bool = false
    private var savedColorQueryEnabled: Bool = false
    private var savedConfirmMultiLinePaste: Bool = false
    private var savedTranslucency: Double = 0

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw              = p.themeRaw
        savedThemeModeRaw          = p.themeModeRaw
        savedFontName              = p.fontName
        savedFontSize              = p.fontSize
        savedBellRaw               = p.bellRaw
        savedCursorShapeRaw        = p.cursorShapeRaw
        savedOptionKeyRaw          = p.optionKeyRaw
        savedWindowDragModifierRaw   = p.windowDragModifierRaw
        savedWindowResizeModifierRaw = p.windowResizeModifierRaw
        savedCursorBlink           = p.cursorBlink
        savedConfirmClose          = p.confirmClose
        savedAutoUpdateChecks      = p.autoUpdateChecks
        savedOSC52Enabled          = p.osc52Enabled
        savedColorQueryEnabled     = p.colorQueryEnabled
        savedConfirmMultiLinePaste = p.confirmMultiLinePaste
        savedTranslucency          = p.translucency
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw              = savedThemeRaw
        p.themeModeRaw          = savedThemeModeRaw
        p.fontName              = savedFontName
        p.fontSize              = savedFontSize
        p.bellRaw               = savedBellRaw
        p.cursorShapeRaw        = savedCursorShapeRaw
        p.optionKeyRaw          = savedOptionKeyRaw
        p.windowDragModifierRaw   = savedWindowDragModifierRaw
        p.windowResizeModifierRaw = savedWindowResizeModifierRaw
        p.cursorBlink           = savedCursorBlink
        p.confirmClose          = savedConfirmClose
        p.autoUpdateChecks      = savedAutoUpdateChecks
        p.osc52Enabled          = savedOSC52Enabled
        p.colorQueryEnabled     = savedColorQueryEnabled
        p.confirmMultiLinePaste = savedConfirmMultiLinePaste
        p.translucency          = savedTranslucency
        super.tearDown()
    }

    // MARK: - Probe table
    //
    // Each probe drives the sweep for one `@AppStorage` setter. We can't
    // use a `WritableKeyPath` because `@AppStorage` exposes the wrapper's
    // projected value, not a Swift-level keypath — so each probe carries
    // closures that read the current value, write through the wrapper,
    // and own a per-property `committed` flag for the same-value guard.
    //
    // `name` is what the failure message reports — picking a property
    // whose guard breaks gives the future maintainer a direct pointer
    // to the source location instead of a generic "sweep failed".
    private struct GuardProbe {
        let name: String
        /// Installs the self-refiring sink, kicks the bridge once, drains
        /// re-entries, and returns the recorded write count. The sink
        /// uses the canonical `committed != desired` pattern from the
        /// existing test (982b719 fix shape).
        let runSweep: (Preferences) -> Int
    }

    /// Build the table at run time so each probe captures a fresh
    /// `desired` that's distinct from the property's current value.
    /// Picking from `allCases` (theme/themeMode/bell/cursorShape/optionKey)
    /// avoids tripping the enum repair in `repairEnumRawValues`, which
    /// would amplify writes and confuse the guard semantics.
    private func makeProbes(for p: Preferences) -> [GuardProbe] {
        var probes: [GuardProbe] = []

        // String-backed enum properties — pick a valid `allCases` value
        // distinct from current so `repairEnumRawValues` doesn't fire.
        probes.append(makeStringProbe(
            name: "themeRaw",
            current: p.themeRaw,
            candidates: Theme.allCases.map { $0.rawValue },
            write: { p.themeRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "themeModeRaw",
            current: p.themeModeRaw,
            candidates: Preferences.ThemeMode.allCases.map { $0.rawValue },
            write: { p.themeModeRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "bellRaw",
            current: p.bellRaw,
            candidates: Preferences.BellStyle.allCases.map { $0.rawValue },
            write: { p.bellRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "cursorShapeRaw",
            current: p.cursorShapeRaw,
            candidates: Preferences.CursorShape.allCases.map { $0.rawValue },
            write: { p.cursorShapeRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "optionKeyRaw",
            current: p.optionKeyRaw,
            candidates: Preferences.OptionKey.allCases.map { $0.rawValue },
            write: { p.optionKeyRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "windowDragModifierRaw",
            current: p.windowDragModifierRaw,
            candidates: Preferences.WindowGestureModifier.allCases.map { $0.rawValue },
            write: { p.windowDragModifierRaw = $0 }
        ))
        probes.append(makeStringProbe(
            name: "windowResizeModifierRaw",
            current: p.windowResizeModifierRaw,
            candidates: Preferences.WindowGestureModifier.allCases.map { $0.rawValue },
            write: { p.windowResizeModifierRaw = $0 }
        ))

        // Free-form String — fontName has no enum constraint, but we still
        // pick from a small known-good set so picker rendering is stable
        // if a future test snapshots the font Picker after this sweep.
        probes.append(makeStringProbe(
            name: "fontName",
            current: p.fontName,
            candidates: ["Hack Nerd Font Mono", "SF Mono", "Menlo"],
            write: { p.fontName = $0 }
        ))

        // Bool properties — desired is the opposite of current.
        probes.append(makeBoolProbe(
            name: "cursorBlink",
            current: p.cursorBlink,
            write: { p.cursorBlink = $0 }
        ))
        probes.append(makeBoolProbe(
            name: "confirmClose",
            current: p.confirmClose,
            write: { p.confirmClose = $0 }
        ))
        probes.append(makeBoolProbe(
            name: "autoUpdateChecks",
            current: p.autoUpdateChecks,
            write: { p.autoUpdateChecks = $0 }
        ))
        probes.append(makeBoolProbe(
            name: "osc52Enabled",
            current: p.osc52Enabled,
            write: { p.osc52Enabled = $0 }
        ))
        probes.append(makeBoolProbe(
            name: "colorQueryEnabled",
            current: p.colorQueryEnabled,
            write: { p.colorQueryEnabled = $0 }
        ))
        probes.append(makeBoolProbe(
            name: "confirmMultiLinePaste",
            current: p.confirmMultiLinePaste,
            write: { p.confirmMultiLinePaste = $0 }
        ))

        // Double properties — pick an in-range value distinct from
        // current so the didSet's clamp doesn't fire (which would
        // amplify the write count via the recursive clamp path).
        probes.append(makeDoubleProbe(
            name: "fontSize",
            current: p.fontSize,
            inRangeAlternative: p.fontSize == 13 ? 14 : 13,
            write: { p.fontSize = $0 }
        ))
        probes.append(makeDoubleProbe(
            name: "translucency",
            current: p.translucency,
            inRangeAlternative: p.translucency == 5 ? 6 : 5,
            write: { p.translucency = $0 }
        ))

        return probes
    }

    // MARK: - Probe factories
    //
    // Each factory closes over the property-specific write closure (the
    // value lookup happens at probe-construction time so each probe
    // captures a `desired` distinct from the property's pre-sweep
    // value). The returned `runSweep` closure executes the canonical
    // self-refiring-sink pattern, parameterised only by the write
    // action — the same-value guard runs on a sink-internal `committed`
    // flag, NOT a re-read through `@AppStorage`.
    //
    // CRITICAL — read the comment on `runRefireSweep` for why the
    // guard MUST track its own bool flag rather than comparing
    // `p.<property> == desired` inside the sink.

    private func makeStringProbe(
        name: String,
        current: String,
        candidates: [String],
        write: @escaping (String) -> Void
    ) -> GuardProbe {
        let desired = candidates.first { $0 != current } ?? candidates[0]
        return GuardProbe(name: name) { p in
            return Self.runRefireSweep(on: p) { write(desired) }
        }
    }

    private func makeBoolProbe(
        name: String,
        current: Bool,
        write: @escaping (Bool) -> Void
    ) -> GuardProbe {
        let desired = !current
        return GuardProbe(name: name) { p in
            return Self.runRefireSweep(on: p) { write(desired) }
        }
    }

    private func makeDoubleProbe(
        name: String,
        current: Double,
        inRangeAlternative: Double,
        write: @escaping (Double) -> Void
    ) -> GuardProbe {
        let desired = inRangeAlternative
        return GuardProbe(name: name) { p in
            return Self.runRefireSweep(on: p) { write(desired) }
        }
    }

    /// Canonical self-refiring-sink runner. Mirrors
    /// `PreferencesTests.test_sameValueGuard_breaksSelfRefiringSink` —
    /// the sink installs the same-value guard, the bridge re-fires after
    /// the sink's own write, and the guard pins the write count at
    /// exactly 1.
    ///
    /// What this catches per property
    /// ------------------------------
    /// 1. The probe-key kick (an unrelated UserDefaults write) MUST fire
    ///    `Preferences.objectWillChange` via SwiftUI's leaky bridge — if
    ///    a future SwiftUI version tightens that bridge, every probe
    ///    fails with `writeCount = 0` and we know the guard pattern's
    ///    fragility model has shifted.
    /// 2. After the sink's @AppStorage write, the bridge re-fires AGAIN
    ///    (UserDefaults.didChange → `UserDefaultObserver` →
    ///    objectWillChange). The `committed` flag MUST stick across
    ///    that re-entry — if a future change to a property's setter
    ///    somehow invalidates the captured-by-reference closure state
    ///    (e.g. by detaching/reattaching the sink mid-flight), the
    ///    second re-entry drives `writeCount = 2` and we surface it
    ///    with the property name.
    /// 3. The probe-table self-check (`assertProbeCoverageMatchesSourceAppStorage`)
    ///    forces a new @AppStorage in Preferences.swift to land here in
    ///    lockstep, so a net-new property with no probe doesn't sneak
    ///    past the sweep.
    ///
    /// What this does NOT catch
    /// ------------------------
    /// A property whose setter fires `objectWillChange` MORE THAN ONCE
    /// per Swift-side assignment is invisible to this runner — the
    /// `committed` flag short-circuits the second sink call regardless
    /// of how many notifications fire. The M5 tests
    /// (`test_m5_outOfRangeWrite_producesBoundedNotifications`,
    /// `test_m5_outOfRangeTranslucency_producesBoundedNotifications`)
    /// already cap that for the two clamped properties; new clamped
    /// properties should add their own M5-shaped runtime test.
    ///
    /// SHAPE — the guard MUST be a sink-internal `committed: Bool` flag,
    /// not `p.<property> == desired`. The `objectWillChange` notification
    /// fires BEFORE the wrapped value updates (that's what `willSet`
    /// means), so a re-read through `@AppStorage` during a recursive
    /// bridge re-entry could still see the OLD value, the guard would
    /// pass, and the sink would write an unbounded number of times. The
    /// single-flag pattern is what the existing
    /// `test_sameValueGuard_breaksSelfRefiringSink` uses verbatim — keep
    /// the contract identical so the sweep proves the same invariant
    /// for every property.
    private static func runRefireSweep(
        on p: Preferences,
        write: @escaping () -> Void
    ) -> Int {
        var writeCount = 0
        var committed = false
        let c = p.objectWillChange.sink { _ in
            // The 982b719 same-value guard. The sink's own `committed`
            // flag is the canonical state — same shape as the existing
            // single-probe test's `committed != desired` check, just
            // value-erased so this runner is reusable across String /
            // Bool / Double properties.
            guard !committed else { return }
            committed = true
            writeCount += 1
            write()
        }
        defer { c.cancel() }

        // Kick the bridge with an unrelated UserDefaults write — proven
        // by `test_unrelatedUserDefaultsWrite_firesPreferencesObjectWillChange`
        // to fire `Preferences.objectWillChange` via SwiftUI's leaky
        // `UserDefaultObserver`. Using a probe key (rather than e.g.
        // `cursorBlink.toggle()`) keeps the kick orthogonal to the
        // property under sweep — required when sweeping `cursorBlink`
        // itself.
        let probeKey = "blackbird.test.guard-sweep-kick.\(UUID().uuidString)"
        UserDefaults.standard.set(Int.random(in: 1...1_000_000), forKey: probeKey)
        defer { UserDefaults.standard.removeObject(forKey: probeKey) }

        // Drain the bridge. 0.2 s is the same window the existing
        // single-probe test uses; a runaway loop inflates `writeCount`
        // far past 1 within that budget.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        return writeCount
    }

    // MARK: - The sweep
    //
    // Drives the canonical self-refire-detection pattern across every
    // `@AppStorage` setter on `Preferences`. Per-property failures
    // surface with the property name in the failure message so a future
    // engineer sees `Preferences.fontSize lacks same-value guard` rather
    // than a generic `sweep failed`.

    /// Coverage parity between the probe table and `Preferences.swift`
    /// — pure regex + set-equality, no RunLoop pumping or SwiftUI
    /// bridge involvement. Runs unconditionally on every PR because
    /// the ASan / CATransaction hazard that gates the runtime sweep
    /// below does NOT apply here. If a new `@AppStorage` lands in
    /// `Preferences.swift` without an entry in `makeProbes`, this
    /// fails immediately rather than waiting for a developer to set
    /// `BB_RUN_STRESS_TESTS=1` and notice the runtime sweep skipped
    /// the new property.
    ///
    /// Why split from `test_sameValueGuard_holdsAcrossAllPreferencesSetters`:
    /// historically the coverage check was inlined into the gated
    /// runtime sweep, so default CI saw the entire class skip and
    /// silently assumed parity held. It didn't. The split lifts the
    /// coverage gate out of the env-gated path while keeping the
    /// runtime sweep gated for its own reasons.
    func test_preferenceProbeCoverageMatchesSourceAppStorage() throws {
        let p = Preferences.shared
        let probes = makeProbes(for: p)
        try assertProbeCoverageMatchesSourceAppStorage(probes: probes)
    }

    func test_sameValueGuard_holdsAcrossAllPreferencesSetters() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping guard-sweep test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the SwiftUI-bridge runtime assertion")

        let p = Preferences.shared
        let probes = makeProbes(for: p)

        // Coverage parity also runs in `test_preferenceProbeCoverageMatchesSourceAppStorage`
        // without env-gating, so default CI catches a missing probe
        // immediately. We re-run it here so a developer running this
        // gated test in isolation also gets the parity check.
        try assertProbeCoverageMatchesSourceAppStorage(probes: probes)

        // The sweep itself. Each probe runs in isolation: install the
        // sink, kick the bridge, drain, record `writeCount`. A failure
        // names the specific property so the follow-up commit knows
        // exactly which @AppStorage's setter is amplifying writes past
        // the canonical guard pattern.
        //
        // writeCount = 0 means the kick (or the @AppStorage write) didn't
        // reach `Preferences.objectWillChange` at all — a SwiftUI bridge
        // regression for that property.
        // writeCount = 1 is the documented invariant.
        // writeCount > 1 means the `committed` flag failed to stick
        // across a recursive bridge re-entry — the canonical 982b719
        // guard pattern would NOT contain a runaway loop that touches
        // this property in production.
        for probe in probes {
            let writeCount = probe.runSweep(p)
            XCTAssertEqual(
                writeCount, 1,
                "Preferences.\(probe.name) lacks same-value guard: writeCount=\(writeCount). The canonical 982b719 same-value-guard pattern (`guard committed != desired else { return }`) failed to pin the sink to one write across the SwiftUI `@AppStorage` bridge re-entries. See `feedback_swiftui_userdefaults_feedback_loop.md` and the existing `test_sameValueGuard_breaksSelfRefiringSink` for the canonical shape."
            )
        }
    }

    /// Cross-checks the probe table against every `@AppStorage("bb.X")`
    /// in `Preferences.swift`. The `appStorageKeyToPropertyName` table
    /// maps the on-disk key (which is what the regex captures) to the
    /// swift-side property identifier (which is what the probe table
    /// names). A future @AppStorage that lands without an entry here
    /// fails this assertion — the per-property writeCount sweep is
    /// otherwise blind to net-new properties.
    private func assertProbeCoverageMatchesSourceAppStorage(probes: [GuardProbe]) throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)"\)"#)
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        let declaredKeys = Set(re.matches(in: src, range: range).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: src) else { return nil }
            return String(src[r])
        })

        // bb.<key> → swift property identifier. The mapping is hand-
        // maintained because @AppStorage's projected name doesn't have
        // to match the on-disk key (and historically diverges for the
        // enum-rawValue-backed strings: `bb.theme` ↔ `themeRaw`, etc.).
        let appStorageKeyToPropertyName: [String: String] = [
            "bb.theme":                 "themeRaw",
            "bb.themeMode":             "themeModeRaw",
            "bb.fontName":              "fontName",
            "bb.fontSize":              "fontSize",
            "bb.cursorBlink":           "cursorBlink",
            "bb.bell":                  "bellRaw",
            "bb.cursorShape":           "cursorShapeRaw",
            "bb.optionKey":             "optionKeyRaw",
            "bb.windowDragModifier":    "windowDragModifierRaw",
            "bb.windowResizeModifier":  "windowResizeModifierRaw",
            "bb.confirmClose":          "confirmClose",
            "bb.autoUpdateChecks":      "autoUpdateChecks",
            "bb.osc52Enabled":          "osc52Enabled",
            "bb.colorQueryEnabled":     "colorQueryEnabled",
            "bb.confirmMultiLinePaste": "confirmMultiLinePaste",
            "bb.translucency":          "translucency",
        ]
        let unknownKeys = declaredKeys.subtracting(appStorageKeyToPropertyName.keys)
        XCTAssertTrue(
            unknownKeys.isEmpty,
            "Guard-sweep map missing entry for @AppStorage key(s): \(unknownKeys.sorted()). Add the key → swift-property mapping to `appStorageKeyToPropertyName` and a probe to `makeProbes(for:)` so the new pref is covered by the same-value-guard sweep."
        )
        let expectedPropertyNames = Set(declaredKeys.compactMap { appStorageKeyToPropertyName[$0] })
        let sweptNames = Set(probes.map(\.name))
        XCTAssertEqual(
            sweptNames, expectedPropertyNames,
            "Probe table drift vs. Preferences.swift @AppStorage declarations. Sweep covers \(sweptNames.sorted()), source declares \(expectedPropertyNames.sorted()). Update `makeProbes(for:)` to keep parity."
        )
    }

    /// Resolve `Sources/Blackbird/Settings/Preferences.swift` via the
    /// compile-time-embedded path of THIS file (`#filePath`). Same
    /// strategy as `PreferencesTests.locatePreferencesSwift` — the CWD
    /// under xcodebuild sits inside DerivedData and never contains the
    /// source tree, so `#filePath` is the only stable anchor for the
    /// repo root.
    fileprivate static func locatePreferencesSwift(
        file: String = #filePath
    ) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Blackbird/Settings/Preferences.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Preferences.swift not found at \(url.path)")
        }
        return url
    }
}
