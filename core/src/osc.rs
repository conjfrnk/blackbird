//! The parallel OSC tap: a second `vte::Perform` driven alongside alacritty's own parser for the
//! sequences alacritty leaves unhandled (OSC 7, OSC 133, notifications, XTGETTCAP).

use std::collections::HashMap;
use std::sync::OnceLock;

use alacritty_terminal::term::Term;
use alacritty_terminal::vte::{Params, Perform};

use crate::callback::{CallbackCell, RoutingListener};
use crate::diag::breadcrumb;
use crate::event::{BBEvent, BBEventKind};
use crate::rate_limit::{EventRateState, PROMPT_MARK_PER_SECOND};
use crate::scrub::{
    contains_bidi_or_invisible, is_bidi_or_invisible_scalar, percent_decode,
    strip_prefix_ascii_case_insensitive,
};
use crate::BBPromptMarkKind;

/// A macro rather than a `&mut self` method: the caller needs a disjoint `&mut bb.osc_parser`
/// to drive the scanner, and a method would lock the whole `BBTerm`.
macro_rules! osc_scanner {
    ($bb:expr) => {
        $crate::osc::OscScanner {
            cell: &$bb.callback,
            term: &$bb.term,
            sync_pending: $bb.processor.sync_timeout().sync_timeout().is_some(),
            tap: &mut $bb.osc_tap,
            latches: &mut $bb.osc_latches,
            prompt_mark_rate: &mut $bb.prompt_mark_rate,
            osc7_rate: &mut $bb.osc7_rate,
            startup_hostname: &$bb.startup_hostname,
            osc7_hostname_rate: &mut $bb.osc7_hostname_rate,
            terminal_version: &$bb.terminal_version,
        }
    };
}
pub(crate) use osc_scanner;

pub(crate) struct OscScanner<'a> {
    pub(crate) cell: &'a CallbackCell,
    /// Read only to stamp an OSC 133;A mark; in step with the tap unless `sync_pending`.
    pub(crate) term: &'a Term<RoutingListener>,
    /// A DEC 2026 synchronized update is open, so the grid has NOT consumed the bytes the tap
    /// is about to see; prompt marks are held on `tap.held_prompt_marks` until it closes.
    pub(crate) sync_pending: bool,
    pub(crate) tap: &'a mut OscTapState,
    pub(crate) latches: &'a mut OscLatches,
    pub(crate) prompt_mark_rate: &'a mut EventRateState,
    pub(crate) osc7_rate: &'a mut EventRateState,
    /// `gethostname(3)` as of `bb_term_new`; see `local_hostname`.
    pub(crate) startup_hostname: &'a [u8],
    pub(crate) osc7_hostname_rate: &'a mut EventRateState,
    pub(crate) terminal_version: &'a str,
}

/// Carried across `bb_term_input` calls: a DCS can fragment across PTY reads.
#[derive(Debug)]
pub(crate) struct OscTapState {
    pub(crate) in_xtgettcap: bool,
    pub(crate) xtgettcap_buf: Vec<u8>,
    pub(crate) in_decrqss: bool,
    pub(crate) decrqss_buf: Vec<u8>,
    /// In-flight kitty OSC 99 (`d=0` chunks) awaiting its final chunk.
    pub(crate) osc99_pending: Option<Osc99Pending>,
    /// xterm `modifyOtherKeys` level (0 = off, 1, 2), set by `CSI > 4 ; N m`.
    pub(crate) modify_other_keys: u8,
    /// OSC 133 marks parsed while a DEC 2026 synchronized update was open, oldest first.
    /// Every kind is held (not just A) so A/B/C/D reach the host in the order they were parsed.
    pub(crate) held_prompt_marks: Vec<HeldPromptMark>,
}

#[derive(Debug)]
pub(crate) struct HeldPromptMark {
    /// `BBPromptMarkKind` as `u8` (A/B/C/D = 1..=4).
    pub(crate) kind: u8,
    pub(crate) payload: Vec<u8>,
}

impl Default for OscTapState {
    fn default() -> Self {
        Self {
            in_xtgettcap: false,
            xtgettcap_buf: Vec::with_capacity(64),
            in_decrqss: false,
            decrqss_buf: Vec::with_capacity(16),
            osc99_pending: None,
            modify_other_keys: 0,
            held_prompt_marks: Vec::new(),
        }
    }
}

impl OscTapState {
    pub(crate) fn reset(&mut self) {
        self.in_xtgettcap = false;
        self.xtgettcap_buf.clear();
        self.in_decrqss = false;
        self.decrqss_buf.clear();
        self.osc99_pending = None;
        self.modify_other_keys = 0;
        self.held_prompt_marks.clear();
    }
}

/// One-shot reject-log latches, per instance. Deliberately NOT reset by `bb_term_clear_all`.
#[derive(Debug, Default)]
pub(crate) struct OscLatches {
    pub(crate) osc7_reject: [bool; 9],
    pub(crate) osc133_d_nondigit: bool,
    pub(crate) osc133_abc_tainted: bool,
    pub(crate) osc133_rate_limited: bool,
}

#[inline]
pub(crate) fn once(flag: &mut bool) -> bool {
    !std::mem::replace(flag, true)
}

#[derive(Debug, Default)]
pub(crate) struct Osc99Pending {
    pub(crate) id: Vec<u8>,
    pub(crate) title: Vec<u8>,
    pub(crate) body: Vec<u8>,
}

/// Per-field byte cap: the vte 8 MiB cap is per sequence, not per sum of same-id `d=0` chunks.
const OSC99_PENDING_FIELD_MAX_BYTES: usize = 64 * 1024;

/// A cut inside a UTF-8 scalar is harmless: `notification_field` decodes lossily.
fn append_capped(dst: &mut Vec<u8>, src: &[u8]) {
    let room = OSC99_PENDING_FIELD_MAX_BYTES.saturating_sub(dst.len());
    dst.extend_from_slice(&src[..src.len().min(room)]);
}

pub(crate) const OSC7_URL_MAX: usize = 4096;

impl Perform for OscScanner<'_> {
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        match params.first().copied() {
            Some(b"7") => self.handle_osc7(params),
            Some(b"133") => self.handle_osc133(params),
            Some(b"9") => self.handle_osc9(params),
            Some(b"777") => self.handle_osc777(params),
            Some(b"99") => self.handle_osc99(params),
            _ => {}
        }
        let _ = bell_terminated;
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // XTVERSION: `CSI > q` / `CSI > 0 q` → `DCS > | Blackbird <ver> ST`.
        if action == 'q' && intermediates == [b'>'] {
            let first = params
                .iter()
                .next()
                .and_then(|p| p.first().copied())
                .unwrap_or(0);
            if first == 0 {
                let mut reply = b"\x1bP>|Blackbird".to_vec();
                if !self.terminal_version.is_empty() {
                    reply.push(b' ');
                    reply.extend_from_slice(self.terminal_version.as_bytes());
                }
                reply.extend_from_slice(b"\x1b\\");
                unsafe {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::PtyWrite,
                        payload: reply.as_ptr(),
                        len: reply.len(),
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
            }
            return;
        }
        // xterm `modifyOtherKeys`: `CSI > 4 ; N m`, N = 0 (off), 1 or 2; `CSI > 4 m` is the
        // reset form. alacritty_terminal does not handle this sequence.
        if action == 'm' && intermediates == [b'>'] {
            let mut it = params.iter();
            let first = it.next().and_then(|p| p.first().copied());
            if first == Some(4) {
                let level = it.next().and_then(|p| p.first().copied()).unwrap_or(0);
                let clamped: u8 = match level {
                    0 => 0,
                    1 | 2 => level as u8,
                    _ => return,
                };
                self.tap.modify_other_keys = clamped;
            }
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        // RIS (`ESC c`) resets alacritty's modes; mirror it for this sidecar state. Not DECSTR
        // (`CSI ! p`): alacritty has no handler for it, so clearing there would desync.
        if byte == b'c' && intermediates.is_empty() {
            self.tap.modify_other_keys = 0;
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        if intermediates == b"+" && action == 'q' {
            self.tap.in_xtgettcap = true;
            self.tap.xtgettcap_buf.clear();
        } else if intermediates == b"$" && action == 'q' {
            // DECRQSS: `DCS $ q <Pt> ST`.
            self.tap.in_decrqss = true;
            self.tap.decrqss_buf.clear();
        }
    }

    fn put(&mut self, byte: u8) {
        if self.tap.in_xtgettcap && self.tap.xtgettcap_buf.len() < 4096 {
            self.tap.xtgettcap_buf.push(byte);
        } else if self.tap.in_decrqss && self.tap.decrqss_buf.len() < 16 {
            self.tap.decrqss_buf.push(byte);
        }
    }

    fn unhook(&mut self) {
        if self.tap.in_decrqss {
            self.tap.in_decrqss = false;
            let buf = std::mem::take(&mut self.tap.decrqss_buf);
            // Valid (`1$r`) only for SGR (the reset state) and cursor style (the default block);
            // everything else is `0$r`, the spec's "invalid request".
            let reply: &[u8] = match buf.as_slice() {
                b"m" => b"\x1bP1$r0m\x1b\\",
                b" q" => b"\x1bP1$r0 q\x1b\\",
                _ => b"\x1bP0$r\x1b\\",
            };
            unsafe {
                self.cell.fire(BBEvent {
                    kind: BBEventKind::PtyWrite,
                    payload: reply.as_ptr(),
                    len: reply.len(),
                    i32_arg: 0,
                    cursor_row: 0,
                    lines_scrolled: 0,
                });
            }
            return;
        }
        if !self.tap.in_xtgettcap {
            return;
        }
        self.tap.in_xtgettcap = false;
        let buf = std::mem::take(&mut self.tap.xtgettcap_buf);
        unsafe { dispatch_xtgettcap(self.cell, &buf) };
    }
}

/// # Safety
/// Caller must ensure single-threaded access to `cell` (standard BBTerm thread discipline).
unsafe fn dispatch_xtgettcap(cell: &CallbackCell, payload: &[u8]) {
    for cap_hex in payload.split(|&b| b == b';') {
        if cap_hex.is_empty() {
            continue;
        }
        let reply = build_xtgettcap_reply(cap_hex);
        cell.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: reply.as_ptr(),
            len: reply.len(),
            i32_arg: 0,
            cursor_row: 0,
            lines_scrolled: 0,
        });
    }
}

fn build_xtgettcap_reply(cap_hex: &[u8]) -> Vec<u8> {
    // Echo only even-length pure hex: anything else (an embedded ST) would terminate the DCS
    // early and land the tail bytes as top-level input.
    let is_valid_hex = !cap_hex.is_empty()
        && cap_hex.len() % 2 == 0
        && cap_hex.iter().all(|b| b.is_ascii_hexdigit());
    let found = if is_valid_hex {
        find_cap_value(cap_hex)
    } else {
        None
    };
    // Found: `DCS 1 + r <cap>[=<value>] ST`. Unknown: `DCS 0 + r <cap> ST`.
    match (is_valid_hex, found) {
        (true, Some(answer)) => {
            let mut v = Vec::with_capacity(cap_hex.len() + 8);
            v.extend_from_slice(b"\x1bP1+r");
            v.extend_from_slice(cap_hex);
            if let CapAnswer::Value(value_hex) = answer {
                v.push(b'=');
                v.extend_from_slice(value_hex);
            }
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (true, None) => {
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

/// Values are hex-encoded, as on the wire.
enum CapAnswer {
    Flag,
    /// Un-evaluated terminfo bytes (`%p1`-style escapes are left for the caller's tparm).
    Value(Vec<u8>),
}

/// The terminfo source `TERM=xterm-kitty` resolves to; the app compiles this same file with `tic`.
static KITTY_TERMINFO: &str =
    include_str!("../../Sources/Blackbird/Resources/Terminfo/kitty.terminfo");

struct CapIndex {
    caps: HashMap<Vec<u8>, CapAnswer>,
    max_name_len: usize,
}

/// A query is attacker-controlled (~1300 caps per DCS), so each lookup must stay O(1).
fn cap_index() -> &'static CapIndex {
    static INDEX: OnceLock<CapIndex> = OnceLock::new();
    INDEX.get_or_init(|| {
        let mut caps = terminfo_caps();
        for (key, value) in XTGETTCAP_TABLE {
            if let (Some(name), Some(value)) = (unhex(key), unhex(value)) {
                caps.insert(name, CapAnswer::Value(hex_upper(&value)));
            }
        }
        let max_name_len = caps.keys().map(Vec::len).max().unwrap_or(0);
        CapIndex { caps, max_name_len }
    })
}

/// Matched ASCII-case-insensitively: some ncurses builds lowercase the query hex.
fn find_cap_value(cap_hex: &[u8]) -> Option<&'static CapAnswer> {
    let index = cap_index();
    if cap_hex.len() > index.max_name_len * 2 {
        return None;
    }
    index.caps.get(unhex(cap_hex)?.as_slice())
}

fn unhex(hex: &[u8]) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    let nibble = |b: u8| char::from(b).to_digit(16).map(|d| d as u8);
    hex.chunks_exact(2)
        .map(|pair| Some((nibble(pair[0])? << 4) | nibble(pair[1])?))
        .collect()
}

/// Numeric capabilities are not answered. A string using an escape `unescape_terminfo` does not
/// know is left out, so it reads as unsupported. The first definition of a name wins.
fn terminfo_caps() -> HashMap<Vec<u8>, CapAnswer> {
    let mut caps = HashMap::new();
    // One capability per indented line ending in `,`; the unindented first line is the header.
    for line in KITTY_TERMINFO.lines() {
        if !line.starts_with(char::is_whitespace) {
            continue;
        }
        let Some(entry) = line.trim().strip_suffix(',') else {
            continue;
        };
        let name_len = entry
            .find(|c: char| !c.is_ascii_alphanumeric())
            .unwrap_or(entry.len());
        let (cap, rest) = entry.split_at(name_len);
        let answer = match rest.strip_prefix('=') {
            Some(raw) => match unescape_terminfo(raw) {
                Some(bytes) => CapAnswer::Value(hex_upper(&bytes)),
                None => continue,
            },
            None if rest.is_empty() => CapAnswer::Flag,
            None => continue,
        };
        caps.entry(cap.as_bytes().to_vec()).or_insert(answer);
    }
    caps
}

fn hex_upper(bytes: &[u8]) -> Vec<u8> {
    const DIGITS: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = Vec::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(DIGITS[usize::from(b >> 4)]);
        out.push(DIGITS[usize::from(b & 0x0F)]);
    }
    out
}

/// Terminfo-source string escapes (`\E`, `\007`, `^G`, `\s`, `\,`, ...) to bytes. `%` sequences
/// and `$<..>` padding stay as written. `None` on an escape the bundled file does not use.
fn unescape_terminfo(raw: &str) -> Option<Vec<u8>> {
    let b = raw.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\\' => {
                i += 1;
                match *b.get(i)? {
                    b'E' | b'e' => out.push(0x1B),
                    b'n' | b'l' => out.push(b'\n'),
                    b'r' => out.push(b'\r'),
                    b't' => out.push(b'\t'),
                    b'b' => out.push(0x08),
                    b'f' => out.push(0x0C),
                    b's' => out.push(b' '),
                    e @ (b'^' | b'\\' | b',' | b':') => out.push(e),
                    b'0'..=b'7' => {
                        let mut v: u32 = 0;
                        let mut digits = 0;
                        while digits < 3 && i < b.len() && (b'0'..=b'7').contains(&b[i]) {
                            v = v * 8 + u32::from(b[i] - b'0');
                            i += 1;
                            digits += 1;
                        }
                        out.push(u8::try_from(v).ok()?);
                        continue; // `i` is already past the digits
                    }
                    _ => return None,
                }
                i += 1;
            }
            b'^' => {
                i += 1;
                let c = *b.get(i)?;
                out.push(if c == b'?' { 0x7F } else { c & 0x1F });
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    Some(out)
}

/// (hex cap name, hex value) rows that override the terminfo: TN = "xterm-kitty",
/// Co = "16777216" (TUIs gate truecolor on the colour count), RGB = "8" (bits per channel).
static XTGETTCAP_TABLE: &[(&[u8], &[u8])] = &[
    (b"544E", b"787465726D2D6B69747479"),
    (b"436F", b"3136373737323136"),
    (b"524742", b"38"),
];

const OSC7_REJECT_RATE: usize = 0;
const OSC7_REJECT_PERCENT_DECODE: usize = 1;
const OSC7_REJECT_UTF8: usize = 2;
const OSC7_REJECT_NUL: usize = 3;
const OSC7_REJECT_CONTROL: usize = 4;
const OSC7_REJECT_BIDI: usize = 5;
const OSC7_REJECT_NON_ABSOLUTE: usize = 6;
const OSC7_REJECT_TRAVERSAL: usize = 7;
const OSC7_REJECT_HOST: usize = 8;
fn osc7_reject(latches: &mut [bool; 9], class: usize, name: &str) {
    if let Some(slot) = latches.get_mut(class) {
        if once(slot) {
            breadcrumb!("[blackbird_core] OSC 7 rejected ({})", name);
        }
    }
}

/// `gethostname(3)`, empty on failure. Not cached for the process: macOS renames the host at
/// runtime, while a shell keeps the name it read at startup.
pub(crate) fn local_hostname() -> Vec<u8> {
    // Declared here, not at module level, so cbindgen keeps it out of BBCore.h.
    unsafe extern "C" {
        fn gethostname(name: *mut std::os::raw::c_char, len: usize) -> std::os::raw::c_int;
    }
    // Last byte stays NUL even if the name is truncated.
    let mut buf = [0u8; 256];
    // SAFETY: `buf` is valid for `buf.len() - 1` writable bytes.
    let rc = unsafe { gethostname(buf.as_mut_ptr().cast(), buf.len() - 1) };
    if rc != 0 {
        return Vec::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    buf[..end].to_vec()
}

/// `rest` is the text after `file://`. Returns the path, leading `/` included, when the authority
/// names `local` (case-insensitive, percent-decoded, ignoring an mDNS `.local` suffix on either).
pub(crate) fn strip_own_hostname<'a>(rest: &'a [u8], local: &[u8]) -> Option<&'a [u8]> {
    fn without_mdns_suffix(host: &[u8]) -> &[u8] {
        match host.len().checked_sub(6) {
            Some(n) if n > 0 && host[n..].eq_ignore_ascii_case(b".local") => &host[..n],
            _ => host,
        }
    }
    let slash = rest.iter().position(|&b| b == b'/')?;
    let (authority, path) = rest.split_at(slash);
    // Percent-escaping at most triples a byte: skip the decode for an authority too long to match.
    if local.is_empty() || authority.len() > (local.len() + b".local".len()) * 3 {
        return None;
    }
    let authority = percent_decode(authority)?;
    if !without_mdns_suffix(&authority).eq_ignore_ascii_case(without_mdns_suffix(local)) {
        return None;
    }
    Some(path)
}

const NOTIFICATION_TITLE_MAX_CHARS: usize = 128;
const NOTIFICATION_BODY_MAX_CHARS: usize = 1024;

impl OscScanner<'_> {
    /// vte splits the OSC body on every ';', but a body may legitimately contain them.
    fn join_params(params: &[&[u8]], from: usize) -> Vec<u8> {
        let mut out = Vec::new();
        for (i, p) in params.iter().enumerate().skip(from) {
            if i > from {
                out.push(b';');
            }
            out.extend_from_slice(p);
        }
        out
    }

    fn notification_field(bytes: &[u8], max_chars: usize) -> String {
        let s = String::from_utf8_lossy(bytes);
        // The scrub drops newlines; a space keeps a multi-line body's words apart.
        let s = s.replace(['\r', '\n'], " ");
        let scrubbed = crate::scrub::scrub_title_controls(&s);
        scrubbed
            .chars()
            .take(max_chars)
            .collect::<String>()
            .trim()
            .to_string()
    }

    fn emit_notification(&mut self, title: &[u8], body: &[u8]) {
        let title = Self::notification_field(title, NOTIFICATION_TITLE_MAX_CHARS);
        let body = Self::notification_field(body, NOTIFICATION_BODY_MAX_CHARS);
        if title.is_empty() && body.is_empty() {
            return;
        }
        // The separator is unambiguous only because the scrub strips every C0 scalar.
        debug_assert!(!title.contains('\u{1F}') && !body.contains('\u{1F}'));
        let mut payload = title.into_bytes();
        payload.push(0x1F);
        payload.extend_from_slice(body.as_bytes());
        // SAFETY: single-thread-per-BBTerm discipline; the payload outlives the synchronous call.
        unsafe {
            self.cell.fire(BBEvent {
                kind: BBEventKind::Notification,
                payload: payload.as_ptr(),
                len: payload.len(),
                i32_arg: 0,
                cursor_row: 0,
                lines_scrolled: 0,
            });
        }
    }

    /// iTerm2 form: `OSC 9 ; message ST`.
    fn handle_osc9(&mut self, params: &[&[u8]]) {
        if params.len() < 2 {
            return;
        }
        // `9;4;…` is the ConEmu / Windows Terminal progress bar, `9;9;…` ConEmu's cwd report.
        if params.len() >= 3 && (params[1] == b"4" || params[1] == b"9") {
            return;
        }
        let body = Self::join_params(params, 1);
        self.emit_notification(b"", &body);
    }

    /// rxvt-unicode / Ghostty / foot form: `OSC 777 ; notify ; title ; body ST`.
    fn handle_osc777(&mut self, params: &[&[u8]]) {
        if params.len() < 3 || params[1] != b"notify" {
            return;
        }
        let title = params[2];
        let body = Self::join_params(params, 3);
        self.emit_notification(title, &body);
    }

    /// kitty form: `OSC 99 ; metadata ; payload ST`, metadata being `key=value` pairs joined by
    /// ':'. `d=0` chunks accumulate (keyed by `i=`) until the final chunk; `e=1` is dropped.
    fn handle_osc99(&mut self, params: &[&[u8]]) {
        if params.len() < 3 {
            return;
        }
        let metadata = params[1];
        let payload = Self::join_params(params, 2);
        let mut id: Vec<u8> = Vec::new();
        let mut part = b"body".as_slice();
        let mut more = false;
        let mut encoded = false;
        for kv in metadata.split(|&b| b == b':') {
            match kv {
                b"d=0" => more = true,
                b"e=1" => encoded = true,
                _ if kv.starts_with(b"i=") => id = kv[2..].to_vec(),
                _ if kv.starts_with(b"p=") => part = &kv[2..],
                _ => {}
            }
        }
        if encoded {
            return;
        }
        if self.tap.osc99_pending.is_some()
            && self.tap.osc99_pending.as_ref().map(|p| &p.id) != Some(&id)
        {
            if let Some(p) = self.tap.osc99_pending.take() {
                self.emit_notification(&p.title, &p.body);
            }
        }
        let mut pending = self.tap.osc99_pending.take().unwrap_or(Osc99Pending {
            id: id.clone(),
            title: Vec::new(),
            body: Vec::new(),
        });
        match part {
            b"title" => append_capped(&mut pending.title, &payload),
            b"body" => append_capped(&mut pending.body, &payload),
            _ => {}
        }
        if more {
            self.tap.osc99_pending = Some(pending);
        } else {
            self.emit_notification(&pending.title, &pending.body);
        }
    }

    fn handle_osc7(&mut self, params: &[&[u8]]) {
        if params.len() < 2 {
            return;
        }
        let joined: Vec<u8>;
        let url: &[u8] = if params.len() == 2 {
            params[1]
        } else {
            joined = Self::join_params(params, 1);
            &joined
        };

        // Length cap first: it is free, and `percent_decode` allocates the input's length.
        if url.len() > OSC7_URL_MAX {
            return;
        }

        // RFC 3986 §3.1 / §3.2.2: scheme and host are case-insensitive; the path is not.
        let Some(rest) = strip_prefix_ascii_case_insensitive(url, b"file://") else {
            return;
        };
        let path_bytes: &[u8] = if rest.starts_with(b"/") {
            rest
        } else if let Some(r) =
            strip_prefix_ascii_case_insensitive(rest, b"localhost").filter(|r| r.starts_with(b"/"))
        {
            r
        } else if let Some(r) = strip_own_hostname(rest, self.startup_hostname).or_else(|| {
            // Rejects consume no `osc7_rate` slot, so the live read has its own budget.
            if !self.osc7_hostname_rate.allow() {
                return None;
            }
            strip_own_hostname(rest, &local_hostname())
        }) {
            r
        } else {
            osc7_reject(&mut self.latches.osc7_reject, OSC7_REJECT_HOST, "host");
            return;
        };

        let Some(decoded) = percent_decode(path_bytes) else {
            osc7_reject(
                &mut self.latches.osc7_reject,
                OSC7_REJECT_PERCENT_DECODE,
                "percent_decode",
            );
            return;
        };
        // The `CwdChanged` payload contract is UTF-8; percent-decoding can produce arbitrary bytes.
        let Ok(decoded_str) = std::str::from_utf8(&decoded) else {
            osc7_reject(&mut self.latches.osc7_reject, OSC7_REJECT_UTF8, "utf8");
            return;
        };
        // `%00` is valid UTF-8 but truncates the path for consumers that go through a C API.
        if decoded.contains(&0) {
            osc7_reject(&mut self.latches.osc7_reject, OSC7_REJECT_NUL, "nul");
            return;
        }
        // Codepoint-level: C1 controls encode as `0xC2 0x80..0xC2 0x9F`, which a byte sweep misses.
        if decoded_str.chars().any(|c| {
            let cp = c as u32;
            cp <= 0x1F || cp == 0x7F || (0x80..=0x9F).contains(&cp)
        }) {
            osc7_reject(
                &mut self.latches.osc7_reject,
                OSC7_REJECT_CONTROL,
                "control",
            );
            return;
        }
        if contains_bidi_or_invisible(decoded.as_slice()) {
            osc7_reject(&mut self.latches.osc7_reject, OSC7_REJECT_BIDI, "bidi");
            return;
        }
        // OSC 7 specifies an absolute path; any `..` segment (e.g. `%2e%2e`) is refused.
        if !decoded_str.starts_with('/') {
            osc7_reject(
                &mut self.latches.osc7_reject,
                OSC7_REJECT_NON_ABSOLUTE,
                "non_absolute",
            );
            return;
        }
        for component in std::path::Path::new(decoded_str).components() {
            match component {
                std::path::Component::ParentDir => {
                    osc7_reject(
                        &mut self.latches.osc7_reject,
                        OSC7_REJECT_TRAVERSAL,
                        "traversal",
                    );
                    return;
                }
                std::path::Component::Normal(s) if s.as_encoded_bytes() == b".." => {
                    osc7_reject(
                        &mut self.latches.osc7_reject,
                        OSC7_REJECT_TRAVERSAL,
                        "traversal",
                    );
                    return;
                }
                _ => {}
            }
        }
        // The ssh / docker gate lives on the Swift side: the core can't see the process tree.

        // Rate gate last, after every reject path: only OSC 7s that will emit consume budget, so
        // a flood of rejected payloads cannot starve a legitimate cwd update.
        if !self.osc7_rate.allow() {
            osc7_reject(&mut self.latches.osc7_reject, OSC7_REJECT_RATE, "rate");
            return;
        }

        let ev = BBEvent {
            kind: BBEventKind::CwdChanged,
            payload: decoded.as_ptr(),
            len: decoded.len(),
            i32_arg: 0,
            cursor_row: 0,
            lines_scrolled: 0,
        };
        // SAFETY: `fire` invokes the C callback synchronously, so `decoded` outlives the borrow.
        unsafe { self.cell.fire(ev) };
    }

    fn handle_osc133(&mut self, params: &[&[u8]]) {
        let Some(kind_param) = params.get(1) else {
            return;
        };
        let kind_param = *kind_param;
        // `OSC 133 ; D ; <code> ST` arrives as [b"133", b"D", b"0"]; shells that combine
        // (`OSC 133 ; D;0`) arrive as [b"133", b"D;0"].
        let (kind_byte, exit_code_bytes): (u8, &[u8]) = if kind_param.len() == 1 {
            (kind_param[0], params.get(2).copied().unwrap_or(b""))
        } else if let Some(idx) = kind_param.iter().position(|&b| b == b';') {
            (kind_param[0], &kind_param[idx + 1..])
        } else {
            return;
        };

        let kind: u8 = match kind_byte {
            b'A' => BBPromptMarkKind::A as u8,
            b'B' => BBPromptMarkKind::B as u8,
            b'C' => BBPromptMarkKind::C as u8,
            b'D' => BBPromptMarkKind::D as u8,
            _ => return,
        };

        // All four kinds are rate-limited, D included: a D flood would rotate legitimate entries
        // out of Swift's bounded prompt ring.
        if matches!(kind_byte, b'A' | b'B' | b'C' | b'D') && !self.prompt_mark_rate.allow() {
            if once(&mut self.latches.osc133_rate_limited) {
                breadcrumb!(
                    "[blackbird_core] OSC 133 prompt-mark rate cap ({PROMPT_MARK_PER_SECOND}/s) \
                     engaged — dropping excess marks. One-shot per session."
                );
            }
            return;
        }

        // A 17+-digit "exit code" is rejected, not truncated to a bogus 16-digit prefix.
        if exit_code_bytes.len() > 16 {
            if once(&mut self.latches.osc133_d_nondigit) {
                breadcrumb!("[blackbird_core] OSC 133 D rejected (exit code longer than 16 bytes)");
            }
            return;
        }
        let payload = exit_code_bytes;

        // The Swift consumer turns the payload into a String for display: drop a non-numeric D.
        if kind_byte == b'D' && !payload.is_empty() && !payload.iter().all(|b| b.is_ascii_digit()) {
            if once(&mut self.latches.osc133_d_nondigit) {
                breadcrumb!("[blackbird_core] OSC 133 D rejected (non-digit payload)");
            }
            return;
        }

        // A/B/C payloads are screened at the codepoint level, not byte level, like OSC 7.
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
                if once(&mut self.latches.osc133_abc_tainted) {
                    breadcrumb!(
                        "[blackbird_core] OSC 133 A/B/C rejected (control/bidi/non-UTF-8 payload)"
                    );
                }
                return;
            }
        }

        // The grid lags the stream while a synchronized update is open, so the cursor read below
        // would be stale. Hold the mark, and every mark behind it so A/B/C/D keep their order.
        if self.sync_pending || !self.tap.held_prompt_marks.is_empty() {
            self.tap.held_prompt_marks.push(HeldPromptMark {
                kind,
                payload: payload.to_vec(),
            });
            return;
        }
        let ev = prompt_mark_event(self.term, kind, payload);
        // SAFETY: `payload` borrows `params`, alive for this callback; `fire` is synchronous.
        unsafe { self.cell.fire(ev) };
    }
}

/// Kind A carries the cursor position of `term` at the moment of the call: call it only when
/// `term` has consumed exactly the bytes before the mark. B/C/D carry zeroes.
pub(crate) fn prompt_mark_event(term: &Term<RoutingListener>, kind: u8, payload: &[u8]) -> BBEvent {
    let is_prompt_start = kind == BBPromptMarkKind::A as u8;
    BBEvent {
        kind: BBEventKind::PromptMark,
        payload: payload.as_ptr(),
        len: payload.len(),
        i32_arg: kind as i32,
        cursor_row: if is_prompt_start {
            term.grid().cursor.point.line.0.max(0) as u16
        } else {
            0
        },
        lines_scrolled: if is_prompt_start {
            term.primary_lines_scrolled()
        } else {
            0
        },
    }
}
