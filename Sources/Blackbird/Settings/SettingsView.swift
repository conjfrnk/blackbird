import SwiftUI
import AppKit

public struct SettingsView: View {
    @StateObject private var prefs = Preferences.shared

    public init() {}

    public var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintpalette") }
            behaviorTab.tabItem   { Label("Behavior",   systemImage: "keyboard") }
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
