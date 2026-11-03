import Foundation

/// Locale environment for the child shell.
///
/// A Finder-launched app inherits no `LANG` from launchd, so through v0.8.0
/// the `-il` login shell ran in the C locale unless the user's dotfiles set
/// one: the zsh line editor mangled non-ASCII input, `ls` escaped file
/// names, and ncurses box drawing degraded. Terminal.app, iTerm2, kitty,
/// Alacritty and Ghostty all synthesise `LANG` from the system locale for
/// exactly this reason ("Set locale environment variables on startup").
///
/// Pure: every input is a parameter so the rule is unit-testable without
/// touching the process environment or the filesystem.
enum LocaleEnvironment {
    /// The `LANG` value every macOS install has a locale definition for.
    static let fallback = "en_US.UTF-8"

    /// Overrides to merge into the child's environment.
    ///
    /// - Returns `[:]` when disabled, or when the parent environment already
    ///   carries any of `LANG` / `LC_ALL` / `LC_CTYPE` (the user or launcher
    ///   made a choice; never second-guess it).
    /// - Otherwise `["LANG": "<lang>_<REGION>.UTF-8"]` when the system
    ///   locale's language + region name a locale definition that exists on
    ///   this machine (`isAvailable`), else `["LANG": fallback]`.
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

    /// The locale the user chose in System Settings, for `overrides(locale:)`,
    /// read from the live preferences. Production wiring of
    /// `systemLocale(preferredLanguages:regionSetting:)`.
    ///
    /// The Region comes from the `AppleLocale` preference (what System
    /// Settings writes; `Locale.current` is derived from it, but it is a
    /// cached snapshot whose language is filtered by the app bundle).
    /// `Locale.current` is only the fallback for a Mac with no `AppleLocale`
    /// at all.
    ///
    /// `defaults` and `preferredLanguages` default to the live system values;
    /// tests pass a private suite and a fixed list so they can emulate a
    /// System Settings choice without writing `AppleLanguages` / `AppleLocale`
    /// into the real app domain.
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

    /// Combine the user's language and Region choices into one locale.
    ///
    /// `Locale.current` can't be used as-is: Foundation resolves its language
    /// against the app bundle's localizations, and Blackbird ships English
    /// only, so on a German Mac it reads `en_DE` (no such definition ->
    /// `en_US.UTF-8` fallback). The un-filtered preference list still has the
    /// real language, so the language comes from its first tag.
    ///
    /// The region comes from `regionSetting` (the Region the user picked; it
    /// also honours an `@rg=` override), NOT from the tag: a tag's region is
    /// often not the user's country (`es-419` is a UN M.49 macro-region with
    /// no locale definition, and `en-US` + Region United Kingdom must still
    /// give `en_GB`). The tag's region is only the fallback when
    /// `regionSetting` has no country region. Only 2-letter country regions
    /// are used; numeric macro-regions (`419`, `001`, `150`) never name a
    /// `/usr/share/locale` entry. With no usable language or region,
    /// `regionSetting` is returned unchanged.
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

    /// Is `id` a 2-letter ISO 3166 country code (as opposed to a UN M.49
    /// numeric macro-region such as `419`)?
    private static func isCountryRegion(_ id: String) -> Bool {
        id.count == 2 && id.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    /// `<language>_<REGION>.UTF-8` for the locale, if it names an available
    /// locale definition. A language without a region (or a script-qualified
    /// identifier like `zh-Hans`) rarely has a matching `locale -a` entry;
    /// the caller falls back to `en_US.UTF-8`, which is what Terminal.app
    /// does too.
    static func candidate(for locale: Locale, isAvailable: (String) -> Bool) -> String? {
        guard let lang = locale.language.languageCode?.identifier,
              let region = locale.language.region?.identifier
        else { return nil }
        let name = "\(lang)_\(region).UTF-8"
        // Belt-and-braces shape check so a malformed identifier can never
        // reach `setenv`: letters, one underscore, letters/digits, `.UTF-8`.
        let shape = #"^[a-z]{2,3}_[A-Z0-9]{2,3}\.UTF-8$"#
        guard name.range(of: shape, options: .regularExpression) != nil else { return nil }
        return isAvailable(name) ? name : nil
    }

    /// Does `/usr/share/locale/<name>` exist? (What `locale -a` enumerates.)
    static func localeDefinitionExists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: "/usr/share/locale/\(name)", isDirectory: &isDir
        ) && isDir.boolValue
    }
}
