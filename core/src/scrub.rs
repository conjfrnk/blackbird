//! Text-sanitization primitives shared across the OSC parse paths: the
//! canonical bidi/zero-width/invisible codepoint set (single source of
//! truth — REFACTOR.md Part III §3), the title control scrubber, and the
//! percent-decoder. Pure functions, no in-crate dependencies.

/// True for Unicode scalars that NSWindow / NSTextField will render in a
/// way the user can't see: bidi-control overrides, zero-width joiners,
/// invisible tag-block / variation-selector codepoints, and the BOM.
///
/// Sibling of `contains_bidi_or_invisible`'s byte-shape sweep below — the
/// scalar list MUST stay in lock-step with it. If you add a codepoint to
/// one, add the matching UTF-8 byte range to the other (and vice versa).
/// The two functions exist because their input shapes differ: this one
/// takes a `char` (callers already validated UTF-8), while
/// `contains_bidi_or_invisible` takes raw bytes (post-percent-decode
/// payloads that may not yet be valid UTF-8).
///
/// Codepoints rejected (mirroring `contains_bidi_or_invisible`'s byte
/// table, see its doc for the byte ranges):
///   U+00AD (SHY), U+061C (ALM), U+180E (MVS),
///   U+200B..=U+200F (ZWSP/ZWNJ/ZWJ/LRM/RLM),
///   U+2028..=U+202E (LS/PS, LRE/RLE/PDF/LRO/RLO),
///   U+2060 (WJ), U+2066..=U+2069 (LRI/RLI/FSI/PDI),
///   U+FE00..=U+FE0F (variation selectors 1..16), U+FEFF (BOM/ZWNBSP),
///   U+E0000..=U+E007F (tag block),
///   U+E0100..=U+E01EF (variation selectors 17..256).
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

/// Strip C0 controls (U+0000..=U+001F), DEL (U+007F), C1 controls
/// (U+0080..=U+009F), AND bidi-control / invisible scalars from an OSC
/// 0/1/2 window-title payload.
///
/// Bug #18: a hostile stream sets the title to `before\x1b[31mafter`;
/// downstream loggers / accessibility consumers misinterpret the embedded
/// controls even though NSWindow sanitizes for display.
///
/// Audit H-5 (2026-04-29): C0/C1 stripping isn't enough. A hostile shell
/// can emit `\x1b]2;safe\u{202E}txt\x07` and AppKit's titlebar honours
/// U+202E (RIGHT-TO-LEFT OVERRIDE), visually flipping the suffix to
/// `txt.efas` while the underlying title stays whatever the shell said.
/// The OSC 7 path got `contains_bidi_or_invisible` (rejection); the title
/// path can't reject (that would drop the entire title), so we strip the
/// offending scalars in-place and keep everything else.
///
/// Codepoint-wise filter so C1 (UTF-8 `0xC2 0x80..=0xC2 0x9F`) drops by
/// a single `c <= '\u{9F}'` check rather than a fragile byte sweep that
/// would corrupt multi-byte UTF-8.
///
/// Allocation note: alacritty hands us a `&String`; a clean (no-control)
/// title is the common case. We could short-circuit when no control char
/// is present, but the title path fires once per OSC 0/2 dispatch — at
/// most a few times per second even for animated TUIs — so a single
/// always-allocate keeps the code obvious.
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
        if is_bidi_or_invisible_scalar(c) {
            continue;
        }
        out.push(c);
    }
    out
}

/// True when `bytes` contains any UTF-8 sequence for a Unicode bidi-
/// control / zero-width / invisible-payload codepoint, OR when `bytes`
/// is not valid UTF-8 at all (caller-policy: refuse). Symmetric with
/// the Swift paste sanitizer's `stripBidiOverrides` byte map.
///
/// Used by `handle_osc7` to refuse cwd paths that would visually
/// spoof the titlebar / "Open in Finder" target. A path like
/// `/Users/foo/%E2%80%AE.bashrc` decodes to RLO + `.bashrc`; any
/// renderer that honours bidi (NSTextField, AppKit titlebar) flips
/// the visible suffix while the filesystem target stays whatever the
/// shell actually said. The defense lives at the parse boundary so
/// EVERY downstream consumer of the path benefits.
///
/// Reviewer feedback (2026-04-29): the previous implementation was a
/// hand-rolled UTF-8 byte sweep that duplicated the codepoint list in
/// `is_bidi_or_invisible_scalar`. Two encodings of the same set drift
/// the moment one is updated and the other isn't. Delegating to
/// `is_bidi_or_invisible_scalar` makes them mechanically equivalent —
/// the canonical list lives in exactly one place.
///
/// Behavior on invalid UTF-8: returns `true` (refuse). This is a
/// no-op vs. the previous behavior at the only call site
/// (`handle_osc7` already gates `std::str::from_utf8(&decoded)`
/// BEFORE this check, so invalid UTF-8 returns early there). Stating
/// the policy here makes future call sites safer-by-default.
///
/// Codepoint set rejected — see `is_bidi_or_invisible_scalar` for the
/// canonical list. Audit M2.
pub(crate) fn contains_bidi_or_invisible(bytes: &[u8]) -> bool {
    let Ok(s) = std::str::from_utf8(bytes) else {
        return true;
    };
    s.chars().any(is_bidi_or_invisible_scalar)
}

/// Strip `prefix` from `s` using ASCII case-insensitive comparison.
/// Returns `Some(remainder)` on match, `None` otherwise. Used by the
/// OSC 7 ingest gate to honour RFC 3986 §3.1 / §3.2.2 (scheme and host
/// are case-insensitive) without normalising the path component (which
/// is case-sensitive on POSIX). Audit fix-#08 (2026-05-21).
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

/// RFC 3986 percent-decode. Returns `None` only on truncated escapes
/// (`%` with fewer than two hex digits remaining) or non-hex digits.
/// Raw bytes pass through unchanged.
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
