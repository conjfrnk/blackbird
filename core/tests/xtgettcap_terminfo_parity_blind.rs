//! Blind regression tests: XTGETTCAP must agree with the bundled
//! `kitty.terminfo` that `TERM=xterm-kitty` resolves to.
//!
//! Blackbird advertises `TERM=xterm-kitty` and ships a terminfo entry for it
//! (`Sources/Blackbird/Resources/Terminfo/kitty.terminfo`). TUIs that probe
//! capabilities with XTGETTCAP (`DCS + q <hex-name> ST`) rather than reading
//! terminfo are entitled to the SAME answers the terminfo gives:
//!
//!   - a string capability the terminfo defines is answered
//!     `DCS 1 + r <hex-name>=<hex-value> ST`, where the value is the
//!     un-evaluated terminfo string (ESC is the raw byte 0x1B, `%p1`-style
//!     parameter escapes are left for the caller's tparm — compare the
//!     existing `Smulx` pin in `xtgettcap.rs`);
//!   - a boolean capability the terminfo asserts is answered with status 1
//!     (`DCS 1 + r <hex-name> ... ST`), NOT the "unknown" status 0;
//!   - a string capability that a caller then evaluates with tparm must do
//!     what its name promises. For `Setulc` (set underline colour) the
//!     bundled terminfo takes ONE packed `0xRRGGBB` parameter in `%p1`.
//!
//! Failure modes covered here:
//!   1. the reported `Setulc` is wrong under the terminfo's own calling
//!      convention (a packed 0x112233 loses green and blue);
//!   2. `Su`, `Tc`, `XF`, `Ms`, `Sync`, `Ss`, ... and in fact nearly every
//!      other capability in the terminfo are answered "unsupported".
//!
//! The expected values in the named tests are hand-written literals; the
//! two whole-file sweeps derive theirs by parsing the terminfo source with
//! the small independent decoder below. A harness self-check (the terminfo's
//! own `Setulc` pushed through the same evaluate-and-render pipeline) runs
//! inside the Setulc test so that test cannot pass or fail vacuously.
//!
//! Cost: every query builds a fresh 80x24 / 100-line-scrollback terminal
//! (a few tens of KiB) and frees it again. The sweeps issue ~270 queries in
//! well under a second; no sleeps, no threads.

use std::ffi::c_void;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Terminal harness
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Captured {
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != bc::BBEventKind::PtyWrite as u32 {
        return;
    }
    if ev.payload.is_null() || ev.len == 0 {
        return;
    }
    let cap = &*(ctx as *const Mutex<Captured>);
    let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
    cap.lock().unwrap().pty_writes.push(bytes.to_vec());
}

/// Feed `input` to a fresh terminal and return every byte it wrote back to
/// the PTY, concatenated in order.
fn pty_reply_to(input: &[u8]) -> Vec<u8> {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null(), "bb_term_new returned null");
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_input(term, input.as_ptr(), input.len());
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
    let guard = cap.lock().unwrap();
    guard.pty_writes.iter().flatten().copied().collect()
}

/// `(flags, ch, underline_color)` of the top-left cell of a fresh 10x1
/// terminal after feeding `seq`.
fn first_cell_after(seq: &[u8]) -> (u16, u32, u32) {
    unsafe {
        let term = bc::bb_term_new(10, 1, 100);
        assert!(!term.is_null(), "bb_term_new returned null");
        bc::bb_term_input(term, seq.as_ptr(), seq.len());
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        let cell = *(*snap).cells;
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
        (cell.flags, cell.ch, cell.underline_color)
    }
}

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

fn hex_upper(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02X}"));
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    assert!(s.len() % 2 == 0, "odd-length hex string {s:?}");
    let digits: Vec<u8> = s.bytes().collect();
    let nibble = |c: u8| -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            other => panic!("non-hex byte {other:#04x} in {s:?}"),
        }
    };
    digits
        .chunks(2)
        .map(|pair| (nibble(pair[0]) << 4) | nibble(pair[1]))
        .collect()
}

// ---------------------------------------------------------------------------
// XTGETTCAP query + reply parser
// ---------------------------------------------------------------------------

/// One parsed `DCS <status> + r <hex-name>[=<hex-value>] ST` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Reply {
    /// `b'1'` supported / `b'0'` unknown.
    status: u8,
    /// Hex name exactly as echoed (empty when the terminal echoed none).
    name_hex: String,
    /// Decoded value bytes; `None` when the reply carried no `=value`.
    value: Option<Vec<u8>>,
    /// The raw bytes the terminal wrote, for failure messages.
    raw: Vec<u8>,
}

/// Send `ESC P + q <hex(name)> ESC \` to a fresh terminal and parse the
/// single reply. Panics (with the raw bytes) on a malformed or missing
/// reply: every XTGETTCAP query, supported or not, must be answered.
fn query_cap(name: &str) -> Reply {
    let mut req = b"\x1bP+q".to_vec();
    req.extend_from_slice(hex_upper(name.as_bytes()).as_bytes());
    req.extend_from_slice(b"\x1b\\");
    let raw = pty_reply_to(&req);

    let shown = || show(&raw);
    assert!(
        raw.len() >= 7 && raw.starts_with(b"\x1bP") && raw.ends_with(b"\x1b\\"),
        "XTGETTCAP {name}: reply is not a well-formed DCS ... ST; raw = {}",
        shown()
    );
    let status = raw[2];
    assert!(
        (status == b'0' || status == b'1') && &raw[3..5] == b"+r",
        "XTGETTCAP {name}: reply header is not `DCS <0|1> + r`; raw = {}",
        shown()
    );
    let body = std::str::from_utf8(&raw[5..raw.len() - 2]).unwrap_or_else(|_| {
        panic!(
            "XTGETTCAP {name}: reply body is not ASCII; raw = {}",
            shown()
        )
    });
    let (name_hex, value) = match body.split_once('=') {
        Some((n, v)) => (n.to_string(), Some(unhex(v))),
        None => (body.to_string(), None),
    };
    Reply {
        status,
        name_hex,
        value,
        raw,
    }
}

fn show(bytes: &[u8]) -> String {
    String::from_utf8_lossy(&bytes.escape_ascii().collect::<Vec<u8>>()).into_owned()
}

// ---------------------------------------------------------------------------
// Minimal terminfo `tparm` (only what the capabilities here need)
// ---------------------------------------------------------------------------

fn pop_or_zero(stack: &mut Vec<i64>) -> i64 {
    stack.pop().unwrap_or(0)
}

/// Return the index just past the `%;` that closes the conditional we are in
/// (or past the `%e` of the same conditional when `stop_at_else`).
fn skip_branch(fmt: &[u8], mut i: usize, stop_at_else: bool) -> usize {
    let mut depth = 0usize;
    while i < fmt.len() {
        if fmt[i] != b'%' {
            i += 1;
            continue;
        }
        let op = fmt.get(i + 1).copied().unwrap_or(0);
        i += 2;
        match op {
            b'?' => depth += 1,
            b';' => {
                if depth == 0 {
                    return i;
                }
                depth -= 1;
            }
            b'e' if depth == 0 && stop_at_else => return i,
            b'{' => {
                while i < fmt.len() && fmt[i] != b'}' {
                    i += 1;
                }
                i += 1;
            }
            b'\'' => i += 2,
            b'p' => i += 1,
            _ => {}
        }
    }
    i
}

/// Evaluate a terminfo parameterised string with integer parameters
/// `p1..p9`. Supports the stack, arithmetic, comparison and conditional
/// operators plus `%d %c %o %x %X` with optional `0`/width/precision. A
/// stray `%;` (no open conditional) is a no-op, as in ncurses.
fn tparm(fmt: &[u8], params: [i64; 9]) -> Vec<u8> {
    let mut p = params;
    let mut out: Vec<u8> = Vec::new();
    let mut stack: Vec<i64> = Vec::new();
    let mut i = 0usize;
    while i < fmt.len() {
        let c = fmt[i];
        if c != b'%' {
            out.push(c);
            i += 1;
            continue;
        }
        i += 1;
        let op = *fmt.get(i).expect("dangling % at end of terminfo string");
        i += 1;
        match op {
            b'%' => out.push(b'%'),
            b'p' => {
                let n = (fmt[i] - b'0') as usize;
                i += 1;
                assert!((1..=9).contains(&n), "bad %p index {n}");
                stack.push(p[n - 1]);
            }
            b'{' => {
                let mut n: i64 = 0;
                while fmt[i] != b'}' {
                    n = n * 10 + i64::from(fmt[i] - b'0');
                    i += 1;
                }
                i += 1;
                stack.push(n);
            }
            b'\'' => {
                stack.push(i64::from(fmt[i]));
                i += 3;
            }
            b'i' => {
                p[0] += 1;
                p[1] += 1;
            }
            b'+' | b'-' | b'*' | b'/' | b'm' | b'&' | b'|' | b'^' | b'=' | b'>' | b'<' | b'A'
            | b'O' => {
                let b = pop_or_zero(&mut stack);
                let a = pop_or_zero(&mut stack);
                let v = match op {
                    b'+' => a + b,
                    b'-' => a - b,
                    b'*' => a * b,
                    b'/' => {
                        if b == 0 {
                            0
                        } else {
                            a / b
                        }
                    }
                    b'm' => {
                        if b == 0 {
                            0
                        } else {
                            a % b
                        }
                    }
                    b'&' => a & b,
                    b'|' => a | b,
                    b'^' => a ^ b,
                    b'=' => i64::from(a == b),
                    b'>' => i64::from(a > b),
                    b'<' => i64::from(a < b),
                    b'A' => i64::from(a != 0 && b != 0),
                    _ => i64::from(a != 0 || b != 0),
                };
                stack.push(v);
            }
            b'!' => {
                let a = pop_or_zero(&mut stack);
                stack.push(i64::from(a == 0));
            }
            b'~' => {
                let a = pop_or_zero(&mut stack);
                stack.push(!a);
            }
            b'?' | b';' => {}
            b't' => {
                if pop_or_zero(&mut stack) == 0 {
                    i = skip_branch(fmt, i, true);
                }
            }
            b'e' => {
                i = skip_branch(fmt, i, false);
            }
            b'c' => out.push(pop_or_zero(&mut stack) as u8),
            _ => {
                // `%[0][width][.precision](d|o|x|X)`; `op` is the first byte
                // of the spec, so re-scan from there.
                let mut j = i - 1;
                let zero = fmt[j] == b'0';
                let mut width = 0usize;
                while fmt[j].is_ascii_digit() {
                    width = width * 10 + usize::from(fmt[j] - b'0');
                    j += 1;
                }
                let mut precision = 0usize;
                if fmt[j] == b'.' {
                    j += 1;
                    while fmt[j].is_ascii_digit() {
                        precision = precision * 10 + usize::from(fmt[j] - b'0');
                        j += 1;
                    }
                }
                let v = pop_or_zero(&mut stack);
                let mut digits = match fmt[j] {
                    b'd' => v.to_string(),
                    b'o' => format!("{v:o}"),
                    b'x' => format!("{v:x}"),
                    b'X' => format!("{v:X}"),
                    other => panic!(
                        "unsupported terminfo op `%{}` in {:?}",
                        other as char,
                        show(fmt)
                    ),
                };
                while digits.len() < precision {
                    digits.insert(0, '0');
                }
                let pad = if zero { '0' } else { ' ' };
                while digits.len() < width {
                    digits.insert(0, pad);
                }
                out.extend_from_slice(digits.as_bytes());
                i = j + 1;
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Bundled terminfo parsing
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
enum CapValue {
    Bool,
    Num,
    Str(Vec<u8>),
}

fn terminfo_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("CARGO_MANIFEST_DIR (core/) must have a parent (workspace root)")
        .join("Sources/Blackbird/Resources/Terminfo/kitty.terminfo")
}

/// Decode terminfo source escapes (`\E`, `\007`, `^G`, `\\`, `\,`, `\:`,
/// `\s`, ...) to the raw bytes a compiled entry would hold. `%` sequences
/// and `$<..>` padding are left untouched.
fn decode_terminfo_string(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        match b[i] {
            b'\\' => {
                i += 1;
                let e = *b.get(i).expect("dangling backslash in terminfo string");
                match e {
                    b'E' | b'e' => out.push(0x1B),
                    b'n' | b'l' => out.push(b'\n'),
                    b'r' => out.push(b'\r'),
                    b't' => out.push(b'\t'),
                    b'b' => out.push(0x08),
                    b'f' => out.push(0x0C),
                    b's' => out.push(b' '),
                    b'^' | b'\\' | b',' | b':' => out.push(e),
                    b'0'..=b'7' => {
                        let mut v: u32 = 0;
                        let mut n = 0;
                        while n < 3 && i < b.len() && (b'0'..=b'7').contains(&b[i]) {
                            v = v * 8 + u32::from(b[i] - b'0');
                            i += 1;
                            n += 1;
                        }
                        out.push(v as u8);
                        continue; // `i` already points past the digits
                    }
                    other => panic!("unhandled terminfo escape `\\{}` in {s:?}", other as char),
                }
                i += 1;
            }
            b'^' => {
                i += 1;
                let c = *b.get(i).expect("dangling ^ in terminfo string");
                out.push(if c == b'?' { 0x7F } else { c & 0x1F });
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// Every capability of the bundled terminfo, in file order. One capability
/// per line, each line ending in an unescaped `,`.
fn bundled_caps() -> Vec<(String, CapValue)> {
    let path = terminfo_path();
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read terminfo at {}: {e}", path.display()));
    let mut caps = Vec::new();
    for line in text.lines() {
        // The header line (`xterm-kitty|KovIdTTY,`) is not indented.
        if !line.starts_with(char::is_whitespace) {
            continue;
        }
        let entry = line.trim();
        if entry.is_empty() || entry.starts_with('#') {
            continue;
        }
        let body = entry
            .strip_suffix(',')
            .unwrap_or_else(|| panic!("terminfo line without trailing comma: {line:?}"));
        let name_len = body
            .find(|c: char| !c.is_ascii_alphanumeric())
            .unwrap_or(body.len());
        let (name, rest) = body.split_at(name_len);
        let value = if rest.is_empty() {
            CapValue::Bool
        } else if rest.starts_with('#') {
            CapValue::Num
        } else if let Some(s) = rest.strip_prefix('=') {
            CapValue::Str(decode_terminfo_string(s))
        } else {
            panic!("cannot classify terminfo capability {line:?}");
        };
        caps.push((name.to_string(), value));
    }
    caps
}

fn bundled_string(caps: &[(String, CapValue)], name: &str) -> Vec<u8> {
    for (n, v) in caps {
        if n == name {
            if let CapValue::Str(s) = v {
                return s.clone();
            }
            panic!("terminfo cap {name} is not a string capability: {v:?}");
        }
    }
    panic!("terminfo cap {name} not found in bundled kitty.terminfo");
}

fn bundled_is_bool(caps: &[(String, CapValue)], name: &str) -> bool {
    caps.iter().any(|(n, v)| n == name && *v == CapValue::Bool)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Parameters for `Setulc`'s packed convention: one 0xRRGGBB integer in `%p1`.
fn packed(rgb: u32) -> [i64; 9] {
    let mut p = [0i64; 9];
    p[0] = i64::from(rgb);
    p
}

/// Evaluate `setulc_fmt` with `rgb` packed into `%p1`, feed the result to a
/// terminal after `CSI 4 m` (underline on) followed by `X`, and describe what
/// the first cell ended up with. Returns `(evaluated escape, cell)`.
fn render_setulc(setulc_fmt: &[u8], rgb: u32) -> (Vec<u8>, (u16, u32, u32)) {
    let escape = tparm(setulc_fmt, packed(rgb));
    let mut input = b"\x1b[4m".to_vec();
    input.extend_from_slice(&escape);
    input.push(b'X');
    (escape, first_cell_after(&input))
}

/// Harness self-check shared by the sweeps (not a bug probe): proves the
/// terminfo file parsed, that the capabilities named in the bug report are
/// really in it, and that the decoder agrees with hand-decoded literals, so a
/// sweep can neither pass nor fail vacuously.
fn assert_terminfo_harness_sane(caps: &[(String, CapValue)]) {
    assert!(
        caps.len() >= 200,
        "bundled kitty.terminfo parsed to only {} capabilities; the sweeps would be vacuous",
        caps.len()
    );
    for name in ["Su", "Tc", "XF"] {
        assert!(
            bundled_is_bool(caps, name),
            "bundled terminfo must assert boolean capability {name}"
        );
    }
    assert_eq!(
        bundled_string(caps, "Ms"),
        b"\x1b]52;%p1%s;%p2%s\x1b\\".to_vec(),
        "terminfo decoder disagrees with the hand-decoded Ms value"
    );
    assert_eq!(
        bundled_string(caps, "Ss"),
        b"\x1b[%p1%d q".to_vec(),
        "terminfo decoder disagrees with the hand-decoded Ss value"
    );
    for name in ["Setulc", "Smulx", "Sync", "Se"] {
        assert!(
            !bundled_string(caps, name).is_empty(),
            "terminfo string capability {name} is empty"
        );
    }
}

#[test]
fn setulc_reported_by_xtgettcap_colours_the_underline_when_evaluated() {
    // ESC P + q 536574756C63 ESC \   ("Setulc")
    let caps = bundled_caps();
    assert_terminfo_harness_sane(&caps);
    let terminfo_setulc = bundled_string(&caps, "Setulc");

    let colours: [u32; 6] = [0x112233, 0xFF0000, 0x00FF00, 0x0000FF, 0xFF8040, 0x0A0B0C];

    // Harness self-check: the terminfo's own Setulc, run through exactly the
    // same evaluate -> render -> read-back pipeline, must paint every colour.
    // If this trips, the evaluator or the terminal harness is broken, not the
    // XTGETTCAP answer under test.
    for rgb in colours {
        let (escape, (flags, ch, got)) = render_setulc(&terminfo_setulc, rgb);
        assert_eq!(
            (flags & bc::cell_flags::UNDERLINE != 0, ch, got & 0x00FF_FFFF),
            (true, u32::from('X'), rgb),
            "HARNESS SELF-CHECK: bundled terminfo Setulc {} evaluated for {rgb:#08x} gave escape {}",
            show(&terminfo_setulc),
            show(&escape)
        );
    }

    let reply = query_cap("Setulc");
    assert_eq!(
        (reply.status, reply.name_hex.as_str()),
        (b'1', "536574756C63"),
        "XTGETTCAP Setulc must be answered as supported; raw reply = {}",
        show(&reply.raw)
    );
    let value = reply.value.clone().unwrap_or_default();
    assert!(
        !value.is_empty(),
        "XTGETTCAP Setulc carried no value; raw reply = {}",
        show(&reply.raw)
    );

    // The reported string, evaluated with the terminfo's calling convention
    // (one packed 0xRRGGBB in %p1), must colour the underline exactly.
    let mut report = String::new();
    let mut all_ok = true;
    for rgb in colours {
        let (escape, (flags, ch, got)) = render_setulc(&value, rgb);
        let ok = flags & bc::cell_flags::UNDERLINE != 0
            && ch == u32::from('X')
            && got != bc::UNDERLINE_COLOR_UNSET
            && got & 0x00FF_FFFF == rgb;
        all_ok &= ok;
        report.push_str(&format!(
            "\n  p1={rgb:#08x}: escape {} -> underline colour {} (cell ch={ch:#x}) {}",
            show(&escape),
            if got == bc::UNDERLINE_COLOR_UNSET {
                "UNSET".to_string()
            } else {
                format!("{:#08x}", got & 0x00FF_FFFF)
            },
            if ok { "ok" } else { "WRONG" }
        ));
    }
    assert!(
        all_ok,
        "XTGETTCAP Setulc value {} does not colour the underline when evaluated with a \
         packed 0xRRGGBB in %p1 (the bundled terminfo's convention: {}):{report}",
        show(&value),
        show(&terminfo_setulc)
    );
}

#[test]
fn xtgettcap_reports_su_tc_xf_booleans_as_supported() {
    // Su (styled underlines), Tc (truecolor) and XF (focus events) are
    // asserted by the bundled terminfo for xterm-kitty. Asking for them must
    // not yield the "unknown capability" status 0.
    let mut bad = Vec::new();
    for name in ["Su", "Tc", "XF"] {
        let reply = query_cap(name);
        if reply.status != b'1' || reply.name_hex != hex_upper(name.as_bytes()) {
            bad.push(format!("{name}: raw reply {}", show(&reply.raw)));
        }
    }
    assert!(
        bad.is_empty(),
        "XTGETTCAP must report terminfo booleans Su/Tc/XF as supported (DCS 1 + r <hex-name> ...); \
         got:\n  {}",
        bad.join("\n  ")
    );
}

#[test]
fn xtgettcap_reports_ms_sync_ss_se_with_the_terminfo_strings() {
    // Hand-written oracles (not derived from the terminfo parser). Each is
    // the terminfo value with `\E` -> 0x1B and `\s` -> space.
    let cases: [(&str, &[u8]); 4] = [
        ("Ms", b"\x1b]52;%p1%s;%p2%s\x1b\\"),
        ("Sync", b"%?%p1%{1}%=%t\x1b[?2026h%e\x1b[?2026l%;"),
        ("Ss", b"\x1b[%p1%d q"),
        ("Se", b"\x1b[2 q"),
    ];
    let mut bad = Vec::new();
    for (name, want) in cases {
        let reply = query_cap(name);
        let want_reply = (b'1', hex_upper(name.as_bytes()), Some(want.to_vec()));
        let got_reply = (reply.status, reply.name_hex.clone(), reply.value.clone());
        if got_reply != want_reply {
            bad.push(format!(
                "{name}: want `DCS 1 + r {}={} ST`, got raw {}",
                want_reply.1,
                hex_upper(want),
                show(&reply.raw)
            ));
        }
    }
    assert!(
        bad.is_empty(),
        "XTGETTCAP must answer these terminfo string caps with the terminfo bytes:\n  {}",
        bad.join("\n  ")
    );
}

#[test]
fn xtgettcap_reports_every_boolean_cap_of_the_bundled_terminfo_as_supported() {
    let caps = bundled_caps();
    assert_terminfo_harness_sane(&caps);
    let mut total = 0usize;
    let mut bad = Vec::new();
    for (name, value) in &caps {
        if *value != CapValue::Bool {
            continue;
        }
        total += 1;
        let reply = query_cap(name);
        if reply.status != b'1' || reply.name_hex != hex_upper(name.as_bytes()) {
            bad.push(format!("{name}: raw reply {}", show(&reply.raw)));
        }
    }
    assert!(
        total >= 10,
        "only {total} boolean caps parsed; sweep is vacuous"
    );
    assert!(
        bad.is_empty(),
        "{} of {total} boolean capabilities asserted by kitty.terminfo are answered \
         as unsupported by XTGETTCAP:\n  {}",
        bad.len(),
        bad.join("\n  ")
    );
}

#[test]
fn xtgettcap_reports_every_string_cap_of_the_bundled_terminfo_byte_for_byte() {
    // `Setulc` is judged behaviourally in its own test (its exact bytes may
    // legitimately differ in the optional colour-space slot); every other
    // string capability must round-trip byte for byte.
    let caps = bundled_caps();
    assert_terminfo_harness_sane(&caps);
    let mut total = 0usize;
    let mut bad = Vec::new();
    for (name, value) in &caps {
        let CapValue::Str(want) = value else {
            continue;
        };
        if name == "Setulc" {
            continue;
        }
        total += 1;
        let reply = query_cap(name);
        let ok = reply.status == b'1'
            && reply.name_hex == hex_upper(name.as_bytes())
            && reply.value.as_deref() == Some(want.as_slice());
        if !ok {
            bad.push(format!(
                "{name}: want status 1 value {}, got status {} value {}",
                show(want),
                reply.status as char,
                match &reply.value {
                    Some(v) => show(v),
                    None => "<none>".to_string(),
                }
            ));
        }
    }
    assert!(
        total >= 100,
        "only {total} string caps parsed; sweep is vacuous"
    );
    let shown: Vec<&String> = bad.iter().take(25).collect();
    assert!(
        bad.is_empty(),
        "{} of {total} string capabilities defined by kitty.terminfo are not reported \
         byte-for-byte by XTGETTCAP (first {} shown):\n  {}",
        bad.len(),
        shown.len(),
        shown
            .iter()
            .map(|s| s.as_str())
            .collect::<Vec<&str>>()
            .join("\n  ")
    );
}
