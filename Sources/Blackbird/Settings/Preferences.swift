import SwiftUI
import Combine
import os

/// Single source of truth for user preferences, backed by `UserDefaults`
/// via `@AppStorage`. `ObservableObject` so SwiftUI views bind via
/// `@EnvironmentObject` / `@StateObject` and ThemeManager observes via
/// `objectWillChange`.
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    // MARK: - Schema version
    //
    // `prefsSchemaVersion` is the integer on-disk version of the Preferences
    // layout. Bump it whenever a pref key is renamed, a pref's type changes,
    // or an enum rawValue migrates (e.g. `BellStyle.visual` → `.audioVisual`).
    // `migrateIfNeeded()` walks the stored version forward to `currentSchemaVersion`,
    // one version at a time, then writes the new version back.
    //
    // v1 → v2: moved every key behind a `bb.` prefix so Blackbird's settings no
    // longer collide with `defaults write -g <key>` writes in NSGlobalDomain
    // (keys like "theme", "bell", "fontName", "fontSize" are plausibly used by
    // other apps/tools). The migration copies each legacy unprefixed key into
    // its prefixed counterpart and removes the original so `defaults read
    // dev.conjfrnk.blackbird` returns a dump that's self-identifying.
    // (settings F3)
    public static let currentSchemaVersion: Int = 2
    private static let schemaVersionKey = "prefsSchemaVersion"

    // MARK: - Key prefix (settings F3)
    //
    // Every pref key lands under `bb.` so our reads don't fall through to
    // NSGlobalDomain for a plain name like `fontSize` that another tool
    // might have set globally. The `k(_:)` helper is used both in the
    // `@AppStorage` declarations and in the migration/registration code so
    // the canonical on-disk form is authored in one place.
    @inline(__always)
    private static func k(_ name: String) -> String { "bb.\(name)" }

    /// The unprefixed names we used in schema v1, in the order they appear
    /// as `@AppStorage` declarations below. Walked by the v1 → v2 migrator
    /// to copy legacy values forward into `bb.`-prefixed keys. Kept as a
    /// private static so a future v2 → v3 migration can't accidentally
    /// reuse these names without reviewing the history.
    private static let legacyUnprefixedKeys: [String] = [
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

    @AppStorage("bb.theme")          public var themeRaw: String  = Theme.gruvbox.rawValue
    @AppStorage("bb.themeMode")      public var themeModeRaw: String = ThemeMode.dark.rawValue
    @AppStorage("bb.fontName")       public var fontName: String = "Hack Nerd Font Mono"
    @AppStorage("bb.fontSize")       public var fontSize: Double = 13 {
        didSet {
            // A tampered plist or a stale UserDefaults key can surface
            // NaN, ±Infinity, negative, or absurdly large sizes.
            // The Settings slider and ⌘+/⌘- bump actions both bound the
            // user-visible value to 9...32. Mirror that same envelope at
            // the model layer (audit M-13 / DI-6, 2026-04-29): the prior
            // ceiling of 64 let tampered or migrated values in (32, 64]
            // survive the clamp while the slider could only render up to
            // 32, so the user opened Settings and saw the thumb pinned to
            // its max while the actual font was e.g. 48. Aligning the
            // ceiling at 32 makes the model and the UI agree by
            // construction; no other code reads `fontSize` expecting a
            // value above 32.
            let normalised = fontSize.isFinite ? fontSize : 13
            let clamped = max(9, min(32, normalised))
            if clamped != fontSize { fontSize = clamped }
        }
    }
    @AppStorage("bb.cursorBlink")    public var cursorBlink: Bool = false
    @AppStorage("bb.bell")           public var bellRaw: String = BellStyle.visual.rawValue
    @AppStorage("bb.cursorShape")    public var cursorShapeRaw: String = CursorShape.followShell.rawValue
    @AppStorage("bb.optionKey")      public var optionKeyRaw: String = OptionKey.meta.rawValue
    @AppStorage("bb.confirmClose")   public var confirmClose: Bool = true
    @AppStorage("bb.autoUpdateChecks") public var autoUpdateChecks: Bool = false
    /// Default off (v0.1.10): arbitrary PTY output can overwrite the system
    /// clipboard up to 1 MiB without user consent when on. The scrub
    /// pipeline blocks raw C0/C1/bidi bytes, but cross-app paste into a
    /// password field or bank-transfer IBAN is still trivial once a
    /// hostile remote can emit OSC 52. Users who want auto-clipboard
    /// integration (helix, some nvim clipboard providers) can opt in
    /// explicitly via Settings. See `SEC-001` in the v0.1.9 sweep triage.
    @AppStorage("bb.osc52Enabled")   public var osc52Enabled: Bool = false
    /// Allow OSC 10 / 11 / 12 `?` queries to emit a reply. Off by default
    /// because the reply (`\e]10;rgb:…\e\\`) is routed back into the PTY
    /// where a misbehaving shell / zsh-vi-mode can interpret it as
    /// commands. Turn on if you want nvim / tmux auto-theming and you
    /// trust your shell's escape-handling. See `terminal_replies.rs`
    /// security test.
    @AppStorage("bb.colorQueryEnabled") public var colorQueryEnabled: Bool = false
    /// Combined transparency + blur intensity on a 1…10 scale. 1 = fully
    /// opaque, 10 = maximum transparency with heavy blur. 5 is the
    /// daily-driver default — the lift Connor ended up preferring after
    /// A/B'ing the curve. See `translucencyResolved` for the anchor points.
    @AppStorage("bb.translucency") public var translucency: Double = 5 {
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

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "preferences")

    /// Held weakly across `init` so the observer is torn down with the
    /// singleton. Tagged `nonisolated(unsafe)` only because `Preferences`
    /// is itself a process-wide singleton; the observer is created once,
    /// in `init`, and never reassigned.
    private var defaultsObserver: NSObjectProtocol?

    /// Re-entry guard for the `UserDefaults.didChangeNotification` handler.
    /// Without this, the same-value-guard pattern alone is enough to break
    /// the SwiftUI bridge re-fire loop, but a second-order hazard remains:
    /// our own clamp/repair writes fire `didChangeNotification` recursively
    /// from inside the observer callback. The recursion is bounded (each
    /// pass converges) but `true` here lets us short-circuit cheaply on
    /// the inner re-entry.
    private var isProcessingDefaultsChange = false

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
        // Register defaults in NSRegistrationDomain BEFORE the first
        // `@AppStorage` read so that `defaults read dev.conjfrnk.blackbird`
        // surfaces our full pref set even on a fresh install (where no
        // persistent-domain values exist yet), and so `@AppStorage`'s
        // default-on-missing-key path matches the registered defaults
        // exactly. Without this, a tool asking for `bb.fontSize` before
        // Blackbird has ever written one gets nil instead of `13`.
        // (settings F7)
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            // Audit EI-02: do NOT register `schemaVersionKey`. Earlier
            // builds did, on the theory that a fresh install would
            // read back as currentSchemaVersion and skip the
            // migration walk. That hides a legacy install whose
            // `prefsSchemaVersion` was never written to disk: with
            // registration the read-through returns currentSchemaVersion
            // and the seam early-returns, leaving legacy unprefixed
            // keys uncopied. Without registration, an absent key reads
            // 0, the seam treats 0 as "needs walk", `migrateV1toV2`
            // copies legacy keys (no-op when none exist), and the seam
            // stamps the current version on completion. This also makes
            // `migrateIfNeeded(in:)` testable: a fresh
            // `UserDefaults(suiteName:)` truly reads 0 and exercises
            // the v1→v2 path.
            Preferences.k("theme"):             Theme.gruvbox.rawValue,
            Preferences.k("themeMode"):         ThemeMode.dark.rawValue,
            Preferences.k("fontName"):          "Hack Nerd Font Mono",
            Preferences.k("fontSize"):          13.0,
            Preferences.k("cursorBlink"):       false,
            Preferences.k("bell"):              BellStyle.visual.rawValue,
            Preferences.k("cursorShape"):       CursorShape.followShell.rawValue,
            Preferences.k("optionKey"):         OptionKey.meta.rawValue,
            Preferences.k("confirmClose"):      true,
            Preferences.k("autoUpdateChecks"):  false,
            Preferences.k("osc52Enabled"):      false,
            Preferences.k("colorQueryEnabled"): false,
            Preferences.k("translucency"):      5.0,
        ])

        // Type-guard pass. `@AppStorage<Double>` trusts the KVC getter — a
        // CLI write like `defaults write dev.conjfrnk.blackbird bb.fontSize
        // -string "big"` stores a String under the key, and the next
        // `UserDefaults.standard.double(forKey:)` bridge returns 0 (or, in
        // some Swift versions, crashes on an Objective-C cast). Remove
        // wrong-type values for numeric keys so the registered default
        // below takes effect. Runs before the v1 → v2 migration so a
        // legacy unprefixed key with a wrong type is removed before the
        // migrator tries to carry it forward. (settings F7)
        Preferences.sanitizeStoredTypes(in: defaults)

        migrateIfNeeded()

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
        //
        // Audit H-8 / DI-1 (2026-04-29): SKIP this repair on a downgrade —
        // when stored schema version > currentSchemaVersion, an enum
        // rawValue we don't recognise is most likely a vN+1 case the
        // current binary lacks. Clobbering it to the vN default would
        // silently destroy the user's preference; on re-upgrade to vN+1
        // the value is gone. On a non-downgrade (stored <= current) the
        // repair runs as before — that's the original "garbage from a
        // typo / hand-edited plist" recovery path, which we still want.
        let storedSchemaVersion = defaults.integer(forKey: Preferences.schemaVersionKey)
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            Preferences.repairEnumRawValues(in: self)
        }

        // Force a through-didSet write on each numeric pref so values
        // already on disk get sanitised. `@AppStorage`'s `didSet` runs
        // only on in-session writes, not on first read from UserDefaults,
        // so a tampered plist with NaN / out-of-range values would
        // otherwise sneak past the clamp. Re-assigning the value triggers
        // the didSet chain and normalises once at launch.
        fontSize = fontSize
        translucency = translucency

        // Audit M-14 / DI-7, L-28 / MS-9 (2026-04-29): in-session
        // `didSet` clamps and the init-time enum repair both miss values
        // landed by an external `defaults write …` call mid-run. The
        // SwiftUI @AppStorage bridge bridges the change into the binding
        // (so the Picker / Slider re-evaluates) but `didSet` doesn't
        // fire — by design, since the new value came from the
        // userDefaults bridge, not from a Swift assignment. Subscribe
        // to `UserDefaults.didChangeNotification` and re-run the same
        // sanitisation passes the init does.
        //
        // CRITICAL HAZARD — `feedback_swiftui_userdefaults_feedback_loop.md`,
        // commit 982b719: any UserDefaults write from a sink that
        // observes `Preferences.objectWillChange` re-fires itself via
        // SwiftUI's global `UserDefaultObserver`. We're observing
        // `UserDefaults.didChangeNotification` directly here (one layer
        // closer to the source) but the same guarantee applies: a
        // re-write from inside the callback fires the notification
        // again, immediately, on the same queue. Two guards close it:
        //
        //   (a) `isProcessingDefaultsChange` re-entrancy flag — cheap
        //       short-circuit when our own clamp write is the trigger.
        //   (b) Same-value comparison inside each clamp/repair branch:
        //       a clamp that produces the same value as the current
        //       in-memory state is a no-op WRITE (we skip it), even if
        //       it's a logical repair.
        //
        // The downgrade gate from H-8 wires through here too, so
        // mid-session external writes of vN+1 values don't get clobbered.
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

    /// Re-runs the sanitisation passes on the in-memory `Preferences`
    /// state when an external `defaults write` lands a tampered numeric
    /// or unknown enum rawValue mid-session. The init-time repair only
    /// fires once; this hooks the same machinery to
    /// `UserDefaults.didChangeNotification` so the model recovers
    /// without a relaunch.
    private func handleDefaultsChange() {
        // Re-entry guard — our own clamp/repair writes below fire
        // `UserDefaults.didChangeNotification` synchronously on the same
        // queue. The same-value guards inside each branch are the
        // canonical defence (they'd terminate a runaway in one extra
        // pass) but this short-circuit makes it cheap and explicit.
        guard !isProcessingDefaultsChange else { return }
        isProcessingDefaultsChange = true
        defer { isProcessingDefaultsChange = false }

        let defaults = UserDefaults.standard

        // H-8 downgrade gate: skip the enum repair when the on-disk
        // schema version is ahead of the current binary. Same predicate
        // as init.
        let storedSchemaVersion = defaults.integer(forKey: Preferences.schemaVersionKey)
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            Preferences.repairEnumRawValues(in: self)
        }

        // Numeric clamps — same envelope as the `didSet` blocks. The
        // didSet fires on Swift-side assignment, which is exactly what
        // `self.fontSize = …` triggers; the same-value guard inside
        // didSet skips the write when the clamped value matches.
        let currentFontSize = self.fontSize
        let normalisedFont = currentFontSize.isFinite ? currentFontSize : 13
        let clampedFont = max(9, min(32, normalisedFont))
        if clampedFont != currentFontSize {
            Preferences.logger.log("re-clamping fontSize after external defaults write: \(currentFontSize) → \(clampedFont)")
            self.fontSize = clampedFont
        }

        let currentTrans = self.translucency
        let normalisedTrans = currentTrans.isFinite ? currentTrans : 1
        let clampedTrans = max(1, min(10, normalisedTrans))
        if clampedTrans != currentTrans {
            Preferences.logger.log("re-clamping translucency after external defaults write: \(currentTrans) → \(clampedTrans)")
            self.translucency = clampedTrans
        }
    }

    /// Repair every enum-backed @AppStorage string whose stored value
    /// doesn't match a known case. Reset to the documented default,
    /// matching the derived getter's `?? .default` fallback so the
    /// SwiftUI Picker can render the row and the model + UI agree.
    ///
    /// Same-value guards on every branch — required by
    /// `feedback_swiftui_userdefaults_feedback_loop.md` because both
    /// the init caller and the `UserDefaults.didChangeNotification`
    /// observer can fire this on a path that loops back through the
    /// SwiftUI bridge.
    private static func repairEnumRawValues(in prefs: Preferences) {
        if Theme(rawValue: prefs.themeRaw) == nil {
            let target = Theme.defaultTheme.rawValue
            if prefs.themeRaw != target { prefs.themeRaw = target }
        }
        if ThemeMode(rawValue: prefs.themeModeRaw) == nil {
            let target = ThemeMode.auto.rawValue
            if prefs.themeModeRaw != target { prefs.themeModeRaw = target }
        }
        if BellStyle(rawValue: prefs.bellRaw) == nil {
            let target = BellStyle.visual.rawValue
            if prefs.bellRaw != target { prefs.bellRaw = target }
        }
        if CursorShape(rawValue: prefs.cursorShapeRaw) == nil {
            let target = CursorShape.followShell.rawValue
            if prefs.cursorShapeRaw != target { prefs.cursorShapeRaw = target }
        }
        if OptionKey(rawValue: prefs.optionKeyRaw) == nil {
            let target = OptionKey.meta.rawValue
            if prefs.optionKeyRaw != target { prefs.optionKeyRaw = target }
        }
    }

    /// Remove wrong-type values from numeric pref keys. `@AppStorage<Double>`
    /// and `@AppStorage<Bool>` trust the key's KVC getter — if an external
    /// tool stashed a String under a numeric key, the read returns 0/false
    /// (or trips a Swift bridge assertion on some toolchain/OS combos).
    /// Removing the offending value lets the registered default take over.
    /// Covers both `bb.`-prefixed and legacy unprefixed names, so a user
    /// upgrading from v0.1.5 with a corrupted legacy key still gets cleaned
    /// up before the migration copies it forward. (settings F7)
    private static func sanitizeStoredTypes(in defaults: UserDefaults) {
        let numericDoubleKeys = ["fontSize", "translucency"]
        let boolKeys = [
            "cursorBlink", "confirmClose", "autoUpdateChecks",
            "osc52Enabled", "colorQueryEnabled",
        ]
        for name in numericDoubleKeys {
            for key in [k(name), name] {
                if let v = defaults.object(forKey: key), !(v is NSNumber) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for name in boolKeys {
            for key in [k(name), name] {
                if let v = defaults.object(forKey: key), !(v is NSNumber) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Walk the on-disk schema version forward to `currentSchemaVersion`,
    /// one step at a time. (settings F2)
    ///
    /// v1 → v2 (settings F3): move every pref key behind a `bb.` prefix so
    /// Blackbird's keys no longer collide with `defaults write -g` writes to
    /// generic names like `fontSize`/`theme`/`bell`. For each legacy key
    /// with a value on disk, copy it to the prefixed form and delete the
    /// original. Runs once per user — idempotent on any subsequent launch
    /// because the stored version is stamped at `currentSchemaVersion` on
    /// the way out, and the legacy key is gone.
    ///
    /// Pattern for future migrations:
    /// ```
    /// switch stored {
    /// case 2: /* migrate 2 → 3 … */
    ///         stored = 3
    ///         fallthrough
    /// default: break
    /// }
    /// UserDefaults.standard.set(stored, forKey: Preferences.schemaVersionKey)
    /// ```
    private func migrateIfNeeded() {
        Preferences.migrateIfNeeded(in: UserDefaults.standard)
    }

    /// Testable seam for `migrateIfNeeded()`. Drives the same migration
    /// machinery against any `UserDefaults` instance so we can exercise
    /// downgrade / upgrade pathways in isolated suites without touching
    /// `UserDefaults.standard`. Keep this `internal`, not `public` —
    /// production code should always go through the no-arg instance method.
    /// (F-S7-003 regression seam)
    ///
    /// F-S7-003 fix — DOWNGRADE-SAFETY INVARIANT
    /// =========================================
    /// Bug: previously, when a user ran a future schema (say v3) and
    /// downgraded to a build whose `currentSchemaVersion` is v2, the
    /// "already current or newer" branch unconditionally STAMPED the
    /// stored key down to v2. The on-disk record then said "this user
    /// is at v2" while the data on disk was actually v3-shaped. A
    /// subsequent upgrade back to v3 would observe `stored=2 < current=3`
    /// and re-run the v2→v3 migration against ALREADY v3-shaped data,
    /// corrupting it.
    ///
    /// Fix: on downgrade (`stored > currentSchemaVersion`), do NOT touch
    /// the stored version key. The disk keeps the high-water mark intact,
    /// so a future re-upgrade observes `stored == intended` and correctly
    /// skips the no-op migration. The older build's read paths already
    /// tolerate unknown keys via the registered-default + enum-fallback
    /// machinery (`Theme(rawValue:) ?? .defaultTheme`, etc.), so leaving
    /// a higher version number on disk is safe.
    internal static func migrateIfNeeded(in defaults: UserDefaults) {
        // `integer(forKey:)` returns 0 if the key is absent. Now that
        // we no longer register `schemaVersionKey` in NSRegistrationDomain
        // (audit EI-02), 0 unambiguously means "no schema version has
        // ever been stamped to this defaults instance" — treat as v0,
        // walk through every migration step, and stamp current at the
        // end. A non-zero `stored` is an actual persistent-domain value
        // we trust verbatim.
        let stored = defaults.integer(forKey: Preferences.schemaVersionKey)
        guard stored < Preferences.currentSchemaVersion else {
            // Already current (stored == current) or NEWER (downgrade).
            //
            // Downgrade case (stored > current): leave the key alone. See
            // the F-S7-003 invariant comment above — clobbering the high-
            // water mark would cause a future re-upgrade to re-run already-
            // applied migrations and corrupt v(N+1)-shaped data.
            //
            // Equal case (stored == current): nothing to do.
            return
        }
        var v = stored
        if v < 2 {
            migrateV1toV2(defaults: defaults)
            v = 2
        }
        // Future steps slot in here: `if v < 3 { migrateV2toV3(...); v = 3 }` etc.
        defaults.set(v, forKey: Preferences.schemaVersionKey)
    }

    /// Copy every legacy unprefixed key into its `bb.`-prefixed counterpart
    /// and remove the original. No-op for keys that are absent on disk —
    /// they'll fall through to the registered default transparently.
    ///
    /// EI-02: previously this conditioned the copy on `alreadyPrefixed
    /// == nil` (intent: in a mid-upgrade-crash where both keys were
    /// set, prefer the prefixed value). That check called
    /// `defaults.object(forKey: prefixed)`, which walks the search list
    /// and returns the registered default — `bb.theme` always reads
    /// non-nil because `Preferences.init` registers
    /// `Theme.gruvbox.rawValue`. So `alreadyPrefixed != nil` was
    /// effectively always true, and the copy never happened. Result:
    /// legacy v1 users had their unprefixed keys silently deleted on
    /// upgrade, and their settings reset to the registered defaults.
    /// We unconditionally copy now. The mid-crash case becomes "legacy
    /// wins"; an exotic edge case which is no worse than the previous
    /// "legacy is silently dropped." (settings F3)
    private static func migrateV1toV2(defaults: UserDefaults) {
        for name in Preferences.legacyUnprefixedKeys {
            let prefixed = Preferences.k(name)
            guard let legacy = defaults.object(forKey: name) else { continue }
            defaults.set(legacy, forKey: prefixed)
            defaults.removeObject(forKey: name)
        }
    }
}
