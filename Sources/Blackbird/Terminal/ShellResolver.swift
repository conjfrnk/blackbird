import Foundation

enum ShellResolver {
    static let lastResort = "/bin/zsh"

    struct Resolution: Equatable {
        let path: String
        let preferenceRejected: Bool
    }

    static func resolve(
        preference: String?,
        loginShell: String?,
        environmentShell: String?,
        isExecutable: (String) -> Bool
    ) -> Resolution {
        var preferenceRejected = false
        if let pref = preference?.trimmingCharacters(in: .whitespacesAndNewlines), !pref.isEmpty {
            if pref.hasPrefix("/"), isExecutable(pref) {
                return Resolution(path: pref, preferenceRejected: false)
            }
            preferenceRejected = true
        }
        for candidate in [loginShell, environmentShell] {
            if let c = candidate, c.hasPrefix("/"), isExecutable(c) {
                return Resolution(path: c, preferenceRejected: preferenceRejected)
            }
        }
        return Resolution(path: lastResort, preferenceRejected: preferenceRejected)
    }

    static func launchArguments(for path: String) -> [String] {
        // Only shells known to accept the combined `-il`: tcsh wants `-l` alone, nu/elvish/xonsh
        // spell the flags differently, and a non-shell program would reject it.
        let name = (path as NSString).lastPathComponent
        return posixLikeShells.contains(name) ? ["-il"] : []
    }

    private static let posixLikeShells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh"]

    /// Shells that take no launch arguments but may still be named by `$SHELL`.
    private static let otherShells: Set<String> = ["tcsh", "csh", "nu", "elvish", "xonsh"]

    /// The shell is exec'd directly, without `login(1)` to export `SHELL`. A non-shell program is
    /// not exported: tmux's `default-shell`, vim's `'shell'` and `sudo -s` would run it as a shell.
    static func environmentOverrides(for path: String, loginShell: String?) -> [String: String] {
        let name = (path as NSString).lastPathComponent
        let isShell = path == loginShell || posixLikeShells.contains(name) || otherShells.contains(name)
        return isShell ? ["SHELL": path] : [:]
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    static func loginShellFromPasswd() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let s = String(cString: shell)
        return s.isEmpty ? nil : s
    }
}
