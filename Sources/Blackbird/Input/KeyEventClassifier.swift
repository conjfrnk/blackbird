import AppKit

enum KeyEventClassifier {
    private static let returnKeyCode: UInt16 = 36       // kVK_Return
    private static let keypadEnterKeyCode: UInt16 = 76  // kVK_ANSI_KeypadEnter
    private static let tabKeyCode: UInt16 = 48          // kVK_Tab

    static func isOptionMetaChord(
        optionIsMeta: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        optionIsMeta
            && modifierFlags.contains(.option)
            && !modifierFlags.contains(.control)
            && !modifierFlags.contains(.command)
    }

    /// The Return chords `NSApplication.sendEvent` consumes itself ("show the contextual menu").
    /// Ctrl+Option+Return and Ctrl+keypad-Enter are not consumed; they reach `keyDown`.
    static func isContextMenuKeyChord(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == Self.returnKeyCode
            && modifierFlags.contains(.control)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
    }

    /// AppKit commits keypad digits / operators via `insertText`, which never consults DECPAM; callers bypass the IME.
    static func isApplicationKeypadKey(_ event: NSEvent, applicationKeypad: Bool) -> Bool {
        applicationKeypad && isKeypadCharacterKey(event)
    }

    /// Keypad Enter is excluded: it arrives as `doCommand(insertNewline:)`, never as committed text.
    static func isKeypadCharacterKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.numericPad),
              let key = keypadKey(for: event) else { return false }
        return key != .kpEnter
    }

    /// Under Ctrl, keypad Enter's raw `characters` is ETX (0x03 = SIGINT), so the encoder must decide.
    static func isEnterKey(keyCode: UInt16) -> Bool {
        keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode
    }

    /// Chords the input context commits through `insertText` with the modifiers dropped: Ctrl+Option + any key,
    /// and Shift + Return / keypad Enter (keypad Enter reports ETX). Keyed on the physical key.
    static func isNonComposableControlChord(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard !modifierFlags.contains(.command) else { return false }
        if modifierFlags.contains([.control, .option]) { return true }
        return isEnterKey(keyCode: keyCode) && modifierFlags.contains(.shift)
    }

    /// Ctrl+Return can surface as LF; Return is always "\r" so the kitty Enter mapping (`CSI 13 ; <mod> u`) applies.
    static func normalizedReturnChars(keyCode: UInt16, chars: String) -> String {
        keyCode == Self.returnKeyCode ? "\r" : chars
    }

    /// AppKit reports Shift+Tab as U+0019 (`NSBackTabCharacter`), which is also the C0 byte for Ctrl+Y;
    /// keyed on the physical Tab key so a genuine Ctrl+Y is never reinterpreted.
    static func isBackTab(keyCode: UInt16, chars: String) -> Bool {
        keyCode == Self.tabKeyCode && chars == "\u{19}"
    }

    static func normalizedTabChars(keyCode: UInt16, chars: String) -> String {
        isBackTab(keyCode: keyCode, chars: chars) ? "\t" : chars
    }

    static func specialKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        let key = event.specialKey
        switch key {
        case NSEvent.SpecialKey.upArrow:    return .up
        case NSEvent.SpecialKey.downArrow:  return .down
        case NSEvent.SpecialKey.leftArrow:  return .left
        case NSEvent.SpecialKey.rightArrow: return .right
        case NSEvent.SpecialKey.home:       return .home
        case NSEvent.SpecialKey.end:        return .end
        case NSEvent.SpecialKey.pageUp:     return .pageUp
        case NSEvent.SpecialKey.pageDown:   return .pageDown
        // NSEvent.SpecialKey.delete is Backspace: it must send DEL (0x7F) through the char path, not CSI 3 ~.
        case NSEvent.SpecialKey.deleteForward: return .delete
        // A PC Insert key arrives as NSHelpFunctionKey (U+F746) or, on some drivers, NSInsertFunctionKey (U+F727).
        case NSEvent.SpecialKey.insert, NSEvent.SpecialKey.help: return .insert
        case NSEvent.SpecialKey.f1:  return .f1
        case NSEvent.SpecialKey.f2:  return .f2
        case NSEvent.SpecialKey.f3:  return .f3
        case NSEvent.SpecialKey.f4:  return .f4
        case NSEvent.SpecialKey.f5:  return .f5
        case NSEvent.SpecialKey.f6:  return .f6
        case NSEvent.SpecialKey.f7:  return .f7
        case NSEvent.SpecialKey.f8:  return .f8
        case NSEvent.SpecialKey.f9:  return .f9
        case NSEvent.SpecialKey.f10: return .f10
        case NSEvent.SpecialKey.f11: return .f11
        case NSEvent.SpecialKey.f12: return .f12
        case NSEvent.SpecialKey.f13: return .f13
        case NSEvent.SpecialKey.f14: return .f14
        case NSEvent.SpecialKey.f15: return .f15
        case NSEvent.SpecialKey.f16: return .f16
        case NSEvent.SpecialKey.f17: return .f17
        case NSEvent.SpecialKey.f18: return .f18
        case NSEvent.SpecialKey.f19: return .f19
        case NSEvent.SpecialKey.f20: return .f20
        default:
            // Arrows also carry .numericPad on some layouts; keypadKey matches digit / operator key codes only.
            if event.modifierFlags.contains(.numericPad) {
                return keypadKey(for: event)
            }
            return nil
        }
    }

    /// AppKit encodes keys with no printable form as PUA scalars (the U+F700 block); they must never reach the PTY.
    static func isPrivateUseOnly(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0xE000 && v <= 0xF8FF)          // BMP PUA
                || (v >= 0xF0000 && v <= 0xFFFFD)        // Plane 15
                || (v >= 0x100000 && v <= 0x10FFFD)      // Plane 16
        }
    }

    private static func keypadKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        // Carbon/HIToolbox virtual key codes, stable across keyboard layouts.
        switch event.keyCode {
        case 82: return .kp0
        case 83: return .kp1
        case 84: return .kp2
        case 85: return .kp3
        case 86: return .kp4
        case 87: return .kp5
        case 88: return .kp6
        case 89: return .kp7
        case 91: return .kp8
        case 92: return .kp9
        case Self.keypadEnterKeyCode: return .kpEnter
        case 69: return .kpPlus
        case 78: return .kpMinus
        case 67: return .kpMultiply
        case 75: return .kpDivide
        case 65: return .kpDecimal
        case 81: return .kpEquals
        default: return nil
        }
    }
}
