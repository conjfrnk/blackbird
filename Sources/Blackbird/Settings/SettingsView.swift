import SwiftUI
import AppKit

public struct SettingsView: View {
    // `Preferences.shared` is a long-lived singleton; using `@ObservedObject`
    // (rather than `@StateObject`) makes it explicit that SettingsView doesn't
    // own the object's lifecycle — the view just observes a pre-existing one.
    // `@StateObject` would still function here because its init closure is
    // evaluated once, but it adds lifecycle semantics SettingsView doesn't
    // need and reads wrong at a glance.
    @ObservedObject private var prefs = Preferences.shared

    /// Cached list of monospaced font families on the system. Built once
    /// per process launch and reused across SettingsView renders —
    /// without this, SwiftUI re-enumerates NSFontManager on every body
    /// re-eval (every slider drag, every toggle), turning the 100+
    /// font lookup into ~120× per second of wasted work during drags.
    /// Fonts rarely change at runtime; if a user installs a new one
    /// they can restart Settings to see it.
    private static let cachedMonospaceFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { name in
                guard let font = NSFont(name: name, size: 12) else { return false }
                return font.isFixedPitch
            }
            .sorted()
    }()

    /// Human-readable "short (build)" version string used in the Updates
    /// tab. Read once per launch; neither value changes at runtime.
    private static let versionString: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return short == build ? short : "\(short) (\(build))"
    }()

    /// Section-footer helper. SwiftUI's grouped Form on macOS treats a bare
    /// `Text` in a footer as label-column content: it gets the narrow left
    /// column and defaults `multilineTextAlignment` to `.center`, producing
    /// the ragged centered column the user sees. `.frame(maxWidth: .infinity,
    /// alignment: .leading)` alone doesn't fix it — that only says "accept
    /// up to ∞ if offered," and the parent never offers more than the label
    /// column. The HStack with a trailing `Spacer(minLength: 0)` is the
    /// standard workaround: HStack is a flexible-width container the footer
    /// parent does propose the full row to, and the Spacer absorbs whatever
    /// is left of the Text so the Text pins leading.
    /// `.multilineTextAlignment(.leading)` is the explicit override of the
    /// Form's centered default — the HStack on its own would still leave
    /// wrapped lines center-aligned within the Text's frame.
    private static func footer(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    public init() {}

    public var body: some View {
        tabs.frame(minWidth: 520, minHeight: 520)
    }

    // `.containerBackground(for: .window)` is macOS 15+. On older systems
    // the NSVisualEffectView installed behind the hosting controller
    // (see SettingsWindowController) already shows through any non-
    // opaque SwiftUI layers, so the guard is purely to adopt the
    // explicit-clear-window API when available.
    @ViewBuilder
    private var tabs: some View {
        let base = TabView {
            appearanceTab.tabItem  { Label("Appearance",  systemImage: "paintpalette") }
            behaviorTab.tabItem    { Label("Behavior",    systemImage: "keyboard") }
            updatesTab.tabItem     { Label("Updates",     systemImage: "arrow.down.circle") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        if #available(macOS 15.0, *) {
            base.containerBackground(.clear, for: .window)
        } else {
            base
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
                    ForEach(Self.cachedMonospaceFamilies, id: \.self) { name in
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

            // Translucency lives in its own "Window" section — the previous
            // layout left it as a headerless row that visually floated below
            // the Cursor section. Pairing it with the explanatory footer under
            // a proper header also matches how every other pref group in this
            // file is organized. SwiftUI's titleKey+footer convenience doesn't
            // exist on macOS 14, so we spell out header:/footer: builders.
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
                Self.footer("Higher values make the window background more translucent and apply a stronger blur.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                Toggle("Confirm quit while processes are running", isOn: $prefs.confirmClose)
            } header: {
                Text("Terminal")
            } footer: {
                Self.footer("Hold the chosen modifier and drag the terminal — or a tab — to move the window; right-drag to resize. A plain tab drag reorders the tabs.")
            }

            Section {
                // The "Allow remote clipboard writes (OSC 52)" toggle was
                // removed (audit S4-001): the Rust core hardcodes
                // `Osc52::Disabled` with no FFI to change it, so OSC 52 writes
                // never reach the Swift side — the toggle advertised a
                // capability that could never take effect. The `osc52Enabled`
                // preference and the Swift-side scrub / size-cap handler are
                // retained as dormant defence-in-depth (and stay unit-tested)
                // for if the core ever opts back in, but they are no longer
                // user-exposed.
                Toggle("Reply to color queries (OSC 10/11/12)", isOn: $prefs.colorQueryEnabled)
            } header: {
                Text("Security")
            } footer: {
                Self.footer("OSC 10/11/12 lets TUIs like Neovim and tmux query your current foreground, background, and cursor colors. Off by default — the reply travels back through the PTY, where a misbehaving shell could attempt to interpret it as commands.")
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
                    Text(Self.versionString)
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
                Self.footer("Check the release feed at launch and notify when a new version is available.")
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
