# Blackbird compatibility matrix

Status of apps and protocols Blackbird is tested against.

| Symbol | Meaning |
|--------|---------|
| ✅     | Works as expected; no known issues. |
| ⚠️     | Works with caveats — see Notes column. |
| ❌     | Known broken / out of scope. |

## Apps

| App / protocol     | Tested version  | Status | Scenarios verified                                                  | Notes                                                                                  |
|--------------------|-----------------|--------|---------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| Claude Code        | latest CLI      | ✅     | TUI, paste, ⌘C copy, ⌘V paste, OSC 8 click, find (⌘F), large output | Daily driver — Blackbird's design target. Project-wide testbed.                        |
| vim                | 9.1             | ✅     | Scrollback, mouse, ⌘C copy, modifyOtherKeys, true-color              | `TERM=xterm-kitty` (set by Blackbird) is auto-detected.                                |
| neovim             | 0.10            | ✅     | LSP UI, true-color, modifyOtherKeys, Kitty keyboard flags 1+8        | --                                                                                     |
| Emacs (terminal)   | 29              | ✅     | modifyOtherKeys (Ctrl+. and similar), true-color                     | `M-x set-input-mode` works. xterm-256color compat path exercised.                      |
| tmux               | 3.5a            | ⚠️     | Scrollback, mouse, paste, attach/detach                              | OSC 7 is not proxied across panes — multiplexer evades the SSH trust gate (KNOWN_ISSUES § "OSC 7 trust over SSH"). |
| zellij             | 0.40+           | ⚠️     | Scrollback, layouts                                                  | Multiplexer caveats same as tmux.                                                      |
| ssh (OpenSSH)      | 9.x             | ✅     | OSC 7 trust gate engaged                                             | Remote `cwd` is dropped; trust gate fails closed (KNOWN_ISSUES).                       |
| mosh               | 1.4             | ✅     | OSC 7 trust gate engaged                                             | Same as ssh.                                                                           |
| fzf                | 0.55+           | ✅     | UTF-8 box drawing, true-color, fast key responsiveness               | --                                                                                     |
| git (less pager)   | git 2.45+ / less 643+ | ✅ | Scrollback, find, OSC 8 hyperlinks                                   | `LESS=-R --use-color`.                                                                 |
| bat                | 0.24+           | ✅     | true-color                                                           | --                                                                                     |
| lazygit            | 0.42+           | ✅     | mouse, scrollback                                                    | --                                                                                     |
| gh (GitHub CLI)    | 2.x             | ✅     | OSC 8 hyperlinks                                                     | --                                                                                     |
| ranger             | 1.9.x           | ✅     | mouse, true-color                                                    | --                                                                                     |
| htop / btop        | latest          | ✅     | true-color, redraw stress, mouse                                     | --                                                                                     |
| Sixel              | n/a             | ❌     | --                                                                   | **Out of scope.** Blackbird does not implement image protocols (locked non-goal).      |
| Kitty graphics     | n/a             | ❌     | --                                                                   | **Out of scope.** Same rationale.                                                      |
| AppleScript        | n/a             | ❌     | --                                                                   | **Out of scope.** Blackbird is not scriptable (locked non-goal).                       |

## Manual checklist (Connor)

For each ✅ entry, periodically re-verify:

1. Boot Blackbird (Debug build is fine).
2. Open the listed app in a Blackbird tab.
3. Exercise every Scenario in the row.
4. Update Tested version in this file if it bumped.
5. Note any new issues in `KNOWN_ISSUES.md` and downgrade the row's Status to ⚠️.
6. Commit the doc change in the same commit as any related fix.

## Where the byte-level contracts are pinned

The matrix above describes USER-VISIBLE compat status. The byte-level
protocol contracts those apps depend on are pinned by automated tests:

| Contract                                | Pin location                                                        |
|-----------------------------------------|---------------------------------------------------------------------|
| XTGETTCAP `TN`/`Co`/`RGB`/`Smulx`/`Setulc` | `core/tests/xtgettcap.rs` — Rust-side hex-byte assertions.        |
| modifyOtherKeys `CSI 27;<mod>;<cp>~`     | `Tests/BlackbirdTests/KeyEncoderAdversarialTests.swift`             |
| Kitty / mOK / legacy precedence          | `Tests/BlackbirdTests/KeyEncoderProtocolPrecedenceTests.swift`      |
| Kitty keyboard flags 1 / 2 / 8 / 16 †    | `Tests/BlackbirdTests/KittyKeyboardProtocolTests.swift`             |
| OSC 8 emit + scrollback retain + click   | `Tests/BlackbirdTests/HyperlinkTests.swift`                         |
| Cursor shape (DECSCUSR)                  | `Tests/BlackbirdTests/CursorShapeTests.swift`                       |
| OSC 7 SSH trust gate                     | `Tests/BlackbirdTests/CwdTests.swift`                               |
| OSC 133 prompt marks                     | `Tests/BlackbirdTests/OSC133Tests.swift`                            |
| OSC 52 paste (defense-in-depth, opt-in)  | Covered in `core/` and `Tests/BlackbirdTests/HostileInputIntegrationTests.swift` |
| URL detection (http/https/ftp/mailto)    | `Tests/BlackbirdTests/URLDetectorTests.swift`                       |
| IME astral-plane glyphs                  | `Tests/BlackbirdTests/IMEAstralRectTests.swift`, `IMETests.swift`   |
| BBTerm FFI memory invariants             | `Tests/BlackbirdTests/BBTermLifetimeTests.swift`, `core/tests/`     |

If you intentionally bump a contract (e.g., adding a new XTGETTCAP cap),
update the corresponding pin test in the same commit. CI will fail the build
if the contract drifts without a test update.

† Kitty flags row caveats live in `KNOWN_ISSUES.md` § "Kitty flag 4 / 16
— US-layout only": flag 4 falls back to legacy on non-US layouts (Carbon
`UCKeyTranslate` plumbing deferred); flag 16 elides associated-text when
it equals the base codepoint and does not synthesize for IME multi-scalar
commits.

## v0.2 ship status

Compat doc shipped 2026-04-30 as part of v0.2 (spec
`docs/superpowers/specs/2026-04-30-blackbird-v0.2-design.md`). Last
reviewed 2026-05-18 against v0.2.6 — no row state changes in the
v0.2.1–v0.2.6 window; all shipped work was correctness / hardening.
