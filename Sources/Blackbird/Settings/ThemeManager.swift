import Combine
import AppKit

@MainActor
public final class ThemeManager {
    public static let shared = ThemeManager()

    private var observers = [AnyCancellable]()
    private var appearanceObs: NSKeyValueObservation?
    private weak var currentApp: NSApplication?

    private struct Registration {
        weak var owner: AnyObject?
        let sessionProvider: () -> TerminalSession?
        let viewProvider: () -> TerminalView?
        /// The session push overwrites palette slots 0-15 + fg/bg/cursor, wiping a program's OSC 4/10/11/12
        /// colours, so it is gated on this resolved palette, not on `PaletteInputs`.
        var lastSessionPalette: ThemePalette?
    }
    private var registrations: [ObjectIdentifier: Registration] = [:]

    /// The inputs `applyTheme(_:)` consumes. `objectWillChange` fires on every `@AppStorage` write, so an
    /// apply is skipped unless one of these changed.
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
        // Sinks on `Preferences.shared.objectWillChange` must not write UserDefaults, even transitively:
        // SwiftUI bridges every UserDefaults write back into `objectWillChange`, re-firing the sink without bound.
        observers.append(
            Preferences.shared.objectWillChange
                .sink { [weak self] _ in
                    // objectWillChange fires before the update; apply on the next runloop tick.
                    DispatchQueue.main.async { self?.applyToAllIfPaletteChanged() }
                }
        )
    }

    public func attach(toApp app: NSApplication) {
        currentApp = app
        appearanceObs = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.applyToAllIfPaletteChanged() }
        }
    }

    public func register(owner: AnyObject,
                         sessionProvider: @escaping () -> TerminalSession?,
                         viewProvider:    @escaping () -> TerminalView?) {
        let key = ObjectIdentifier(owner)
        let registration = Registration(
            owner: owner,
            sessionProvider: sessionProvider,
            viewProvider: viewProvider
        )
        registrations[key] = registration
        apply(key, registration, palette: resolvedPalette, pushSession: true)
    }

    private func systemIsDark() -> Bool {
        let app = currentApp ?? NSApp
        return app?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public var resolvedPalette: ThemePalette {
        let p = Preferences.shared
        let dark: Bool
        switch p.themeMode {
        case .auto:  dark = systemIsDark()
        case .light: dark = false
        case .dark:  dark = true
        }
        return p.theme.palette(dark: dark)
    }

    public func refresh() {
        // Unconditional: first-show blur wiring needs a live windowNumber even when the palette is unchanged.
        applyToAll(inputs: currentPaletteInputs(), forceSession: true)
    }

    /// View only: `register()` already pushed the session palette, and re-pushing it wipes any OSC
    /// 4/10/11 palette a program set.
    public func refresh(owner: AnyObject) {
        guard let reg = registrations[ObjectIdentifier(owner)], reg.owner === owner else { return }
        reg.viewProvider()?.applyTheme(resolvedPalette)
    }

    private func applyToAllIfPaletteChanged() {
        let inputs = currentPaletteInputs()
        if let last = lastPaletteInputs, last == inputs {
            reapDeadRegistrations()
            return
        }
        applyToAll(inputs: inputs)
    }

    private func currentPaletteInputs() -> PaletteInputs {
        let p = Preferences.shared
        let isDark = systemIsDark()
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

    private func applyToAll(inputs: PaletteInputs, forceSession: Bool = false) {
        reapDeadRegistrations()
        lastPaletteInputs = inputs
        let palette = resolvedPalette
        for (key, reg) in registrations {
            apply(key, reg, palette: palette,
                  pushSession: forceSession || reg.lastSessionPalette != palette)
        }
    }

    private func apply(_ key: ObjectIdentifier, _ reg: Registration,
                       palette: ThemePalette, pushSession: Bool) {
        // Stamp only when a session actually received the palette, so a registration whose session isn't
        // up yet is still pushed later.
        if pushSession, let session = reg.sessionProvider() {
            session.applyPalette(palette)
            registrations[key]?.lastSessionPalette = palette
        }
        reg.viewProvider()?.applyTheme(palette)
    }
}
