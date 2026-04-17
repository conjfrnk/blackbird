import Combine
import AppKit

/// Single object that observes `Preferences` + `NSApp.effectiveAppearance`
/// (for Auto mode) and pushes the resolved palette into every registered
/// session + view.
public final class ThemeManager {
    public static let shared = ThemeManager()

    private var observers = [AnyCancellable]()
    private var appearanceObs: NSKeyValueObservation?
    private weak var currentApp: NSApplication?
    private var registrations: [(() -> TerminalSession?, () -> TerminalView?)] = []

    private init() {
        observers.append(
            Preferences.shared.objectWillChange
                .sink { [weak self] _ in
                    // objectWillChange fires before the update; re-apply on
                    // the next runloop tick once the @AppStorage value has
                    // actually settled.
                    DispatchQueue.main.async { self?.applyToAll() }
                }
        )
    }

    public func attach(toApp app: NSApplication) {
        currentApp = app
        appearanceObs = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyToAll() }
        }
    }

    public func register(sessionProvider: @escaping () -> TerminalSession?,
                         viewProvider:    @escaping () -> TerminalView?) {
        registrations.append((sessionProvider, viewProvider))
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

    private func applyToAll() {
        // Reap registrations whose window controller has been deallocated
        // (both providers return nil), then apply to the survivors. Without
        // the prune the array grows by one closure per opened-then-closed
        // window for the life of the process.
        registrations.removeAll { s, v in s() == nil && v() == nil }
        for (s, v) in registrations { apply(session: s(), view: v()) }
    }

    private func apply(session: TerminalSession?, view: TerminalView?) {
        let palette = resolvedPalette
        session?.applyPalette(palette)
        view?.applyTheme(palette)
    }
}
