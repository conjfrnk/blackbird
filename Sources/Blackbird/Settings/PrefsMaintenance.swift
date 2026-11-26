import Foundation

/// Reads go through `persistentDomain(forName:)`, never `defaults.<type>(forKey:)`: the latter walks the
/// search list, so a `defaults write -g …` to NSGlobalDomain would surface a foreign value.
enum PersistentDomainReader {
    static func bool(forKey key: String, in defaults: UserDefaults, domain: String) -> Bool? {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return nil }
        if let n = persistent[key] as? NSNumber { return n.boolValue }
        return nil
    }

    static func storedSchemaVersion(in defaults: UserDefaults, domain: String) -> Int {
        storedSchemaVersion(inSnapshot: defaults.persistentDomain(forName: domain))
    }

    static func storedSchemaVersion(inSnapshot persistent: [String: Any]?) -> Int {
        if let n = persistent?[Preferences.schemaVersionKey] as? NSNumber { return n.intValue }
        return 0
    }

    static func double(in defaults: UserDefaults, domain: String, key: String) -> Double? {
        double(inSnapshot: defaults.persistentDomain(forName: domain), key: key)
    }

    static func double(inSnapshot persistent: [String: Any]?, key: String) -> Double? {
        if let n = persistent?[key] as? NSNumber { return n.doubleValue }
        return nil
    }
}

enum PrefsSanitizer {
    /// `@AppStorage<Double>` / `<Bool>` read a wrong-typed value as 0 / false; removal restores the registered default.
    static func sanitizeStoredTypes(in defaults: UserDefaults, domain: String) {
        let numericLikeNames: [String] = Preferences.registeredDefaults.compactMap { key, value in
            guard key.hasPrefix("bb."), value is Bool || value is Double else { return nil }
            return String(key.dropFirst("bb.".count))
        }
        // Persistent domain only: `removeObject(forKey:)` cannot remove a value that lives in NSGlobalDomain.
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        let isNumericLike: (Any) -> Bool = { $0 is NSNumber }
        for name in numericLikeNames {
            for key in [Preferences.k(name), name] {
                if let v = persistent[key], !isNumericLike(v) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Reads from `domain` but writes through `prefs`'s `@AppStorage` props, bound to `UserDefaults.standard`.
    static func repairEnumRawValues(in prefs: Preferences, defaults: UserDefaults, domain: String) {
        repairEnumRawValues(in: prefs, snapshot: defaults.persistentDomain(forName: domain))
    }

    /// Writes only the enum-backed keys, so a snapshot stays valid for schema-version / fontSize / translucency reads.
    static func repairEnumRawValues(in prefs: Preferences, snapshot: [String: Any]?) {
        let persistent = snapshot ?? [:]
        func storedRaw(_ name: String) -> String? { persistent[Preferences.k(name)] as? String }

        func repair<E: RawRepresentable>(
            _ key: String, _ type: E.Type, default def: E, assign: (String) -> Void
        ) where E.RawValue == String {
            let raw = storedRaw(key) ?? def.rawValue
            if E(rawValue: raw) == nil {
                let target = def.rawValue
                if raw != target { assign(target) }
            }
        }

        repair("theme", Theme.self, default: Preferences.defaultThemeChoice) { prefs.themeRaw = $0 }
        repair("themeMode", Preferences.ThemeMode.self, default: .dark) { prefs.themeModeRaw = $0 }
        repair("bell", Preferences.BellStyle.self, default: .visual) { prefs.bellRaw = $0 }
        repair("cursorShape", Preferences.CursorShape.self, default: .followShell) { prefs.cursorShapeRaw = $0 }
        repair("optionKey", Preferences.OptionKey.self, default: .meta) { prefs.optionKeyRaw = $0 }
        repair("windowDragModifier", Preferences.WindowGestureModifier.self, default: .command) { prefs.windowDragModifierRaw = $0 }
        repair("windowResizeModifier", Preferences.WindowGestureModifier.self, default: .command) { prefs.windowResizeModifierRaw = $0 }
    }
}

enum PrefsMigrator {
    /// On downgrade (`stored > currentSchemaVersion`) the stored version key is left untouched: stamping it down
    /// would make a later re-upgrade re-run migrations against already-migrated data.
    static func migrateIfNeeded(in defaults: UserDefaults, domain: String) {
        bootstrapSchemaVersionKey(in: defaults, domain: domain)

        // 0 means no schema version was ever stamped: the key is not registered in NSRegistrationDomain.
        let stored = PersistentDomainReader.storedSchemaVersion(in: defaults, domain: domain)
        guard stored < Preferences.currentSchemaVersion else {
            return
        }
        var v = stored
        if v < 2 {
            migrateV1toV2(defaults: defaults, domain: domain)
            v = 2
        }
        defaults.set(v, forKey: Preferences.schemaVersionKey)
    }

    private static func bootstrapSchemaVersionKey(in defaults: UserDefaults, domain: String) {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        guard let legacyValue = persistent[Preferences.legacySchemaVersionKey] else { return }
        // If both keys are on disk (mid-upgrade crash), the prefixed value wins.
        if persistent[Preferences.schemaVersionKey] == nil {
            defaults.set(legacyValue, forKey: Preferences.schemaVersionKey)
        }
        defaults.removeObject(forKey: Preferences.legacySchemaVersionKey)
    }

    /// Copies unconditionally: `defaults.object(forKey: prefixed)` returns the registered default, so an
    /// "already prefixed" check is always true and would silently drop the legacy values.
    private static func migrateV1toV2(defaults: UserDefaults, domain: String) {
        guard let persistent = defaults.persistentDomain(forName: domain) else { return }
        for name in Preferences.legacyUnprefixedKeys {
            let prefixed = Preferences.k(name)
            guard let legacy = persistent[name] else { continue }
            defaults.set(legacy, forKey: prefixed)
            defaults.removeObject(forKey: name)
        }
    }
}
