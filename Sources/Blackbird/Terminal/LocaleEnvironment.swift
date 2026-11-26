import Foundation

/// Synthesises `LANG` for the child shell: a Finder-launched app inherits none from launchd.
enum LocaleEnvironment {
    static let fallback = "en_US.UTF-8"

    static func overrides(
        enabled: Bool,
        parentEnv: [String: String],
        locale: Locale,
        isAvailable: (String) -> Bool
    ) -> [String: String] {
        guard enabled else { return [:] }
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let v = parentEnv[key], !v.isEmpty { return [:] }
        }
        return ["LANG": candidate(for: locale, isAvailable: isAvailable) ?? fallback]
    }

    /// The Region comes from the `AppleLocale` preference: `Locale.current` is a cached
    /// snapshot whose language is filtered by the app bundle.
    static func currentSystemLocale(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Locale {
        let appleLocale: String? = defaults.string(forKey: "AppleLocale")
        let regionSetting: Locale
        if let id = appleLocale, !id.isEmpty {
            regionSetting = Locale(identifier: id)
        } else {
            regionSetting = Locale.current
        }
        return systemLocale(preferredLanguages: preferredLanguages, regionSetting: regionSetting)
    }

    /// The region comes from `regionSetting`, not the language tag: a tag's region is often not the
    /// user's country (`es-419` is a UN M.49 macro-region with no `/usr/share/locale` entry).
    static func systemLocale(preferredLanguages: [String], regionSetting: Locale) -> Locale {
        guard let tag = preferredLanguages.first else { return regionSetting }
        let language = Locale.Language(identifier: tag)
        guard let lang = language.languageCode?.identifier else { return regionSetting }
        let regions: [Locale.Region?] = [regionSetting.region, language.region]
        for region in regions {
            if let id = region?.identifier, isCountryRegion(id) {
                return Locale(identifier: "\(lang)_\(id)")
            }
        }
        return regionSetting
    }

    private static func isCountryRegion(_ id: String) -> Bool {
        id.count == 2 && id.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    static func candidate(for locale: Locale, isAvailable: (String) -> Bool) -> String? {
        guard let lang = locale.language.languageCode?.identifier,
              let region = locale.language.region?.identifier
        else { return nil }
        let name = "\(lang)_\(region).UTF-8"
        // Shape check so a malformed identifier can never reach `setenv`.
        let shape = #"^[a-z]{2,3}_[A-Z0-9]{2,3}\.UTF-8$"#
        guard name.range(of: shape, options: .regularExpression) != nil else { return nil }
        return isAvailable(name) ? name : nil
    }

    static func localeDefinitionExists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: "/usr/share/locale/\(name)", isDirectory: &isDir
        ) && isDir.boolValue
    }
}
