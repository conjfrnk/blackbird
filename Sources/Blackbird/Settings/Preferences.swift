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

    public enum CursorShape: String, CaseIterable, Identifiable {
        case followShell = "Follow Shell"
        case block       = "Block"
        case underline   = "Underline"
        case bar         = "Bar"
        public var id: String { rawValue }
        /// `nil` → renderer uses the DECSCUSR shape from the current snapshot
        /// (today's behaviour). A non-nil value pins the cursor regardless of
        /// what the shell sends. Numeric codes match the snapshot encoding:
        /// 0 block, 1 bar/beam, 2 underline.
        public var rendererOverride: UInt8? {
            switch self {
            case .followShell: return nil
            case .block:       return 0
            case .bar:         return 1
            case .underline:   return 2
            }
        }
    }

    @AppStorage("theme")          public var themeRaw: String  = Theme.gruvbox.rawValue
    @AppStorage("themeMode")      public var themeModeRaw: String = ThemeMode.dark.rawValue
    @AppStorage("fontName")       public var fontName: String = "Hack Nerd Font Mono"
    @AppStorage("fontSize")       public var fontSize: Double = 13 {
        didSet {
            // A tampered plist or a stale UserDefaults key can surface
            // NaN, ±Infinity, negative, or absurdly large sizes.
            // Settings UI clamps to 9…32 at the bump actions; mirror the
            // same bound on every set so direct writes (migrations,
            // scripting, tests) can't poison readers downstream.
            let normalised = fontSize.isFinite ? fontSize : 13
            let clamped = max(9, min(64, normalised))
            if clamped != fontSize { fontSize = clamped }
        }
    }
    @AppStorage("cursorBlink")    public var cursorBlink: Bool = false
    @AppStorage("bell")           public var bellRaw: String = BellStyle.visual.rawValue
    @AppStorage("cursorShape")    public var cursorShapeRaw: String = CursorShape.followShell.rawValue
    @AppStorage("optionKey")      public var optionKeyRaw: String = OptionKey.meta.rawValue
    @AppStorage("confirmClose")   public var confirmClose: Bool = true
    @AppStorage("autoUpdateChecks") public var autoUpdateChecks: Bool = false
    @AppStorage("osc52Enabled")   public var osc52Enabled: Bool = true
    /// Allow OSC 10 / 11 / 12 `?` queries to emit a reply. Off by default
    /// because the reply (`\e]10;rgb:…\e\\`) is routed back into the PTY
    /// where a misbehaving shell / zsh-vi-mode can interpret it as
    /// commands. Turn on if you want nvim / tmux auto-theming and you
    /// trust your shell's escape-handling. See `terminal_replies.rs`
    /// security test.
    @AppStorage("colorQueryEnabled") public var colorQueryEnabled: Bool = false
    /// Combined transparency + blur intensity on a 1…10 scale. 1 = fully
    /// opaque, 10 = maximum transparency with heavy blur. 5 is the
    /// daily-driver default — the lift Connor ended up preferring after
    /// A/B'ing the curve. See `translucencyResolved` for the anchor points.
    @AppStorage("translucency") public var translucency: Double = 5 {
        didSet {
            // Same NaN / range hygiene as fontSize. `translucencyResolved`
            // below already normalises at read time, but any other caller
            // that inspects `translucency` directly (e.g. SettingsView
            // binding readout) would see the raw value. Clamp on set.
            //
            // NaN / ±Infinity fall to the opaque end (1) rather than the
            // middle — a tampered plist shouldn't surprise the user with
            // see-through windows out of nowhere.
            let normalised = translucency.isFinite ? translucency : 1
            let clamped = max(1, min(10, normalised))
            if clamped != translucency { translucency = clamped }
        }
    }

    public var theme: Theme         { Theme(rawValue: themeRaw) ?? .defaultTheme }
    public var themeMode: ThemeMode { ThemeMode(rawValue: themeModeRaw) ?? .auto }
    public var bell: BellStyle      { BellStyle(rawValue: bellRaw) ?? .visual }
    public var cursorShape: CursorShape { CursorShape(rawValue: cursorShapeRaw) ?? .followShell }
    public var optionKey: OptionKey { OptionKey(rawValue: optionKeyRaw) ?? .meta }

    /// Resolved `(opacity, blurRadius)` from the single translucency slider.
    /// Piecewise-linear with three anchors:
    ///   v=1  (Solid)   → opacity 1.000, blur 0
    ///   v=5  (default) → opacity 0.595, blur 18  ← daily-driver lift
    ///   v=10 (Ghost)   → opacity 0.400, blur 30  ← max readability-preserving
    /// The bottom half (1..5) ramps quickly into the useful range; the top
    /// half (5..10) tapers out to the Ghost extreme so users who want it
    /// can still reach it without the default sitting too close to the wall.
    public var translucencyResolved: (opacity: Double, blurRadius: Int) {
        // A hand-edited UserDefaults (or a bridging conversion) could leave
        // translucency as NaN / ±Infinity. min/max pass NaN through, which
        // would propagate into Int(round(...)) and crash. Normalise to the
        // opaque end first.
        let raw = translucency.isFinite ? translucency : 1.0
        let v = max(1.0, min(10.0, raw))
        let opacity: Double
        let blurFloat: Double
        if v <= 5 {
            let t = (v - 1.0) / 4.0
            opacity = 1.0 - t * (1.0 - 0.595)
            blurFloat = t * 18.0
        } else {
            let t = (v - 5.0) / 5.0
            opacity = 0.595 - t * (0.595 - 0.4)
            blurFloat = 18.0 + t * (30.0 - 18.0)
        }
        return (opacity, Int(round(max(0, blurFloat))))
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

        // Repair the enum-backed @AppStorage strings when we find a value
        // that doesn't match any case. Otherwise the Settings Picker shows
        // an empty row (no tag matches) while the app silently falls back
        // to the default via Theme(rawValue:) ?? .defaultTheme, so the
        // user can't pick from the list without first choosing something
        // valid. Repair at init so the picker and the running palette
        // agree on first render.
        if Theme(rawValue: themeRaw) == nil { themeRaw = Theme.defaultTheme.rawValue }
        if ThemeMode(rawValue: themeModeRaw) == nil { themeModeRaw = ThemeMode.auto.rawValue }
        if BellStyle(rawValue: bellRaw) == nil { bellRaw = BellStyle.visual.rawValue }
        if CursorShape(rawValue: cursorShapeRaw) == nil { cursorShapeRaw = CursorShape.followShell.rawValue }
        if OptionKey(rawValue: optionKeyRaw) == nil { optionKeyRaw = OptionKey.meta.rawValue }

        // Force a through-didSet write on each numeric pref so values
        // already on disk get sanitised. `@AppStorage`'s `didSet` runs
        // only on in-session writes, not on first read from UserDefaults,
        // so a tampered plist with NaN / out-of-range values would
        // otherwise sneak past the clamp. Re-assigning the value triggers
        // the didSet chain and normalises once at launch.
        fontSize = fontSize
        translucency = translucency
    }
}
