import Foundation

// UserDefaults maintenance for `Preferences`, split out of the @AppStorage bag
// so migration, sanitization, and persistent-domain reads live in their own
// units — independently testable, with no SwiftUI / @AppStorage coupling. Each
// operates on an explicit `(defaults, domain)` so tests can drive them against
// an isolated suite. The key/schema CONSTANTS stay on `Preferences` (the
// @AppStorage registration references them too); only the LOGIC moved here.
// `Preferences` keeps thin static forwarders (`migrateIfNeeded`,
// `storedSchemaVersion`, `repairEnumRawValues`, `sanitizeStoredTypes`,
// `doubleInPersistentDomain`) so existing call sites and the migration test
// suites bind unchanged.

/// Persistent-domain-scoped reads. Every read goes through
/// `persistentDomain(forName:)` — the app's OWN domain — rather than the
/// search-list-walking `defaults.<type>(forKey:)`, so a `defaults write -g …`
/// to NSGlobalDomain can't surface a foreign value into a gate or clamp.
/// (audit S5-R-001 / S5-001 family)
enum PersistentDomainReader {
    /// Read the stored schema version from the app's persistent domain only —
    /// NOT via `defaults.integer(forKey:)` which walks the full UserDefaults
    /// search list (app persistent → NSGlobalDomain → registration). A hostile
    /// or accidental `defaults write -g bb.prefsSchemaVersion <n>` to
    /// NSGlobalDomain would otherwise elevate the version, flip `isDowngrade`
    /// true at Preferences-init time, and silently skip the S6-010 init-time
    /// numeric clamp (M-14 / DI-7 recovery for tampered NaN / out-of-range
    /// fontSize / translucency). Mirrors the same defense already applied to
    /// `bootstrapSchemaVersionKey` (H-8) and `migrateV1toV2` (S5-001). Audit
    /// S5-R-001.
    ///
    /// Returns 0 when the key is absent from the persistent domain, matching
    /// `integer(forKey:)`'s contract for missing keys.
    static func storedSchemaVersion(in defaults: UserDefaults, domain: String) -> Int {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return 0 }
        if let n = persistent[Preferences.schemaVersionKey] as? NSNumber { return n.intValue }
        return 0
    }

    /// Audit fix-#04 (2026-05-21): persistentDomain-scoped double read,
    /// returning nil when the key is absent. Used by the runtime change-handler
    /// so `defaults.double(forKey:)`'s full search-list walk can't surface an
    /// attacker-staged `defaults write -g bb.fontSize` on the very first launch
    /// (before the through-didSet init has populated the app domain) into the
    /// user's pref. Mirrors the `storedSchemaVersion` hardening (audit S5-R-001).
    ///
    /// Returns nil rather than 0 so the caller can distinguish "key absent on
    /// disk" (use the registered default) from "key set to 0" (a legitimate but
    /// out-of-envelope value worth re-clamping).
    static func double(in defaults: UserDefaults, domain: String, key: String) -> Double? {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return nil }
        if let n = persistent[key] as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// Wrong-type removal + unknown-enum repair for stored prefs. Both read ONLY
/// the app's persistent domain (S5-009 / S5-001) so a `defaults write -g`
/// can't trigger a misleading no-op or clobber a valid app-domain value.
enum PrefsSanitizer {
    /// Remove wrong-type values from numeric pref keys. `@AppStorage<Double>`
    /// and `@AppStorage<Bool>` trust the key's KVC getter — if an external tool
    /// stashed a String under a numeric key, the read returns 0/false (or trips
    /// a Swift bridge assertion on some toolchain/OS combos). Removing the
    /// offending value lets the registered default take over. Covers both
    /// `bb.`-prefixed and legacy unprefixed names, so a user upgrading from
    /// v0.1.5 with a corrupted legacy key still gets cleaned up before the
    /// migration copies it forward. (settings F7)
    static func sanitizeStoredTypes(in defaults: UserDefaults, domain: String) {
        let numericDoubleKeys = ["fontSize", "translucency"]
        let boolKeys = [
            "cursorBlink", "confirmClose", "autoUpdateChecks",
            "osc52Enabled", "colorQueryEnabled",
            // Audit fix-#15: include confirmMultiLinePaste in the sanitize
            // sweep so a wrong-typed CLI write (e.g. defaults write … -string
            // yes) is stripped before the registered default is applied,
            // matching sibling bool prefs.
            "confirmMultiLinePaste",
        ]
        // S5-009: read from the persistent domain only, mirroring the S5-001
        // migration fix. `defaults.object(forKey:)` walks the full search list
        // (app persistent → NSGlobalDomain → registration); a `defaults write
        // -g fontSize -string foo` would otherwise trip the sanitize for an
        // unprefixed key, but `removeObject(forKey:)` only writes to the app's
        // persistent domain — so the global value persists, no work was done,
        // and the user-visible behaviour was a misleading no-op. persistentDomain
        // reads ONLY the app's domain, so we sanitize what we can actually mutate.
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        let isNumericLike: (Any) -> Bool = { $0 is NSNumber }
        for name in numericDoubleKeys {
            for key in [Preferences.k(name), name] {
                if let v = persistent[key], !isNumericLike(v) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for name in boolKeys {
            for key in [Preferences.k(name), name] {
                if let v = persistent[key], !isNumericLike(v) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Repair the enum-backed @AppStorage strings when a stored value doesn't
    /// match any case: write the registered default back, but only when it
    /// actually differs (so a value that's already the default doesn't fire a
    /// redundant `didChangeNotification`).
    ///
    /// Audit S5-001: each rawValue is read from the APP's persistent domain
    /// (`persistentDomain(forName:)`), NOT via `defaults.string(forKey:)` which
    /// walks the full search list (app persistent → NSGlobalDomain →
    /// registration). This matches the sibling hardening already applied to the
    /// numeric clamps (`doubleInPersistentDomain`) and the schema-version gate
    /// (`storedSchemaVersion`): a `defaults write -g bb.theme <x>` to
    /// NSGlobalDomain can no longer be surfaced as a "valid" foreign value that
    /// suppresses repair, nor (when it is garbage) trigger a clobber of the app
    /// domain. A key absent from the persistent domain reads as nil and falls
    /// back to the canonical default, which is exactly the registered default
    /// the @AppStorage getter already returns for an unset key — so legitimate
    /// first-run / never-customised state is unchanged.
    ///
    /// Store asymmetry (why this one can't be sealed-suite-isolated like its
    /// siblings): it READS rawValues from the passed `domain`, but WRITES via
    /// `prefs`'s `@AppStorage` props, which are hardwired to
    /// `UserDefaults.standard`. So the repair test must pass `Preferences.shared`
    /// + drive the standard domain. This split is inherent to `@AppStorage`, not
    /// this extraction.
    static func repairEnumRawValues(in prefs: Preferences, defaults: UserDefaults, domain: String) {
        let persistent = defaults.persistentDomain(forName: domain) ?? [:]
        func storedRaw(_ name: String) -> String? { persistent[Preferences.k(name)] as? String }

        // Repair one enum-backed pref: if the stored rawValue doesn't decode to
        // a valid case, write the default back — but only when it actually
        // differs, so a value that's already the default doesn't fire a
        // redundant `didChangeNotification`. One shape for all seven; the
        // per-pref blocks this replaces were byte-identical apart from the key,
        // enum type, default case, and target property.
        func repair<E: RawRepresentable>(
            _ key: String, _ type: E.Type, default def: E, assign: (String) -> Void
        ) where E.RawValue == String {
            let raw = storedRaw(key) ?? def.rawValue
            if E(rawValue: raw) == nil {
                let target = def.rawValue
                if raw != target { assign(target) }
            }
        }

        repair("theme", Theme.self, default: .gruvbox) { prefs.themeRaw = $0 }
        repair("themeMode", Preferences.ThemeMode.self, default: .dark) { prefs.themeModeRaw = $0 }
        repair("bell", Preferences.BellStyle.self, default: .visual) { prefs.bellRaw = $0 }
        repair("cursorShape", Preferences.CursorShape.self, default: .followShell) { prefs.cursorShapeRaw = $0 }
        repair("optionKey", Preferences.OptionKey.self, default: .meta) { prefs.optionKeyRaw = $0 }
        repair("windowDragModifier", Preferences.WindowGestureModifier.self, default: .command) { prefs.windowDragModifierRaw = $0 }
        repair("windowResizeModifier", Preferences.WindowGestureModifier.self, default: .command) { prefs.windowResizeModifierRaw = $0 }
    }
}

/// Schema-version migration: walk the on-disk version forward to
/// `Preferences.currentSchemaVersion`, one step at a time. (settings F2/F3)
enum PrefsMigrator {
    /// Drive the migration machinery against any `UserDefaults` instance — the
    /// no-arg `Preferences.migrateIfNeeded()` passes `UserDefaults.standard` +
    /// the bundle identifier; tests pass an isolated suite + suite name.
    ///
    /// F-S7-003 fix — DOWNGRADE-SAFETY INVARIANT
    /// =========================================
    /// Bug: previously, when a user ran a future schema (say v3) and downgraded
    /// to a build whose `currentSchemaVersion` is v2, the "already current or
    /// newer" branch unconditionally STAMPED the stored key down to v2. The
    /// on-disk record then said "this user is at v2" while the data on disk was
    /// actually v3-shaped. A subsequent upgrade back to v3 would observe
    /// `stored=2 < current=3` and re-run the v2→v3 migration against ALREADY
    /// v3-shaped data, corrupting it.
    ///
    /// Fix: on downgrade (`stored > currentSchemaVersion`), do NOT touch the
    /// stored version key. The disk keeps the high-water mark intact, so a
    /// future re-upgrade observes `stored == intended` and correctly skips the
    /// no-op migration. The older build's read paths already tolerate unknown
    /// keys via the registered-default + enum-fallback machinery
    /// (`Theme(rawValue:) ?? .defaultTheme`, etc.), so leaving a higher version
    /// number on disk is safe.
    static func migrateIfNeeded(in defaults: UserDefaults, domain: String) {
        // H-8 bootstrap: the schema-version key was renamed from
        // `prefsSchemaVersion` to `bb.prefsSchemaVersion` to keep it out of the
        // global-domain search path. On first launch with the fix, look up the
        // OLD key in the app's PERSISTENT DOMAIN — not via
        // `defaults.integer(forKey:)`, which walks NSGlobalDomain and would let
        // `defaults write -g prefsSchemaVersion 99` poison the migration seam —
        // then copy its value forward and remove the legacy key from the
        // persistent domain. After this one-shot, every read goes to the
        // prefixed key.
        bootstrapSchemaVersionKey(in: defaults, domain: domain)

        // `storedSchemaVersion` reads from the persistent domain only (audit
        // S5-R-001) and returns 0 if the key is absent there. Now that we no
        // longer register `schemaVersionKey` in NSRegistrationDomain (audit
        // EI-02), 0 unambiguously means "no schema version has ever been
        // stamped to this defaults instance" — treat as v0, walk through every
        // migration step, and stamp current at the end. A non-zero `stored` is
        // an actual persistent-domain value we trust verbatim. The earlier
        // claim that `bb.`-prefixed keys are immune to `defaults write -g` was
        // WRONG — NSGlobalDomain doesn't strip prefixes, it serves the literal
        // key — so the persistent-domain-only read is the load-bearing defense,
        // not the prefix.
        let stored = PersistentDomainReader.storedSchemaVersion(in: defaults, domain: domain)
        guard stored < Preferences.currentSchemaVersion else {
            // Already current (stored == current) or NEWER (downgrade).
            //
            // Downgrade case (stored > current): leave the key alone. See the
            // F-S7-003 invariant comment above — clobbering the high-water mark
            // would cause a future re-upgrade to re-run already-applied
            // migrations and corrupt v(N+1)-shaped data.
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

    /// One-shot promotion of the legacy unprefixed `prefsSchemaVersion` key to
    /// its `bb.`-prefixed counterpart. Reads through `persistentDomain(forName:)`
    /// instead of `defaults.integer(forKey:)` so a hostile `defaults write -g
    /// prefsSchemaVersion <n>` write to NSGlobalDomain can't bypass the
    /// migration. Idempotent — the second launch sees no legacy key in the
    /// persistent domain and short-circuits. (audit H-8)
    private static func bootstrapSchemaVersionKey(in defaults: UserDefaults, domain: String) {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        guard let legacyValue = persistent[Preferences.legacySchemaVersionKey] else { return }
        // Prefer an already-stamped prefixed value if both keys ended up on disk
        // (mid-upgrade-crash window). Either way, drop the legacy key from the
        // persistent domain so the next launch short-circuits.
        if persistent[Preferences.schemaVersionKey] == nil {
            defaults.set(legacyValue, forKey: Preferences.schemaVersionKey)
        }
        defaults.removeObject(forKey: Preferences.legacySchemaVersionKey)
    }

    /// v1 → v2 (settings F3): copy every legacy unprefixed key into its
    /// `bb.`-prefixed counterpart and remove the original. No-op for keys absent
    /// on disk — they fall through to the registered default transparently.
    ///
    /// EI-02: previously this conditioned the copy on `alreadyPrefixed == nil`
    /// (intent: in a mid-upgrade-crash where both keys were set, prefer the
    /// prefixed value). That check called `defaults.object(forKey: prefixed)`,
    /// which walks the search list and returns the registered default —
    /// `bb.theme` always reads non-nil because `Preferences.init` registers
    /// `Theme.gruvbox.rawValue`. So `alreadyPrefixed != nil` was effectively
    /// always true, and the copy never happened. Result: legacy v1 users had
    /// their unprefixed keys silently deleted on upgrade, and their settings
    /// reset to the registered defaults. We unconditionally copy now. The
    /// mid-crash case becomes "legacy wins"; an exotic edge case which is no
    /// worse than the previous "legacy is silently dropped." (settings F3)
    private static func migrateV1toV2(defaults: UserDefaults, domain: String) {
        // Read each legacy key from the persistent domain directly, NOT via
        // `defaults.object(forKey:)` which walks the full search list (app
        // persistent → NSGlobalDomain → registration). A hostile or accidental
        // `defaults write -g theme "X"` / `defaults write -g fontSize 25` to
        // NSGlobalDomain would otherwise be imported into `bb.theme` /
        // `bb.fontSize` on first migration, silently substituting the user's
        // settings. Mirrors the same defense applied to `bootstrapSchemaVersionKey`
        // (audit H-8) extended to the legacy data keys. Audit S5-001.
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        for name in Preferences.legacyUnprefixedKeys {
            let prefixed = Preferences.k(name)
            guard let legacy = persistent[name] else { continue }
            defaults.set(legacy, forKey: prefixed)
            defaults.removeObject(forKey: name)
        }
    }
}
