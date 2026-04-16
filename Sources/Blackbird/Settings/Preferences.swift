import SwiftUI
import Combine

/// Single source of truth for user preferences, backed by `UserDefaults`
/// via `@AppStorage`. `ObservableObject` so SwiftUI views bind via
/// `@EnvironmentObject` / `@StateObject` and ThemeManager observes via
/// `objectWillChange`.
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    public enum ThemeMode: String, CaseIterable, Identifiable {
        case auto, light, dark
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
    }

    public enum BellStyle: String, CaseIterable, Identifiable {
        case visual = "Visual", off = "Off"
        public var id: String { rawValue }
    }

    public enum OptionKey: String, CaseIterable, Identifiable {
        case meta = "Meta (ESC+)", native = "Native"
        public var id: String { rawValue }
    }

    @AppStorage("theme")          public var themeRaw: String  = Theme.gruvbox.rawValue
    @AppStorage("themeMode")      public var themeModeRaw: String = ThemeMode.dark.rawValue
    @AppStorage("fontName")       public var fontName: String = "Hack Nerd Font Mono"
    @AppStorage("fontSize")       public var fontSize: Double = 13
    @AppStorage("cursorBlink")    public var cursorBlink: Bool = false
    @AppStorage("bell")           public var bellRaw: String = BellStyle.visual.rawValue
    @AppStorage("optionKey")      public var optionKeyRaw: String = OptionKey.meta.rawValue
    @AppStorage("confirmClose")   public var confirmClose: Bool = true
    @AppStorage("autoUpdateChecks") public var autoUpdateChecks: Bool = false
    @AppStorage("osc52Enabled")   public var osc52Enabled: Bool = true
    /// Combined transparency + blur intensity on a 1…10 scale. 1 = fully
    /// opaque, 10 = maximum transparency with heavy blur. 3 is a mild
    /// default: a little see-through, a subtle blur that keeps content
    /// behind the window legible without it competing for attention.
    @AppStorage("translucency") public var translucency: Double = 3

    public var theme: Theme         { Theme(rawValue: themeRaw) ?? .defaultTheme }
    public var themeMode: ThemeMode { ThemeMode(rawValue: themeModeRaw) ?? .auto }
    public var bell: BellStyle      { BellStyle(rawValue: bellRaw) ?? .visual }
    public var optionKey: OptionKey { OptionKey(rawValue: optionKeyRaw) ?? .meta }

    /// Resolved `(opacity, blurRadius)` from the single translucency slider.
    /// - value 1 → opaque, no blur
    /// - value 3 (default) → ~0.9 opacity, blur 6
    /// - value 10 → 0.55 opacity, blur 27
    public var translucencyResolved: (opacity: Double, blurRadius: Int) {
        let v = max(1.0, min(10.0, translucency))
        let opacity = max(0.4, 1.0 - (v - 1) * 0.05)
        let blur = Int(max(0, (v - 1) * 3))
        return (opacity, blur)
    }

    private init() {
        // Migrate legacy PostScript names written by earlier builds
        // ("SFMono-Regular", "HackNerdFontMono-Regular") to the family name
        // the Settings picker uses. Without this, the picker shows nothing
        // selected because its rows are family names and the stored value
        // isn't one of them. Idempotent — runs once per launch but only
        // writes when a rewrite is needed.
        switch fontName {
        case "SFMono-Regular":          fontName = "SF Mono"
        case "HackNerdFontMono-Regular": fontName = "Hack Nerd Font Mono"
        default: break
        }
    }
}
