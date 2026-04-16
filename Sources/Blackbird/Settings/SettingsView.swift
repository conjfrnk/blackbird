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

            // Transparency (iTerm2 layout): Opaque ← slider → Transparent,
            // with the numeric value shown to the right.
            HStack {
                Text("Transparency:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Slider(value: $prefs.transparency, in: 0...100, step: 1)
                        Text("\(Int(prefs.transparency))").frame(width: 32, alignment: .trailing)
                    }
                    HStack {
                        Text("Opaque").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Transparent").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer().frame(width: 110)
                Toggle("Keep background colors opaque", isOn: $prefs.keepBgOpaque)
            }

            HStack(alignment: .top) {
                Text("Blur:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Blur content behind the window", isOn: $prefs.blurEnabled)
                    HStack {
                        Slider(value: $prefs.blurRadius, in: 0...30, step: 1)
                            .disabled(!prefs.blurEnabled)
                        Text("\(Int(prefs.blurRadius))").frame(width: 32, alignment: .trailing)
                    }
                    HStack {
                        Text("Small Radius").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Large Radius").font(.caption).foregroundStyle(.secondary)
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
