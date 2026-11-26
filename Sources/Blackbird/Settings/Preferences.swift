import SwiftUI
import AppKit
import Combine
import os

private extension ClosedRange where Bound == Double {
    func clamping(_ value: Bound, nonFiniteFallback: Bound) -> Bound {
        let normalised = value.isFinite ? value : nonFiniteFallback
        return Swift.max(lowerBound, Swift.min(upperBound, normalised))
    }
}

public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    // MARK: - Envelopes

    /// Shared by the model clamp and the Settings slider's `in:`, so the two cannot disagree.
    public static let fontSizeRange: ClosedRange<Double> = 9...32
    public static let translucencyRange: ClosedRange<Double> = 1...10

    public static let persistentDomainName = Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"

    // MARK: - Schema version
    // Bump whenever a pref key is renamed, a pref's type changes, or an enum rawValue migrates.
    public static let currentSchemaVersion: Int = 2
    static let schemaVersionKey = "bb.prefsSchemaVersion"
    static let legacySchemaVersionKey = "prefsSchemaVersion"

    // MARK: - Key prefix
    @inline(__always)
    static func k(_ name: String) -> String { "bb.\(name)" }

    /// The schema v1 unprefixed names, walked by the v1 → v2 migration. Review before reusing any of them.
    static let legacyUnprefixedKeys: [String] = [
        "theme", "themeMode", "fontName", "fontSize", "cursorBlink", "bell",
        "cursorShape", "optionKey", "confirmClose", "autoUpdateChecks",
        "osc52Enabled", "colorQueryEnabled", "translucency",
    ]

    public enum ThemeMode: String, CaseIterable, Identifiable {
        case auto, light, dark
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
    }

    public enum BellStyle: String, CaseIterable, Identifiable {
        case visual = "Visual", sound = "Sound", visualAndSound = "Visual and Sound", off = "Off"
        public var id: String { rawValue }
        public var flashes: Bool { self == .visual || self == .visualAndSound }
        public var sounds: Bool { self == .sound || self == .visualAndSound }
    }

    public enum OptionKey: String, CaseIterable, Identifiable {
        case meta = "Meta (ESC+)", native = "Native"
        public var id: String { rawValue }
    }

    /// Only ⌘ and ⌥⌘ are offered: plain ⌥ is rectangular selection and the TUI mouse-capture escape, and macOS
    /// routes ⌃+left-click to `rightMouseDown`, so a ⌃ left-drag never reaches the move path.
    public enum WindowGestureModifier: String, CaseIterable, Identifiable {
        case command = "Command", optionCommand = "Option-Command"
        public var id: String { rawValue }
        public var modifierMask: NSEvent.ModifierFlags {
            switch self {
            case .command:       return .command
            case .optionCommand: return [.option, .command]
            }
        }
    }

    public enum CursorShape: String, CaseIterable, Identifiable {
        case followShell = "Follow Shell"
        case block       = "Block"
        case underline   = "Underline"
        case bar         = "Bar"
        public var id: String { rawValue }
        /// nil follows the DECSCUSR shape in the snapshot. Snapshot encoding: 0 block, 1 bar, 2 underline.
        public var rendererOverride: UInt8? {
            switch self {
            case .followShell: return nil
            case .block:       return 0
            case .bar:         return 1
            case .underline:   return 2
            }
        }
    }

    public static let defaultThemeChoice: Theme = .gruvbox
    public static let fontSizeDefault: Double = 13
    public static let scrollbackLinesDefault: Double = 100_000
    @AppStorage("bb.theme")          public var themeRaw: String  = Preferences.defaultThemeChoice.rawValue
    @AppStorage("bb.themeMode")      public var themeModeRaw: String = ThemeMode.dark.rawValue
    @AppStorage("bb.fontName")       public var fontName: String = "Hack Nerd Font Mono"
    @AppStorage("bb.fontSize")       public var fontSize: Double = Preferences.fontSizeDefault {
        didSet {
            let clamped = Self.fontSizeRange.clamping(fontSize, nonFiniteFallback: Preferences.fontSizeDefault)
            guard clamped != fontSize else { return }
            withSelfWriteSuppressed { fontSize = clamped }
        }
    }
    @AppStorage("bb.cursorBlink")    public var cursorBlink: Bool = false
    @AppStorage("bb.bell")           public var bellRaw: String = BellStyle.visual.rawValue
    @AppStorage("bb.cursorShape")    public var cursorShapeRaw: String = CursorShape.followShell.rawValue
    @AppStorage("bb.optionKey")      public var optionKeyRaw: String = OptionKey.meta.rawValue
    @AppStorage("bb.windowDragModifier")   public var windowDragModifierRaw: String = WindowGestureModifier.command.rawValue
    @AppStorage("bb.windowResizeModifier") public var windowResizeModifierRaw: String = WindowGestureModifier.command.rawValue
    @AppStorage("bb.confirmClose")   public var confirmClose: Bool = true
    /// On by default: Info.plist's `SUEnableAutomaticChecks` suppresses Sparkle's permission prompt.
    @AppStorage("bb.autoUpdateChecks") public var autoUpdateChecks: Bool = true
    /// Dormant: the Rust core hardcodes `Osc52::Disabled`, so OSC 52 writes never reach the Swift handler.
    @AppStorage("bb.osc52Enabled")   public var osc52Enabled: Bool = false
    /// Confirms a paste containing LF when the foreground process has not requested bracketed paste.
    @AppStorage("bb.confirmMultiLinePaste") public var confirmMultiLinePaste: Bool = false
    @AppStorage("bb.setLocaleEnvironment") public var setLocaleEnvironment: Bool = true
    /// Empty means the account's login shell.
    @AppStorage("bb.shellPath") public var shellPath: String = ""
    /// Release builds only: Debug is always on, and `BB_HANG_WATCHDOG` overrides both.
    @AppStorage("bb.hangDetection") public var hangDetection: Bool = true
    @AppStorage("bb.programNotifications") public var programNotifications: Bool = true
    /// Applies to new sessions. The core caps at 200k.
    @AppStorage("bb.scrollbackLines") public var scrollbackLines: Double = Preferences.scrollbackLinesDefault
    public static let scrollbackLinesRange: ClosedRange<Double> = 1_000...200_000
    public var scrollbackLinesClamped: UInt32 {
        let v = scrollbackLines.isFinite ? scrollbackLines : Self.scrollbackLinesDefault
        return UInt32(min(Self.scrollbackLinesRange.upperBound, max(Self.scrollbackLinesRange.lowerBound, v)))
    }
    @AppStorage("bb.copyOnSelect") public var copyOnSelect: Bool = false
    /// OSC 10 / 11 / 12 `?` replies; TUIs probe them for light / dark detection. Replies travel back through the PTY.
    @AppStorage("bb.colorQueryEnabled") public var colorQueryEnabled: Bool = true
    /// Read at session start, so a toggle affects only the next spawned shell. Not `@AppStorage`: a same-value
    /// `@AppStorage` write still writes UserDefaults and re-enters `objectWillChange` through SwiftUI's global bridge.
    public var automaticShellIntegration: Bool {
        get {
            // Persistent domain only: a `defaults write -g` must not be able to flip injection.
            PersistentDomainReader.bool(
                forKey: Self.k("automaticShellIntegration"),
                in: UserDefaults.standard,
                domain: Self.persistentDomainName
            ) ?? true
        }
        set {
            guard newValue != automaticShellIntegration else { return }
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.k("automaticShellIntegration"))
        }
    }
    /// 1…10 scale: 1 = fully opaque, 10 = maximum transparency with heavy blur.
    @AppStorage("bb.translucency") public var translucency: Double = 5 {
        didSet {
            let clamped = Self.translucencyRange.clamping(translucency, nonFiniteFallback: Self.translucencyRange.lowerBound)
            guard clamped != translucency else { return }
            withSelfWriteSuppressed { translucency = clamped }
        }
    }

    public var theme: Theme         { Theme(rawValue: themeRaw) ?? Preferences.defaultThemeChoice }
    public var themeMode: ThemeMode { ThemeMode(rawValue: themeModeRaw) ?? .auto }
    public var bell: BellStyle      { BellStyle(rawValue: bellRaw) ?? .visual }
    public var cursorShape: CursorShape { CursorShape(rawValue: cursorShapeRaw) ?? .followShell }
    public var optionKey: OptionKey { OptionKey(rawValue: optionKeyRaw) ?? .meta }
    public var windowDragModifier: WindowGestureModifier {
        WindowGestureModifier(rawValue: windowDragModifierRaw) ?? .command
    }
    public var windowResizeModifier: WindowGestureModifier {
        WindowGestureModifier(rawValue: windowResizeModifierRaw) ?? .command
    }

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "preferences")

    private var defaultsObserver: NSObjectProtocol?

    private var isSuppressingSelfWrite = false

    /// Skips `body` when a self-write is already in flight. Every write inside `body` must already be clamped and
    /// finite: the corrective `didSet` clamp is exactly the write this suppresses. Main thread only.
    private func withSelfWriteSuppressed(_ body: () -> Void) {
        guard !isSuppressingSelfWrite else { return }
        isSuppressingSelfWrite = true
        defer { isSuppressingSelfWrite = false }
        body()
    }

    public var translucencyResolved: (opacity: Double, blurRadius: Int) {
        // min / max pass NaN through, and Int(round(NaN)) crashes.
        let raw = translucency.isFinite ? translucency : Self.translucencyRange.lowerBound
        let v = max(Self.translucencyRange.lowerBound, min(Self.translucencyRange.upperBound, raw))
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

    /// Source for `register(defaults:)` and for `PrefsSanitizer`, which derives its key lists from the value types.
    static var registeredDefaults: [String: Any] {
        [
            // `schemaVersionKey` is deliberately not registered: an absent key must read 0 so the migration walk runs.
            Preferences.k("theme"):             Preferences.defaultThemeChoice.rawValue,
            Preferences.k("themeMode"):         ThemeMode.dark.rawValue,
            Preferences.k("fontName"):          "Hack Nerd Font Mono",
            Preferences.k("fontSize"):          Preferences.fontSizeDefault,
            Preferences.k("cursorBlink"):       false,
            Preferences.k("bell"):              BellStyle.visual.rawValue,
            Preferences.k("cursorShape"):       CursorShape.followShell.rawValue,
            Preferences.k("optionKey"):         OptionKey.meta.rawValue,
            Preferences.k("windowDragModifier"):   WindowGestureModifier.command.rawValue,
            Preferences.k("windowResizeModifier"): WindowGestureModifier.command.rawValue,
            Preferences.k("confirmClose"):      true,
            Preferences.k("autoUpdateChecks"):  true,
            Preferences.k("osc52Enabled"):      false,
            Preferences.k("colorQueryEnabled"): true,
            Preferences.k("automaticShellIntegration"): true,
            Preferences.k("translucency"):      5.0,
            Preferences.k("confirmMultiLinePaste"): false,
            Preferences.k("setLocaleEnvironment"): true,
            Preferences.k("shellPath"):         "",
            Preferences.k("hangDetection"):     true,
            Preferences.k("programNotifications"): true,
            Preferences.k("scrollbackLines"):   Preferences.scrollbackLinesDefault,
            Preferences.k("copyOnSelect"):      false,
        ]
    }

    private init() {
        // Register before the first `@AppStorage` read.
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.registeredDefaults)

        // Before the migration, so a wrong-typed legacy key is removed rather than carried forward.
        Preferences.sanitizeStoredTypes(
            in: defaults,
            domain: Self.persistentDomainName
        )

        migrateIfNeeded()

        switch fontName {
        case "SFMono-Regular":          fontName = "SF Mono"
        case "HackNerdFontMono-Regular": fontName = "Hack Nerd Font Mono"
        default: break
        }

        // Skipped on downgrade: an unknown rawValue is most likely a newer build's case and must not be clobbered.
        let storedSchemaVersion = Preferences.storedSchemaVersion(
            in: defaults,
            domain: Self.persistentDomainName
        )
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            Preferences.repairEnumRawValues(
                in: self,
                defaults: defaults,
                domain: Self.persistentDomainName
            )
        }

        // `didSet` does not run on first read, so re-assign to clamp what is already on disk. Only when the key is in
        // the app's persistent domain: `fontSize = fontSize` would otherwise absorb an NSGlobalDomain value into it.
        if !isDowngrade {
            let domain = Self.persistentDomainName
            if Preferences.doubleInPersistentDomain(
                in: defaults, domain: domain, key: Preferences.k("fontSize")
            ) != nil {
                fontSize = fontSize
            }
            if Preferences.doubleInPersistentDomain(
                in: defaults, domain: domain, key: Preferences.k("translucency")
            ) != nil {
                translucency = translucency
            }
        }

        // An external `defaults write` mid-run updates the binding but never fires `didSet`; re-run the sanitisation.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.handleDefaultsChange()
        }
    }

    deinit {
        if let token = defaultsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Decisions are read from the persistent domain, not from the `@AppStorage` properties: on a non-`View` host
    /// the wrapper's cached value is stale right after an external write. Writes go through the `@AppStorage` setters.
    private func handleDefaultsChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        withSelfWriteSuppressed { applyExternalDefaultsChange() }
    }

    private func applyExternalDefaultsChange() {
        // One copy for the whole pass: `persistentDomain(forName:)` copies the entire dictionary and this runs on every
        // UserDefaults write. If a repair ever writes the keys read below, re-read the domain before them.
        let persistent = UserDefaults.standard.persistentDomain(forName: Self.persistentDomainName)

        let storedSchemaVersion = PersistentDomainReader.storedSchemaVersion(inSnapshot: persistent)
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            PrefsSanitizer.repairEnumRawValues(in: self, snapshot: persistent)
        }

        // Not gated on `isDowngrade`: numeric envelopes are stable across schema versions; out-of-range is tampering.
        if let diskFontSize = PersistentDomainReader.double(
            inSnapshot: persistent, key: Preferences.k("fontSize")
        ) {
            let clampedFont = Self.fontSizeRange.clamping(diskFontSize, nonFiniteFallback: Preferences.fontSizeDefault)
            if clampedFont != diskFontSize {
                Preferences.logger.log("re-clamping fontSize after external defaults write: \(diskFontSize, privacy: .public) → \(clampedFont, privacy: .public)")
                self.fontSize = clampedFont
            }
        }

        if let diskTrans = PersistentDomainReader.double(
            inSnapshot: persistent, key: Preferences.k("translucency")
        ) {
            let clampedTrans = Self.translucencyRange.clamping(diskTrans, nonFiniteFallback: Self.translucencyRange.lowerBound)
            if clampedTrans != diskTrans {
                Preferences.logger.log("re-clamping translucency after external defaults write: \(diskTrans, privacy: .public) → \(clampedTrans, privacy: .public)")
                self.translucency = clampedTrans
            }
        }
    }

    // MARK: - Maintenance forwarders

    static func repairEnumRawValues(in prefs: Preferences, defaults: UserDefaults, domain: String) {
        PrefsSanitizer.repairEnumRawValues(in: prefs, defaults: defaults, domain: domain)
    }

    private static func sanitizeStoredTypes(in defaults: UserDefaults, domain: String) {
        PrefsSanitizer.sanitizeStoredTypes(in: defaults, domain: domain)
    }

    private func migrateIfNeeded() {
        Preferences.migrateIfNeeded(
            in: UserDefaults.standard,
            domain: Self.persistentDomainName
        )
    }

    internal static func migrateIfNeeded(in defaults: UserDefaults, domain: String) {
        PrefsMigrator.migrateIfNeeded(in: defaults, domain: domain)
    }

    static func storedSchemaVersion(in defaults: UserDefaults, domain: String) -> Int {
        PersistentDomainReader.storedSchemaVersion(in: defaults, domain: domain)
    }

    static func doubleInPersistentDomain(
        in defaults: UserDefaults,
        domain: String,
        key: String
    ) -> Double? {
        PersistentDomainReader.double(in: defaults, domain: domain, key: key)
    }
}
