# Blackbird

A macOS-only terminal emulator. Native AppKit + SwiftUI. Metal-rendered. NSWindow-native tabs. No config files.

## Goals

- Perfect for macOS. Feels like Apple could have shipped it.
- Extremely minimal. Tabs, no splits. Seven settings total.
- Rendering-correct for modern TUIs. VT parsing via `alacritty_terminal` (Rust), the same engine used by Alacritty and Zed.
- Performant and bulletproof. 120 Hz on ProMotion, under 3 ms input-to-pixel, over 200 MB/s PTY throughput, zero allocations in the frame path, fuzz-tested parser.

## Non-goals

- Cross-platform support.
- Splits, multiplexing, session restore.
- Plugins, scripting, config files, AI features, inline image protocols.
- User-editable color palettes beyond shipped themes.

## Stack

- Swift, Metal, AppKit, SwiftUI for the app.
- Rust (`alacritty_terminal`) for the VT core, wrapped in a thin C ABI.
- Universal binary (arm64 + x86_64), macOS 14+.

## Themes

Default, Gruvbox, Solarized, Catppuccin. Each with light and dark variants. "Auto" follows the system appearance.

## Status

In development. Plan 3 (Metal renderer) complete — terminal rendering now uses a Metal glyph atlas with per-cell instanced drawing at 120 Hz on ProMotion. Plan 2's visible behavior is unchanged (white-on-black, single window, login shell, OSC 2 title, ⌘C/⌃C separated); under the hood, CoreText per-character drawing has been replaced with a single instanced draw call per frame. Plans 4-8 remain: tabs + keybindings (Plan 4), settings UI + themes (Plan 5), selection + find + clipboard (Plan 6), test infrastructure (Plan 7), distribution (Plan 8).

## License

MIT.
