import Combine
import AppKit

/// Single object that observes `Preferences` + `NSApp.effectiveAppearance`
/// (for Auto mode) and pushes the resolved palette into every registered
/// session + view.
///
/// Threading: annotated `@MainActor`. All palette mutations, registration
/// bookkeeping, and Preferences reads must happen on the main runloop. Every
/// fire-path (`objectWillChange` sink, `effectiveAppearance` KVO, first-show
/// `refresh`, `register`) already hops via `DispatchQueue.main.async` or is
/// called directly from AppKit main-thread callbacks, so this annotation
/// is descriptive — it just nails the invariant down so a future background-
/// queue caller (or Swift Concurrency migration) gets a compile-time warning
/// instead of a silently-corrupt `registrations` array. (settings F4)
@MainActor
public final class ThemeManager {
    public static let shared = ThemeManager()

    private var observers = [AnyCancellable]()
    private var appearanceObs: NSKeyValueObservation?
    private weak var currentApp: NSApplication?

    /// One registration per live window controller. `owner` is held weakly
    /// and keyed by `ObjectIdentifier(owner)` so a window teardown auto-
    /// evicts the entry — no explicit unregister() needed from the caller.
    /// (main-window F1)
    private struct Registration {
        weak var owner: AnyObject?
        let sessionProvider: () -> TerminalSession?
        let viewProvider: () -> TerminalView?
    }
    private var registrations: [ObjectIdentifier: Registration] = [:]

    /// Cache of the inputs `applyTheme(_:)` actually consumes.
    /// `objectWillChange` fires on every `@AppStorage` write (font-size
    /// slider, OSC 52 toggle, …), but most of those don't change what
    /// `applyTheme` pushes. Compare the tuple on every would-be apply and
    /// skip the 19× `bbterm.setColor` + renderer push when nothing
    /// relevant changed.
    ///
    /// Why each field is in the tuple:
    /// - `themeRaw`, `themeModeRaw`, `appearanceIsDark` — drive which
    ///   palette is resolved (the core palette swap).
    /// - `translucency` — consumed by `applyTheme` for `clearColor`
    ///   alpha, renderer bg opacity, and window blur radius. Must be in
    ///   the tuple or translucency-slider changes wouldn't propagate
    ///   live (the palette itself doesn't change when the slider moves).
    /// - `cursorBlink`, `cursorShapeRaw` — also consumed by
    ///   `applyTheme`; same liveness requirement. (settings F1)
    private struct PaletteInputs: Equatable {
        let themeRaw: String
        let themeModeRaw: String
        let appearanceIsDark: Bool
        let translucency: Double
        let cursorBlink: Bool
        let cursorShapeRaw: String
    }
    private var lastPaletteInputs: PaletteInputs?

    private init() {
        // ⚠ FEEDBACK-LOOP HAZARD — DO NOT WRITE USERDEFAULTS HERE.
        //
        // Subscribers to `Preferences.shared.objectWillChange` must NOT perform
        // a `UserDefaults.standard.set(…)` or any call that transitively writes
        // UserDefaults (e.g. Sparkle's `automaticallyChecksForUpdates =`).
        // Every UserDefaults write fires `NSUserDefaultsDidChangeNotification`,
        // which SwiftUI's global `UserDefaultObserver` bridges back into
        // `objectWillChange` on every ObservableObject holding an @AppStorage —
        // including `Preferences.shared`. That re-fires this sink, which
        // writes again, and the main queue piles up `main.async` blocks until
        // the process OOMs (see commit 982b719 / AppDelegate.autoUpdateObserver
        // for the fix pattern). If a UserDefaults write is unavoidable, add a
        // same-value guard before the write so the self-re-entry short-circuits.
        //
        // This closure is safe: it only pushes palette/state into TerminalSession
        // (Rust) and TerminalView (Metal/AppKit). No UserDefaults writes.
        observers.append(
            Preferences.shared.objectWillChange
                .sink { [weak self] _ in
                    // objectWillChange fires before the update; re-apply on
                    // the next runloop tick once the @AppStorage value has
                    // actually settled.
                    DispatchQueue.main.async { self?.applyToAllIfPaletteChanged() }
                }
        )
    }

    public func attach(toApp app: NSApplication) {
        currentApp = app
        appearanceObs = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyToAllIfPaletteChanged() }
        }
    }

    /// Register a (session, view) pair keyed by a long-lived owner object
    /// (typically the `MainWindowController`). The owner is captured weakly,
    /// so when the controller deinits the entry auto-evicts on the next
    /// apply pass — callers don't need to pair this with an unregister.
    /// Re-registering with the same owner replaces the prior entry.
    public func register(owner: AnyObject,
                         sessionProvider: @escaping () -> TerminalSession?,
                         viewProvider:    @escaping () -> TerminalView?) {
        let key = ObjectIdentifier(owner)
        registrations[key] = Registration(
            owner: owner,
            sessionProvider: sessionProvider,
            viewProvider: viewProvider
        )
        apply(session: sessionProvider(), view: viewProvider())
    }

    public var resolvedPalette: ThemePalette {
        let p = Preferences.shared
        let dark: Bool
        switch p.themeMode {
        case .auto:
            let app = currentApp ?? NSApp
            dark = app?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .light: dark = false
        case .dark:  dark = true
        }
        return p.theme.palette(dark: dark)
    }

    /// Re-apply the resolved palette to every registration. Use from any
    /// "the window just became ready for a palette" hook (e.g. first show),
    /// so quantities that need a live windowNumber — like the CGS blur
    /// radius — actually take effect.
    public func refresh() {
        // Unconditional apply — first-show blur wiring needs this even when
        // the palette itself hasn't changed since the last apply (the window
        // number wasn't live last time). Bypass the equality gate.
        applyToAll()
    }

    /// Called from the Preferences-change sink and the effectiveAppearance
    /// KVO. Short-circuits when no palette-relevant input changed — prevents
    /// font-size slider drags from re-applying the palette at per-frame
    /// rates. (settings F1)
    private func applyToAllIfPaletteChanged() {
        let inputs = currentPaletteInputs()
        if let last = lastPaletteInputs, last == inputs {
            // Still reap dead owners even on the fast path so the dictionary
            // doesn't grow when palette-irrelevant prefs churn.
            reapDeadRegistrations()
            return
        }
        lastPaletteInputs = inputs
        applyToAll()
    }

    private func currentPaletteInputs() -> PaletteInputs {
        let p = Preferences.shared
        let app = currentApp ?? NSApp
        let isDark = app?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return PaletteInputs(
            themeRaw: p.themeRaw,
            themeModeRaw: p.themeModeRaw,
            appearanceIsDark: isDark,
            translucency: p.translucency,
            cursorBlink: p.cursorBlink,
            cursorShapeRaw: p.cursorShapeRaw
        )
    }

    private func reapDeadRegistrations() {
        for (key, reg) in registrations where reg.owner == nil {
            registrations.removeValue(forKey: key)
        }
    }

    private func applyToAll() {
        // Reap registrations whose owner (MainWindowController) has been
        // deallocated. Weak-owner keying means dead windows self-evict
        // here — no explicit unregister call is required from the caller
        // side. (main-window F1)
        reapDeadRegistrations()
        lastPaletteInputs = currentPaletteInputs()
        for reg in registrations.values {
            apply(session: reg.sessionProvider(), view: reg.viewProvider())
        }
    }

    private func apply(session: TerminalSession?, view: TerminalView?) {
        let palette = resolvedPalette
        session?.applyPalette(palette)
        view?.applyTheme(palette)
    }
}
