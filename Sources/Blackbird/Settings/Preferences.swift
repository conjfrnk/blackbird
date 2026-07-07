import SwiftUI
import AppKit
import Combine
import os

private extension ClosedRange where Bound == Double {
    /// Clamp `value` into the range, sending NaN / ±Infinity to `fallback`
    /// first so a tampered plist can't surface a non-finite reading. The one
    /// clamp envelope shared by the `fontSize` / `translucency` `didSet`
    /// blocks and the external-defaults re-clamp in
    /// `applyExternalDefaultsChange` — audit M-13/DI-6: with the clamp routed
    /// through the `fontSizeRange` / `translucencyRange` symbol, no competing
    /// inline ceiling literal can drift from the `9...32` / `1...10` envelope.
    func clamping(_ value: Bound, nonFiniteFallback: Bound) -> Bound {
        let normalised = value.isFinite ? value : nonFiniteFallback
        return Swift.max(lowerBound, Swift.min(upperBound, normalised))
    }
}

/// Single source of truth for user preferences, backed by `UserDefaults`
/// via `@AppStorage`. `ObservableObject` so SwiftUI views bind via
/// `@EnvironmentObject` / `@StateObject` and ThemeManager observes via
/// `objectWillChange`.
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    // MARK: - Single-source-of-truth envelopes (REFACTOR.md Part III §4)

    /// Font-size clamp envelope — the ONE definition shared by the model
    /// `fontSize.didSet` clamp and the SettingsView slider's `in:`. Keeping
    /// these aligned by construction is why the M-13/DI-6 "model ceiling 64 vs
    /// slider 32" mismatch (tampered value renders with the thumb pinned at max)
    /// can't reappear.
    public static let fontSizeRange: ClosedRange<Double> = 9...32
    /// Translucency clamp envelope (10 = opaque). Shared by the model clamp and
    /// the slider, same rationale as `fontSizeRange`.
    public static let translucencyRange: ClosedRange<Double> = 1...10

    /// The UserDefaults persistent domain for every security-relevant
    /// `persistentDomain(forName:)` read (bundle id in production; the literal
    /// id only as a test/edge fallback). One definition so the domain a config
    /// decision is read from can't drift between call sites — it was inlined as
    /// `Bundle.main.bundleIdentifier ?? "..."` at 6 sites.
    public static let persistentDomainName = Bundle.main.bundleIdentifier ?? "dev.conjfrnk.blackbird"

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
    // <bundle-id>` returns a dump that's self-identifying.
    // (settings F3)
    public static let currentSchemaVersion: Int = 2
    // Audit H-8: the schema-version key sits under the `bb.` namespace so
    // a `defaults write -g prefsSchemaVersion 99` can't reach into our
    // search list and force the migration seam to think we're already
    // current. The legacy unprefixed name is bootstrapped forward (and
    // then removed from the persistent domain) on first launch with the
    // fix — see `migrateIfNeeded(in:domain:)`.
    // `internal` (not `private`): the migration/sanitize logic moved to
    // `PrefsMigrator` / `PersistentDomainReader` (same module) reference these
    // canonical keys.
    static let schemaVersionKey = "bb.prefsSchemaVersion"
    static let legacySchemaVersionKey = "prefsSchemaVersion"

    // MARK: - Key prefix (settings F3)
    //
    // Every pref key lands under `bb.` so our reads don't fall through to
    // NSGlobalDomain for a plain name like `fontSize` that another tool
    // might have set globally. The `k(_:)` helper is used both in the
    // `@AppStorage` declarations and in the migration/registration code so
    // the canonical on-disk form is authored in one place.
    // `internal` (not `private`): the extracted `PrefsSanitizer` / `PrefsMigrator`
    // build the same canonical on-disk key form via this one helper.
    @inline(__always)
    static func k(_ name: String) -> String { "bb.\(name)" }

    /// The unprefixed names we used in schema v1, in the order they appear
    /// as `@AppStorage` declarations below. Walked by `PrefsMigrator`'s v1 → v2
    /// step to copy legacy values forward into `bb.`-prefixed keys. `internal`
    /// (not private) so the extracted migrator can read it; a future v2 → v3
    /// migration must still review this history before reusing any name.
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
        case visual = "Visual", off = "Off"
        public var id: String { rawValue }
    }

    public enum OptionKey: String, CaseIterable, Identifiable {
        case meta = "Meta (ESC+)", native = "Native"
        public var id: String { rawValue }
    }

    /// Modifier held while dragging the terminal body or a tab pill to MOVE
    /// the window (a plain tab drag reorders the tabs instead); also reused for
    /// the right-drag resize gesture. With multiple tabs the strip fills the
    /// titlebar, so this modifier is the only in-strip move path; single-tab
    /// windows hide the strip and keep a bare, natively-draggable titlebar.
    ///
    /// Only ⌘ and ⌥⌘ are offered, because in a terminal every other modifier
    /// is already taken:
    /// - Plain ⌥ is rectangular selection + the TUI mouse-capture escape; but
    ///   ⌥⌘ is safe because the drag gate requires BOTH keys, so it never
    ///   matches an ⌥-alone gesture.
    /// - ⌃ is excluded entirely: macOS routes ⌃+left-click to a secondary
    ///   (right) click, so a ⌃ left-drag is delivered to `rightMouseDown` and
    ///   would never reach the move path.
    public enum WindowGestureModifier: String, CaseIterable, Identifiable {
        case command = "Command", optionCommand = "Option-Command"
        public var id: String { rawValue }
        /// AppKit flag(s) this maps to.
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
            let clamped = Self.fontSizeRange.clamping(fontSize, nonFiniteFallback: 13)
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
    @AppStorage("bb.autoUpdateChecks") public var autoUpdateChecks: Bool = false
    /// Default off (v0.1.10): arbitrary PTY output can overwrite the system
    /// clipboard up to 1 MiB without user consent when on. The scrub
    /// pipeline blocks raw C0/C1/bidi bytes, but cross-app paste into a
    /// password field or bank-transfer IBAN is still trivial once a
    /// hostile remote can emit OSC 52. The user-facing Settings toggle was
    /// removed in audit S4-001 because the Rust core hardcodes
    /// `Osc52::Disabled` (no FFI to flip it), so OSC 52 writes never reach the
    /// Swift handler — the toggle promised a capability it could not deliver.
    /// This preference (registered default `false`) and the Swift scrub / size-
    /// cap handler are retained as dormant defence-in-depth — and stay
    /// unit-tested — for if the core ever re-enables OSC 52.
    /// See `SEC-001` in the v0.1.9 sweep triage.
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
    /// Allow OSC 10 / 11 / 12 `?` queries to emit a reply. ON by default
    /// since issue #24: modern TUIs (Codex CLI, nvim, delta, fzf) probe
    /// OSC 10/11 at startup for light/dark theme detection, and a silent
    /// drop degrades them to a colorless fallback after a reply-timeout
    /// stall — Codex loses its composer background entirely. iTerm2,
    /// kitty, alacritty, WezTerm and Ghostty all reply by default; the
    /// hostile-spam reply rate cap (core Bug #17, `ColorRequestQueue`)
    /// plus this opt-out toggle keep the original concern — the reply
    /// (`\e]10;rgb:…\e\\`) travels back through the PTY where a
    /// misbehaving shell / zsh-vi-mode could try to interpret it — as a
    /// hardening option rather than a broken-by-default. See
    /// `terminal_replies.rs` security test.
    @AppStorage("bb.colorQueryEnabled") public var colorQueryEnabled: Bool = true
    /// Automatic shell integration (issue #23): at spawn, inject OSC 133
    /// prompt marks + the ssh terminfo wrapper for zsh (ZDOTDIR
    /// redirect) and fish (XDG_DATA_DIRS vendor conf.d) without touching
    /// rc files. Read at session start — toggling affects the NEXT
    /// spawned shell, never live ones.
    ///
    /// Deliberately NOT `@AppStorage`: a same-value `@AppStorage` write
    /// still writes UserDefaults, and EVERY UserDefaults write re-enters
    /// `Preferences.objectWillChange` through SwiftUI's global bridge —
    /// the Settings-beachball root cause (982b719). The same-value guard
    /// below makes an unchanged write a true no-op: no store write, no
    /// `didChangeNotification`, no bridge re-entry. SwiftUI bindings
    /// (`$prefs.automaticShellIntegration`) work fine on a plain
    /// computed property via `ObservedObject`'s member subscript.
    public var automaticShellIntegration: Bool {
        get {
            (UserDefaults.standard.object(forKey: Self.k("automaticShellIntegration")) as? Bool) ?? true
        }
        set {
            guard newValue != automaticShellIntegration else { return }
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.k("automaticShellIntegration"))
        }
    }
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
            let clamped = Self.translucencyRange.clamping(translucency, nonFiniteFallback: Self.translucencyRange.lowerBound)
            guard clamped != translucency else { return }
            withSelfWriteSuppressed { translucency = clamped }
        }
    }

    public var theme: Theme         { Theme(rawValue: themeRaw) ?? .defaultTheme }
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

    /// Held weakly across `init` so the observer is torn down with the
    /// singleton. The observer is created once, in `init`, and never
    /// reassigned; mutation of this field is bounded by `init` and
    /// `deinit`, both of which run with exclusive access to the singleton.
    private var defaultsObserver: NSObjectProtocol?

    /// The single reentry-suppression primitive (audit M5 + the
    /// "≤ 1 reentry-suppression primitive" A-target). Replaces the three
    /// former ad-hoc flags `clampingFontSize` / `clampingTranslucency` /
    /// `isProcessingDefaultsChange`, which had identical shape. Set while a
    /// self-write is in flight: the `fontSize` / `translucency` recursive
    /// clamp writes and the `UserDefaults.didChangeNotification` handler all
    /// route through `withSelfWriteSuppressed`.
    ///
    /// The same-value guards inside each `didSet` and the disk-comparison
    /// guards in `applyExternalDefaultsChange` remain the canonical defence;
    /// this flag is the documented belt-and-braces against the 982b719
    /// SwiftUI feedback loop and against `didChangeNotification` re-delivery
    /// (re-delivered on a later main-queue tick, in case Apple ever makes
    /// that delivery synchronous). Main-queue-only access for the handler
    /// path is enforced by `dispatchPrecondition` at the top of
    /// `handleDefaultsChange`.
    private var isSuppressingSelfWrite = false

    /// Run `body` unless a self-write is already in flight, in which case it
    /// is skipped (the outer write already produced the user-visible
    /// objectWillChange / clamp).
    ///
    /// PRECONDITION — every write inside `body` MUST already satisfy the
    /// `didSet` invariants (pre-clamped into its envelope and finite). While
    /// the flag is held, the corrective `didSet` clamp is exactly the write
    /// this primitive suppresses, so a raw / unclamped assignment inside a
    /// suppressed region would skip its own clamp and could leave an
    /// out-of-range value on the security-sensitive tampered-plist path. All
    /// current callers honour this: the `didSet` recursion writes `clamped`,
    /// and `applyExternalDefaultsChange` writes the pre-clamped `clampedFont`
    /// / `clampedTrans`.
    ///
    /// Main-thread only — `isSuppressingSelfWrite` is a non-atomic `Bool` and
    /// this is the single shared choke point. The handler path enforces it via
    /// `dispatchPrecondition(.onQueue(.main))`; the `didSet` paths run on the
    /// main thread by construction (SwiftUI `@AppStorage` mutation).
    private func withSelfWriteSuppressed(_ body: () -> Void) {
        guard !isSuppressingSelfWrite else { return }
        isSuppressingSelfWrite = true
        defer { isSuppressingSelfWrite = false }
        body()
    }

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

    private init() {
        // Register defaults in NSRegistrationDomain BEFORE the first
        // `@AppStorage` read so that `defaults read <bundle-id>`
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
            Preferences.k("windowDragModifier"):   WindowGestureModifier.command.rawValue,
            Preferences.k("windowResizeModifier"): WindowGestureModifier.command.rawValue,
            Preferences.k("confirmClose"):      true,
            Preferences.k("autoUpdateChecks"):  false,
            Preferences.k("osc52Enabled"):      false,
            Preferences.k("colorQueryEnabled"): true,
            Preferences.k("automaticShellIntegration"): true,
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
        // CLI write like `defaults write <bundle-id> bb.fontSize
        // -string "big"` stores a String under the key, and the next
        // `UserDefaults.standard.double(forKey:)` bridge returns 0 (or, in
        // some Swift versions, crashes on an Objective-C cast). Remove
        // wrong-type values for numeric keys so the registered default
        // below takes effect. Runs before the v1 → v2 migration so a
        // legacy unprefixed key with a wrong type is removed before the
        // migrator tries to carry it forward. (settings F7)
        Preferences.sanitizeStoredTypes(
            in: defaults,
            domain: Self.persistentDomainName
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
        //   (a) the shared `withSelfWriteSuppressed` primitive (one
        //       `isSuppressingSelfWrite` flag) — cheap short-circuit when
        //       our own clamp write is the trigger.
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
        // Locks the contract the `withSelfWriteSuppressed` handler path
        // relies on: the observer is registered with `queue: .main`, so this
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
        withSelfWriteSuppressed { applyExternalDefaultsChange() }
    }

    /// The external-defaults repair pass: H-8 schema-version gate, enum
    /// raw-value repair, and the numeric-envelope re-clamp. Always invoked
    /// through `withSelfWriteSuppressed` from `handleDefaultsChange`, so its
    /// clamp/repair writes can't re-enter the handler (audit M5 — one
    /// reentry-suppression primitive).
    private func applyExternalDefaultsChange() {
        let defaults = UserDefaults.standard

        // H-8 downgrade gate: skip the enum repair when the on-disk
        // schema version is ahead of the current binary. Same predicate
        // as init. Reads via persistent-domain helper (audit S5-R-001)
        // so a hostile `defaults write -g bb.prefsSchemaVersion 99` can't
        // poison the gate.
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
        let domain = Self.persistentDomainName

        if let diskFontSize = Preferences.doubleInPersistentDomain(
            in: defaults, domain: domain, key: Preferences.k("fontSize")
        ) {
            let clampedFont = Self.fontSizeRange.clamping(diskFontSize, nonFiniteFallback: 13)
            if clampedFont != diskFontSize {
                Preferences.logger.log("re-clamping fontSize after external defaults write: \(diskFontSize, privacy: .public) → \(clampedFont, privacy: .public)")
                self.fontSize = clampedFont
            }
        }

        if let diskTrans = Preferences.doubleInPersistentDomain(
            in: defaults, domain: domain, key: Preferences.k("translucency")
        ) {
            let clampedTrans = Self.translucencyRange.clamping(diskTrans, nonFiniteFallback: Self.translucencyRange.lowerBound)
            if clampedTrans != diskTrans {
                Preferences.logger.log("re-clamping translucency after external defaults write: \(diskTrans, privacy: .public) → \(clampedTrans, privacy: .public)")
                self.translucency = clampedTrans
            }
        }
    }

    // MARK: - Maintenance forwarders
    //
    // The migration / sanitize / persistent-domain-read LOGIC lives in
    // `PrefsMaintenance.swift` (`PrefsMigrator`, `PrefsSanitizer`,
    // `PersistentDomainReader`) so those concerns are independently testable
    // off the @AppStorage bag. These thin static forwarders keep the call sites
    // in `init` / `handleDefaultsChange` and the migration test suites binding
    // through `Preferences.*` unchanged.

    /// Repair enum-backed @AppStorage strings whose stored rawValue doesn't
    /// decode to a known case. See `PrefsSanitizer.repairEnumRawValues`.
    static func repairEnumRawValues(in prefs: Preferences, defaults: UserDefaults, domain: String) {
        PrefsSanitizer.repairEnumRawValues(in: prefs, defaults: defaults, domain: domain)
    }

    /// Remove wrong-type values from numeric/bool pref keys. See
    /// `PrefsSanitizer.sanitizeStoredTypes`.
    private static func sanitizeStoredTypes(in defaults: UserDefaults, domain: String) {
        PrefsSanitizer.sanitizeStoredTypes(in: defaults, domain: domain)
    }

    /// Walk the on-disk schema version forward to `currentSchemaVersion`. The
    /// persistent-domain name is the app's bundle identifier; tests drive the
    /// `migrateIfNeeded(in:domain:)` seam with their own suite name. (H-8)
    private func migrateIfNeeded() {
        Preferences.migrateIfNeeded(
            in: UserDefaults.standard,
            domain: Self.persistentDomainName
        )
    }

    /// Testable migration seam — drives the same machinery against any
    /// `UserDefaults`. Keep `internal`, not `public`: production goes through
    /// the no-arg instance method. See `PrefsMigrator.migrateIfNeeded` for the
    /// F-S7-003 downgrade-safety invariant.
    internal static func migrateIfNeeded(in defaults: UserDefaults, domain: String) {
        PrefsMigrator.migrateIfNeeded(in: defaults, domain: domain)
    }

    /// Read the stored schema version from the app's persistent domain only.
    /// See `PersistentDomainReader.storedSchemaVersion` (audit S5-R-001).
    static func storedSchemaVersion(in defaults: UserDefaults, domain: String) -> Int {
        PersistentDomainReader.storedSchemaVersion(in: defaults, domain: domain)
    }

    /// PersistentDomain-scoped double read, nil when absent. See
    /// `PersistentDomainReader.double` (audit fix-#04).
    static func doubleInPersistentDomain(
        in defaults: UserDefaults,
        domain: String,
        key: String
    ) -> Double? {
        PersistentDomainReader.double(in: defaults, domain: domain, key: key)
    }
}
