import XCTest
import AppKit
@testable import Blackbird

/// Blind XCTest coverage of `ThemeManager`.
///
/// SCOPE: This file authors tests WITHOUT having read
/// `Sources/Blackbird/Settings/ThemeManager.swift`. The contract being
/// exercised is the public API documented at the call sites and in the
/// blind-test brief:
///
///   - `ThemeManager.shared` is a singleton.
///   - `register(owner:sessionProvider:viewProvider:)` is keyed by
///     `ObjectIdentifier(owner)`, holds `owner` weakly, replaces on
///     re-registration with the same key, and auto-evicts on the next
///     apply pass when the owner deinits.
///   - `resolvedPalette` returns the currently-resolved `ThemePalette`
///     given `Preferences.shared.theme` + `themeMode` (and, for `.auto`,
///     `NSApp.effectiveAppearance`).
///   - `refresh()` re-applies the palette to every live registration,
///     bypassing the internal equality gate.
///
/// Memory/time pre-flight:
///   - Each test allocates at most a few stub objects + a `ThemePalette`
///     (16-entry `[UInt32]`). Wall under 100 ms with sanitisers on.
///   - No `MainWindowController`, no PTY, no Metal — only the
///     ThemeManager registration bookkeeping.
///
/// Preferences hygiene mirrors `PreferencesTests` / `ThemeResolutionTests`:
/// snapshot every pref the contract observes in `setUp`, restore in
/// `tearDown`. We do NOT inject a separate UserDefaults suite — neither
/// PreferencesTests nor ThemeResolutionTests do, and `ThemeManager` reads
/// `Preferences.shared` (the standard suite) directly.
@MainActor
final class ThemeManagerBlindTests: XCTestCase {

    // MARK: - Preferences snapshot

    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedTranslucency: Double = 0
    private var savedCursorBlink: Bool = false
    private var savedCursorShapeRaw: String = ""

    // Saved app appearance — `test_autoMode_followsEffectiveAppearance`
    // mutates `NSApp.appearance`; restore it on teardown so we don't
    // contaminate any other tests in the bundle that read it.
    private var savedAppAppearance: NSAppearance?

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw       = p.themeRaw
        savedThemeModeRaw   = p.themeModeRaw
        savedTranslucency   = p.translucency
        savedCursorBlink    = p.cursorBlink
        savedCursorShapeRaw = p.cursorShapeRaw
        savedAppAppearance  = NSApp?.appearance
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw       = savedThemeRaw
        p.themeModeRaw   = savedThemeModeRaw
        p.translucency   = savedTranslucency
        p.cursorBlink    = savedCursorBlink
        p.cursorShapeRaw = savedCursorShapeRaw
        NSApp?.appearance = savedAppAppearance
        // Drain queued ThemeManager applyToAll blocks before the next
        // test starts (same rationale as ThemeResolutionTests.tearDown:
        // ThemeManager.shared observes Preferences.objectWillChange and
        // schedules work on .main; without a drain those queued blocks
        // would run during the NEXT test's body). Short — 0.02 s clears
        // a single tick of backlog.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        super.tearDown()
    }

    // MARK: - Stub types
    //
    // `register()` keys by `ObjectIdentifier(owner)` and holds owner
    // weakly, per the contract. A bare NSObject subclass is the simplest
    // long-lived AnyObject that the test can construct + drop on demand
    // without dragging in MainWindowController.
    //
    // The providers in production return `TerminalSession?` and
    // `TerminalView?`. Returning `nil` from a stub provider satisfies
    // the type signature without standing up real sessions; that's
    // exactly the "test the registration bookkeeping, not the side
    // effects on a live view" path the blind brief calls for.

    private final class StubOwner: NSObject {}

    // MARK: - 1. Singleton identity

    /// Trivial design-pin: `ThemeManager.shared` must be the same instance
    /// across calls. Any future refactor that accidentally drops the
    /// shared-singleton invariant (e.g. recreating the instance on demand)
    /// would break every registration on the second call.
    func test_shared_returnsSameInstance() {
        let a = ThemeManager.shared
        let b = ThemeManager.shared
        XCTAssertTrue(a === b,
                      "ThemeManager.shared must be a singleton; got two distinct instances")
    }

    // MARK: - 2 & 3. Resolved palette for explicit light / dark mode

    /// Forced `.light` mode resolves the currently-selected theme's light
    /// palette regardless of `NSApp.effectiveAppearance`. Pin a specific
    /// theme so the comparison is concrete.
    func test_resolvedPalette_forcedLight_matchesThemeLightPalette() {
        Preferences.shared.themeRaw = Theme.gruvbox.rawValue
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.light.rawValue
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved, Theme.gruvbox.palette(dark: false),
                       "Forced .light must resolve to the theme's light palette")
        XCTAssertFalse(resolved.isDark,
                       "Forced .light must not classify the resulting background as dark")
    }

    /// Forced `.dark` mode resolves the currently-selected theme's dark
    /// palette regardless of `NSApp.effectiveAppearance`.
    func test_resolvedPalette_forcedDark_matchesThemeDarkPalette() {
        Preferences.shared.themeRaw = Theme.solarized.rawValue
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.dark.rawValue
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved, Theme.solarized.palette(dark: true),
                       "Forced .dark must resolve to the theme's dark palette")
        XCTAssertTrue(resolved.isDark,
                      "Forced .dark must classify the resulting background as dark")
    }

    // MARK: - 4. Auto mode follows NSApp.effectiveAppearance

    /// `.auto` mode picks dark / light from `NSApp.effectiveAppearance`:
    /// `darkAqua` ⇒ dark, anything else ⇒ light. We set `NSApp.appearance`
    /// (which dictates `effectiveAppearance` when no system override is
    /// active inside the xctest host) and assert the resolved palette
    /// follows.
    ///
    /// Guarded with `XCTSkipIf` for the (theoretical) headless case where
    /// `NSApp` is nil — the test host is an AppKit `@main` app so NSApp
    /// is normally alive, but the skip keeps the test safe under future
    /// runners.
    func test_autoMode_followsEffectiveAppearance() throws {
        let app = try XCTUnwrap(NSApp, "NSApp must be alive in the xctest host")
        Preferences.shared.themeRaw = Theme.catppuccin.rawValue
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.auto.rawValue

        // Light side.
        app.appearance = NSAppearance(named: .aqua)
        let resolvedLight = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolvedLight, Theme.catppuccin.palette(dark: false),
                       ".auto under aqua must resolve to the light palette")

        // Dark side.
        app.appearance = NSAppearance(named: .darkAqua)
        let resolvedDark = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolvedDark, Theme.catppuccin.palette(dark: true),
                       ".auto under darkAqua must resolve to the dark palette")
    }

    // MARK: - 5. Theme change updates palette

    /// Switching theme rawValue (with mode held constant) must produce a
    /// different `resolvedPalette`. Catches a regression where the
    /// manager's palette cache failed to invalidate on theme change.
    func test_themeChange_updatesResolvedPalette() {
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.dark.rawValue
        Preferences.shared.themeRaw = Theme.gruvbox.rawValue
        let first = ThemeManager.shared.resolvedPalette
        Preferences.shared.themeRaw = Theme.solarized.rawValue
        let second = ThemeManager.shared.resolvedPalette
        XCTAssertNotEqual(first, second,
                          "Switching themeRaw between two distinct themes must change resolvedPalette")
        XCTAssertEqual(first, Theme.gruvbox.palette(dark: true))
        XCTAssertEqual(second, Theme.solarized.palette(dark: true))
    }

    // MARK: - 6. Register + refresh — providers invoked, no crash

    /// `refresh()` walks every live registration and invokes its providers
    /// (the closures the caller passed). Stub providers return nil but
    /// increment a counter so the test can observe invocation.
    func test_register_thenRefresh_invokesProviders_andDoesNotCrash() {
        XCTAssertTrue(Thread.isMainThread,
                      "register/refresh must be called on the main thread (ThemeManager is @MainActor)")
        let owner = StubOwner()
        var sessionCalls = 0
        var viewCalls = 0
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { sessionCalls += 1; return nil },
            viewProvider:    { viewCalls    += 1; return nil }
        )
        ThemeManager.shared.refresh()
        // Precise: register() applies once inline, refresh() applies once
        // more. Two invocations of each provider, no more no less. Bumping
        // from `>= 1` to `== 2` catches mutations that fire only one path
        // (e.g. a refactor that drops the inline apply, or one that walks
        // the registration table twice).
        XCTAssertEqual(sessionCalls, 2,
                       "register() + refresh() must invoke sessionProvider exactly twice")
        XCTAssertEqual(viewCalls, 2,
                       "register() + refresh() must invoke viewProvider exactly twice")
        // Reference owner past refresh() to keep it strongly retained
        // through the apply pass — otherwise the weak-owner contract
        // could evict it before refresh runs.
        withExtendedLifetime(owner) {}
    }

    // MARK: - 7. Re-register same owner replaces prior entry

    /// Two `register()` calls with the same owner key must result in
    /// ONLY the second provider closures firing on the next refresh.
    /// The contract documents that re-registration replaces — a bug
    /// that appended instead would invoke both closures.
    func test_register_sameOwnerReplacesPriorEntry() {
        let owner = StubOwner()
        var firstClosureCalls = 0
        var secondClosureCalls = 0
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { firstClosureCalls += 1; return nil },
            viewProvider:    { firstClosureCalls += 1; return nil }
        )
        // register() performs an inline apply that invokes the freshly-installed
        // providers once each. That's the documented one-shot apply; this test
        // gates on whether the OLD providers fire on a SUBSEQUENT refresh after
        // a replacement. Reset to measure post-replacement behavior only.
        firstClosureCalls = 0
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { secondClosureCalls += 1; return nil },
            viewProvider:    { secondClosureCalls += 1; return nil }
        )
        ThemeManager.shared.refresh()
        XCTAssertEqual(firstClosureCalls, 0,
                       "After replacement, the prior providers must not fire on subsequent applies")
        // The replacement register applies once inline (count 2) and
        // refresh() applies once more (count 4). Pin precisely so an
        // accidental "append-then-iterate-both" bug surfaces as count > 4
        // rather than silently passing the >=1 lower bound.
        XCTAssertEqual(secondClosureCalls, 4,
                       "Replacement: register-inline-apply (2) + refresh (2) = 4 invocations exactly")
        withExtendedLifetime(owner) {}
    }

    // MARK: - 8. Weak-owner auto-evict

    /// Register an owner inside a scope that drops the strong ref. The
    /// next `refresh()` apply pass MUST NOT invoke the evicted entry's
    /// providers (the weak owner reference is nil; the entry is dead).
    ///
    /// Stability note on autoreleasepool: the autorelease pool drains
    /// on block exit, which combined with no further strong references
    /// is enough for ARC to release a plain `NSObject` subclass like
    /// `StubOwner`. We don't rely on the pool for object lifetime per
    /// se (Swift ARC handles that on its own); the explicit pool keeps
    /// the test deterministic across optimisation modes by giving ARC
    /// a clear scope boundary.
    func test_weakOwner_autoEvictsOnNextApplyPass() {
        var providerInvocations = 0
        autoreleasepool {
            let owner = StubOwner()
            ThemeManager.shared.register(
                owner: owner,
                sessionProvider: { providerInvocations += 1; return nil },
                viewProvider:    { providerInvocations += 1; return nil }
            )
            // Sanity: while owner is alive, providers must fire.
            ThemeManager.shared.refresh()
            XCTAssertGreaterThan(
                providerInvocations, 0,
                "Sanity precondition: providers must fire while owner is alive — if this fails the rest of the assertion is meaningless"
            )
            providerInvocations = 0
        }
        // `owner` is out of scope; ARC has dropped the strong ref.
        // The next refresh() must NOT invoke the evicted entry's
        // providers.
        ThemeManager.shared.refresh()
        XCTAssertEqual(
            providerInvocations, 0,
            "After the owner deinits, refresh() must not invoke the evicted entry's providers (weak-owner contract)"
        )
    }

    // MARK: - 9. Equality gate skips redundant applies
    //
    // ASSUMPTION about the equality-gate triggers:
    //
    // Per the blind brief: "The apply path skips the 19× setColor +
    // renderer push when the (themeRaw, themeModeRaw, appearanceIsDark,
    // translucency, cursorBlink, cursorShapeRaw) tuple hasn't changed."
    // BUT: we cannot from a black-box test cleanly distinguish "the
    // closures were not invoked" from "the closures were invoked but
    // their work was a no-op". The brief itself flags this ambiguity
    // ("NOTE: this depends on whether `refresh()` is called by the
    // change path. If unclear, write the test for the path you can
    // observe and document.").
    //
    // The observable contract we CAN pin: writing the SAME pref value
    // (e.g. assigning `themeModeRaw` to its current rawValue) must NOT
    // re-fire the provider closures via the change-notification path.
    // If it did, every keystroke in Settings would re-walk every
    // registered window's renderer pipeline — the 982b719 beachball
    // signature. We assert that contract here.

    /// Writing a Preferences value to its CURRENT value (no actual
    /// change) must not drive the `ThemeManager` apply path to invoke
    /// registered providers. This is the observable form of the
    /// equality-gate guarantee.
    func test_equalityGate_sameValuePrefWrite_doesNotReInvokeProviders() {
        Preferences.shared.themeRaw     = Theme.gruvbox.rawValue
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.dark.rawValue

        let owner = StubOwner()
        var invocations = 0
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { invocations += 1; return nil },
            viewProvider:    { invocations += 1; return nil }
        )
        // Prime: drive a first apply so the manager's internal cache
        // reflects the current inputs.
        ThemeManager.shared.refresh()
        // Drain any queued sink work.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        invocations = 0

        // Now write the SAME values back. The Preferences.objectWillChange
        // sink fires, but the palette inputs haven't moved, so the apply
        // path should short-circuit and NOT invoke the providers.
        Preferences.shared.themeModeRaw = Preferences.ThemeMode.dark.rawValue
        Preferences.shared.themeRaw     = Theme.gruvbox.rawValue
        // Give any queued sink one tick to run.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            invocations, 0,
            """
            Equality gate: writing the same Preferences value back must not \
            re-invoke registered providers. Observed \(invocations) provider \
            calls after a same-value write — every keystroke in Settings \
            would walk every renderer if this regressed.
            """
        )
        withExtendedLifetime(owner) {}
    }

    // MARK: - 10. refresh() bypasses the equality gate

    /// `refresh()` is documented to BYPASS the equality gate — used from
    /// "the window just became ready for a palette" hooks (e.g. first
    /// show / blur wiring) where the inputs haven't moved but the live
    /// view still needs the palette re-applied. Two back-to-back
    /// `refresh()` calls must therefore invoke the providers BOTH times.
    func test_refresh_bypassesEqualityGate_invokesProvidersEveryCall() {
        let owner = StubOwner()
        var invocations = 0
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { invocations += 1; return nil },
            viewProvider:    { invocations += 1; return nil }
        )
        ThemeManager.shared.refresh()
        let firstCount = invocations
        XCTAssertGreaterThan(firstCount, 0,
                             "First refresh() must invoke the providers")
        ThemeManager.shared.refresh()
        XCTAssertGreaterThan(
            invocations, firstCount,
            """
            refresh() must bypass the equality gate; a second back-to-back \
            refresh() with no pref changes must still invoke the providers. \
            Observed \(invocations) total calls (was \(firstCount) after \
            first refresh). If refresh() ever silently no-ops the second \
            call, first-show blur wiring will miss its palette apply.
            """
        )
        withExtendedLifetime(owner) {}
    }

    // MARK: - 11. Main-thread invariant (@MainActor)

    /// Adjacent main-thread assertion. The class is `@MainActor`, so
    /// every call MUST be issued from main; XCTest already runs test
    /// bodies on main but pinning the invariant here catches a future
    /// refactor that moves a test body off-main (e.g. via `Task.detached`)
    /// and would then violate the actor contract silently.
    func test_register_isCalledOnMainThread() {
        XCTAssertTrue(Thread.isMainThread,
                      "Test body must run on the main thread for ThemeManager's @MainActor contract")
        let owner = StubOwner()
        ThemeManager.shared.register(
            owner: owner,
            sessionProvider: { nil },
            viewProvider:    { nil }
        )
        XCTAssertTrue(Thread.isMainThread,
                      "register() must not hop the call off main")
        withExtendedLifetime(owner) {}
    }

    // MARK: - 12. Multiple owners register independently

    /// Two distinct owners register independently. `refresh()` walks both.
    /// When one is dropped (via autoreleasepool scope), `refresh()` only
    /// walks the survivor — the dead entry is auto-evicted.
    func test_multipleOwners_registerIndependently_andSurvivorContinues() {
        var aCalls = 0
        var bCalls = 0
        // Keep `b` alive across the autoreleasepool that owns `a`.
        let b = StubOwner()
        ThemeManager.shared.register(
            owner: b,
            sessionProvider: { bCalls += 1; return nil },
            viewProvider:    { bCalls += 1; return nil }
        )
        autoreleasepool {
            let a = StubOwner()
            ThemeManager.shared.register(
                owner: a,
                sessionProvider: { aCalls += 1; return nil },
                viewProvider:    { aCalls += 1; return nil }
            )
            ThemeManager.shared.refresh()
            XCTAssertGreaterThan(aCalls, 0,
                                 "Both registrations must fire while both owners are alive (a)")
            XCTAssertGreaterThan(bCalls, 0,
                                 "Both registrations must fire while both owners are alive (b)")
            aCalls = 0
            bCalls = 0
        }
        // `a` is gone; `b` survives.
        ThemeManager.shared.refresh()
        XCTAssertEqual(aCalls, 0,
                       "After owner a deinits, its providers must not be invoked again (weak-owner eviction)")
        XCTAssertGreaterThan(bCalls, 0,
                             "The surviving owner b's providers must still fire on subsequent refresh()")
        withExtendedLifetime(b) {}
    }
}
