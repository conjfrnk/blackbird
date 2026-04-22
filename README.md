<p align="center">
  <img src="design/icon/Blackbird-1024.png" alt="Blackbird" width="160" height="160">
</p>

# Blackbird

A minimal, native terminal emulator for macOS. AppKit + SwiftUI, Metal-rendered, no config files.

## What it is

- **macOS-only.** Built to feel like something Apple could have shipped.
- **Minimal.** Tabs, no splits. Preferences live in a single native window.
- **Accurate.** VT parsing via Rust's `alacritty_terminal` — the same engine as Alacritty and Zed.
- **Fast.** 120 Hz on ProMotion, low input-to-pixel latency, GPU-rendered.

Not interested in: cross-platform, splits, session restore, profiles, plugins, scripting, config files, AI, inline images.

## Highlights

- **Rendering.** Metal GPU renderer hitting native 120 Hz on ProMotion. Per-row caching redraws only what changed.
- **Terminal compatibility.** 24-bit color, Kitty keyboard protocol, synchronized output, bracketed paste, mouse reporting, focus events, 10k-line scrollback. Five underline styles with independent colors (LSP squigglies work).
- **Tabs.** Native `NSWindow` tab groups, per-tab shell session, confirmation before closing multi-tab windows.
- **Input.** Full IME support for CJK, dead keys, trackpad pinch-to-zoom.
- **Find.** ⌘F with scrollback search.
- **URLs.** ⌘-click opens `http`/`https`/`ftp`/`mailto`. Other schemes are blocked for safety. OSC 8 hyperlinks supported.
- **Clipboard.** ⌘C/⌘V with paste scrubbing (strips C0 controls and Unicode bidi overrides). OSC 52 remote writes supported, capped at 1 MiB, toggleable.
- **Themes.** Default, Gruvbox, Solarized, Catppuccin. Light/dark auto-follows the system.
- **Shell integration (opt-in).** Bundled OSC 133 snippets for bash/zsh/fish enable prompt-jumping with ⌘⇧↑/⌘⇧↓.
- **Fonts.** Hack Nerd Font Mono ships in the bundle. Any installed monospaced family is selectable.
- **Auto-updates.** Sparkle 2.x, signed appcast.

## Keybindings

| Shortcut          | Action                           |
|-------------------|----------------------------------|
| ⌘T / ⌘N / ⌘W      | New tab / new window / close tab |
| ⌘1 … ⌘9           | Select tab 1–9                   |
| ⌘⇧[ / ⌘⇧]         | Previous / next tab              |
| ⌘,                | Settings                         |
| ⌥⌘R               | Rename active tab                |
| ⌘C / ⌘V / ⌘A      | Copy / paste / select visible    |
| ⌘K                | Clear viewport + scrollback      |
| ⌘F / ⌘G / ⌘⇧G     | Find / next / previous           |
| ⌘+ / ⌘− / ⌘0      | Font bigger / smaller / reset    |
| ⌘⇧↑ / ⌘⇧↓         | Jump to previous / next prompt   |
| ⌘-click URL       | Open in default browser          |
| ⌘-drag            | Move window                      |
| ⌘ + right-drag    | Resize from nearest corner       |

## Building

Requirements: macOS 14+, Xcode 16.2, Rust stable with both Apple targets, [`xcodegen`](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
scripts/build-core.sh
xcodebuild -project Blackbird.xcodeproj -scheme Blackbird build
```

The Xcode target runs `build-core.sh` as a pre-build step, so `xcodebuild build` alone works after `xcodegen generate`.

## Tests

```sh
# Rust core
cargo fmt --all -- --check
cargo clippy -p blackbird_core --all-targets -- -D warnings
cargo test  -p blackbird_core --lib --tests

# Swift
xcodebuild test \
  -project Blackbird.xcodeproj \
  -scheme Blackbird \
  -destination 'platform=macOS,arch=arm64'
```

The Debug scheme enables ASan and UBSan. A cargo-fuzz target for the parser lives in [`core/fuzz/`](core/fuzz/README.md).

## Performance

CI gates on parser throughput (`plain_text` ≥ 25 MiB/s, `binary_garbage` ≥ 15 MiB/s, `ansi_log` ≥ 30 MiB/s over 64 MiB payloads) and long-session memory stability. Dev-machine numbers typically run 2–3× the floors.

See [`docs/benchmarks/vtebench-2026-04-20.md`](docs/benchmarks/vtebench-2026-04-20.md) for a cross-terminal throughput comparison (Terminal.app, iTerm2, Ghostty, Alacritty, Blackbird).

## License

MIT.
