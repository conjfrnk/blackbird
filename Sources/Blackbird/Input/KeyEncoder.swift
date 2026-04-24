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
    /// Plan 5 will surface this as a setting; for now hardcoded true.
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
        if eventType == .release && !mode.contains(.reportEventTypes) {
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
        // In Native-Option mode the shell should not see Option at all —
        // Option-e produces 'é' and Option+Enter produces a plain CR. Stripping
        // .option here makes both the hasMods predicate and the CSI u modifier
        // param agree that Option is invisible in Native mode.
        let effectiveMods: Modifiers = optionIsMeta ? nonCmdMods : nonCmdMods.subtracting(.option)
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
        // Precedence: Kitty flags win when active; this branch only
        // fires in the Kitty-absent case. Matches the consensus of
        // WezTerm / Ghostty / tmux (industry-wide, though xterm's spec
        // leaves the interaction undefined). Scope is the 80/20:
        //
        //   - Any printable with a modifier (Shift+Enter, Ctrl+.,
        //     Ctrl+,, etc.) where Cocoa already gave us the intended
        //     codepoint in `chars`. The codepoint is
        //     `chars.unicodeScalars.first!.value` verbatim — Cocoa
        //     applied Shift/Option already, so Shift+2 arrives as "@"
        //     (or "2" for layouts where 2 is unshifted), matching the
        //     unshifted-printable rule.
        //
        // Known limitation: Ctrl+letter cases where Cocoa pre-converts
        // to the C0 byte (e.g. Ctrl+i → "\t") emit `CSI 27 ; 5 ; 9 ~`
        // instead of the level-2-correct `CSI 27 ; 5 ; 105 ~`. Emacs
        // inside a terminal normally uses level 2 with Kitty as the
        // primary transport anyway; users who want pixel-perfect
        // modifyOtherKeys-only Ctrl+letter output should enable
        // Kitty flag 8 as well. Document in KNOWN_ISSUES.md.
        let kittyAnyActive = kitty || allKeys || alternateKeys || associatedText
            || mode.contains(.reportEventTypes)
        if !kittyAnyActive,
           mode.contains(.modifyOtherKeys),
           hasMods,
           let scalar = chars.unicodeScalars.first {
            if eventType == .release { return Data() }
            return csi27(codepoint: scalar.value, modifiers: effectiveMods)
        }

        // Ctrl+printable: only the first character is transformed.
        if modifiers.contains(.control), let scalar = chars.unicodeScalars.first {
            // Kitty disambiguation: Ctrl+{i,m,[,h} legacy-alias Tab/Enter/Esc/
            // Backspace. Under flag 1, any modifier combination including
            // these collider letters emits CSI u so the TUI can tell them
            // apart from the unmodified Tab/Enter/Esc/Backspace they alias.
            // The codepoint is normalized to the lowercase collider so Shift
            // reports via the mod param instead of by changing the base key.
            // Other Ctrl+letter combinations stay as their C0 byte so shells'
            // SIGINT / SIGQUIT / word-motion bindings keep working.
            if kitty, let cp = ctrlColliderCodepoint(for: scalar) {
                return csiU(codepoint: cp, modifiers: effectiveMods, eventType: eventType)
            }
            if eventType == .release {
                return Data()
            }
            if let ctrlByte = controlByte(for: scalar) {
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
        case "i", "I": return 105
        case "m", "M": return 109
        case "h", "H": return 104
        case "[":      return 91
        default:       return nil
        }
    }

    /// Codepoint to emit under Kitty flag 8 (reportAllKeysAsEsc) for a
    /// given scalar + shift state. Letters are always lowercased so
    /// Shift comes through the modifier field; other scalars pass
    /// through unchanged.
    private func kittyAllKeysCodepoint(
        for scalar: UnicodeScalar,
        shifted: Bool
    ) -> UInt32 {
        if scalar.value >= 0x41 && scalar.value <= 0x5A {
            // Uppercase A-Z → lowercase; Shift is already in the
            // modifier bits so the CSI-u consumer re-shifts as needed.
            return scalar.value + 0x20
        }
        _ = shifted
        return scalar.value
    }

    /// Flag 4 (`reportAlternateKeys`) shifted-form codepoint for an
    /// ASCII letter. `'A'..'Z'` → themselves (already shifted);
    /// `'a'..'z'` → uppercase (which is what Shift produces). `nil`
    /// for non-letters — we don't have a reliable shifted form for
    /// symbols without layout context that `NSEvent` doesn't expose.
    private func shiftedCodepointForLetter(_ scalar: UnicodeScalar) -> UInt32? {
        if scalar.value >= 0x41 && scalar.value <= 0x5A { return scalar.value }
        if scalar.value >= 0x61 && scalar.value <= 0x7A { return scalar.value - 0x20 }
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
    /// output — we emit `base:0:shifted` where 0 indicates "no alternate
    /// layout code", since macOS's `NSEvent` doesn't expose a
    /// keyboard-layout alternate. That's the smallest useful quantum of
    /// the spec: TUIs that care about shifted-vs-base disambiguation
    /// (most commonly tmux, kakoune) get it; TUIs that wanted a true
    /// alt-layout see the 0 and fall back to base. Only set by callers
    /// that have actually derived a distinct shifted form (e.g. Shift+A
    /// → base=97 shifted=65); control chars have no shifted form and
    /// pass `nil`.
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
        // Flag 4 alternate-keys payload: `:0:<shifted>` appended to the
        // base codepoint. `0` (not omitted) for the alternate slot —
        // parsers that split on `:` see three fields and know the
        // middle is empty. Kitty spec allows `:<shifted>` with no
        // alternate, but `0` is more conservative cross-parser.
        if let shifted = shiftedCodepoint {
            bytes.append(0x3A)                            // :
            bytes.append(0x30)                            // 0 (alternate absent)
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
    public func encodeSpecial(
        _ key: SpecialKey,
        modifiers: Modifiers,
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false
    ) -> Data {
        // Modifier-encoded keys use CSI with a trailing modifier parameter.
        // Modern xterm convention: CSI 1;M <final> where M = 1 + bitmask.
        // Bitmask: shift=1, alt=2, ctrl=4, meta=8.
        //
        // `optionIsMeta=false` means the user picked "Native" for the Option
        // key: Option should produce macOS-native glyphs for printables and
        // is invisible to the shell otherwise. Strip it from the modifier
        // param so Option+Arrow emits plain ESC[A rather than alt-modified
        // ESC[1;3A — the app isn't supposed to be treating Option as alt
        // in Native mode.
        let effectiveMods: Modifiers = optionIsMeta ? modifiers : modifiers.subtracting(.option)
        let modBits = modifierParam(effectiveMods)
        let hasMods = modBits > 1

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
            // Fall back to the plain character. Callers should avoid
            // routing here when DECPAM is off; this branch exists so a
            // future dispatch refactor can't regress to emitting nothing.
            let legacy: UInt8 = {
                switch key {
                case .kp0: return 0x30;  case .kp1: return 0x31
                case .kp2: return 0x32;  case .kp3: return 0x33
                case .kp4: return 0x34;  case .kp5: return 0x35
                case .kp6: return 0x36;  case .kp7: return 0x37
                case .kp8: return 0x38;  case .kp9: return 0x39
                case .kpEnter:    return 0x0D  // CR
                case .kpPlus:     return 0x2B
                case .kpMinus:    return 0x2D
                case .kpMultiply: return 0x2A
                case .kpDivide:   return 0x2F
                case .kpDecimal:  return 0x2E
                case .kpEquals:   return 0x3D
                default: return 0x00
                }
            }()
            _ = hasMods // keypad modifier encoding is TUI-specific; omit.
            return Data([legacy])
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
