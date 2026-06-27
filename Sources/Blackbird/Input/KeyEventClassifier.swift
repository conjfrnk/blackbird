import AppKit

/// Pure classification of AppKit `NSEvent`s into the input encoder's vocabulary:
/// the Option-as-Meta chord decision and the NSEvent → `KeyEncoder.SpecialKey`
/// mapping (arrows / nav / function / keypad keys). Extracted verbatim from
/// `TerminalView` (REFACTOR.md Part IV Wave-2) so the keyDown decision tree's
/// building blocks are testable without a live `NSView`/input context.
enum KeyEventClassifier {
    /// True when an Option+key event should bypass the IME and be encoded as a
    /// Meta chord (ESC + base char) rather than composed as a dead-key / accent.
    /// In "Use Option as Meta" mode, Option becomes the Meta modifier, so
    /// Option+e must emit ESC 'e' rather than start a "´" dead-key composition
    /// (and Option+a must emit ESC 'a' rather than insert "å"). Excludes
    /// Ctrl/⌘ chords (Ctrl+Option is handled by the encoder's Meta-prefix path;
    /// ⌘ is a menu/app shortcut). Native-Option mode (`optionIsMeta == false`)
    /// always returns false so dead-key composition is preserved. Pure so the
    /// decision is unit-testable without a live input context (the `keyDown` IME
    /// path can't be driven headlessly).
    static func isOptionMetaChord(
        optionIsMeta: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        optionIsMeta
            && modifierFlags.contains(.option)
            && !modifierFlags.contains(.control)
            && !modifierFlags.contains(.command)
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
        // NSEvent.SpecialKey.delete is the Backspace key. We intentionally do
        // NOT map it to SpecialKey.delete (CSI 3 ~) — Backspace must send the
        // DEL byte (0x7F), which the char-based path produces naturally from
        // event.charactersIgnoringModifiers. Only forward-delete maps here.
        case NSEvent.SpecialKey.deleteForward: return .delete
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
        default:
            // Keypad keys aren't exposed via NSEvent.specialKey.
            // NSEvent.modifierFlags.numericPad fires for external
            // numeric-keypad keys (and for the arrow-cluster on some
            // layouts — hence the explicit keyCode check). Only detect
            // the digit / operator keypad keys, never the arrows
            // (arrows route through the existing specialKey mapping
            // above via NSEvent.SpecialKey.*Arrow).
            if event.modifierFlags.contains(.numericPad) {
                return keypadKey(for: event)
            }
            return nil
        }
    }

    /// Map a numeric-keypad NSEvent to the matching SpecialKey. Returns
    /// nil for anything outside the explicit keypad scan-code set so
    /// the caller's default path can handle arrows (which also carry
    /// `.numericPad` on some keyboards).
    private static func keypadKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        // Virtual key codes from Carbon/HIToolbox are stable across
        // keyboard layouts. Hard-coded here rather than via
        // kVK_ANSI_Keypad0 constants because those live in Carbon, and
        // Blackbird doesn't otherwise link that umbrella.
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
        case 76: return .kpEnter
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
