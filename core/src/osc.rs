//! The parallel OSC tap: a second, stateful `vte::Perform` (`OscScanner`)
//! driven alongside alacritty's own parser to handle the sequences alacritty
//! 0.26 leaves unhandled — OSC 7 (cwd), OSC 133 (prompt marks), and Kitty's
//! XTGETTCAP capability protocol. Kept strictly separate from the grid-
//! mutation path (Part I §8). Moved out of the monolith verbatim
//! (REFACTOR.md Wave 1); behavior unchanged.

use alacritty_terminal::vte::{Params, Perform};

use crate::callback::CallbackCell;
use crate::event::{BBEvent, BBEventKind};
use crate::rate_limit::{Osc7RateState, PromptMarkRateState, PROMPT_MARK_PER_SECOND};
use crate::scrub::{
    contains_bidi_or_invisible, is_bidi_or_invisible_scalar, percent_decode,
    strip_prefix_ascii_case_insensitive,
};
use crate::BBPromptMarkKind;

/// Build an [`OscScanner`] borrowing the scanner-relevant `BBTerm` fields.
///
/// A macro rather than a `fn osc_scanner(&mut self)` method on purpose: the
/// scanner borrows `cell` shared and nine other fields mutably, while the
/// caller still needs a *disjoint* `&mut bb.osc_parser` to drive it
/// (`bb.osc_parser.advance(&mut scanner, …)`). A `&mut self` method would lock
/// the whole `BBTerm` and the parser borrow would conflict; a macro expands
/// inline so the borrow checker sees the per-field split. Kills the verbatim
/// 10-field constructor that was copy-pasted at both `process_input` sites
/// (REFACTOR.md Part IV).
macro_rules! osc_scanner {
    ($bb:expr) => {
        $crate::osc::OscScanner {
            cell: &$bb.callback,
            in_xtgettcap: &mut $bb.in_xtgettcap,
            xtgettcap_buf: &mut $bb.xtgettcap_buf,
            modify_other_keys: &mut $bb.modify_other_keys,
            prompt_mark_rate: &mut $bb.prompt_mark_rate,
            osc7_rate: &mut $bb.osc7_rate,
            osc7_reject_logged: &mut $bb.osc7_reject_logged,
            osc133_d_nondigit_logged: &mut $bb.osc133_d_nondigit_logged,
            osc133_abc_tainted_logged: &mut $bb.osc133_abc_tainted_logged,
            osc133_rate_limited_logged: &mut $bb.osc133_rate_limited_logged,
        }
    };
}
pub(crate) use osc_scanner;

// ---------------------------------------------------------------------------
// OscScanner — parallel vte::Parser tap for OSC sequences we handle outside
// of alacritty: OSC 7 (cwd) and OSC 133 (prompt marks).
// ---------------------------------------------------------------------------

/// Minimal `vte::Perform` impl that fires on OSC 7, OSC 133, and
/// XTGETTCAP (DCS `+ q` ... ST) payloads.
///
/// `alacritty_terminal` 0.26 / `vte` 0.15 do not handle these themselves —
/// they fall through vte's `osc_dispatch` to the unhandled branch. Rather
/// than wrap alacritty's `Handler` (which has a ~90-method surface we'd
/// have to forward perfectly), we run a second, stateful `vte::Parser`
/// owned by `BBTerm` and driven from `bb_term_input` with the same byte
/// stream. That parser drives this scanner, which dispatches by the first
/// OSC param and no-ops every other Perform method — except `hook`/`put`/
/// `unhook`, which implement Kitty's XTGETTCAP capability query protocol.
///
/// Consolidated from two separate parsers (one per OSC number) into one —
/// the earlier split cost ~15% of throughput because every byte was run
/// through three parsers total (alacritty's main + two parallels). One
/// scanner with an inexpensive first-param check is strictly cheaper.
///
/// XTGETTCAP state lives on `BBTerm` rather than this scanner because DCS
/// sequences can fragment across multiple `bb_term_input` calls; the
/// scanner is re-created per call and borrows the state via `&mut`.
pub(crate) struct OscScanner<'a> {
    pub(crate) cell: &'a CallbackCell,
    pub(crate) in_xtgettcap: &'a mut bool,
    pub(crate) xtgettcap_buf: &'a mut Vec<u8>,
    /// xterm `modifyOtherKeys` level bucket. `csi_dispatch` updates this
    /// when it sees `CSI > 4 ; N m`. 0 = off, 1 / 2 = level. Writer
    /// into `BBTerm.modify_other_keys`; downstream code reads the same
    /// field and maps non-zero to `bb_mode::MODIFY_OTHER_KEYS`.
    pub(crate) modify_other_keys: &'a mut u8,
    /// Sliding-window state for OSC 133 A/B/C rate limiting (audit
    /// synthesis #10 — prompt-mark forgery DoS / phishing). Persisted
    /// on `BBTerm` and threaded in via `&mut` because the scanner is
    /// rebuilt per `bb_term_input` call.
    pub(crate) prompt_mark_rate: &'a mut PromptMarkRateState,
    /// Sliding-window state for OSC 7 (CWD) ingest rate limiting (audit
    /// M-7 — `classifyForegroundNamespace()` proc_listpids amplification).
    /// Same threading reason as `prompt_mark_rate`.
    pub(crate) osc7_rate: &'a mut Osc7RateState,
    /// Per-class reject-log latches (audit L3). Threaded in from
    /// BBTerm so the one-shot-per-class log is per-instance rather
    /// than process-wide.
    pub(crate) osc7_reject_logged: &'a mut [bool; 8],
    /// One-shot latch for the OSC 133 D non-digit reject path
    /// (audit L1 + reviewer follow-up). Mirrors the per-instance
    /// stance L3 established for OSC 7.
    pub(crate) osc133_d_nondigit_logged: &'a mut bool,
    /// One-shot latch for the OSC 133 A/B/C tainted-payload reject path
    /// (audit S3R-001/S3R-002 + silent-failure review). Same per-instance,
    /// one-shot rule as the D-path latch so a hostile flood can't drown the
    /// log while still leaving one breadcrumb when prompt marks are dropped.
    pub(crate) osc133_abc_tainted_logged: &'a mut bool,
    /// One-shot latch for the OSC 133 rate-cap drop path (audit S5-009).
    /// Dropped marks are user-visible (missing ⌘-navigation entries,
    /// lost exit codes), so the first drop per session must leave a
    /// breadcrumb; per-drop logging would amplify the flood the cap
    /// defends against.
    pub(crate) osc133_rate_limited_logged: &'a mut bool,
}

/// Maximum byte length of a single OSC 7 URL accepted for percent-decode
/// (audit L-20, 2026-04-29). OSC 8's `OSC8_URI_MAX` is 4096 by the same
/// reasoning: a legitimate `file://` URL for a cwd is at most a few
/// hundred bytes; oversized payloads are either malicious spam or a
/// bug, and the unbounded `Vec::with_capacity(bytes.len())` inside
/// `percent_decode` would otherwise let a remote allocate megabytes per
/// OSC 7 chunk.
pub(crate) const OSC7_URL_MAX: usize = 4096;

impl Perform for OscScanner<'_> {
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        // Dispatch by OSC number. The first param is always the
        // semicolon-separated numeric prefix (e.g. `7`, `133`).
        //
        // We deliberately handle only the OSC numbers that need a
        // Blackbird-side hook: 7 (CWD reporting) and 133 (semantic prompt
        // marks). All other OSC numbers fall through to alacritty's main
        // `Processor` driving `bb.term`. Alacritty handles 0/1/2 (window
        // titles), 4 (palette set), 8 (hyperlinks via the cell hyperlink
        // path), 10/11/12 + 104/110/111/112 (default fg/bg/cursor color
        // get/reset, surfaced via our color-query hook), 50 (cursor),
        // 52 (clipboard — pinned `Disabled`), 110/111/112 (color resets),
        // and a few it explicitly ignores.
        //
        // Anything not matched here AND not handled by alacritty (OSC 6
        // working-file, OSC 1337 iTerm2 extensions, etc.) is silently
        // dropped at both layers. If you add a new Blackbird-owned OSC
        // hook, list it here so this catch-all stays auditable.
        match params.first().copied() {
            Some(b"7") => self.handle_osc7(params),
            Some(b"133") => self.handle_osc133(params),
            _ => {}
        }
        // bell_terminated is irrelevant to downstream semantics; included
        // here only to satisfy the Perform signature.
        let _ = bell_terminated;
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // xterm `modifyOtherKeys`: `CSI > 4 ; N m`. `>` is the only
        // intermediate; first param == 4; second param == 0 (off), 1
        // (level 1), or 2 (level 2). We also accept `CSI > 4 m` (no
        // second param) as the reset form, matching xterm's manpage.
        // alacritty_terminal 0.26.0 does not handle this sequence —
        // we own the entire parse path for it.
        if action == 'm' && intermediates == [b'>'] {
            let mut it = params.iter();
            let first = it.next().and_then(|p| p.first().copied());
            if first == Some(4) {
                let level = it.next().and_then(|p| p.first().copied()).unwrap_or(0);
                let clamped: u8 = match level {
                    0 => 0,
                    1 | 2 => level as u8,
                    _ => return, // unknown level — ignore, don't poison state
                };
                *self.modify_other_keys = clamped;
            }
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        // RIS (`ESC c`): full terminal reset. The main alacritty
        // `Processor` driving `bb.term` resets its `TermMode` to
        // defaults on this same byte (via `Term::reset_state`),
        // clearing the Kitty-keyboard / app-cursor / bracketed-paste
        // bits. `modify_other_keys` is Blackbird-side sidecar state
        // that alacritty never sees (we own the entire `CSI > 4 ; N m`
        // parse — see `csi_dispatch` above), so without mirroring the
        // reset here it stays latched across RIS:
        // `extract_mode_with_extras` keeps OR-ing in MODIFY_OTHER_KEYS
        // and Swift's KeyEncoder keeps emitting `CSI 27 ; <mod> ; <cp>
        // ~` for modified keys to a shell that just reset itself and no
        // longer understands the encoding. Clear it so the reported
        // mode tracks the reset, matching xterm semantics (the bit doc
        // at the top of this file states RIS clears modifyOtherKeys).
        //
        // RIS only — deliberately NOT DECSTR (`CSI ! p`): this
        // alacritty/vte version has no DECSTR handler, so a soft reset
        // leaves alacritty's own modes untouched. Clearing
        // modify_other_keys on DECSTR while Kitty / app-cursor /
        // bracketed-paste stay set would introduce the opposite
        // desync. Mirror alacritty exactly.
        if byte == b'c' && intermediates.is_empty() {
            *self.modify_other_keys = 0;
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // XTGETTCAP opens as `ESC P + q` — intermediates == [b'+'],
        // final byte == 'q'. Any other DCS (sixel, sync output, iTerm2
        // conductor, etc.) stays inert: `dcs_rejection` tests pin that.
        if intermediates == b"+" && action == 'q' {
            *self.in_xtgettcap = true;
            self.xtgettcap_buf.clear();
        }
    }

    fn put(&mut self, byte: u8) {
        // Only collect while inside a recognized XTGETTCAP sequence. Cap
        // at 4 KiB as a DoS backstop: a legitimate query is at most a
        // few hundred bytes; truncation of an oversized query produces
        // a short reply rather than a crash or unbounded allocation.
        if *self.in_xtgettcap && self.xtgettcap_buf.len() < 4096 {
            self.xtgettcap_buf.push(byte);
        }
    }

    fn unhook(&mut self) {
        if !*self.in_xtgettcap {
            return;
        }
        *self.in_xtgettcap = false;
        // `std::mem::take` moves the buffer's bytes+allocation out into
        // `buf` for the reply-building step; the field becomes
        // `Vec::new()` (capacity 0). The next DCS will re-alloc on its
        // first `put()`. XTGETTCAP is human-rate so this churn is
        // invisible; simpler code wins over a micro-optimization.
        let buf = std::mem::take(self.xtgettcap_buf);
        // SAFETY: our parallel `vte::Parser` is driven from
        // `bb_term_input` OUTSIDE alacritty's `&mut Term` borrow, so
        // firing synchronously here is safe — we are not re-entering
        // alacritty. No deferred queue needed (unlike OSC 10/11/12,
        // which must defer because they hit the palette mid-borrow).
        unsafe { dispatch_xtgettcap(self.cell, &buf) };
    }
}

/// Fire one `PtyWrite` reply per `;`-delimited cap. Unknown caps reply
/// with status 0 and no `=value`. Match replies echo the request's cap
/// hex verbatim (preserving casing) so TUIs can correlate requests and
/// replies without canonicalizing.
///
/// # Safety
/// Caller must ensure single-threaded access to `cell` (standard BBTerm
/// thread discipline).
unsafe fn dispatch_xtgettcap(cell: &CallbackCell, payload: &[u8]) {
    for cap_hex in payload.split(|&b| b == b';') {
        if cap_hex.is_empty() {
            // `;;` or leading/trailing `;` — skip silently.
            continue;
        }
        let reply = build_xtgettcap_reply(cap_hex);
        cell.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: reply.as_ptr(),
            len: reply.len(),
            i32_arg: 0,
        });
        // `reply` drops here; `fire` is synchronous so the C callback
        // has already consumed the bytes by the time we release.
    }
}

fn build_xtgettcap_reply(cap_hex: &[u8]) -> Vec<u8> {
    // Reject anything that isn't pure hex. XTGETTCAP specifies the payload
    // as hex-encoded cap name bytes (each cap name byte = 2 hex digits),
    // but nothing upstream enforced it — an ssh'd attacker could smuggle
    // `\x1b\\` (ST) or other control bytes inside the cap_hex echo of the
    // DCS-0-r "unknown" response, terminating the DCS early and landing
    // the tail bytes as top-level input (shell-injection primitive on the
    // remote). Audit rust-core-1 F8. Unknown non-hex cap → reply with an
    // empty cap name so the reply stays well-formed and the echo channel
    // closes.
    //
    // S3-004: also require EVEN length. Odd-length all-hex payloads
    // (e.g. a 3-char query, or a 4097-byte query truncated mid-pair)
    // are still "pure hex" but echo as a malformed cap name with a
    // half-byte at the tail — every legitimate downstream consumer
    // expects paired hex digits. Reject as malformed alongside the
    // non-hex case.
    let is_valid_hex = !cap_hex.is_empty()
        && cap_hex.len() % 2 == 0
        && cap_hex.iter().all(|b| b.is_ascii_hexdigit());
    match (is_valid_hex, find_cap_value(cap_hex)) {
        (true, Some(value_hex)) => {
            // DCS 1 + r <cap>=<value> ST
            let mut v = Vec::with_capacity(cap_hex.len() + value_hex.len() + 8);
            v.extend_from_slice(b"\x1bP1+r");
            v.extend_from_slice(cap_hex);
            v.push(b'=');
            v.extend_from_slice(value_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (true, None) => {
            // DCS 0 + r <cap> ST — hex echo is safe.
            let mut v = Vec::with_capacity(cap_hex.len() + 7);
            v.extend_from_slice(b"\x1bP0+r");
            v.extend_from_slice(cap_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (false, _) => {
            // DCS 0 + r ST — no echo; hostile bytes dropped.
            b"\x1bP0+r\x1b\\".to_vec()
        }
    }
}

/// ASCII-case-insensitive lookup against `XTGETTCAP_TABLE`. Cap hex is
/// canonically uppercase, but tolerate lowercase defensively — some
/// ncurses builds lowercase hex when emitting `tput`-style queries.
fn find_cap_value(cap_hex: &[u8]) -> Option<&'static [u8]> {
    for (key, value) in XTGETTCAP_TABLE {
        if cap_hex.eq_ignore_ascii_case(key) {
            return Some(value);
        }
    }
    None
}

/// Kitty XTGETTCAP capabilities Blackbird claims. Each row is
/// (hex-encoded cap name, hex-encoded terminfo-compiled value).
///
/// Values are the bytes of the terminfo string, hex-encoded upper-case.
/// `\E` in terminfo source is ESC (0x1B), not a literal `\`+`E`, so the
/// hex is `1B` in those positions.
///
/// Claimed caps (why each matters):
/// - TN     = "xterm-kitty"  — the terminal identity string some TUIs
///   key on to enable advanced protocols.
/// - Co     = "16777216"     — color count. Pre-LOW-sweep this was
///   "256" (legacy default), which made `tput colors` report 256 even
///   though Blackbird decodes truecolor SGR 38;2;R;G;Bm — TUIs that
///   gate truecolor branches on the terminfo Co value (mc, less +F,
///   ranger, some neovim plugins) fell back to 256-color paths.
///   Audit NEW-DF-004.
/// - RGB    = "8"             — truecolor bits per channel.
/// - Smulx  = "\E[4:%p1%dm"   — styled underline select (SGR 4:n).
/// - Setulc = "\E[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
///   — RGB underline color (SGR 58:2:R:G:B).
///
/// Smulx/Setulc together are what nvim probes before emitting colored
/// undercurl (`spellbad`, LSP diagnostics). Getting both right is the
/// whole point of claiming xterm-kitty.
///
/// Test `core/tests/xtgettcap.rs::xtgettcap_smulx_returns_expected_hex`
/// and `..._setulc_returns_expected_hex` pin these exact hex strings.
static XTGETTCAP_TABLE: &[(&[u8], &[u8])] = &[
    // TN     = "TN"     → 544E        value "xterm-kitty"  → 787465726D2D6B69747479
    (b"544E", b"787465726D2D6B69747479"),
    // Co     = "Co"     → 436F        value "16777216"     → 3136373737323136
    (b"436F", b"3136373737323136"),
    // RGB    = "RGB"    → 524742      value "8"            → 38
    (b"524742", b"38"),
    // Smulx  = "Smulx"  → 536D756C78  value "\x1B[4:%p1%dm"
    //                                 → 1B5B343A25703125646D
    (b"536D756C78", b"1B5B343A25703125646D"),
    // Setulc = "Setulc" → 536574756C63
    //                                 value "\x1B[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
    //                                 → see test for byte-by-byte derivation
    (
        b"536574756C63",
        b"1B5B35383A323A3A257031257B36353533367D252F25643A257032257B3235367D252F25643A2570332564253B6D",
    ),
];

/// Reject-class indices for `osc7_reject` — keep stable so the per-class
/// `Once` instances (and any future test that asserts a specific class
/// fired) line up across builds.
const OSC7_REJECT_RATE: usize = 0;
const OSC7_REJECT_PERCENT_DECODE: usize = 1;
const OSC7_REJECT_UTF8: usize = 2;
const OSC7_REJECT_NUL: usize = 3;
const OSC7_REJECT_CONTROL: usize = 4;
const OSC7_REJECT_BIDI: usize = 5;
const OSC7_REJECT_NON_ABSOLUTE: usize = 6;
const OSC7_REJECT_TRAVERSAL: usize = 7;
/// Per-class one-shot latches. Audit follow-up (2026-04-29): the eight
/// silent `return` paths in `handle_osc7` made an attacker / shell-misbehaving
/// regression invisible. One-shot per class so a sustained flood doesn't
/// drown the log; the first reject of each shape produces a breadcrumb.
///
/// Audit L3: latches live in `BBTerm` rather than a process-wide static.
/// Pre-fix, the first BBTerm to fire each rejection class consumed the
/// `Once` for the whole process; sibling tabs (or the same tab on a
/// fresh shell) silently dropped the same reject — a multi-tab session
/// that hits one class on tab 1 lost the breadcrumb on tabs 2..N.
/// Per-instance bool flags restore one-shot-per-tab semantics without
/// re-introducing log floods.
fn osc7_reject(latches: &mut [bool; 8], class: usize, name: &str) {
    if let Some(slot) = latches.get_mut(class) {
        if !*slot {
            *slot = true;
            eprintln!("[blackbird_core] OSC 7 rejected ({})", name);
        }
    }
}

impl OscScanner<'_> {
    fn handle_osc7(&mut self, params: &[&[u8]]) {
        let Some(url) = params.get(1) else { return };

        // Audit L-20 (2026-04-29): cap the input length BEFORE
        // `percent_decode`. percent_decode does
        // `Vec::with_capacity(bytes.len())`, so an unbounded URL lets a
        // hostile remote allocate megabytes per OSC 7 chunk. OSC 8 caps
        // its URI at the same shape (`OSC8_URI_MAX = 4096`); legitimate
        // `file://` cwd URLs are at most a few hundred bytes.
        //
        // The length check stays FIRST (free, no allocation, no state
        // mutation) so an oversized hostile URL never even consumes a
        // rate-limit slot.
        if url.len() > OSC7_URL_MAX {
            return;
        }

        // Audit S4-001 (2026-05-30): EVERY reject path — structural (scheme,
        // authority, below) AND semantic (percent-decode, UTF-8, NUL,
        // control, bidi, absolute-path, traversal) — runs BEFORE the rate
        // gate, which now sits immediately before the CwdChanged emission at
        // the end of this function. So a hostile remote firing OSC 7s that
        // will be rejected — wrong scheme `http://x`, or `file://`-valid-but-
        // tainted like `file:///%E2%80%AE` (bidi) / `file:///%2e%2e/x`
        // (traversal) — consumes ZERO budget, and a legitimate
        // `OSC 7;file:///Users/foo/proj` from the user's own shell can't be
        // starved out of the 1-second window by a flood that was never going
        // to emit an event. (The earlier 2026-04-29 reorder moved the gate
        // past scheme+authority only; this moves it past every reject path.)
        // L-20's length cap (above) and the M-7 proc_listpids gate (below)
        // both remain enforced.

        // Accept only `file://` with an empty or `localhost` authority.
        // Audit fix-#08 (2026-05-21): RFC 3986 §3.1 / §3.2.2 define
        // scheme and host as case-insensitive. Match the literal prefix
        // case-insensitively so shell emitters that produce `FILE://`,
        // `File://localhost/...`, `file://LocalHost/...` etc. are not
        // silently dropped at ingest. The path portion stays
        // case-sensitive (POSIX paths are).
        let Some(rest) = strip_prefix_ascii_case_insensitive(url, b"file://") else {
            return;
        };
        let path_bytes: &[u8] = if rest.starts_with(b"/") {
            rest // "file:///path" → "/path"
        } else if let Some(r) = strip_prefix_ascii_case_insensitive(rest, b"localhost") {
            if !r.starts_with(b"/") {
                return;
            }
            r // "file://localhost/path" → "/path"
        } else {
            return; // non-local host
        };

        let Some(decoded) = percent_decode(path_bytes) else {
            osc7_reject(
                self.osc7_reject_logged,
                OSC7_REJECT_PERCENT_DECODE,
                "percent_decode",
            );
            return;
        };
        // Spec (2026-04-17-blackbird-gaps-design.md §4.1): "Malformed UTF-8
        // in the path is ignored." Percent-decoding can produce arbitrary
        // byte sequences (e.g. `file:///%ff`), so validate before firing.
        // The event's payload contract in `BBEventKind::CwdChanged` is
        // UTF-8 bytes — Swift wraps the pointer in a Swift String which
        // assumes UTF-8 validity.
        let Ok(decoded_str) = std::str::from_utf8(&decoded) else {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_UTF8, "utf8");
            return;
        };
        // Reject embedded NUL bytes. `%00` is valid UTF-8 and slips past
        // the str::from_utf8 gate, but a pathname containing NUL is
        // nonsense at the OS level (C string terminator) and lets a
        // hostile payload truncate what downstream consumers see when
        // they cast through a C API. TST-S1-014.
        if decoded.contains(&0) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_NUL, "nul");
            return;
        }
        // Reject every other ASCII control byte (0x01..=0x1F, 0x7F) AND
        // C1 controls (U+0080..=U+009F). Same shape as OSC title scrub
        // (scrub_title_controls): control codepoints in a chrome-
        // displayed string can fool screen readers, log shippers, or
        // any downstream parser that doesn't pre-scrub.
        //
        // Audit S3-001: this used to be a byte-wise sweep that missed
        // C1 controls — U+0080..U+009F encodes as `0xC2 0x80..0xC2 0x9F`
        // in UTF-8, and neither byte is `< 0x20`. The title path was
        // already codepoint-level (see scrub_title_controls comment at
        // L525-527: "byte sweep would corrupt multi-byte UTF-8"). This
        // gate now walks `chars()` so the two paths agree.
        if decoded_str.chars().any(|c| {
            let cp = c as u32;
            cp <= 0x1F || cp == 0x7F || (0x80..=0x9F).contains(&cp)
        }) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_CONTROL, "control");
            return;
        }
        // Reject Unicode bidi-control / zero-width / invisible-payload
        // codepoints in the path. Without this gate a hostile shell can
        // emit `OSC 7;file:///Users/foo/%E2%80%AE.bashrc` and the
        // titlebar proxy icon / "Open in Finder" affordance displays
        // the path RTL-flipped (visual `cqahsab.<rtl>oof/sresU/` while
        // the actual filesystem target is what Finder will open). Same
        // codepoint list the Swift paste sanitizer strips. Audit M2.
        if contains_bidi_or_invisible(decoded.as_slice()) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_BIDI, "bidi");
            return;
        }
        // Audit synthesis #13 — path-traversal via percent-encoded `..`.
        // An attacker can emit `OSC 7;file:///%2e%2e/%2e%2e/etc/`. After
        // percent-decode the path is `../../../../etc/`; downstream
        // consumers (titlebar proxy icon, "Open in Finder", new-tab cwd
        // inheritance) all use the raw value via NSWorkspace. Drop the
        // event silently on any `..` segment OR any non-absolute path.
        // OSC 7 specifies an absolute path; relative paths are illegal
        // by spec.
        if !decoded_str.starts_with('/') {
            osc7_reject(
                self.osc7_reject_logged,
                OSC7_REJECT_NON_ABSOLUTE,
                "non_absolute",
            );
            return;
        }
        for component in std::path::Path::new(decoded_str).components() {
            match component {
                // The standard parent-dir component.
                std::path::Component::ParentDir => {
                    osc7_reject(self.osc7_reject_logged, OSC7_REJECT_TRAVERSAL, "traversal");
                    return;
                }
                // Defensive paranoia for the `\..` shape on
                // case-insensitive HFS+ / APFS — a literal `Normal`
                // component whose bytes equal `..` would mean some
                // higher layer mis-parsed components, but we'd still
                // refuse it.
                std::path::Component::Normal(s) if s.as_encoded_bytes() == b".." => {
                    osc7_reject(self.osc7_reject_logged, OSC7_REJECT_TRAVERSAL, "traversal");
                    return;
                }
                _ => {}
            }
        }
        // Audit synthesis #4 (SSH-trust): the gate lives on the Swift
        // side because the Rust core can't see the foreground process
        // tree. `TerminalSession` walks `proc_listpids(PROC_PPID_ONLY)`
        // from the fg pgroup and drops `.cwdChanged` events at ingest
        // when the tree contains an `ssh`/`mosh-client`/`docker`/etc
        // binary. Shipped 2026-04-28; this site stays validation-only.

        // Audit M-7 (2026-04-29) + S4-001 (2026-05-30): rate-limit ingest,
        // positioned AFTER every validation/reject path so that ONLY OSC 7s
        // which will actually emit a CwdChanged consume a budget slot — a
        // flood of rejected payloads (wrong scheme, bidi, traversal, …) can
        // no longer starve a legitimate cwd update out of the window
        // (S4-001). Legitimate shells emit one OSC 7 per `cd`; a hostile
        // remote streaming VALID `file://` cwds in a tight loop still forces
        // Swift's `classifyForegroundNamespace()` to run a `proc_listpids`
        // BFS per event (main-thread work that beachballs the UI), so excess
        // valid events are still dropped within the sliding window (M-7).
        if !self.osc7_rate.allow() {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_RATE, "rate");
            return;
        }

        let ev = BBEvent {
            kind: BBEventKind::CwdChanged,
            payload: decoded.as_ptr(),
            len: decoded.len(),
            i32_arg: 0,
        };
        // SAFETY: `cell` is a live reference for the duration of this call;
        // `fire` invokes the C callback synchronously, so `decoded` (owned
        // by this stack frame) outlives the borrow the callback receives.
        // `decoded` drops at the end of this scope, after `fire` returns.
        unsafe { self.cell.fire(ev) };
    }

    fn handle_osc133(&mut self, params: &[&[u8]]) {
        let Some(kind_param) = params.get(1) else {
            return;
        };
        let kind_param = *kind_param;
        // The common split: some shells emit `OSC 133 ; D ; <code> ST` →
        // params = [b"133", b"D", b"0"]. Others combine: `OSC 133 ; D;0` →
        // params = [b"133", b"D;0"]. Handle both so snippets from iTerm2,
        // kitty, fish, starship, etc. all work.
        let (kind_byte, exit_code_bytes): (u8, &[u8]) = if kind_param.len() == 1 {
            (kind_param[0], params.get(2).copied().unwrap_or(b""))
        } else if let Some(idx) = kind_param.iter().position(|&b| b == b';') {
            // `D;<code>` — split on the first ';'.
            (kind_param[0], &kind_param[idx + 1..])
        } else {
            // Longer than 1 byte without a ';' — unknown extension.
            return;
        };

        let kind: u8 = match kind_byte {
            b'A' => BBPromptMarkKind::A as u8,
            b'B' => BBPromptMarkKind::B as u8,
            b'C' => BBPromptMarkKind::C as u8,
            b'D' => BBPromptMarkKind::D as u8,
            _ => return, // unknown sub-kind — silently ignore rather than crash.
        };

        // Audit synthesis #10 + RC-03 — OSC 133 prompt-mark forgery DoS / phishing.
        // Rate-limit ALL mark kinds (A = prompt start, B = command start,
        // C = command output, D = command end with exit code) at
        // PROMPT_MARK_PER_SECOND per rolling 1-second window.
        //
        // Earlier versions exempted D on the assumption it was tied 1:1
        // to an accepted C, but the code never enforced that pairing. A
        // hostile remote could spam `OSC 133;D;0\x07` to rotate
        // legitimate D entries out of Swift's bounded prompt ring. A
        // marks (the navigation targets) were already protected, so the
        // realistic impact was exit-code history corruption rather than
        // navigable-prompt forgery — but the comment claimed an
        // invariant the code didn't keep. Including D in the gate
        // restores the comment-vs-code contract.
        if matches!(kind_byte, b'A' | b'B' | b'C' | b'D') && !self.prompt_mark_rate.allow() {
            // Audit S5-009: dropped marks silently degrade ⌘ prompt
            // navigation and exit-code chrome — leave one breadcrumb
            // per session (same one-shot stance as the sibling reject
            // latches above/below).
            if !*self.osc133_rate_limited_logged {
                *self.osc133_rate_limited_logged = true;
                eprintln!(
                    "[blackbird_core] OSC 133 prompt-mark rate cap ({PROMPT_MARK_PER_SECOND}/s) \
                     engaged — dropping excess marks. One-shot per session."
                );
            }
            return;
        }

        // Cap exit-code payload at 16 bytes. A well-behaved shell emits
        // at most 3–4 digits; anything longer is either malicious spam or
        // a bug and the hosting TUI wouldn't know what to do with it
        // either.
        let cap = exit_code_bytes.len().min(16);
        let payload = &exit_code_bytes[..cap];

        // Audit L1. Validate the D-kind payload as ASCII decimal digits
        // before delivering. A hostile shell can emit OSC 133;D;<bytes>
        // ST with arbitrary control characters; the Swift consumer
        // turns the payload into a String for display alongside the
        // prompt-mark UI. Non-digit bytes (NUL, ESC, OSC re-entry,
        // bidi controls) reach Swift as a String containing those
        // bytes' UTF-8 replacement-character interpretation, which
        // can confuse downstream rendering. Be symmetric with the
        // OSC 7 cwd path which already refuses control bytes.
        // Drop the whole event when the payload is non-numeric —
        // we'd rather omit the exit code than display garbage.
        if kind_byte == b'D' && !payload.is_empty() && !payload.iter().all(|b| b.is_ascii_digit()) {
            // Mirror L3's per-instance one-shot logging stance:
            // first reject of this class on this BBTerm produces a
            // breadcrumb; subsequent rejects stay silent so a flood
            // can't drown the log.
            if !*self.osc133_d_nondigit_logged {
                *self.osc133_d_nondigit_logged = true;
                eprintln!("[blackbird_core] OSC 133 D rejected (non-digit payload)");
            }
            return;
        }

        // Audit fix-#07 (2026-05-21) + S3R-001/S3R-002 (2026-05-30): A/B/C
        // kinds also accept payload bytes (e.g. shell-supplied prompt
        // metadata) and forward them to Swift as a String. The Swift
        // consumer's `String(decoding:as:UTF8.self)` passes valid-UTF-8
        // control codepoints through — so they could leak into any future
        // chrome surface that renders TerminalSession's lastPromptMark.
        // Screen the payload at the CODEPOINT level, NOT byte level: a byte
        // sweep (b < 0x20 || b == 0x7F) misses C1 controls (U+0080..=U+009F
        // encode as 0xC2 0x80..=0xC2 0x9F — neither byte is < 0x20) and bidi
        // / invisible scalars (U+202E RIGHT-TO-LEFT OVERRIDE, zero-width
        // joiners, variation selectors, …), which a hostile shell can use to
        // visually spoof or confuse downstream consumers. This is the exact
        // gap the OSC 7 cwd path (the `decoded_str.chars()` gate above) and
        // the title scrubber (`scrub_title_controls`) already close; the
        // A/B/C path was the lone byte-level holdout. Reject the whole mark
        // when the payload is not well-formed UTF-8, or contains any C0 / DEL
        // / C1 control or bidi/invisible scalar. The de-facto A/B/C payload
        // is empty, so this tightening has no real-world false-positive
        // surface.
        if matches!(kind_byte, b'A' | b'B' | b'C') {
            let payload_clean = match std::str::from_utf8(payload) {
                Ok(s) => !s.chars().any(|c| {
                    let cp = c as u32;
                    cp <= 0x1F
                        || cp == 0x7F
                        || (0x80..=0x9F).contains(&cp)
                        || is_bidi_or_invisible_scalar(c)
                }),
                Err(_) => false,
            };
            if !payload_clean {
                // One-shot breadcrumb (silent-failure review): mirror the
                // D-path and OSC 7 reject latches so a dropped prompt mark
                // isn't invisible to an operator debugging why command
                // navigation / exit-code chrome stopped working. Subsequent
                // rejects on this instance stay silent so a flood can't drown
                // the log.
                if !*self.osc133_abc_tainted_logged {
                    *self.osc133_abc_tainted_logged = true;
                    eprintln!(
                        "[blackbird_core] OSC 133 A/B/C rejected (control/bidi/non-UTF-8 payload)"
                    );
                }
                return;
            }
        }

        let ev = BBEvent {
            kind: BBEventKind::PromptMark,
            payload: payload.as_ptr(),
            len: payload.len(),
            // Pack kind (A/B/C/D as 1..=4) into i32_arg so Swift can
            // branch without parsing the payload.
            i32_arg: kind as i32,
        };
        // SAFETY: `payload` borrows `params` which the caller (vte parser)
        // owns for the duration of this callback. `fire` delivers
        // synchronously, so the borrow is alive for the full dispatch.
        unsafe { self.cell.fire(ev) };
    }
}
