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
        case f1, f2, f3, f4  // extend later
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
    /// Plan 2 only handles the bare-modifier cases for arrow keys.
    public func encodeSpecial(_ key: SpecialKey, modifiers: Modifiers) -> Data {
        // Bare arrow keys use CSI (ESC [) sequences.
        switch key {
        case .up:    return Data([0x1B, 0x5B, 0x41])
        case .down:  return Data([0x1B, 0x5B, 0x42])
        case .right: return Data([0x1B, 0x5B, 0x43])
        case .left:  return Data([0x1B, 0x5B, 0x44])
        case .home:     return Data([0x1B, 0x5B, 0x48])
        case .end:      return Data([0x1B, 0x5B, 0x46])
        case .pageUp:   return Data([0x1B, 0x5B, 0x35, 0x7E])
        case .pageDown: return Data([0x1B, 0x5B, 0x36, 0x7E])
        case .delete:   return Data([0x1B, 0x5B, 0x33, 0x7E])
        case .insert:   return Data([0x1B, 0x5B, 0x32, 0x7E])
        case .f1:       return Data([0x1B, 0x4F, 0x50])  // ESC O P
        case .f2:       return Data([0x1B, 0x4F, 0x51])
        case .f3:       return Data([0x1B, 0x4F, 0x52])
        case .f4:       return Data([0x1B, 0x4F, 0x53])
        }
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
