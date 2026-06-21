import Foundation
import BBCore

/// Maps keyboard input into the byte sequences the shell expects.
///
/// Encodes two protocols:
///   * **Legacy** (default): bare ASCII, Return=CR, Tab=HT, Backspace=DEL,
///     Ctrl+printable=C0 byte, Option-as-Meta (ESC+), xterm `CSI 1;M <final>`
///     for modified arrows / F-keys, CSI Z for Shift+Tab.
///   * **Kitty progressive enhancement** (active when the TUI has pushed
///     flag 1 via `ESC[>1u` and `mode` contains `.disambiguateEscCodes`):
///     modified Enter/Esc/Tab/Backspace become `CSI <cp>;<mod>u`, and
///     Ctrl+letter combinations that alias C0 control codes (Ctrl+i, Ctrl+m,
///     Ctrl+[, Ctrl+h) also switch to CSI u so the TUI can tell them apart
///     from the unmodified Tab/Enter/Esc/Backspace keys they collide with.
///
/// Shift+Enter in Claude Code depends on the kitty path.
public final class KeyEncoder {

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let shift    = Modifiers(rawValue: 1 << 0)
        public static let control  = Modifiers(rawValue: 1 << 1)
        public static let option   = Modifiers(rawValue: 1 << 2)
        public static let command  = Modifiers(rawValue: 1 << 3)
    }

    public enum SpecialKey {
        case up, down, right, left
        case home, end, pageUp, pageDown
        case delete, insert
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        // Keypad keys — only routed through encodeSpecial when the TUI
        // has enabled application-keypad mode (DECPAM, `appKeypad`).
        // Without the mode bit the legacy bytes (plain digits, plain
        // operators) are correct, so we let those chars take the normal
        // `encode(chars:)` path. Audit key-encoder F9.
        case kp0, kp1, kp2, kp3, kp4, kp5, kp6, kp7, kp8, kp9
        case kpEnter, kpPlus, kpMinus, kpMultiply, kpDivide
        case kpDecimal, kpEquals
    }

    /// Kitty-protocol event-type sub-parameter (`CSI <cp>;<mod>:<event>u`).
    /// Only surfaces in the CSI-u output when `reportEventTypes` is set;
    /// the legacy path ignores it entirely.
    public enum EventType: Int {
        case press   = 1
        case `repeat` = 2
        case release = 3
    }

    /// If true, Option modifier produces ESC+char (traditional Meta behavior).
    /// If false, Option produces the character the OS assigned (e.g., Option-e -> accent).
    /// Resolved from `Preferences.shared.optionKey` at construction; the
    /// encoder is rebuilt by `TerminalView.syncEncoderFromPreferences()`
    /// when the user toggles "Option Key" in Settings.
    public let optionIsMeta: Bool

    public init(optionIsMeta: Bool = true) {
        self.optionIsMeta = optionIsMeta
    }

    /// Encode a character sequence plus modifiers into bytes.
    ///
    /// - Parameter mode: terminal mode bits from the current snapshot.
    ///   When `mode.contains(.disambiguateEscCodes)` the kitty progressive
    ///   enhancement path is active; otherwise we emit legacy bytes.
    /// - Parameter eventType: press / repeat / release. When mode contains
    ///   `.reportEventTypes`, CSI-u output carries the event type as a
    ///   sub-parameter of the modifier field. In all other cases:
    ///   `.press` / `.repeat` encode identically to the default
    ///   behaviour; `.release` returns empty `Data` because the key-down
    ///   code path is the only one that emits bytes to the PTY.
    public func encode(
        chars: String,
        modifiers: Modifiers,
        mode: BBTermMode = [],
        eventType: EventType = .press
    ) -> Data {
        // Release events are reported ONLY when Kitty flag 2 is active
        // AND the key would have gone through the CSI-u path. Everything
        // else drops the release — legacy TUIs get confused by post-key
        // traffic they didn't ask for.
        // Non-press events (release, repeat) only leave the encoder
        // when the TUI has opted into `reportEventTypes` (Kitty flag 2).
        // Every other protocol path expects press-only traffic; the CSI u
        // / CSI 27 / legacy shapes have no way to distinguish repeat from
        // press otherwise.
        if eventType != .press && !mode.contains(.reportEventTypes) {
            return Data()
        }
        guard !chars.isEmpty else { return Data() }

        // ⌘-prefixed keys belong to the app layer (menu shortcuts, window
        // management) and must never turn into PTY bytes — otherwise ⌘C
        // could end up sending a literal 'c' to the shell. TerminalView
        // filters these at the event boundary; defence-in-depth here means
        // a future caller exercising the encoder directly still won't leak.
        if modifiers.contains(.command) { return Data() }

        let kitty = mode.contains(.disambiguateEscCodes)
        let allKeys = mode.contains(.reportAllKeysAsEsc)
        let alternateKeys = mode.contains(.reportAlternateKeys)
        let associatedText = mode.contains(.reportAssociatedText)
        let nonCmdMods = modifiers.subtracting(.command)
        // In Native-Option mode the shell should not see Option for
        // *printable* keystrokes — Option-e produces 'é', Option-Enter
        // produces a plain CR, etc. Stripping `.option` keeps `hasMods`
        // and the CSI u modifier param agreeing that Option is invisible.
        //
        // EXCEPTION: when `.control` is also held there is no dead-key /
        // OS-printable to compete with — the user clearly wants the
        // Option modifier (Emacs M-C-* bindings, terminal Meta+Ctrl).
        // Stripping Option in that case silently degrades Ctrl+Opt+letter
        // to bare Ctrl+letter, which means modifyOtherKeys reports
        // mod=5 (Ctrl) instead of mod=7 (Ctrl+Alt) and Emacs can't see
        // the meta bit. Preserve Option whenever Ctrl is present so the
        // mod param surfaces the full chord. Audit H7.
        let effectiveMods: Modifiers = {
            if optionIsMeta { return nonCmdMods }
            if nonCmdMods.contains(.control) { return nonCmdMods }
            return nonCmdMods.subtracting(.option)
        }()
        let hasMods = !effectiveMods.isEmpty

        // Kitty disambiguation: Enter / Esc / Tab / Backspace with any
        // effective modifier must emit `CSI <cp>;<mod>u` so the TUI can
        // distinguish Shift+Enter from plain Enter, Option+Esc from plain
        // Esc (which previously leaked as two raw ESCs), etc.
        if kitty, hasMods, let cp = kittyDisambiguationCodepoint(for: chars) {
            // Flag 16 adds the actual text the key would have produced
            // as a `;<utf32>` trailing section. Disambiguation keys
            // (Enter/Esc/Tab/Backspace) don't produce visible text on
            // their own, so associatedText stays empty and the on-wire
            // shape is unchanged. `.shift` on these keys also doesn't
            // produce a distinct shifted codepoint — Shift+Enter is
            // still Enter, just with the mod bit — so flag 4 similarly
            // adds nothing on this path.
            return csiU(
                codepoint: cp,
                modifiers: effectiveMods,
                eventType: eventType,
                associatedText: associatedText ? textCodepoints(chars, codepoint: cp) : []
            )
        }

        // Kitty flag 8 (reportAllKeysAsEsc): every printable emits CSI u
        // including plain unmodified keys. Breaks the default shell
        // contract by design — only TUIs that asked for it see it.
        // Ctrl+letter still routes through the collider branch below so
        // the colliders get lowercase-normalized codepoints.
        // CSI u carries one base codepoint — IME-committed multi-scalar
        // input (NFD `à`, keycaps, VS-16-paired emoji) falls back to plain
        // UTF-8 to avoid silently dropping every scalar after the first.
        if allKeys, chars.unicodeScalars.count > 1 {
            return Data(chars.utf8)
        }
        if allKeys, let scalar = chars.unicodeScalars.first,
           ctrlColliderCodepoint(for: scalar) == nil || !modifiers.contains(.control) {
            // Kitty's "all keys as CSI u" uses the lowercase of a letter
            // as the base codepoint; Shift is reported via the mod
            // param. For non-letter scalars the scalar value is used
            // directly.
            let cp = kittyAllKeysCodepoint(for: scalar, shifted: modifiers.contains(.shift))
            // Flag 4: surface the shifted form (uppercase of the base
            // letter) when the user is actually shifting. `alt=0` in
            // the payload since macOS doesn't expose a true alternate
            // layout per key.
            let shifted: UInt32? = {
                guard alternateKeys, modifiers.contains(.shift),
                      let shiftedCp = shiftedCodepointForLetter(scalar) else {
                    return nil
                }
                return shiftedCp
            }()
            return csiU(
                codepoint: cp,
                shiftedCodepoint: shifted,
                modifiers: effectiveMods,
                eventType: eventType,
                associatedText: associatedText ? textCodepoints(chars, codepoint: cp) : []
            )
        }

        // xterm `modifyOtherKeys` — `CSI 27 ; <mod> ; <cp> ~`.
        //
        // Precedence: Kitty flags win when active (matches the WezTerm /
        // Ghostty / tmux consensus even though xterm's own spec leaves
        // the interaction undefined). A TUI that pushed any Kitty bit is
        // telling us it prefers the Kitty protocol, so modifyOtherKeys
        // stays suppressed.
        //
        // Ctrl+letter cases arriving here come from TerminalView's
        // keyDown fast-path deferring to the encoder once it sees
        // `.modifyOtherKeys` in the current mode; they carry the letter
        // in `chars` (not the C0 byte) so CSI 27 emission uses the
        // letter's codepoint as expected by Emacs / tmux / nvim with
        // `extended-keys on` (F-S3-002).
        let kittyAnyActive = kitty || allKeys || alternateKeys || associatedText
            || mode.contains(.reportEventTypes)
        if !kittyAnyActive,
           mode.contains(.modifyOtherKeys),
           hasMods,
           let scalar = chars.unicodeScalars.first {
            // CSI 27 carries one codepoint — multi-scalar input falls back to UTF-8 to avoid silent truncation.
            if chars.unicodeScalars.count > 1 {
                return Data(chars.utf8)
            }
            return csi27(codepoint: scalar.value, modifiers: effectiveMods)
        }

        // Ctrl+printable: only the first character is transformed.
        if modifiers.contains(.control), let scalar = chars.unicodeScalars.first {
            // Kitty disambiguation: Ctrl+{i,m,[,h,?} legacy-alias Tab/Enter/
            // Esc/Backspace/DEL. Under flag 1 OR flag 8 (both contracted to
            // "every key as CSI u"), any modifier combination including these
            // collider letters emits CSI u so the TUI can tell them apart
            // from the unmodified C0 byte they alias. The codepoint is
            // normalized to the lowercase collider so Shift reports via the
            // mod param instead of by changing the base key. Other Ctrl+letter
            // combinations in the flag-1-only case stay as their C0 byte so
            // shells' SIGINT / SIGQUIT / word-motion bindings keep working.
            if (kitty || allKeys), let cp = ctrlColliderCodepoint(for: scalar) {
                return csiU(codepoint: cp, modifiers: effectiveMods, eventType: eventType)
            }
            // F-S3: under Kitty flag 1 / 8, a Ctrl+printable that has NO C0
            // mapping (Ctrl+digit, Ctrl+. , Ctrl+/ , Ctrl+; , …) is LOSSY in
            // legacy — the Ctrl bit can't be encoded, so the bare char goes out
            // and the TUI never sees Ctrl. Emit CSI u so the modifier survives.
            // Letters and @[\]^_ ? space keep their unambiguous C0 bytes
            // (handled below). The CSI-u codepoint is the UNSHIFTED base (Shift
            // reports via the mod param): map a US-layout shifted symbol back to
            // its base (Ctrl+> = Ctrl+Shift+. → '.'), else the scalar already IS
            // the base. (flag 8 alone already routes these through the
            // reportAllKeys branch above; this closes the flag-1-only gap.)
            // Non-US layouts miss the shifted-symbol base map — same
            // UCKeyTranslate caveat as flag 4.
            if (kitty || allKeys),
               controlByte(for: scalar) == nil,
               scalar.value >= 0x20, scalar.value != 0x7F {
                let base = (modifiers.contains(.shift)
                            ? Self.usLayoutUnshiftedSymbol(scalar) : nil) ?? scalar.value
                return csiU(codepoint: base, modifiers: effectiveMods, eventType: eventType)
            }
            if eventType == .release {
                return Data()
            }
            if let ctrlByte = controlByte(for: scalar) {
                // Ctrl+Option+letter in Meta mode is the Emacs/readline M-C-*
                // chord (forward-sexp, beginning-of-defun, …). The bare C0
                // byte drops the Meta bit, silently degrading M-C-f to plain
                // ^F. Prepend ESC so the shell sees ESC + C0 — matching how
                // arrows already report mod=7 for Ctrl+Option (audit H7) and
                // Terminal.app / iTerm2's Option-as-Meta behaviour. Only in
                // Meta mode: Native-Option has no Meta bit to carry, and the
                // kitty / modifyOtherKeys branches above already frame the
                // chord with the full modifier param.
                if optionIsMeta && modifiers.contains(.option) {
                    return Data([0x1B, ctrlByte])
                }
                return Data([ctrlByte])
            }
        }

        // Release events past here would end up emitting a legacy byte
        // sequence (CSI Z, ESC+UTF-8, or plain UTF-8) with no paired
        // release form. Drop so release traffic matches press traffic.
        if eventType == .release {
            return Data()
        }

        // Shift+Tab → CSI Z (reverse tab, "backtab"). Completion widgets and
        // the readline/zsh reverse-menu selection all expect this specific
        // sequence when kitty mode is NOT active. AppKit delivers Shift+Tab
        // as chars "\t" with .shift set.
        if !kitty, modifiers.contains(.shift), chars == "\t" {
            return Data([0x1B, 0x5B, 0x5A])    // ESC [ Z
        }

        // Option as Meta: prepend ESC.
        if optionIsMeta && modifiers.contains(.option) {
            var out = Data([0x1B])
            out.append(contentsOf: Array(chars.utf8))
            return out
        }

        return Data(chars.utf8)
    }

    /// Kitty progressive-enhancement maps one of four "ambiguous" keys to its
    /// protocol codepoint. Any modifier on these keys must emit `CSI <cp>;<mod>u`.
    /// Returns nil for other inputs — they take the legacy path.
    private func kittyDisambiguationCodepoint(for chars: String) -> UInt32? {
        switch chars {
        case "\r":     return 13   // Enter
        case "\u{1B}": return 27   // Escape
        case "\t":     return 9    // Tab
        case "\u{7F}": return 127  // Backspace (DEL)
        default:       return nil
        }
    }

    /// For Ctrl+{i, m, [, h} (the four C0 colliders), return the kitty-protocol
    /// codepoint normalized to the lowercase form so Shift is reported through
    /// the modifier param rather than by flipping between 'i' (105) and 'I' (73).
    /// '[' has no case. Returns nil for any non-collider.
    private func ctrlColliderCodepoint(for scalar: UnicodeScalar) -> UInt32? {
        switch scalar {
        case "i", "I": return 105   // Ctrl+I → Tab (0x09)
        case "m", "M": return 109   // Ctrl+M → CR (0x0D)
        case "h", "H": return 104   // Ctrl+H → BS (0x08)
        case "[":      return 91    // Ctrl+[ → ESC (0x1B)
        case "?":      return 63    // Ctrl+? → DEL (0x7F) — same byte as Backspace
        default:       return nil
        }
    }

    /// Codepoint to emit under Kitty flag 8 (`reportAllKeysAsEsc`) for a
    /// given scalar + shift state. Collapses the received (shifted)
    /// form to its *unshifted* base so Shift comes through the
    /// modifier field rather than by swapping the base key:
    ///
    ///   - Uppercase ASCII letter → lowercase.
    ///   - US-layout shifted symbol (`@`, `!`, `_`, `+`, etc.) →
    ///     unshifted counterpart (`2`, `1`, `-`, `=`, etc.) when
    ///     `shifted == true`. Without the Shift-held gate we'd
    ///     clobber cases where a user typed the shifted form via a
    ///     different route (Option combinations, macro replay) on a
    ///     layout where the symbol is unshifted.
    ///   - Anything else → pass through unchanged.
    ///
    /// Per-layout coverage is US-only; this table won't help German
    /// QWERTZ (Shift+2 → `"`) or Dvorak. Full layout fidelity needs
    /// Carbon's `UCKeyTranslate`, tracked separately.
    private func kittyAllKeysCodepoint(
        for scalar: UnicodeScalar,
        shifted: Bool
    ) -> UInt32 {
        if scalar.value >= 0x41 && scalar.value <= 0x5A {
            return scalar.value + 0x20
        }
        if shifted, let base = Self.usLayoutUnshiftedSymbol(scalar) {
            return base
        }
        return scalar.value
    }

    /// US-layout reverse map: given a shifted symbol the user just
    /// pressed (e.g. `@`), return the unshifted key codepoint (`2`).
    /// Returns nil for characters that either aren't ASCII symbols or
    /// aren't on the shift-row of a US layout. Letters are handled
    /// separately via the `'A'..'Z'` range check above.
    ///
    /// The `fileprivate static` makes the table a fixed compile-time
    /// cost, reachable from tests without re-declaring.
    fileprivate static func usLayoutUnshiftedSymbol(_ scalar: UnicodeScalar) -> UInt32? {
        switch scalar.value {
        case 0x21: return 0x31   // ! ← 1
        case 0x40: return 0x32   // @ ← 2
        case 0x23: return 0x33   // # ← 3
        case 0x24: return 0x34   // $ ← 4
        case 0x25: return 0x35   // % ← 5
        case 0x5E: return 0x36   // ^ ← 6
        case 0x26: return 0x37   // & ← 7
        case 0x2A: return 0x38   // * ← 8
        case 0x28: return 0x39   // ( ← 9
        case 0x29: return 0x30   // ) ← 0
        case 0x5F: return 0x2D   // _ ← -
        case 0x2B: return 0x3D   // + ← =
        case 0x7B: return 0x5B   // { ← [
        case 0x7D: return 0x5D   // } ← ]
        case 0x3A: return 0x3B   // : ← ;
        case 0x22: return 0x27   // " ← '
        case 0x3C: return 0x2C   // < ← ,
        case 0x3E: return 0x2E   // > ← .
        case 0x3F: return 0x2F   // ? ← /
        case 0x7E: return 0x60   // ~ ← `
        case 0x7C: return 0x5C   // | ← \
        default: return nil
        }
    }

    /// Flag 4 (`reportAlternateKeys`) shifted-form codepoint for the
    /// scalar the user just pressed. The scalar arrives post-Shift
    /// from `NSEvent.charactersIgnoringModifiers`, so:
    ///
    ///   - ASCII letters: `'A'..'Z'` is already the shifted form
    ///     (return as-is); `'a'..'z'` upcases.
    ///   - US-layout shifted symbols (`@`, `!`, etc.): scalar IS the
    ///     shifted form, so return it directly.
    ///   - Anything else: nil — the shifted form isn't derivable
    ///     without a keyboard-layout lookup we don't do yet.
    ///
    /// Non-US layouts still miss. Full layout fidelity requires
    /// `UCKeyTranslate`; tracked as follow-up.
    private func shiftedCodepointForLetter(_ scalar: UnicodeScalar) -> UInt32? {
        if scalar.value >= 0x41 && scalar.value <= 0x5A { return scalar.value }
        if scalar.value >= 0x61 && scalar.value <= 0x7A { return scalar.value - 0x20 }
        // Shifted ASCII symbol: the scalar itself IS the shifted form.
        // `usLayoutUnshiftedSymbol` returns non-nil iff the scalar is a
        // known US-layout shift-row glyph; reuse that membership test
        // to decide whether to emit a shifted slot.
        if Self.usLayoutUnshiftedSymbol(scalar) != nil {
            return scalar.value
        }
        return nil
    }

    /// Flag 16 (`reportAssociatedText`) text payload for a key.
    /// Control characters (ESC, Tab, CR, DEL) don't have meaningful
    /// visible text — the CSI-u codepoint already carries the key
    /// identity and a redundant text repeat would just bloat the
    /// stream. For visible characters we emit the actual UTF-32
    /// codepoints from `chars`, which may differ from `codepoint`
    /// after dead-key or IME composition.
    ///
    /// Returns empty when the text equals the base codepoint (saves
    /// on-wire bytes for the common "no IME, no dead key" case, which
    /// any conforming parser resolves by treating "text absent" as
    /// "text = base").
    private func textCodepoints(_ chars: String, codepoint: UInt32) -> [UInt32] {
        let values = chars.unicodeScalars.map { $0.value }
        // Control chars: no associated text. Covers \r, \t, \u{1B}, \u{7F}.
        if values.count == 1, values[0] < 0x20 || values[0] == 0x7F {
            return []
        }
        // Redundant: single scalar matching the base codepoint means
        // the parser can already infer text = base.
        if values == [codepoint] { return [] }
        return values
    }

    /// `CSI <codepoint>[:<alt>:<shifted>] ; <modParam>[:<eventType>][;<text>...] u`.
    ///
    /// Collapses the modifier field when modParam == 1 AND eventType ==
    /// .press AND there is no alt/shifted/text payload — the kitty spec
    /// says the entire `;M` can be omitted in that case. When
    /// eventType is non-press, flag 4 provides a `shiftedCodepoint`, or
    /// flag 16 provides `associatedText`, the modifier field is always
    /// emitted so later sub-parameters parse correctly.
    ///
    /// `shiftedCodepoint` lights the Kitty flag 4 (`reportAlternateKeys`)
    /// output — we emit `base:shifted` (the spec's key-code field is
    /// `unicode-key : shifted-key : base-layout-key`, so the shifted key
    /// is the second sub-field). The third base-layout field is omitted
    /// because macOS's `NSEvent` doesn't expose a keyboard-layout
    /// alternate, and the spec drops an absent trailing field. That's the
    /// smallest useful quantum of the spec: TUIs that care about
    /// shifted-vs-base disambiguation (most commonly tmux, kakoune) get
    /// it. Only set by callers that have actually derived a distinct
    /// shifted form (e.g. Shift+A → base=97 shifted=65); control chars
    /// have no shifted form and pass `nil`.
    ///
    /// `associatedText` lights Kitty flag 16 (`reportAssociatedText`).
    /// Carries the UTF-32 codepoints the key would actually produce —
    /// same as the base codepoint for most keys, but differs for dead
    /// keys / IME / compose. Each codepoint is appended as `;N`.
    private func csiU(
        codepoint: UInt32,
        shiftedCodepoint: UInt32? = nil,
        modifiers: Modifiers,
        eventType: EventType = .press,
        associatedText: [UInt32] = []
    ) -> Data {
        let mod = modifierParam(modifiers)
        var bytes: [UInt8] = [0x1B, 0x5B]                 // ESC [
        bytes.append(contentsOf: Array(String(codepoint).utf8))
        // Flag 4 alternate-keys payload. The Kitty key-code field is
        // `unicode-key-code : shifted-key : base-layout-key`
        // (https://sw.kovidgoyal.net/kitty/keyboard-protocol/, "Report
        // alternate keys"): the SHIFTED key is the *second* sub-field and
        // the base-layout (alternate-layout) key is the *third*. macOS
        // doesn't expose a per-key base-layout codepoint, so we emit only
        // `:<shifted>` and omit the third field — the spec says an absent
        // trailing sub-field is simply left out (and an absent middle
        // field is empty, never a literal `0`).
        //
        // Pre-fix this emitted `:0:<shifted>`, which a spec-compliant TUI
        // reads as shifted-key = U+0000 (NUL) with the real shifted value
        // misplaced into the base-layout slot — i.e. the wrong fields. The
        // earlier code comment misread the spec ("0 for the alternate
        // slot"); the order is shifted-then-base-layout, not the reverse.
        if let shifted = shiftedCodepoint {
            bytes.append(0x3A)                            // :
            bytes.append(contentsOf: Array(String(shifted).utf8))
        }
        let includeMod = mod > 1
            || eventType != .press
            || !associatedText.isEmpty
            || shiftedCodepoint != nil
        if includeMod {
            bytes.append(0x3B)                            // ;
            bytes.append(contentsOf: Array(String(mod).utf8))
            if eventType != .press {
                bytes.append(0x3A)                        // :
                bytes.append(contentsOf: Array(String(eventType.rawValue).utf8))
            }
        }
        // Flag 16 associated-text payload: one `;<codepoint>` per text
        // character. Empty array emits nothing — keeps the plain
        // "CSI 13;2u" shape for unmodified / no-text keys.
        for cp in associatedText {
            bytes.append(0x3B)                            // ;
            bytes.append(contentsOf: Array(String(cp).utf8))
        }
        bytes.append(0x75)                                // u
        return Data(bytes)
    }

    /// Encode a special key (arrow, function key, etc.) with modifiers.
    ///
    /// - Parameter applicationCursorKeys: When true and no modifiers are set,
    ///   arrow and Home/End keys use SS3 (`ESC O …`) sequences instead of CSI.
    ///   This is xterm's DECCKM mode, enabled by the shell via `ESC [ ? 1 h`.
    ///   vim, nvim, less, and most full-screen TUIs set this.
    /// CSI-parameter shape `(lead, terminator)` for the special keys that have
    /// one — i.e. those encoded as `CSI <lead> [; <mod>[:<event>]] <terminator>`
    /// (arrows/Home/End/F1–F4 use a final letter terminator; nav + F5–F12 use
    /// `~`). Used to encode Kitty flag-2 release/repeat events without
    /// duplicating the press switch's selection logic, so press encoding stays
    /// byte-identical. Keypad (DECPAM / SS3) keys have no such form → nil.
    private static func csiParamShape(for key: SpecialKey) -> (lead: String, term: UInt8)? {
        switch key {
        case .up:       return ("1", 0x41)   // A
        case .down:     return ("1", 0x42)   // B
        case .right:    return ("1", 0x43)   // C
        case .left:     return ("1", 0x44)   // D
        case .home:     return ("1", 0x48)   // H
        case .end:      return ("1", 0x46)   // F
        case .f1:       return ("1", 0x50)   // P
        case .f2:       return ("1", 0x51)   // Q
        case .f3:       return ("1", 0x52)   // R
        case .f4:       return ("1", 0x53)   // S
        case .pageUp:   return ("5", 0x7E)   // ~
        case .pageDown: return ("6", 0x7E)
        case .delete:   return ("3", 0x7E)
        case .insert:   return ("2", 0x7E)
        case .f5:       return ("15", 0x7E)
        case .f6:       return ("17", 0x7E)
        case .f7:       return ("18", 0x7E)
        case .f8:       return ("19", 0x7E)
        case .f9:       return ("20", 0x7E)
        case .f10:      return ("21", 0x7E)
        case .f11:      return ("23", 0x7E)
        case .f12:      return ("24", 0x7E)
        default:        return nil           // keypad (DECPAM/SS3) — no mod/event field
        }
    }

    public func encodeSpecial(
        _ key: SpecialKey,
        modifiers: Modifiers,
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false,
        mode: BBTermMode = [],
        eventType: EventType = .press
    ) -> Data {
        // Modifier-encoded keys use CSI with a trailing modifier parameter.
        // Modern xterm convention: CSI 1;M <final> where M = 1 + bitmask.
        // Bitmask: shift=1, alt=2, ctrl=4, meta=8.
        //
        // `optionIsMeta=false` means the user picked "Native" for the
        // Option key: Option produces macOS-native glyphs for printables
        // and is invisible to the shell otherwise — Option+Arrow emits
        // plain ESC[A rather than alt-modified ESC[1;3A.
        //
        // EXCEPTION: when `.control` is also held there's no dead-key /
        // OS-printable to compete with. The user clearly wants Option
        // surfaced as the alt bit so Emacs / readline can see Meta+Ctrl
        // chords. Stripping Option here would silently degrade
        // Ctrl+Opt+Up to bare Ctrl+Up and lose the meta bit. Audit H7.
        let effectiveMods: Modifiers = {
            if optionIsMeta { return modifiers }
            if modifiers.contains(.control) { return modifiers }
            return modifiers.subtracting(.option)
        }()
        let modBits = modifierParam(effectiveMods)
        let hasMods = modBits > 1

        // F-S3-005: Kitty flag 2 (reportEventTypes) release / repeat events for
        // the CSI-parameter special keys (arrows, nav, F-keys): `CSI <lead> ;
        // <mod>:<event> <terminator>`. PRESS is left to the legacy switch below
        // (byte-identical — kitty omits the `:1` press sub-param), so nothing
        // changes when this isn't a release/repeat. Without flag 2 a non-press
        // event emits nothing (legacy TUIs must never see post-keystroke
        // traffic — matches the printable release path). The mod field is
        // forced present (even unmodified) because the `:event` sub-param needs
        // a parameter to attach to. Keypad (DECPAM/SS3) keys have no such form
        // (`csiParamShape` returns nil) so their releases also emit nothing.
        if eventType != .press {
            guard mode.contains(.reportEventTypes),
                  let shape = Self.csiParamShape(for: key) else {
                return Data()
            }
            var bytes: [UInt8] = [0x1B, 0x5B]                            // ESC [
            bytes.append(contentsOf: Array(shape.lead.utf8))            // <lead>
            bytes.append(0x3B)                                          // ;
            bytes.append(contentsOf: Array(String(max(modBits, 1)).utf8)) // <mod>
            bytes.append(0x3A)                                          // :
            bytes.append(contentsOf: Array(String(eventType.rawValue).utf8)) // <event>
            bytes.append(shape.term)                                   // <final> / ~
            return Data(bytes)
        }

        switch key {
        case .up, .down, .right, .left, .home, .end:
            let final: UInt8 = {
                switch key {
                case .up: return 0x41       // A
                case .down: return 0x42     // B
                case .right: return 0x43    // C
                case .left: return 0x44     // D
                case .home: return 0x48     // H
                case .end: return 0x46      // F
                default: return 0x41
                }
            }()
            if hasMods {
                // CSI 1 ; M <final>
                return Data([0x1B, 0x5B, 0x31, 0x3B]) + Data(String(modBits).utf8) + Data([final])
            }
            if applicationCursorKeys {
                // SS3 <final> — ESC O <final>
                return Data([0x1B, 0x4F, final])
            }
            // CSI <final> — ESC [ <final>
            return Data([0x1B, 0x5B, final])

        case .pageUp, .pageDown, .delete, .insert:
            let num: UInt8 = {
                switch key {
                case .pageUp: return 0x35   // "5"
                case .pageDown: return 0x36 // "6"
                case .delete: return 0x33   // "3"
                case .insert: return 0x32   // "2"
                default: return 0x35
                }
            }()
            if hasMods {
                // CSI <num> ; M ~
                return Data([0x1B, 0x5B, num, 0x3B]) + Data(String(modBits).utf8) + Data([0x7E])
            }
            return Data([0x1B, 0x5B, num, 0x7E])

        case .f1, .f2, .f3, .f4:
            let final: UInt8 = {
                switch key {
                case .f1: return 0x50       // P
                case .f2: return 0x51       // Q
                case .f3: return 0x52       // R
                case .f4: return 0x53       // S
                default: return 0x50
                }
            }()
            if hasMods {
                // CSI 1 ; M <final>
                return Data([0x1B, 0x5B, 0x31, 0x3B]) + Data(String(modBits).utf8) + Data([final])
            }
            // SS3 <final> — ESC O P
            return Data([0x1B, 0x4F, final])

        case .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            // CSI <code> ~    — codes per xterm:
            // F5=15, F6=17, F7=18, F8=19, F9=20, F10=21, F11=23, F12=24.
            let code: String = {
                switch key {
                case .f5: return "15"
                case .f6: return "17"
                case .f7: return "18"
                case .f8: return "19"
                case .f9: return "20"
                case .f10: return "21"
                case .f11: return "23"
                case .f12: return "24"
                default: return "15"
                }
            }()
            if hasMods {
                // CSI <code> ; M ~
                return Data([0x1B, 0x5B]) + Data(code.utf8) + Data([0x3B]) + Data(String(modBits).utf8) + Data([0x7E])
            }
            return Data([0x1B, 0x5B]) + Data(code.utf8) + Data([0x7E])

        case .kp0, .kp1, .kp2, .kp3, .kp4, .kp5, .kp6, .kp7, .kp8, .kp9,
             .kpEnter, .kpPlus, .kpMinus, .kpMultiply, .kpDivide,
             .kpDecimal, .kpEquals:
            // DECPAM (application keypad mode). Only active when the TUI
            // has requested it via `ESC =`; otherwise the caller should
            // pass the plain digit / operator through `encode(chars:)`
            // instead of routing through here. xterm keypad mappings:
            //   0…9  → ESC O p … ESC O y
            //   +    → ESC O k       −    → ESC O m
            //   *    → ESC O j       /    → ESC O o
            //   .    → ESC O n       =    → ESC O X
            //   Enter→ ESC O M
            // See xterm's termcap `ka1..kc3` plus `kp*` entries.
            let final: UInt8 = {
                switch key {
                case .kp0: return 0x70  // p
                case .kp1: return 0x71  // q
                case .kp2: return 0x72  // r
                case .kp3: return 0x73  // s
                case .kp4: return 0x74  // t
                case .kp5: return 0x75  // u
                case .kp6: return 0x76  // v
                case .kp7: return 0x77  // w
                case .kp8: return 0x78  // x
                case .kp9: return 0x79  // y
                case .kpEnter:    return 0x4D // M
                case .kpPlus:     return 0x6B // k
                case .kpMinus:    return 0x6D // m
                case .kpMultiply: return 0x6A // j
                case .kpDivide:   return 0x6F // o
                case .kpDecimal:  return 0x6E // n
                case .kpEquals:   return 0x58 // X
                default: return 0x70
                }
            }()
            if applicationKeypad {
                // SS3 <final> — ESC O <final>
                return Data([0x1B, 0x4F, final])
            }
            // DECPAM off: a keypad key is just its plain character, so route
            // it through `encode(chars:)` — the same path a normal printable
            // key takes — instead of emitting a bare byte that silently drops
            // modifiers. This makes Option-as-Meta (ESC prefix), Kitty
            // disambiguation / flag-8, and xterm modifyOtherKeys framing all
            // apply to keypad keys exactly as they do to the top-row digits.
            // Audit S3S-002. With no modifiers and no protocol mode the result
            // is the same bare legacy byte as before (e.g. kp5 -> 0x35,
            // kpEnter -> CR 0x0D), so the unmodified fast path is unchanged.
            let legacyChar: String = {
                switch key {
                case .kp0: return "0";  case .kp1: return "1"
                case .kp2: return "2";  case .kp3: return "3"
                case .kp4: return "4";  case .kp5: return "5"
                case .kp6: return "6";  case .kp7: return "7"
                case .kp8: return "8";  case .kp9: return "9"
                case .kpEnter:    return "\r"  // CR (0x0D)
                case .kpPlus:     return "+"
                case .kpMinus:    return "-"
                case .kpMultiply: return "*"
                case .kpDivide:   return "/"
                case .kpDecimal:  return "."
                case .kpEquals:   return "="
                default: return ""
                }
            }()
            guard !legacyChar.isEmpty else { return Data() }
            return encode(chars: legacyChar, modifiers: modifiers, mode: mode)
        }
    }

    /// xterm `modifyOtherKeys` emit — `CSI 27 ; <mod> ; <cp> ~`. Uses
    /// the same 1+bits modifier encoding as CSI u; the tilde final
    /// byte distinguishes from CSI u's `u`. Emacs, tmux `extended-keys
    /// on`, neovim auto-request, and the Julia/IPython REPLs all read
    /// this shape. `formatOtherKeys=1` would use `u` instead — not
    /// implemented; Emacs defaults to `~` so every real consumer is
    /// covered.
    private func csi27(codepoint: UInt32, modifiers: Modifiers) -> Data {
        let mod = modifierParam(modifiers)
        var bytes: [UInt8] = [0x1B, 0x5B]    // ESC [
        bytes.append(contentsOf: Array("27".utf8))
        bytes.append(0x3B)                    // ;
        bytes.append(contentsOf: Array(String(mod).utf8))
        bytes.append(0x3B)                    // ;
        bytes.append(contentsOf: Array(String(codepoint).utf8))
        bytes.append(0x7E)                    // ~
        return Data(bytes)
    }

    /// xterm-style modifier parameter: 1 + (shift|alt|ctrl|meta bits).
    private func modifierParam(_ m: Modifiers) -> Int {
        var bits = 0
        if m.contains(.shift) { bits |= 1 }
        if m.contains(.option) { bits |= 2 }   // alt
        if m.contains(.control) { bits |= 4 }
        // Ignore .command — never reaches the encoder (TerminalView filters it).
        return 1 + bits
    }

    // MARK: - Helpers

    private func controlByte(for scalar: UnicodeScalar) -> UInt8? {
        let v = scalar.value
        switch v {
        case 0x40...0x5F: return UInt8(v - 0x40)       // @...?  -> 0x00..0x1F
        case 0x61...0x7A: return UInt8(v - 0x60)       // a..z    -> 0x01..0x1A
        case 0x20:        return 0x00                  // Ctrl-Space -> NUL
        case 0x3F:        return 0x7F                  // Ctrl-?     -> DEL
        default:          return nil
        }
    }
}
