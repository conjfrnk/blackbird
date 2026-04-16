import SwiftUI
import AppKit

public struct SettingsView: View {
    @StateObject private var prefs = Preferences.shared

    public init() {}

    public var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintpalette") }
            behaviorTab.tabItem   { Label("Behavior",   systemImage: "keyboard") }
            updatesTab.tabItem    { Label("Updates",    systemImage: "arrow.down.circle") }
        }
        .frame(minWidth: 480, minHeight: 280)
        .padding()
    }

    private var appearanceTab: some View {
        Form {
            Picker("Theme Mode", selection: $prefs.themeModeRaw) {
                ForEach(Preferences.ThemeMode.allCases) { m in
                    Text(m.displayName).tag(m.rawValue)
                }
            }
            Picker("Theme", selection: $prefs.themeRaw) {
                ForEach(Theme.allCases) { t in
                    Text(t.displayName).tag(t.rawValue)
                }
            }
            Picker("Font", selection: $prefs.fontName) {
                ForEach(monospaceFamilies(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            HStack {
                Text("Size: \(Int(prefs.fontSize))")
                Slider(value: $prefs.fontSize, in: 9...32, step: 1)
            }

            Divider()

            // Single combined translucency slider (1 = opaque, 10 = very
            // see-through with heavy blur). Default 3 is a subtle lift.
            HStack {
                Text("Translucency:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Slider(value: $prefs.translucency, in: 1...10, step: 1)
                        Text("\(Int(prefs.translucency))").frame(width: 32, alignment: .trailing)
                    }
                    HStack {
                        Text("Solid").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Ghost").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var behaviorTab: some View {
        Form {
            Toggle("Cursor Blink", isOn: $prefs.cursorBlink)
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
            Toggle("Confirm close while running", isOn: $prefs.confirmClose)

            Divider()
            Toggle("Remote clipboard write (OSC 52)", isOn: $prefs.osc52Enabled)
            Text("When on, remote shells (e.g., a server emitting OSC 52 or `tmux set -g set-clipboard on`) can write text directly to your Mac clipboard. Turn off if you're working on untrusted remotes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var updatesTab: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $prefs.autoUpdateChecks)
            Text("Blackbird can check the official release feed at app launch and notify you when a new version is available. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    /// Enumerate monospaced font families available on the system. A family
    /// is "monospace" if its regular face reports `isFixedPitch`. Cached per
    /// render; NSFontManager keeps its own internal cache.
    private func monospaceFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { name in
                if let font = NSFont(name: name, size: 12) {
                    return font.isFixedPitch
                }
                return false
            }
            .sorted()
    }
}
