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
