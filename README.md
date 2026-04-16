# Blackbird

A macOS-only terminal emulator. Native AppKit + SwiftUI. Metal-rendered. NSWindow-native tabs. No config files.

## Goals

- Perfect for macOS. Feels like Apple could have shipped it.
- Extremely minimal. Tabs, no splits. Preferences live in a single native window.
- Rendering-correct for modern TUIs. VT parsing via `alacritty_terminal` (Rust), the same engine used by Alacritty and Zed.
- Performant and bulletproof. 120 Hz on ProMotion, low input-to-pixel latency, fuzz-tested parser, ASan + UBSan on Debug.

## Non-goals

- Cross-platform support.
- Splits, multiplexing, session restore, profiles.
- Plugins, scripting, config files, AI features, inline image protocols.
- User-editable color palettes beyond shipped themes.

## Stack

- Swift, Metal, AppKit, SwiftUI for the app shell, renderer, and Settings UI.
- Rust `alacritty_terminal` 0.26.0 for the VT core, wrapped in a thin C ABI (~10 functions, header auto-generated via `cbindgen`).
- Sparkle 2.x for auto-updates (inert until the appcast URL and EdDSA public key are configured; dev builds no-op).
- Universal binary (arm64 + x86_64), macOS 14+.

## Features

- **Rendering.** Metal GPU renderer, fixed-capacity glyph atlas, 120 Hz opt-in on ProMotion via triple-buffered drawable, right-edge scroll indicator, visual bell flash.
- **VT support.** Application cursor keys (DECCKM), bracketed paste, X10 and SGR mouse reporting including motion and drag, F1–F12, 24-bit color, DECSCUSR cursor shapes (block/bar/underline), CSI u modifier encoding, 10,000-line scrollback.
- **Tabs and windows.** Native `NSWindow` tab group, per-tab shell session, confirmation before closing a window with multiple tabs, content-size snap to whole cells, ⌘-drag anywhere to move the window, ⌘ + right-drag to resize from the nearest corner, auto-close on shell exit.
- **Selection and clipboard.** Character / word / line / rectangular selection, ⌘C copies, ⌘V pastes (bracketed when the TUI requests it), ⌃C always sends `0x03` and never copies, right-click menu, OSC 52 remote clipboard writes with an opt-out toggle.
- **Find.** ⌘F opens the bar, ⌘G / ⌘⇧G step through matches across visible buffer and scrollback.
- **URLs.** ⌘-click on any `http`/`https`/`ftp`/`file` URL opens it in the default browser.
- **Themes.** Default, Gruvbox, Solarized, Catppuccin — each with light and dark palettes. Auto mode follows `NSApp.effectiveAppearance`; changes apply live to every open session.
- **Settings.** SwiftUI window hosted through AppKit, backed by `@AppStorage` — Theme mode, Theme, Font family (monospace only), Font size, Cursor blink, Bell, Option key (Meta / Native), Confirm close, OSC 52 toggle, auto-update check.
- **Fonts.** Hack Nerd Font Mono ships inside the bundle (Regular / Bold / Italic / Bold-Italic); any monospaced family installed on the system is selectable in Settings. ⌘+ / ⌘− / ⌘0 adjust size live.
- **Distribution.** Tag-triggered GitHub Actions workflow builds the universal binary, signs with Developer ID, notarizes, staples, and attaches the DMG to a GitHub release.

## Keybindings

| Shortcut          | Action                           |
|-------------------|----------------------------------|
| ⌘T                | New tab                          |
| ⌘N                | New window                       |
| ⌘W                | Close tab                        |
| ⌘⇧W               | Close window (all tabs)          |
| ⌘1 … ⌘9           | Select tab 1–9                   |
| ⌘⇧[ / ⌘⇧]         | Previous / next tab              |
| ⌘,                | Settings                         |
| ⌘C / ⌘V           | Copy / paste                     |
| ⌘A                | Select visible grid              |
| ⌘K                | Clear viewport + scrollback      |
| ⌘F / ⌘G / ⌘⇧G     | Find / next / previous           |
| ⌘+ / ⌘− / ⌘0      | Font size bigger / smaller / reset |
| ⌘-click URL       | Open in default browser          |
| ⌘-drag            | Move window                      |
| ⌘ + right-drag    | Resize from nearest corner       |

## Building from source

Requirements:

- macOS 14+
- Xcode 16.2 (matches CI)
- Rust stable with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

From a clean checkout:

```sh
xcodegen generate             # generates Blackbird.xcodeproj from project.yml
scripts/build-core.sh         # builds the universal Rust static lib
xcodebuild -scheme Blackbird build
```

The Xcode target runs `scripts/build-core.sh` as a pre-build step, so `xcodebuild build` after `xcodegen generate` also works from scratch.

## Tests

```sh
# Rust core — fmt, clippy, unit, golden parser tests
cargo fmt --all -- --check
cargo clippy -p blackbird_core --all-targets -- -D warnings
cargo test  -p blackbird_core --lib --tests

# Swift — PTY, TerminalSession, MetalRenderer, GlyphAtlas, KeyEncoder, TerminalView
xcodebuild test \
  -project Blackbird.xcodeproj \
  -scheme Blackbird \
  -destination 'platform=macOS,arch=arm64'
```

The Debug scheme enables Address and Undefined-Behaviour sanitizers. A cargo-fuzz target for `bb_term_input` lives in `core/fuzz/` — run manually with `cargo +nightly fuzz run fuzz_term_input`. `scripts/smoke.sh` launches the built app for three seconds and checks it exits cleanly.

## Packaging a release

`scripts/release.sh` builds a universal Release binary, verifies the code signature, and writes a DMG to `./dist/`. Pass `notarize` to also submit to Apple's notary service and staple the ticket (requires `APPLE_ID`, `APP_SPECIFIC_PASSWORD`, `TEAM_ID`).

The `release.yml` workflow runs the same flow on any `v*` tag push using repository secrets for the Developer ID certificate and notarization credentials. Missing secrets produce an unsigned DMG (useful for dry-run tags); with them, the release is signed, notarized, stapled, and uploaded to the matching GitHub release.

`scripts/make-appcast.sh` generates a Sparkle `<item>` snippet for the freshest DMG in `./dist/`, ready to paste into a hosted `appcast.xml`.

## License

MIT.
