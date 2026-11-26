//! Text-sanitization primitives shared across the OSC parse paths.

/// Scalars NSWindow / NSTextField render invisibly: bidi controls, zero-width, tag block, VS, BOM.
pub(crate) fn is_bidi_or_invisible_scalar(c: char) -> bool {
    let cp = c as u32;
    matches!(cp,
        0x00AD
        | 0x061C
        | 0x180E
        | 0x200B..=0x200F
        | 0x2028..=0x202E
        | 0x2060
        | 0x2066..=0x2069
        | 0xFE00..=0xFE0F
        | 0xFEFF
        | 0xE0000..=0xE007F
        | 0xE0100..=0xE01EF
    )
}

/// ZWNJ/ZWJ and the variation selectors spell text (emoji, Persian / Indic words), not hide it.
/// Deliberately not in `is_bidi_or_invisible_scalar`: OSC 7 / 8 / 133 keep rejecting them.
fn is_joiner_or_variation_selector(c: char) -> bool {
    matches!(c as u32,
        0x200C | 0x200D
        | 0xFE00..=0xFE0F
        | 0xE0100..=0xE01EF
    )
}

/// For OSC 0/1/2 titles and OSC 9/777 notifications. Strips rather than rejects (that would drop
/// the whole title): AppKit's titlebar honours U+202E.
pub(crate) fn scrub_title_controls(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        let is_c0 = cp <= 0x1F;
        let is_del = cp == 0x7F;
        let is_c1 = (0x80..=0x9F).contains(&cp);
        if is_c0 || is_del || is_c1 {
            continue;
        }
        if is_bidi_or_invisible_scalar(c) && !is_joiner_or_variation_selector(c) {
            continue;
        }
        out.push(c);
    }
    out
}

/// Invalid UTF-8 returns `true` (refuse).
pub(crate) fn contains_bidi_or_invisible(bytes: &[u8]) -> bool {
    let Ok(s) = std::str::from_utf8(bytes) else {
        return true;
    };
    s.chars().any(is_bidi_or_invisible_scalar)
}

/// RFC 3986 §3.1 / §3.2.2: scheme and host are case-insensitive; the path is not normalised.
pub(crate) fn strip_prefix_ascii_case_insensitive<'a>(
    s: &'a [u8],
    prefix: &[u8],
) -> Option<&'a [u8]> {
    if s.len() < prefix.len() {
        return None;
    }
    let (head, rest) = s.split_at(prefix.len());
    if head.eq_ignore_ascii_case(prefix) {
        Some(rest)
    } else {
        None
    }
}

/// RFC 3986 percent-decode. `None` only on a truncated or non-hex escape.
pub(crate) fn percent_decode(bytes: &[u8]) -> Option<Vec<u8>> {
    fn hex(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            out.push((hex(bytes[i + 1])? << 4) | hex(bytes[i + 2])?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
}
