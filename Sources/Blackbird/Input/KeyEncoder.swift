import Foundation
import BBCore

/// Maps keyboard input to PTY bytes: legacy xterm encoding, or the kitty keyboard protocol once a program pushes flags.
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
        case f13, f14, f15, f16, f17, f18, f19, f20
        case kp0, kp1, kp2, kp3, kp4, kp5, kp6, kp7, kp8, kp9
        case kpEnter, kpPlus, kpMinus, kpMultiply, kpDivide
        case kpDecimal, kpEquals
    }

    /// Kitty event-type sub-parameter (`CSI <cp>;<mod>:<event>u`).
    public enum EventType: Int {
        case press   = 1
        case `repeat` = 2
        case release = 3
    }

    public let optionIsMeta: Bool

    public init(optionIsMeta: Bool = true) {
        self.optionIsMeta = optionIsMeta
    }

    /// Native Option is invisible to the shell, except with Control held: stripping it there would degrade
    /// Ctrl+Opt+key to bare Ctrl+key (mod=5 instead of mod=7).
    private func applyNativeOptionRule(_ mods: Modifiers) -> Modifiers {
        if optionIsMeta { return mods }
        if mods.contains(.control) { return mods }
        return mods.subtracting(.option)
    }

    public func encode(
        chars: String,
        modifiers: Modifiers,
        mode: BBTermMode = [],
        eventType: EventType = .press
    ) -> Data {
        // Release / repeat leave the encoder only under kitty flag 2 (`reportEventTypes`).
        if eventType != .press && !mode.contains(.reportEventTypes) {
            return Data()
        }
        guard !chars.isEmpty else { return Data() }

        // ⌘ chords belong to the app layer and must never become PTY bytes.
        if modifiers.contains(.command) { return Data() }

        let kitty = mode.contains(.disambiguateEscCodes)
        let allKeys = mode.contains(.reportAllKeysAsEsc)
        let alternateKeys = mode.contains(.reportAlternateKeys)
        let associatedText = mode.contains(.reportAssociatedText)
        let nonCmdMods = modifiers.subtracting(.command)
        let effectiveMods = applyNativeOptionRule(nonCmdMods)
        let hasMods = !effectiveMods.isEmpty

        if let bytes = tryKittyDisambiguation(
            chars: chars, kitty: kitty, hasMods: hasMods,
            effectiveMods: effectiveMods, eventType: eventType, associatedText: associatedText
        ) {
            return bytes
        }

        if let bytes = tryKittyAllKeys(
            chars: chars, modifiers: modifiers, effectiveMods: effectiveMods,
            allKeys: allKeys, alternateKeys: alternateKeys,
            associatedText: associatedText, eventType: eventType
        ) {
            return bytes
        }

        // xterm modifyOtherKeys (`CSI 27 ; <mod> ; <cp> ~`); any active kitty flag suppresses it.
        // Ctrl+letter arrives here as the letter, not the C0 byte, so CSI 27 carries the letter's codepoint.
        let kittyAnyActive = kitty || allKeys || alternateKeys || associatedText
            || mode.contains(.reportEventTypes)
        if !kittyAnyActive,
           mode.contains(.modifyOtherKeys),
           hasMods,
           let scalar = chars.unicodeScalars.first {
            // CSI 27 carries one codepoint; multi-scalar input falls back to UTF-8.
            if chars.unicodeScalars.count > 1 {
                return Data(chars.utf8)
            }
            return csi27(codepoint: scalar.value, modifiers: effectiveMods)
        }

        if let bytes = tryControlPrintable(
            chars: chars, modifiers: modifiers, effectiveMods: effectiveMods,
            kitty: kitty, allKeys: allKeys, eventType: eventType
        ) {
            return bytes
        }

        // Flag 1 reports alt+key / shift+alt+key as CSI u. Must precede the release drop below: the press
        // has a paired release form (`CSI <cp>;<mod>:3 u`).
        if kitty, optionIsMeta, modifiers.contains(.option),
           chars.unicodeScalars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value != 0x7F {
            let base = kittyAllKeysCodepoint(for: scalar, shifted: modifiers.contains(.shift))
            return csiU(codepoint: base, modifiers: effectiveMods, eventType: eventType)
        }

        // The legacy sequences below have no paired release form.
        if eventType == .release {
            return Data()
        }

        if !kitty, modifiers.contains(.shift), chars == "\t" {
            return Data([0x1B, 0x5B, 0x5A])    // ESC [ Z
        }

        if optionIsMeta && modifiers.contains(.option) {
            var out = Data([0x1B])
            out.append(contentsOf: Array(chars.utf8))
            return out
        }

        return Data(chars.utf8)
    }

    /// Branch order is precedence: kitty collider, kitty CSI u, release drop, C0 byte.
    private func tryControlPrintable(
        chars: String,
        modifiers: Modifiers,
        effectiveMods: Modifiers,
        kitty: Bool,
        allKeys: Bool,
        eventType: EventType
    ) -> Data? {
        guard modifiers.contains(.control), let scalar = chars.unicodeScalars.first else {
            return nil
        }
        // Ctrl+{i,m,[,h,?} alias Tab / Enter / Esc / Backspace / DEL. Under flag 1 or 8 they emit CSI u with
        // the lowercase codepoint, so Shift reports via the mod param.
        if (kitty || allKeys), let cp = ctrlColliderCodepoint(for: scalar) {
            return csiU(codepoint: cp, modifiers: effectiveMods, eventType: eventType)
        }
        // Flag 1 reports every ctrl+key as CSI u (Ctrl+c included) with the unshifted base codepoint; Shift
        // rides in the modifier bits. The shifted-symbol base map is US-layout only.
        if (kitty || allKeys),
           scalar.value >= 0x20, scalar.value != 0x7F {
            let base = kittyAllKeysCodepoint(for: scalar, shifted: modifiers.contains(.shift))
            return csiU(codepoint: base, modifiers: effectiveMods, eventType: eventType)
        }
        if eventType == .release {
            return Data()
        }
        if let ctrlByte = controlByte(for: scalar) {
            // Ctrl+Option+letter in Meta mode is the M-C-* chord: ESC + C0, so the Meta bit survives.
            if optionIsMeta && modifiers.contains(.option) {
                return Data([0x1B, ctrlByte])
            }
            return Data([ctrlByte])
        }
        return nil
    }

    private func tryKittyDisambiguation(
        chars: String,
        kitty: Bool,
        hasMods: Bool,
        effectiveMods: Modifiers,
        eventType: EventType,
        associatedText: Bool
    ) -> Data? {
        guard kitty, let cp = kittyDisambiguationCodepoint(for: chars) else {
            return nil
        }
        // Kitty spec: unmodified Enter / Tab / Backspace keep their legacy bytes, but a plain Esc is `CSI 27 u`.
        if !hasMods && cp != 27 {
            return nil
        }
        return csiU(
            codepoint: cp,
            modifiers: effectiveMods,
            eventType: eventType,
            associatedText: associatedText ? textCodepoints(chars, codepoint: cp) : []
        )
    }

    /// Flag 8: every printable emits CSI u, unmodified keys included. A Ctrl+collider scalar is left to
    /// `tryControlPrintable`; multi-scalar input falls back to UTF-8 so no scalar is dropped.
    private func tryKittyAllKeys(
        chars: String,
        modifiers: Modifiers,
        effectiveMods: Modifiers,
        allKeys: Bool,
        alternateKeys: Bool,
        associatedText: Bool,
        eventType: EventType
    ) -> Data? {
        guard allKeys else { return nil }
        if chars.unicodeScalars.count > 1 {
            return Data(chars.utf8)
        }
        guard let scalar = chars.unicodeScalars.first,
              ctrlColliderCodepoint(for: scalar) == nil || !modifiers.contains(.control) else {
            return nil
        }
        let cp = kittyAllKeysCodepoint(for: scalar, shifted: modifiers.contains(.shift))
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

    private func kittyDisambiguationCodepoint(for chars: String) -> UInt32? {
        switch chars {
        case "\r":     return 13   // Enter
        case "\u{1B}": return 27   // Escape
        case "\t":     return 9    // Tab
        case "\u{7F}": return 127  // Backspace (DEL)
        default:       return nil
        }
    }

    private func ctrlColliderCodepoint(for scalar: UnicodeScalar) -> UInt32? {
        switch scalar {
        case "i", "I": return 105   // Ctrl+I → Tab (0x09)
        case "m", "M": return 109   // Ctrl+M → CR (0x0D)
        case "h", "H": return 104   // Ctrl+H → BS (0x08)
        case "[":      return 91    // Ctrl+[ → ESC (0x1B)
        case "?":      return 63 // Ctrl+? → DEL (0x7F)
        default:       return nil
        }
    }

    /// Collapses the received form to its unshifted base so Shift reports through the modifier field.
    /// The symbol map is US-layout only and applies only while Shift is held.
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

    /// The scalar arrives post-Shift from `charactersIgnoringModifiers`; nil when a layout lookup would be needed.
    private func shiftedCodepointForLetter(_ scalar: UnicodeScalar) -> UInt32? {
        if scalar.value >= 0x41 && scalar.value <= 0x5A { return scalar.value }
        if scalar.value >= 0x61 && scalar.value <= 0x7A { return scalar.value - 0x20 }
        if Self.usLayoutUnshiftedSymbol(scalar) != nil {
            return scalar.value
        }
        return nil
    }

    /// Flag 16 text: empty for control characters and when it equals the base codepoint (absent means base).
    private func textCodepoints(_ chars: String, codepoint: UInt32) -> [UInt32] {
        let values = chars.unicodeScalars.map { $0.value }
        if values.count == 1, values[0] < 0x20 || values[0] == 0x7F {
            return []
        }
        if values == [codepoint] { return [] }
        return values
    }

    /// `CSI <codepoint>[:<shifted>] ; <modParam>[:<eventType>][;<text>...] u`.
    /// `;<modParam>` is omitted only when it is 1, the event is a press, and there is no shifted / text payload.
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
        // The kitty key-code field is `unicode-key : shifted-key : base-layout-key`. macOS exposes no base-layout
        // key, so only `:<shifted>` is emitted; an absent trailing sub-field is left out, never written as 0.
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
        for cp in associatedText {
            bytes.append(0x3B)                            // ;
            bytes.append(contentsOf: Array(String(cp).utf8))
        }
        bytes.append(0x75)                                // u
        return Data(bytes)
    }

    /// `(lead, terminator)` for keys encoded as `CSI <lead> [; <mod>[:<event>]] <terminator>`; nil for keypad keys.
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
        // Not `CSI 1 ; <mod> R`: that is byte-identical to a cursor-position report, so kitty and the
        // xterm-kitty terminfo use `CSI 13 ; <mod> ~`. Unmodified F3 stays SS3 R.
        case .f3:       return ("13", 0x7E)
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
        // VT220 / xterm numbering; the gaps at 27 and 30 are real.
        case .f13:      return ("25", 0x7E)
        case .f14:      return ("26", 0x7E)
        case .f15:      return ("28", 0x7E)
        case .f16:      return ("29", 0x7E)
        case .f17:      return ("31", 0x7E)
        case .f18:      return ("32", 0x7E)
        case .f19:      return ("33", 0x7E)
        case .f20:      return ("34", 0x7E)
        default:        return nil
        }
    }

    /// Modified: `CSI <lead> ; <mod> <term>`. Unmodified: arrows / Home / End drop the lead and honour DECCKM
    /// (`SS3 <term>` vs `CSI <term>`), F1-F4 always use SS3, nav and F5+ keep the lead.
    private static func csiParamPress(
        _ key: SpecialKey,
        shape: (lead: String, term: UInt8),
        modBits: Int,
        hasMods: Bool,
        applicationCursorKeys: Bool
    ) -> Data {
        if hasMods {
            return Data([0x1B, 0x5B]) + Data(shape.lead.utf8) + Data([0x3B])
                + Data(String(modBits).utf8) + Data([shape.term])
        }
        switch key {
        case .up, .down, .right, .left, .home, .end:
            return applicationCursorKeys
                ? Data([0x1B, 0x4F, shape.term])
                : Data([0x1B, 0x5B, shape.term])
        case .f1, .f2, .f4:
            return Data([0x1B, 0x4F, shape.term])
        case .f3:
            // Not `shape.term`: F3's CSI shape is `13 ~`, so its SS3 final (R) is spelled out.
            return Data([0x1B, 0x4F, 0x52])
        default:
            return Data([0x1B, 0x5B]) + Data(shape.lead.utf8) + Data([shape.term])
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
        let effectiveMods = applyNativeOptionRule(modifiers)
        let modBits = modifierParam(effectiveMods)
        let hasMods = modBits > 1

        // Flag 2 release / repeat for CSI-parameter keys: `CSI <lead> ; <mod>:<event> <terminator>`. The mod field
        // is forced present so `:<event>` has a parameter to attach to. Keypad keys fall through to `encodeKeypadKey`.
        if eventType != .press {
            guard mode.contains(.reportEventTypes) else { return Data() }
            if let shape = Self.csiParamShape(for: key) {
                var bytes: [UInt8] = [0x1B, 0x5B]                            // ESC [
                bytes.append(contentsOf: Array(shape.lead.utf8))
                bytes.append(0x3B)                                          // ;
                bytes.append(contentsOf: Array(String(max(modBits, 1)).utf8))
                bytes.append(0x3A)                                          // :
                bytes.append(contentsOf: Array(String(eventType.rawValue).utf8))
                bytes.append(shape.term)
                return Data(bytes)
            }
        }

        switch key {
        case .up, .down, .right, .left, .home, .end,
             .pageUp, .pageDown, .delete, .insert,
             .f1, .f2, .f3, .f4,
             .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
             .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            guard let shape = Self.csiParamShape(for: key) else { return Data() }
            return Self.csiParamPress(
                key, shape: shape, modBits: modBits,
                hasMods: hasMods, applicationCursorKeys: applicationCursorKeys
            )

        case .kp0, .kp1, .kp2, .kp3, .kp4, .kp5, .kp6, .kp7, .kp8, .kp9,
             .kpEnter, .kpPlus, .kpMinus, .kpMultiply, .kpDivide,
             .kpDecimal, .kpEquals:
            return encodeKeypadKey(key, applicationKeypad: applicationKeypad,
                                   modifiers: modifiers, mode: mode, eventType: eventType)
        }
    }

    /// DECPAM on: xterm's `SS3 <final>` keypad map. Otherwise the key is its plain character, routed through
    /// `encode(chars:)` so modifier and protocol framing still apply.
    private func encodeKeypadKey(
        _ key: SpecialKey,
        applicationKeypad: Bool,
        modifiers: Modifiers,
        mode: BBTermMode,
        eventType: EventType
    ) -> Data {
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
        // Kitty flags 1 and 8 take the keypad over from DECPAM; flags 2 / 4 / 16 only decorate and leave it alone.
        let kittyOwnsKeypad = mode.contains(.disambiguateEscCodes)
            || mode.contains(.reportAllKeysAsEsc)
        if applicationKeypad && !kittyOwnsKeypad {
            // SS3 has no event field: a release would replay the press bytes.
            if eventType == .release { return Data() }
            return Data([0x1B, 0x4F, final])
        }
        let legacyChar: String = {
            switch key {
            case .kp0: return "0";  case .kp1: return "1"
            case .kp2: return "2";  case .kp3: return "3"
            case .kp4: return "4";  case .kp5: return "5"
            case .kp6: return "6";  case .kp7: return "7"
            case .kp8: return "8";  case .kp9: return "9"
            case .kpEnter:    return "\r"
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
        return encode(chars: legacyChar, modifiers: modifiers, mode: mode, eventType: eventType)
    }

    /// xterm modifyOtherKeys: `CSI 27 ; <mod> ; <cp> ~`. `formatOtherKeys=1` (final `u`) is not implemented.
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

    /// xterm modifier parameter: 1 + bitmask (shift=1, alt=2, ctrl=4).
    private func modifierParam(_ m: Modifiers) -> Int {
        var bits = 0
        if m.contains(.shift) { bits |= 1 }
        if m.contains(.option) { bits |= 2 }   // alt
        if m.contains(.control) { bits |= 4 }
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
        // AppKit delivers Ctrl+Backspace as DEL; xterm and kitty's legacy table map it to BS.
        case 0x7F:        return 0x08                  // Ctrl-Backspace -> BS
        // xterm's legacy digit / symbol chords. Ctrl-1, Ctrl-9 and Ctrl-0 have no C0 mapping.
        case 0x32:        return 0x00                  // Ctrl-2 -> NUL
        case 0x33:        return 0x1B                  // Ctrl-3 -> ESC
        case 0x34:        return 0x1C                  // Ctrl-4 -> FS
        case 0x35:        return 0x1D                  // Ctrl-5 -> GS
        case 0x36:        return 0x1E                  // Ctrl-6 -> RS
        case 0x37:        return 0x1F                  // Ctrl-7 -> US
        case 0x38:        return 0x7F                  // Ctrl-8 -> DEL
        case 0x2D, 0x2F:  return 0x1F                  // Ctrl-- / Ctrl-/ -> US
        default:          return nil
        }
    }
}
