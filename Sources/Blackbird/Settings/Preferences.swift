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
    // `bb.prefsSchemaVersion` is the integer on-disk version of the
    // Preferences layout. Bump it whenever a pref key is renamed, a pref's
    // type changes, or an enum rawValue migrates (e.g. `BellStyle.visual`
    // → `.audioVisual`). `migrateIfNeeded()` walks the stored version
    // forward to `currentSchemaVersion`, one version at a time, then
    // writes the new version back.
    //
    // v1 → v2: moved every key behind a `bb.` prefix so Blackbird's settings no
    // longer collide with `defaults write -g <key>` writes in NSGlobalDomain
    // (keys like "theme", "bell", "fontName", "fontSize" are plausibly used by
    // other apps/tools). The migration copies each legacy unprefixed key into
    // its prefixed counterpart and removes the original so `defaults read
    // dev.conjfrnk.blackbird` returns a dump that's self-identifying.
    // (settings F3)
    public static let currentSchemaVersion: Int = 2
    // Audit H-8: the schema-version key sits under the `bb.` namespace so
    // a `defaults write -g prefsSchemaVersion 99` can't reach into our
    // search list and force the migration seam to think we're already
    // current. The legacy unprefixed name is bootstrapped forward (and
    // then removed from the persistent domain) on first launch with the
    // fix — see `migrateIfNeeded(in:domain:)`.
    private static let schemaVersionKey = "bb.prefsSchemaVersion"
    private static let legacySchemaVersionKey = "prefsSchemaVersion"

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
            //
            // Re-entry guard: writing to `fontSize` from inside its own
            // `didSet` re-fires the observer (and double-fires the
            // SwiftUI @AppStorage objectWillChange / UserDefaults write),
            // which is the 982b719 feedback-loop pattern. Skip the
            // recursive write entirely when we're already inside a
            // clamping pass — the outer `didSet` already produced the
            // user-visible objectWillChange.
            guard !clampingFontSize else { return }
            let normalised = fontSize.isFinite ? fontSize : 13
            let clamped = max(9, min(32, normalised))
            guard clamped != fontSize else { return }
            clampingFontSize = true
            defer { clampingFontSize = false }
            fontSize = clamped
        }
    }
    private var clampingFontSize = false
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
    /// Audit L19. When true, pasting text containing a newline (LF)
    /// while the foreground process has NOT requested bracketed paste
    /// pops a confirmation alert. Default off so the long-standing
    /// "paste runs" behaviour is preserved unless the user opts in.
    /// Modern TUIs (vim, nvim, less, fzf, ssh wrappers, claude) all
    /// enable bracketed paste, so the warning only fires at a bare
    /// shell prompt — the exact scenario where a hostile clipboard's
    /// embedded newline would execute the next "line" as a separate
    /// command. iTerm2's "Confirm when pasting more than N lines"
    /// has the same shape; we keep it simple at one-line-or-more.
    @AppStorage("bb.confirmMultiLinePaste") public var confirmMultiLinePaste: Bool = false
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
            //
            // Re-entry guard: same shape as fontSize — see comment there.
            guard !clampingTranslucency else { return }
            let normalised = translucency.isFinite ? translucency : 1
            let clamped = max(1, min(10, normalised))
            guard clamped != translucency else { return }
            clampingTranslucency = true
            defer { clampingTranslucency = false }
            translucency = clamped
        }
    }
    private var clampingTranslucency = false

    public var theme: Theme         { Theme(rawValue: themeRaw) ?? .defaultTheme }
    public var themeMode: ThemeMode { ThemeMode(rawValue: themeModeRaw) ?? .auto }
    public var bell: BellStyle      { BellStyle(rawValue: bellRaw) ?? .visual }
    public var cursorShape: CursorShape { CursorShape(rawValue: cursorShapeRaw) ?? .followShell }
    public var optionKey: OptionKey { OptionKey(rawValue: optionKeyRaw) ?? .meta }

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "preferences")

    /// Held weakly across `init` so the observer is torn down with the
    /// singleton. The observer is created once, in `init`, and never
    /// reassigned; mutation of this field is bounded by `init` and
    /// `deinit`, both of which run with exclusive access to the singleton.
    private var defaultsObserver: NSObjectProtocol?

    /// Re-entry guard for the `UserDefaults.didChangeNotification` handler.
    /// Our clamp/repair writes fire `didChangeNotification`, which is
    /// re-delivered on a later main-queue tick (the observer is
    /// registered with `queue: .main`, which always wraps delivery in an
    /// OperationQueue task). The same-value guards inside each branch
    /// are the canonical defence; this short-circuit is belt-and-braces
    /// in case Apple ever changes the delivery model. Main-queue-only
    /// access enforced by `dispatchPrecondition` at the top of
    /// `handleDefaultsChange`.
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
            // `migrateIfNeeded(in:domain:)` testable: a fresh
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
            // Audit fix-#15: this default was declared above as
            // @AppStorage("bb.confirmMultiLinePaste") but never registered.
            // Without registration the default isn't visible to sibling
            // tooling (defaults read shows the key as absent until first
            // write) and is also absent from sanitizeStoredTypes' boolKeys
            // sweep — a `defaults write … -string "foo"` would persist
            // unsanitized while every other bool pref gets cleaned up.
            Preferences.k("confirmMultiLinePaste"): false,
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
        Preferences.sanitizeStoredTypes(
            in: defaults,
            domain: Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"
        )

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
        let storedSchemaVersion = Preferences.storedSchemaVersion(
            in: defaults,
            domain: Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"
        )
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            Preferences.repairEnumRawValues(in: self, defaults: defaults)
        }

        // Force a through-didSet write on each numeric pref so values
        // already on disk get sanitised. `@AppStorage`'s `didSet` runs
        // only on in-session writes, not on first read from UserDefaults,
        // so a tampered plist with NaN / out-of-range values would
        // otherwise sneak past the clamp. Re-assigning the value triggers
        // the didSet chain and normalises once at launch.
        //
        // S6-010: also skip on downgrade. The same H-8 reasoning applies
        // to numeric envelopes — if a future v(N+1) widens fontSize to
        // 9...64 and the user picked 48, a vN binary would clamp that
        // back to 32, and on re-upgrade the user's preference is gone.
        // The "tampered plist" recovery only matters on the upgrade /
        // same-version path; on downgrade, defer normalisation to the
        // first in-session edit (which fires didSet via the normal
        // Swift-assignment path).
        //
        // Audit fix-#04 (2026-05-21): only invoke the through-didSet
        // write when the value actually lives in the APP's persistent
        // domain. If the app domain is unset (first launch, or after
        // `defaults delete <bundle> bb.fontSize`), `fontSize = fontSize`
        // reads via @AppStorage which walks the search list (app →
        // NSGlobalDomain → registration) and could absorb a hostile
        // `defaults write -g bb.fontSize 999` into the app domain
        // before the runtime observer is wired below. Checking the
        // persistent-domain presence first means a missing app value
        // falls through to the registered default cleanly, and only
        // an actual tampered app-domain value triggers the clamp.
        if !isDowngrade {
            let domain = Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"
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
    ///
    /// CRITICAL — read decisions from `defaults.*(forKey:)`, NOT from
    /// the `@AppStorage` properties on `self`. SwiftUI's `@AppStorage`
    /// caches the wrappedValue inside its `Location` object, and on a
    /// non-`View` host (this class is a singleton, not a `View`) the
    /// cache only refreshes when the SwiftUI bridge re-publishes —
    /// which doesn't happen synchronously with an external
    /// `UserDefaults.standard.set(…)`. Reading `self.fontSize` here
    /// returns the STALE Swift-side cached value (the value before the
    /// external write), so the clamp comparison sees `13 → 13` (no
    /// rewrite) when disk actually holds `999`. Read disk directly for
    /// the comparison; write through the `@AppStorage` setter (which
    /// IS synchronous on UserDefaults + refreshes the cache + fires
    /// didSet for the same-value guard).
    private func handleDefaultsChange() {
        // Locks the contract the `isProcessingDefaultsChange` flag relies
        // on: the observer is registered with `queue: .main`, so this
        // handler must execute on the main queue. If a future change
        // moves the queue without revisiting the flag, the precondition
        // catches it before the data race ships.
        dispatchPrecondition(condition: .onQueue(.main))
        // Re-entry guard — our clamp/repair writes fire
        // `UserDefaults.didChangeNotification`, which is re-delivered on
        // a later main-queue tick. The same-value guards inside each
        // branch are the canonical defence; this re-entrancy short-
        // circuit is belt-and-braces in case Apple ever changes the
        // delivery model.
        guard !isProcessingDefaultsChange else { return }
        isProcessingDefaultsChange = true
        defer { isProcessingDefaultsChange = false }

        let defaults = UserDefaults.standard

        // H-8 downgrade gate: skip the enum repair when the on-disk
        // schema version is ahead of the current binary. Same predicate
        // as init. Reads via persistent-domain helper (audit S5-R-001)
        // so a hostile `defaults write -g bb.prefsSchemaVersion 99` can't
        // poison the gate.
        let storedSchemaVersion = Preferences.storedSchemaVersion(
            in: defaults,
            domain: Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"
        )
        let isDowngrade = storedSchemaVersion > Preferences.currentSchemaVersion
        if !isDowngrade {
            Preferences.repairEnumRawValues(in: self, defaults: defaults)
        }

        // Numeric clamps — same envelope as the `didSet` blocks. The
        // didSet fires on Swift-side assignment, which is exactly what
        // `self.fontSize = …` triggers; the same-value guard inside
        // didSet skips the write when the clamped value matches.
        //
        // NOTE — intentionally NOT gated behind `isDowngrade` (sibling
        // of H-8): the H-8 gate exists because enum rawValues legitimately
        // gain new cases across schema versions, so an unknown rawValue
        // on a downgrade is most plausibly a vN+1 case we shouldn't
        // clobber. Numeric envelopes (fontSize 9...32, translucency
        // 1...10) are presumed STABLE across versions — they're product
        // decisions tied to UI layout, not schema. A NaN / out-of-range
        // value on disk is a tampered-plist case in any version, and
        // clamping it is the correct recovery on every binary that sees
        // it. If a future version widens the envelope, that change
        // SHOULD bump the schema and add an explicit migration; the H-8
        // gate isn't the right place to express it.
        //
        // Audit fix-#04 (2026-05-21): read via persistentDomain so a
        // hostile `defaults write -g bb.fontSize 999` on NSGlobalDomain
        // can't surface here when the app domain is unset. The H-8 /
        // S5-R-001 hardening for the schema-version key already uses
        // this pattern; extending the same scope to the numeric
        // envelope keys closes the symmetric gap. When the key is
        // absent from the persistent domain, the registered default
        // (13 / 1) applies — no re-clamp needed, so we skip the
        // through-didSet write entirely. `defaults.double(forKey:)`
        // would have walked NSGlobalDomain → registration → 13 in that
        // case, then either matched (no write) or re-clamped to a
        // global-poisoned value.
        let domain = Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"

        if let diskFontSize = Preferences.doubleInPersistentDomain(
            in: defaults, domain: domain, key: Preferences.k("fontSize")
        ) {
            let normalisedFont = diskFontSize.isFinite ? diskFontSize : 13
            let clampedFont = max(9, min(32, normalisedFont))
            if clampedFont != diskFontSize {
                Preferences.logger.log("re-clamping fontSize after external defaults write: \(diskFontSize, privacy: .public) → \(clampedFont, privacy: .public)")
                self.fontSize = clampedFont
            }
        }

        if let diskTrans = Preferences.doubleInPersistentDomain(
            in: defaults, domain: domain, key: Preferences.k("translucency")
        ) {
            let normalisedTrans = diskTrans.isFinite ? diskTrans : 1
            let clampedTrans = max(1, min(10, normalisedTrans))
            if clampedTrans != diskTrans {
                Preferences.logger.log("re-clamping translucency after external defaults write: \(diskTrans, privacy: .public) → \(clampedTrans, privacy: .public)")
                self.translucency = clampedTrans
            }
        }
    }

    /// Repair every enum-backed @AppStorage string whose stored value
    /// doesn't match a known case. Reset to the value the
    /// `register(defaults:)` table seeds — `Theme.gruvbox`, `ThemeMode.dark`,
    /// etc. — so the repaired raw matches what a fresh-install user
    /// would see and the SwiftUI Picker can render the row.
    ///
    /// M4 (2026-05-03) realigned the theme + themeMode fallbacks here
    /// from `Theme.defaultTheme` / `ThemeMode.auto` (the derived getter's
    /// `?? .` fallback) to the registered defaults. The mismatch only
    /// surfaces on a corrupted-rawValue path, but when it did the user's
    /// theme silently flipped to a different value than the one shown on
    /// first launch.
    ///
    /// Same-value guards on every branch — required by
    /// `feedback_swiftui_userdefaults_feedback_loop.md` because both
    /// the init caller and the `UserDefaults.didChangeNotification`
    /// observer can fire this on a path that loops back through the
    /// SwiftUI bridge.
    ///
    /// Reads each rawValue from `defaults` directly rather than via the
    /// `@AppStorage` property. The init caller passes the same
    /// `UserDefaults.standard` instance the wrapper writes against; the
    /// observer caller MUST read disk because @AppStorage's
    /// non-`View`-host cache lags behind external `defaults.set(…)`
    /// writes (see `handleDefaultsChange` header). Reading from
    /// `defaults` is correct on both paths.
    private static func repairEnumRawValues(in prefs: Preferences, defaults: UserDefaults) {
        let themeRaw = defaults.string(forKey: k("theme")) ?? Theme.gruvbox.rawValue
        if Theme(rawValue: themeRaw) == nil {
            let target = Theme.gruvbox.rawValue
            if themeRaw != target { prefs.themeRaw = target }
        }
        let themeModeRaw = defaults.string(forKey: k("themeMode")) ?? ThemeMode.dark.rawValue
        if ThemeMode(rawValue: themeModeRaw) == nil {
            let target = ThemeMode.dark.rawValue
            if themeModeRaw != target { prefs.themeModeRaw = target }
        }
        let bellRaw = defaults.string(forKey: k("bell")) ?? BellStyle.visual.rawValue
        if BellStyle(rawValue: bellRaw) == nil {
            let target = BellStyle.visual.rawValue
            if bellRaw != target { prefs.bellRaw = target }
        }
        let cursorShapeRaw = defaults.string(forKey: k("cursorShape")) ?? CursorShape.followShell.rawValue
        if CursorShape(rawValue: cursorShapeRaw) == nil {
            let target = CursorShape.followShell.rawValue
            if cursorShapeRaw != target { prefs.cursorShapeRaw = target }
        }
        let optionKeyRaw = defaults.string(forKey: k("optionKey")) ?? OptionKey.meta.rawValue
        if OptionKey(rawValue: optionKeyRaw) == nil {
            let target = OptionKey.meta.rawValue
            if optionKeyRaw != target { prefs.optionKeyRaw = target }
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
    private static func sanitizeStoredTypes(in defaults: UserDefaults, domain: String) {
        let numericDoubleKeys = ["fontSize", "translucency"]
        let boolKeys = [
            "cursorBlink", "confirmClose", "autoUpdateChecks",
            "osc52Enabled", "colorQueryEnabled",
            // Audit fix-#15: include confirmMultiLinePaste in the
            // sanitize sweep so a wrong-typed CLI write (e.g. defaults
            // write … -string yes) is stripped before the registered
            // default is applied, matching sibling bool prefs.
            "confirmMultiLinePaste",
        ]
        // S5-009: read from the persistent domain only, mirroring the
        // S5-001 migration fix. `defaults.object(forKey:)` walks the
        // full search list (app persistent → NSGlobalDomain →
        // registration); a `defaults write -g fontSize -string foo`
        // would otherwise trip the sanitize for an unprefixed key, but
        // `removeObject(forKey:)` only writes to the app's persistent
        // domain — so the global value persists, no work was done, and
        // the user-visible behaviour was a misleading no-op.
        // persistentDomain reads ONLY the app's domain, so we sanitize
        // what we can actually mutate.
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        let isNumericLike: (Any) -> Bool = { $0 is NSNumber }
        for name in numericDoubleKeys {
            for key in [k(name), name] {
                if let v = persistent[key], !isNumericLike(v) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for name in boolKeys {
            for key in [k(name), name] {
                if let v = persistent[key], !isNumericLike(v) {
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
    /// defaults.set(stored, forKey: Preferences.schemaVersionKey)
    /// ```
    private func migrateIfNeeded() {
        // The persistent-domain name is the app's bundle identifier; that's
        // where `UserDefaults.standard` reads/writes its on-disk values
        // when the search list isn't shadowed. Tests use the seam directly
        // with their own suite name. (H-8 bootstrap path)
        Preferences.migrateIfNeeded(
            in: UserDefaults.standard,
            domain: Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"
        )
    }

    /// Testable seam for `migrateIfNeeded()`. Drives the same migration
    /// machinery against any `UserDefaults` instance so we can exercise
    /// downgrade / upgrade pathways in isolated suites without touching
    /// `UserDefaults.standard`. Keep this `internal`, not `public` —
    /// production code should always go through the no-arg instance method.
    /// `domain` is the persistent-domain name the H-8 bootstrap reads via
    /// `defaults.persistentDomain(forName:)`; pass the bundle identifier
    /// for `UserDefaults.standard`, the suite name for tests.
    /// (F-S7-003 regression seam, H-8 bootstrap path)
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
    internal static func migrateIfNeeded(in defaults: UserDefaults, domain: String) {
        // H-8 bootstrap: the schema-version key was renamed from
        // `prefsSchemaVersion` to `bb.prefsSchemaVersion` to keep it out
        // of the global-domain search path. On first launch with the
        // fix, look up the OLD key in the app's PERSISTENT DOMAIN — not
        // via `defaults.integer(forKey:)`, which walks NSGlobalDomain
        // and would let `defaults write -g prefsSchemaVersion 99` poison
        // the migration seam — then copy its value forward and remove
        // the legacy key from the persistent domain. After this one-shot,
        // every read goes to the prefixed key.
        bootstrapSchemaVersionKey(in: defaults, domain: domain)

        // `storedSchemaVersion` reads from the persistent domain only
        // (audit S5-R-001) and returns 0 if the key is absent there.
        // Now that we no longer register `schemaVersionKey` in
        // NSRegistrationDomain (audit EI-02), 0 unambiguously means "no
        // schema version has ever been stamped to this defaults
        // instance" — treat as v0, walk through every migration step,
        // and stamp current at the end. A non-zero `stored` is an
        // actual persistent-domain value we trust verbatim. The earlier
        // claim that `bb.`-prefixed keys are immune to `defaults write
        // -g` was WRONG — NSGlobalDomain doesn't strip prefixes, it
        // serves the literal key — so the persistent-domain-only read
        // is the load-bearing defense, not the prefix.
        let stored = Preferences.storedSchemaVersion(in: defaults, domain: domain)
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
            migrateV1toV2(defaults: defaults, domain: domain)
            v = 2
        }
        // Future steps slot in here: `if v < 3 { migrateV2toV3(...); v = 3 }` etc.
        defaults.set(v, forKey: Preferences.schemaVersionKey)
    }

    /// Read the stored schema version from the app's persistent domain
    /// only — NOT via `defaults.integer(forKey:)` which walks the full
    /// UserDefaults search list (app persistent → NSGlobalDomain →
    /// registration). A hostile or accidental `defaults write -g
    /// bb.prefsSchemaVersion <n>` to NSGlobalDomain would otherwise
    /// elevate `storedSchemaVersion` to <n>, flip `isDowngrade` true at
    /// Preferences-init time, and the S6-010 init-time numeric clamp
    /// (M-14 / DI-7 recovery for tampered NaN / out-of-range fontSize /
    /// translucency) would be silently skipped. Mirrors the same defense
    /// already applied to `bootstrapSchemaVersionKey` (H-8) and
    /// `migrateV1toV2` (S5-001). Audit S5-R-001.
    ///
    /// Returns 0 when the key is absent from the persistent domain,
    /// matching `integer(forKey:)`'s contract for missing keys.
    static func storedSchemaVersion(in defaults: UserDefaults, domain: String) -> Int {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return 0 }
        if let n = persistent[Preferences.schemaVersionKey] as? NSNumber { return n.intValue }
        return 0
    }

    /// Audit fix-#04 (2026-05-21): persistentDomain-scoped double read,
    /// returning nil when the key is absent. Used by the runtime
    /// change-handler so `defaults.double(forKey:)`'s full search-list
    /// walk can't surface an attacker-staged `defaults write -g
    /// bb.fontSize` on the very first launch (before the through-didSet
    /// init has populated the app domain) into the user's pref. Mirrors
    /// the `storedSchemaVersion` hardening (audit S5-R-001).
    ///
    /// Returns nil rather than 0 so the caller can distinguish
    /// "key absent on disk" (use the registered default) from "key set
    /// to 0" (a legitimate but out-of-envelope value worth re-clamping).
    static func doubleInPersistentDomain(
        in defaults: UserDefaults,
        domain: String,
        key: String
    ) -> Double? {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return nil }
        if let n = persistent[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    /// One-shot promotion of the legacy unprefixed `prefsSchemaVersion`
    /// key to its `bb.`-prefixed counterpart. Reads through
    /// `persistentDomain(forName:)` instead of `defaults.integer(forKey:)`
    /// so a hostile `defaults write -g prefsSchemaVersion <n>` write to
    /// NSGlobalDomain can't bypass the migration. Idempotent — the second
    /// launch sees no legacy key in the persistent domain and short-
    /// circuits. (audit H-8)
    private static func bootstrapSchemaVersionKey(in defaults: UserDefaults, domain: String) {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        guard let legacyValue = persistent[Preferences.legacySchemaVersionKey] else { return }
        // Prefer an already-stamped prefixed value if both keys ended up
        // on disk (mid-upgrade-crash window). Either way, drop the legacy
        // key from the persistent domain so the next launch short-circuits.
        if persistent[Preferences.schemaVersionKey] == nil {
            defaults.set(legacyValue, forKey: Preferences.schemaVersionKey)
        }
        defaults.removeObject(forKey: Preferences.legacySchemaVersionKey)
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
    private static func migrateV1toV2(defaults: UserDefaults, domain: String) {
        // Read each legacy key from the persistent domain directly, NOT
        // via `defaults.object(forKey:)` which walks the full search list
        // (app persistent → NSGlobalDomain → registration). A hostile or
        // accidental `defaults write -g theme "X"` / `defaults write -g
        // fontSize 25` to NSGlobalDomain would otherwise be imported into
        // `bb.theme` / `bb.fontSize` on first migration, silently
        // substituting the user's settings. Mirrors the same defense
        // applied to `bootstrapSchemaVersionKey` (audit H-8) extended
        // to the legacy data keys. Audit S5-001.
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        for name in Preferences.legacyUnprefixedKeys {
            let prefixed = Preferences.k(name)
            guard let legacy = persistent[name] else { continue }
            defaults.set(legacy, forKey: prefixed)
            defaults.removeObject(forKey: name)
        }
    }
}
