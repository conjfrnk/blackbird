//! Palette defaults and alacritty `Color` → 0xRRGGBB resolution. Pure
//! functions consumed by the snapshot builder; no in-crate dependencies.

use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};

/// Fallback Rgb for palette slots the theme hasn't filled in. OSC 10 / 11 /
/// 12 queries target indices 256 (Foreground), 257 (Background), 258
/// (Cursor). The 16 base colors use the xterm default table; the 240-entry
/// 256-color cube is computed. Anything outside that falls back to a
/// visible-on-any-background grey so silence is never the TUI's response.
pub(crate) fn palette_default_rgb(index: usize) -> Rgb {
    let packed: u32 = if index < 256 {
        indexed_color_rgb(index as u8)
    } else {
        match index {
            256 => named_color_rgb(&NamedColor::Foreground),
            257 => named_color_rgb(&NamedColor::Background),
            258 => 0xFFFFFF, // cursor default: solid white
            _ => 0xEEEEEE,
        }
    };
    Rgb {
        r: ((packed >> 16) & 0xFF) as u8,
        g: ((packed >> 8) & 0xFF) as u8,
        b: (packed & 0xFF) as u8,
    }
}

/// Convert an alacritty `Color` to a 0xRRGGBB u32, consulting the terminal's
/// palette first (so OSC 4/10/11/12 and `bb_term_set_named_color` overrides
/// route through). Falls back to built-in xterm defaults when a slot is unset.
pub(crate) fn color_to_rgb(
    color: &Color,
    palette: &alacritty_terminal::term::color::Colors,
) -> u32 {
    match color {
        Color::Spec(rgb) => ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32),
        Color::Named(name) => {
            let idx = *name as usize;
            if let Some(rgb) = palette[idx] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                named_color_rgb(name)
            }
        }
        Color::Indexed(idx) => {
            if let Some(rgb) = palette[*idx as usize] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                indexed_color_rgb(*idx)
            }
        }
    }
}

/// Map the 16 ANSI named colors (and semantic aliases) to xterm defaults.
pub(crate) fn named_color_rgb(name: &NamedColor) -> u32 {
    match name {
        NamedColor::Black => 0x000000,
        NamedColor::Red => 0xCC0000,
        NamedColor::Green => 0x4E9A06,
        NamedColor::Yellow => 0xC4A000,
        NamedColor::Blue => 0x3465A4,
        NamedColor::Magenta => 0x75507B,
        NamedColor::Cyan => 0x06989A,
        NamedColor::White => 0xD3D7CF,
        NamedColor::BrightBlack => 0x555753,
        NamedColor::BrightRed => 0xEF2929,
        NamedColor::BrightGreen => 0x8AE234,
        NamedColor::BrightYellow => 0xFCE94F,
        NamedColor::BrightBlue => 0x729FCF,
        NamedColor::BrightMagenta => 0xAD7FA8,
        NamedColor::BrightCyan => 0x34E2E2,
        NamedColor::BrightWhite => 0xEEEEEC,
        // Semantic aliases — Foreground defaults to light grey, Background to black
        NamedColor::Foreground | NamedColor::BrightForeground => 0xEEEEEE,
        NamedColor::Background => 0x000000,
        // Dim variants: map to the base color (terminal dims it visually)
        NamedColor::DimBlack => 0x000000,
        NamedColor::DimRed => 0xCC0000,
        NamedColor::DimGreen => 0x4E9A06,
        NamedColor::DimYellow => 0xC4A000,
        NamedColor::DimBlue => 0x3465A4,
        NamedColor::DimMagenta => 0x75507B,
        NamedColor::DimCyan => 0x06989A,
        NamedColor::DimWhite => 0xD3D7CF,
        NamedColor::DimForeground => 0xEEEEEE,
        // Cursor and any future variants
        _ => 0xEEEEEE,
    }
}

/// Map xterm 256-color palette index to 0xRRGGBB.
pub(crate) fn indexed_color_rgb(idx: u8) -> u32 {
    match idx {
        0..=15 => {
            // Standard 16 colors — same mapping as named_color_rgb
            const TABLE: [u32; 16] = [
                0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
                0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
            ];
            TABLE[idx as usize]
        }
        16..=231 => {
            // 6×6×6 color cube
            let i = (idx - 16) as u32;
            let r = (i / 36) % 6;
            let g = (i / 6) % 6;
            let b = i % 6;
            let to_byte = |v: u32| -> u32 {
                if v == 0 {
                    0
                } else {
                    55 + 40 * v
                }
            };
            (to_byte(r) << 16) | (to_byte(g) << 8) | to_byte(b)
        }
        232..=255 => {
            // 24-step grayscale ramp
            let v = 8 + 10 * (idx - 232) as u32;
            (v << 16) | (v << 8) | v
        }
    }
}
