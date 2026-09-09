# Security Posture

Blackbird is a macOS-only terminal emulator. Its attack surface is:

1. **Shell output bytes** — arbitrary input from a remote, a compromised
   process, or a user-piped file. Every byte passes through
   `alacritty_terminal`'s VT parser before touching any state.
2. **User keystrokes and paste content** — sourced from system input.
   Pasted content may be web-origin and contain hidden hostile payloads.
3. **Drag-and-drop file URLs** — paths with shell metacharacters.
4. **OSC 8 hyperlinks and regex-detected URLs** — URLs encoded or
   printed by the remote; opened on ⌘-click.
5. **Terminal replies** — the few queries Blackbird answers (DSR, DA,
   colour queries) write bytes back into the PTY.

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
`sanitizeBracketedPaste` (when the foreground app has enabled
bracketed paste) → `convertLoneCRToLF` before reaching the PTY. The
scrub functions live in `Sources/Blackbird/Terminal/PasteSanitizer.swift`
and are driven from `TerminalView+Paste.swift`. Tests in
`Tests/BlackbirdTests/TerminalViewTests.swift` (`test_sanitize*`,
`test_stripBidi*`, `test_paste*`).

- C0 controls (0x00–0x1F except TAB/LF/CR) and DEL → replaced with space.
  Blocks CVE-2026-26982 class (Ctrl+C / ESC inside paste escaping the
  bracketed-paste frame).
- C1 controls (UTF-8 `0xC2 0x80..0x9F`) → replaced with space. Closes
  the ESC-free CSI / OSC / DCS alternates that xterm's
  `allowC1Printable=off` default disables.
- Bidi formatting controls (U+061C, U+180E, U+200E/F, U+202A–E,
  U+2066–9) and related invisible characters (soft hyphen, zero-width
  set) → removed. Blocks Trojan Source (CVE-2021-42574) class.
  Variation selectors (U+FE0F etc.) are deliberately kept — stripping
  them corrupted every emoji paste.
- Optional: the `bb.confirmMultiLinePaste` preference (default off,
  `defaults write` only — no Settings toggle) prompts before a paste
  containing a newline reaches a shell that has *not* requested
  bracketed paste — the one case where an embedded newline executes.
- `ESC [ 201 ~` bracketed-paste terminator → removed. Blocks nested
  paste-injection where pasted content would close the paste frame
  and let subsequent bytes execute as shell input.

### Output sanitization on copy / OSC 52

`copy(_:)` runs the scrub chain (control-byte sanitisation +
bidi-override stripping) before `NSPasteboard.setString`. Prevents
Blackbird from transitively poisoning other apps' pastes with bidi /
control bytes received from a hostile remote. Same code path as
inbound paste — symmetric.

OSC 52 (remote shell writes to your clipboard) is more nuanced.
**The Rust core pins `osc52: Osc52::Disabled`** at `bb_term_new`, so
`Event::ClipboardStore` is never emitted from alacritty's parser.
The Swift `.osc52Clipboard` handler in `TerminalSession`, including
its size cap, scrub chain, and `osc52Enabled` preference toggle, is
therefore unreachable defense-in-depth: if a future change ever
flips the Rust gate to `OnlyCopy` or `CopyPaste`, the Swift gate
already exists to scrub-and-cap before `NSPasteboard.setString`.
The `osc52Enabled` user preference is wired and persisted but has
no observable effect today (audit SI-02). When triaging an "OSC 52
isn't writing to my clipboard" report, the answer is: by design.

### URL scheme allowlist

OSC 8 hyperlinks and regex-detected URLs are filtered through
`OSC8URLPolicy.isAllowed` (`Sources/Blackbird/Terminal/HyperlinkResolver.swift`)
on every hover and click path before `NSWorkspace.open`. Allowlist:
`http`, `https`, `mailto`. `http`/`https` additionally require a host,
reject userinfo (`https://user:pw@host/`), and reject non-ASCII /
punycode hosts (IDN homograph defence); `mailto:` rejects header
injection. Notable omissions:

- `ftp://` rejected (audit S4-022) — macOS 14+ ships no default FTP
  client, so the click falls to whatever the user installed, and FTP
  URLs routinely carry plaintext credentials in the authority
  component. Note the plain-text detector regex in `URLDetector.swift`
  still *matches* `ftp://` so soft-wrapped reconstruction stays
  uniform, but the allowlist rejects it, so an `ftp://` URL is never
  underlined on ⌘-hover and never opens.

- `file://` rejected — `NSWorkspace.open` on `.command` / `.app` /
  `.pkg` / `.workflow` / `.terminal` / `.scpt` executes the payload.
  Users with a legitimate local path should `open <path>` from the
  shell instead.
- `javascript:`, `data:`, `x-man-page:`, custom handlers — all
  rejected. Blocks CVE-2023-46321 (iTerm2 OSC 8 argument-injection)
  class.

### Reply policy for window / colour queries

Blackbird never replies to:

- CSI 20t (report icon label)
- CSI 21t (report window title) — HD Moore 2003 class

These would echo shell-controlled bytes (a title the shell itself set
via OSC 1/2) back to the PTY. Pinned via tests in
`core/tests/terminal_replies.rs`.

OSC 10 / 11 / 12 `?` colour queries (foreground / background / cursor)
**are answered by default since v0.6.0** (issue #24). Modern TUIs —
Codex CLI, Neovim, delta, fzf, tmux — probe OSC 10/11 at startup for
light/dark detection, and a silent drop degrades them to a colourless
fallback after a reply-timeout stall. iTerm2, kitty, Alacritty, WezTerm
and Ghostty all reply by default. What makes this acceptable:

- **What is answered.** Only the three palette slots, formatted from
  Blackbird's *own* palette table. No shell-controlled bytes are ever
  echoed — the reply carries colour values Blackbird chose, not
  anything the remote wrote.
- **Rate cap.** Replies are capped at 32 per second per terminal
  (`COLOR_QUERY_REPLY_PER_SECOND`, `core/src/rate_limit.rs`) and the
  pending-query queue holds at most 256 entries between drains
  (`COLOR_REQUEST_QUEUE_CAP`, `core/src/callback.rs`), so a hostile
  `printf '\e]11;?\a'` loop cannot use Blackbird as a PTY-write
  amplifier. Excess queries are dropped, with a one-shot log per
  episode.
- **Opt-out.** Settings › Security › "Reply to color queries
  (OSC 10/11/12)" (`bb.colorQueryEnabled`). Off is the hardening
  position for shells whose escape handling you do not trust (the
  zsh-vi-mode command-round-trip class on older shells); some TUIs then
  fall back to degraded colours.
- **Fail-closed core.** The Rust core initialises
  `color_query_enabled: false` at `bb_term_new`; the app flips it on
  through `bb_term_set_color_query_enabled` from the preference at
  session start and on every preference change. A core embedded without
  the Swift app therefore stays silent, and
  `terminal_replies.rs::osc_10_11_color_queries_are_silent` pins that
  default.

Other reply-producing queries (DSR, CPR, DA1/DA2, DECRQSS, XTGETTCAP)
share a separate 32-per-second PTY-write cap
(`PTY_WRITE_REPLY_PER_SECOND`), also pinned in `terminal_replies.rs`.
DECRQSS never echoes attacker-controlled selector bytes.

### OSC 7 working-directory reports

OSC 7 (`file://host/path`) is parsed by a dedicated scanner in the Rust
core (`core/src/osc.rs`), not by alacritty. A report is dropped unless
it is a `file://` URL ≤ 4 KiB that percent-decodes to valid UTF-8 with
no NUL, C0/C1 control, or bidi-formatting characters, is absolute, and
contains no `..` traversal segment. Ingest is capped at 32 per second.
On the Swift side (`CwdTracker`) the path is only trusted when the
report classifies as local; reports from an SSH / remote namespace are
dropped fail-closed (see `KNOWN_ISSUES.md` § "OSC 7 trust over SSH").
The stored cwd is consumed only by new-tab cwd inheritance
(`CwdResolver`) and the window / tab title.

### Shell integration injection

Since v0.6.0 automatic shell integration is **on by default**
(`bb.automaticShellIntegration`, Settings › Terminal). It never edits
user rc files: zsh gets `ZDOTDIR` pointed at a Blackbird-owned
bootstrap `.zshenv` under `~/.local/share/blackbird/shell` that
restores the original `ZDOTDIR`, chains the user's own `.zshenv`, and
defers loading the OSC 133 prompt marks plus the ssh terminfo wrapper;
fish gets a `fish/vendor_conf.d/blackbird.fish` on `XDG_DATA_DIRS`.
bash is deliberately not injected (login bash ignores `--rcfile`) —
bash users source the bundled `Resources/shell/osc133.bash` manually.
The bootstrap tree is materialised from the bundle once per process
and re-created at spawn if it has gone missing; if that fails the
shell spawns with no injection at all. Turning the toggle off affects
the next spawned shell, never live ones. Implemented in
`Sources/Blackbird/Terminal/ShellIntegration.swift`.

### PTY child hygiene (post-fork, pre-exec)

`PTY.spawn` in `Sources/Blackbird/Terminal/PTY.swift`:

- Scrubs launchd / XPC / CoreFoundation environment:
  `XPC_SERVICE_NAME`, `XPC_FLAGS`, `__CF_USER_TEXT_ENCODING`,
  `OS_ACTIVITY_DT_MODE`, `OS_ACTIVITY_MODE`,
  `__XCODE_BUILT_PRODUCTS_DIR_PATHS`, `__XPC_DYLD_LIBRARY_PATH`,
  `LaunchInstanceID`, `SECURITYSESSIONID`, plus the dyld injection
  surface (`DYLD_LIBRARY_PATH`, `DYLD_INSERT_LIBRARIES`,
  `DYLD_FRAMEWORK_PATH`, `DYLD_FALLBACK_*`, `DYLD_PRINT_*`),
  `MallocNanoZone`, and the `CA_DEBUG_TRANSACTIONS` /
  `CA_ASSERT_MAIN_THREAD_TRANSACTIONS` debug flags. The list is pinned
  by a unit test (`PTY.scrubbedParentEnvVars`).
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
- OSC 8 URI capped at 4 KiB per link and 1 MiB total interned across
  the session (Rust, `core/src/snapshot.rs`); over the ceiling new
  links degrade to plain text rather than evicting.
- OSC 7 URL capped at 4 KiB and 32 ingests/s; OSC title events 32/s;
  bell 16/s; prompt marks 240/s; PTY-write replies and colour-query
  replies 32/s each (`core/src/rate_limit.rs`). Over-cap events are
  dropped, not queued; logging is latched so the logger cannot itself
  become the amplifier.
- Scrollback capped at 200 000 lines (Rust, `SCROLLBACK_MAX` in
  `bb_term_new`) — 2× the Blackbird default of 100 000 (Swift,
  `BBTerm.init`). Paired with the 1000-col grid ceiling, this bounds
  per-terminal worst-case allocation to a finite envelope rather than
  growing unboundedly with PTY writes.
- OSC 52 payload capped at 1 MiB (Swift,
  `TerminalSession.osc52MaxBytes`) — currently unreachable; OSC 52 is
  pinned `Disabled` in the Rust core. See "Output sanitization on
  copy / OSC 52" above for the layered defence.
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
- Sparkle 2.9.2 (≥ 2.6.4 signed-feed-bypass fix). The appcast at
  `https://blackbird-terminal.com/appcast.xml` is live and EdDSA-signed
  (`SUPublicEDKey` in `project.yml`; the private key never leaves the
  maintainer's machine — `scripts/publish-update.sh` is local-only).
  Updater auto-start is still gated in `App.swift`
  (`isUpdaterConfigured`) on both keys being present, and
  `SUEnableInstallerLauncherService` stays off by policy: Sparkle
  installs in-place, so the root-capable installer-launcher XPC helper
  is never registered.

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

---

Last reviewed 2026-09-09 against v0.8.0.
