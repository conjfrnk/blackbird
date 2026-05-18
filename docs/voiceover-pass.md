# VoiceOver manual pass — Blackbird v0.2

Blackbird's `TerminalView` advertises `.textArea` and implements the line /
character / range accessors VoiceOver expects. Automated tests cover the
contract, but only a real VO session confirms the experience works for
someone using it.

## Setup

1. Build Blackbird Debug (fresh checkout — `project.yml` is canonical, the
   `.xcodeproj` is gitignored):
   ```
   cd ~/projects/blackbird
   xcodegen generate
   xcodebuild build -project Blackbird.xcodeproj -scheme Blackbird -configuration Debug -destination "platform=macOS,arch=arm64"
   ```
2. Launch the resulting app from
   `~/Library/Developer/Xcode/DerivedData/Blackbird-*/Build/Products/Debug/Blackbird.app`.
   (For a Release build, use a signed build from `dist/`.)
3. Enable VoiceOver: ⌘F5 (or System Settings → Accessibility → VoiceOver).

## Checks

For each, record `[x]` / `[!]` (caveat) / `[ ]` (untested).

### Focus and announcement

- [ ] **First focus**: Tab into the terminal. VO should announce
      "Terminal, text area".
- [ ] **Find bar in container mode**: Open the find bar with ⌘F. VO should
      announce the search field; tabbing should reach the prev/next/close
      buttons.

### Read-all (continuous reading)

- [ ] **VO+A** ("Read All from cursor") reads every visible line, in order.
      Stops cleanly at the bottom.
- [ ] **VO+L** ("Read Current Line") reads exactly the line under the
      cursor.

### Line navigation

- [ ] **VO+Down** moves to the next line and reads it.
- [ ] **VO+Up** moves to the previous line and reads it.
- [ ] **VO+Cmd+Down** ("Read from current line down") works without hangs.

### Character navigation

- [ ] **VO+Right** advances one character; reads the new character.
- [ ] **VO+Left** retreats one character; reads it.
- [ ] **VO+Right** across an emoji ("a😀b") reads the emoji as a single
      character, not as a surrogate pair.

### Word navigation

- [ ] **VO+Option+Right** advances one word; reads it.
- [ ] **VO+Option+Left** retreats one word; reads it.

### Find bar

- [ ] Open the find bar (⌘F). VO+arrows reach the text field, the prev/next
      buttons, and the close button. Closing returns focus to the terminal
      with VO announcing the swap.

### Settings panel

- [ ] Open Settings (⌘,). VO+arrows reach every control: Theme picker,
      Font picker, Cursor toggles, Bell radio, Confirm-Close toggle,
      OSC 52 / Color-query toggles, Updates section. No control is mouse-
      only.

### Tab navigation

- [ ] **⌘T** opens a new tab. VO announces the new tab's terminal.
- [ ] **⌘1** through **⌘9** select the corresponding tab. VO announces
      the selected tab's content.
- [ ] **⌃⇥** / **⌃⇧⇥** cycle tabs. VO announces each.

### Stress / no-hang

- [ ] Run a 5-minute Read All over `man bash` in scrollback. No hangs,
      no main-thread beachballs. (If a hang happens, a hang report
      appears in Settings → Diagnostics.)
- [ ] Trigger an unsupported VO+Shift+arrow selection drag. Blackbird
      logs once via `log show --predicate 'subsystem ==
      "dev.conjfrnk.blackbird" && category == "accessibility"'` and is
      otherwise a no-op (no crash, no garbled audio).

## Known limitations (v0.2)

- **Setting selection via VoiceOver is a no-op.** `Selection`'s rectangular
  grid model can't be expressed as a single `NSRange` cleanly when wrapped
  lines or rectangular shapes are involved. Logged once per process via
  `os.Logger`. Tracked for v1.0.
- **`accessibilityFrame(for range:)` returns the view's full bounds**
  (instead of per-cell rectangles). ZoomText / Hover Text won't crop
  tightly to the selected character. Tracked for v1.0.
- **Scrollback** is not exposed to VO — only the visible region. Scrolling
  up exposes earlier rows when the snapshot updates. A virtualised
  scrollback a11y tree is out of scope for v0.2.

## Sign-off

Connor, or any beta user with VoiceOver experience, please run through
the checklist above and record the result here:

| Date | Tester | Pass? | Notes |
|------|--------|-------|-------|
|      |        |       |       |
|      |        |       |       |

## Where the contract is pinned in code

- `Sources/Blackbird/Terminal/TerminalView+Accessibility.swift` — role,
  accessors, selection no-op + log.
- `Tests/BlackbirdTests/AccessibilityTests.swift` — 30 tests covering
  role, value, line/char accessors, range conversions, selection
  contract, snapshot-identity cache invalidation, astral-codepoint
  round-tripping, and trailing-newline line counting (so the dominant
  production case — shell prompt on a blank bottom row — gets the
  right line count for VO navigation).
- `KNOWN_ISSUES.md` — v0.2 deferral entries reference this doc for the
  manual pass.
