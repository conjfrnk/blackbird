import Foundation

/// Maps keyboard input into the byte sequences the shell expects.
///
/// Plan 2 scope: bare-key ASCII, Return, Tab, Backspace, Escape, Arrow keys,
/// Ctrl+printable, Option-as-Meta (ESC+). Full CSI u modifier encoding for
/// non-arrow modifier combinations is deferred to later plans.
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
    }

    /// If true, Option modifier produces ESC+char (traditional Meta behavior).
    /// If false, Option produces the character the OS assigned (e.g., Option-e -> accent).
    /// Plan 5 will surface this as a setting; for now hardcoded true.
    public let optionIsMeta: Bool

    public init(optionIsMeta: Bool = true) {
        self.optionIsMeta = optionIsMeta
    }

    /// Encode a character sequence plus modifiers into bytes.
    public func encode(chars: String, modifiers: Modifiers) -> Data {
        guard !chars.isEmpty else { return Data() }

        // Ctrl+printable: only the first character is transformed.
        if modifiers.contains(.control), let scalar = chars.unicodeScalars.first {
            if let ctrlByte = controlByte(for: scalar) {
                return Data([ctrlByte])
            }
        }

        // Option as Meta: prepend ESC.
        if optionIsMeta && modifiers.contains(.option) {
            var out = Data([0x1B])
            out.append(contentsOf: Array(chars.utf8))
            return out
        }

        return Data(chars.utf8)
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
        applicationCursorKeys: Bool = false
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
        }
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
