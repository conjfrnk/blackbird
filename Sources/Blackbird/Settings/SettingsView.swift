import SwiftUI
import AppKit

enum SettingsChrome {
    static let versionString: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return short == build ? short : "\(short) (\(build))"
    }()

    /// A bare `Text` in a grouped-Form footer gets the narrow label column and centers; the HStack with a
    /// trailing Spacer is offered the full row and pins the text leading.
    static func footer(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Enumerated with CoreText, whose font APIs are thread-safe (NSFontManager is not documented as such),
/// so `prewarm()` can run it off the main thread.
enum MonospaceFontFamilies {
    static let all: [String] = compute()

    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = all }
    }

    static func compute() -> [String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return names
            .filter { name in
                // NSFontManager hides the dot-prefixed system families.
                guard !name.hasPrefix(".") else { return false }
                let font = CTFontCreateWithName(name as CFString, 12, nil)
                // CTFontCreateWithName substitutes a default font for an unresolvable name.
                guard CTFontCopyFamilyName(font) as String == name else { return false }
                return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
            }
            .sorted()
    }
}

public struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    private enum Pane: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case behavior = "Behavior"
        case updates = "Updates"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }
    }

    @State private var pane: Pane = .appearance

    public init() {}

    public var body: some View {
        sections.frame(minWidth: 520, minHeight: 520)
    }

    // A segmented `Picker`, not `TabView`: on macOS 27 the AppKit-backed `TabView` leaves its
    // `NSTabViewSegmentedControl` at 0×0 until the window is resized.
    @ViewBuilder
    private var sections: some View {
        let base = VStack(spacing: 0) {
            Picker("Section", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 4)
            .padding(.bottom, 8)

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        if #available(macOS 15.0, *) {
            base.containerBackground(.clear, for: .window)
        } else {
            base
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .appearance: appearanceTab
        case .behavior: behaviorTab
        case .updates: updatesTab
        case .diagnostics: DiagnosticsView()
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                Picker("Mode", selection: $prefs.themeModeRaw) {
                    ForEach(Preferences.ThemeMode.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                Picker("Palette", selection: $prefs.themeRaw) {
                    ForEach(Theme.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
            }

            Section("Font") {
                Picker("Family", selection: $prefs.fontName) {
                    ForEach(MonospaceFontFamilies.all, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: $prefs.fontSize, in: Preferences.fontSizeRange, step: 1)
                        Text("\(Int(prefs.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Cursor") {
                Picker("Shape", selection: $prefs.cursorShapeRaw) {
                    ForEach(Preferences.CursorShape.allCases) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                Toggle("Blink cursor", isOn: $prefs.cursorBlink)
            }

            Section {
                LabeledContent("Translucency") {
                    HStack(spacing: 10) {
                        Text("Solid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $prefs.translucency, in: Preferences.translucencyRange, step: 1)
                        Text("Ghost")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                SettingsChrome.footer("Higher values make the window background more translucent and apply a stronger blur.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    static func shellPathProblem(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.hasPrefix("/") {
            return "Enter an absolute path (for example /opt/homebrew/bin/fish). \"\(value)\" will be ignored and the login shell used."
        }
        if !ShellResolver.isExecutableFile(value) {
            return "\(value) is not an executable file; the login shell will be used."
        }
        return nil
    }

    // MARK: - Behavior

    private var behaviorTab: some View {
        Form {
            Section {
                Picker("Bell", selection: $prefs.bellRaw) {
                    ForEach(Preferences.BellStyle.allCases) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                Picker("Option Key", selection: $prefs.optionKeyRaw) {
                    ForEach(Preferences.OptionKey.allCases) { o in
                        Text(o.rawValue).tag(o.rawValue)
                    }
                }
                Picker("Move window with", selection: $prefs.windowDragModifierRaw) {
                    ForEach(Preferences.WindowGestureModifier.allCases) { m in
                        Text(m.rawValue).tag(m.rawValue)
                    }
                }
                Picker("Resize window with", selection: $prefs.windowResizeModifierRaw) {
                    ForEach(Preferences.WindowGestureModifier.allCases) { m in
                        Text(m.rawValue).tag(m.rawValue)
                    }
                }
                Toggle("Confirm closing a tab or quitting while processes are running", isOn: $prefs.confirmClose)
                Toggle("Show notifications from programs", isOn: $prefs.programNotifications)
                Toggle("Automatic shell integration", isOn: $prefs.automaticShellIntegration)
                Toggle("Set locale environment variables (LANG)", isOn: $prefs.setLocaleEnvironment)
                Toggle("Copy selected text automatically", isOn: $prefs.copyOnSelect)
                Picker("Scrollback lines", selection: $prefs.scrollbackLines) {
                    Text("10,000").tag(10_000.0)
                    Text("50,000").tag(50_000.0)
                    Text("100,000").tag(100_000.0)
                    Text("200,000").tag(200_000.0)
                }
                TextField("Shell", text: $prefs.shellPath, prompt: Text("Login shell (or an absolute path)"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if let problem = Self.shellPathProblem(prefs.shellPath) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Terminal")
            } footer: {
                SettingsChrome.footer("Hold the chosen modifier and drag the terminal — or a tab — to move the window; right-drag to resize. A plain tab drag reorders the tabs. Shell integration adds prompt marks and the ssh terminfo fix for zsh and fish without touching your rc files. Shell: leave empty to run your account's login shell, or give the absolute path of another program. Scrollback applies to new sessions (the core caps at 200,000). Notifications: programs that emit OSC 9, OSC 777 or kitty OSC 99 reach Notification Center and dot the tab. A bell while you're in another tab or app bounces the Dock icon and dots the tab, unless Bell is Off and program notifications are off. Changes apply to new sessions.")
            }

            Section {
                Toggle("Reply to color queries (OSC 10/11/12)", isOn: $prefs.colorQueryEnabled)
                Toggle("Allow programs to write the clipboard (OSC 52)", isOn: $prefs.osc52Enabled)
                Toggle("Confirm multi-line pastes at a shell prompt", isOn: $prefs.confirmMultiLinePaste)
            } header: {
                Text("Security")
            } footer: {
                SettingsChrome.footer("OSC 10/11/12 lets TUIs like Codex, Neovim, and tmux query your current foreground, background, and cursor colors for light/dark theme detection. On by default (replies are rate-capped); turn off as a hardening measure if you don't trust your shell's escape-handling — some TUIs will fall back to degraded colors. The paste confirmation asks before pasting text that contains a newline into a program that has not enabled bracketed paste (a bare shell prompt), so a clipboard from an untrusted page can't run commands on your behalf. OSC 52 lets Neovim, tmux (`set-clipboard on`) and `pbcopy`-style helpers over ssh copy into your clipboard; off by default because any program running in the terminal could then overwrite it. Reading the clipboard is never allowed.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section("About") {
                LabeledContent("Version") {
                    Text(SettingsChrome.versionString)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $prefs.autoUpdateChecks)
            } header: {
                Text("Automatic updates")
            } footer: {
                SettingsChrome.footer("Check the release feed at launch and notify when a new version is available.")
            }

            if AppDelegate.isUpdaterConfigured {
                Section {
                    Button {
                        NSApp.sendAction(
                            #selector(AppDelegate.checkForUpdatesFromUI(_:)),
                            to: nil,
                            from: nil
                        )
                    } label: {
                        Text("Check for Updates Now")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
