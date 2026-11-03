//! Blind regression tests for bug `VTRO-b`: the "replies inside one input
//! chunk leave in query order" guarantee still has three holes that
//! sentinel-based clients (colour query followed by DA1 / CPR) can fall into.
//!
//! Author had no access to the implementation; the contract consulted was
//! `core/include/BBCore.h`, the sibling suites (`vt_reply_order_blind.rs`,
//! `color_query_chunk_order_blind.rs`, `sync_output.rs`,
//! `sync_update_timeout.rs`) and the xterm control-sequence conventions.
//!
//! Contract under test
//! -------------------
//! A terminal processes its input byte stream strictly in order, and a
//! program that writes `query A` then `query B` reads the reply to A before
//! the reply to B, no matter how the PTY layer chopped the bytes into
//! `read(2)` calls (one `bb_term_input` call each). The sentinel idiom
//! relies on it: ask for the colour, then ask something every terminal
//! answers (DA1 `ESC [ c`, CPR `ESC [ 6 n`); when the sentinel's reply
//! arrives first the client concludes colour queries are unsupported, and
//! the genuine colour answer is later typed into the shell as
//! `ESC ] 11 ; rgb:... ` garbage.
//!
//! The three shapes pinned here
//! ----------------------------
//! 1. An OSC that is NOT terminated by BEL or ST but is ended by the ESC
//!    that starts the next sequence. In every ECMA-48 / xterm-style parser
//!    an ESC inside a string aborts-and-dispatches it, so
//!    `ESC ] 11 ; ?  ESC [ 6 n` is "the colour query, then a CPR" and must
//!    reply OSC 11 first, CPR last, exactly like the BEL / ST-terminated
//!    spelling of the same two queries.
//! 2. Queries inside a DEC 2026 synchronized update
//!    (`ESC [ ? 2026 h ... ESC [ ? 2026 l`). The terminal still answers them,
//!    and they must still be answered in query order. The only acceptable
//!    alternative to fixing the order is to record the residual (with its
//!    reason) in `KNOWN_ISSUES.md`; the sync tests therefore pass when the
//!    order is right, or, if it is not, when `KNOWN_ISSUES.md` carries an
//!    entry that names the synchronized-update reply-order limitation.
//! 3. A flood of separate colour queries in one chunk is a DoS vector that
//!    the core bounds (the reply count is capped); when it bounds the flood
//!    it must leave a breadcrumb on stderr rather than dropping silently,
//!    otherwise the cap is invisible to anyone diagnosing a client that
//!    "never gets its colour answer".
//!
//! Observable surface used: `bb_term_input` chunks in, `PtyWrite` event
//! payloads out, and (for shape 3 only) the stderr of a child process
//! running this very test binary. Replies are classified by their leading
//! bytes into short labels (`DA1`, `CPR`, `OSC11=0xf5f0e1`, ...) so the
//! order is asserted without depending on the precise reply spelling.
//! Colour-query replies are opted in with `bb_term_set_color_query_enabled`.
//!
//! Non-vacuity: the `control_*` tests assert, with no ordering question in
//! play, that every query kind yields exactly one reply of the expected
//! label, that an ESC-ended unterminated colour query still yields its reply
//! at all, that the already-fixed terminated spelling is in order, that a
//! sync block loses no reply, and that the flood child really ran and
//! produced replies. Every bug test re-checks its one-query-per-chunk
//! reference before judging the single-chunk delivery.
//!
//! Cost: every terminal is 80x24 with 100 lines of scrollback (~0.3 MiB),
//! created, fed < 8 KiB and dropped before the next one; the heaviest test
//! (the cut sweeps) builds a few dozen of them sequentially. One child
//! process (this test binary, one test) is spawned for shape 3.

use blackbird_core::*;
use std::ffi::{c_void, CString};
use std::process::Command;
use std::sync::Mutex;

// ---------- the theme the "host app" pushes ------------------------

/// Differs from the built-in xterm defaults, so a colour reply is
/// attributable to the pushed theme.
const THEME_FG: u32 = 0x2B3A4C;
const THEME_BG: u32 = 0xF5F0E1;
const THEME_CURSOR: u32 = 0x336699;
/// ANSI slot 1, pushed through `bb_term_set_named_color(1, ..)`.
const THEME_ANSI1: u32 = 0xB3261E;

const BSU: &[u8] = b"\x1b[?2026h";
const ESU: &[u8] = b"\x1b[?2026l";

// ---------- harness ------------------------------------------------

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

struct Rig {
    term: *mut BBTerm,
    // Boxed so the address handed to the C callback stays stable.
    sink: Box<Sink>,
}

impl Rig {
    /// A fresh 80x24 terminal, colour-query replies enabled, theme pushed,
    /// XTVERSION version string set.
    fn new() -> Rig {
        let sink = Box::new(Sink::default());
        let term = unsafe { bb_term_new(80, 24, 100) };
        assert_ne!(term as usize, 0, "bb_term_new(80,24,100) returned null");
        let version = CString::new("9.9.9").unwrap();
        unsafe {
            bb_term_set_event_cb(term, Some(cb), &*sink as *const Sink as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);
            bb_term_set_terminal_version(term, version.as_ptr());
            bb_term_set_named_color(term, 1, THEME_ANSI1);
            bb_term_set_named_color(term, 256, THEME_FG);
            bb_term_set_named_color(term, 257, THEME_BG);
            bb_term_set_named_color(term, 258, THEME_CURSOR);
        }
        Rig { term, sink }
    }

    /// Feed ONE chunk (one `bb_term_input` call) and return the PtyWrite
    /// payloads that call produced, in emission order.
    fn feed_collect(&self, seq: &[u8]) -> Vec<Vec<u8>> {
        self.sink.events.lock().unwrap().clear();
        unsafe { bb_term_input(self.term, seq.as_ptr(), seq.len()) };
        self.sink
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
            .map(|(_, v)| v.clone())
            .collect()
    }

    /// Feed one chunk, return the labels of the replies it produced.
    fn labels(&self, seq: &[u8]) -> Vec<String> {
        self.feed_collect(seq).iter().map(|w| classify(w)).collect()
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bb_term_free(self.term) };
    }
}

/// Decode `ESC ] <prefix> ; rgb:RRRR/GGGG/BBBB (ST | BEL)` to 0xRRGGBB.
fn parse_rgb_reply(reply: &[u8], prefix: &str) -> Result<u32, String> {
    let s = std::str::from_utf8(reply).map_err(|_| format!("non-UTF-8 reply {reply:?}"))?;
    let head = format!("\x1b]{prefix};rgb:");
    let body = s
        .strip_prefix(head.as_str())
        .ok_or_else(|| format!("reply {s:?} lacks prefix {head:?}"))?;
    let body = body
        .strip_suffix("\x1b\\")
        .or_else(|| body.strip_suffix('\x07'))
        .ok_or_else(|| format!("reply {s:?} lacks an ST/BEL terminator"))?;
    let chans: Vec<&str> = body.split('/').collect();
    if chans.len() != 3 {
        return Err(format!("expected 3 channels in {s:?}"));
    }
    let mut rgb = 0u32;
    for h in chans {
        let v = u32::from_str_radix(h, 16).map_err(|_| format!("bad hex {h:?} in {s:?}"))?;
        let byte = match h.len() {
            2 => v,
            4 => v >> 8,
            n => return Err(format!("unsupported channel width {n} in {s:?}")),
        };
        rgb = (rgb << 8) | byte;
    }
    Ok(rgb)
}

/// Turn a reply into a short label identifying which query it answers.
/// Colour replies carry their decoded colour (`OSC11=0xf5f0e1`).
fn classify(reply: &[u8]) -> String {
    for (prefix, tag) in [
        ("10", "OSC10"),
        ("11", "OSC11"),
        ("12", "OSC12"),
        ("4;1", "OSC4;1"),
    ] {
        let head = format!("\x1b]{prefix};");
        if reply.starts_with(head.as_bytes()) {
            return match parse_rgb_reply(reply, prefix) {
                Ok(rgb) => format!("{tag}={rgb:#08x}"),
                Err(e) => format!("{tag}=<undecodable: {e}>"),
            };
        }
    }
    if reply.starts_with(b"\x1bP>|Blackbird") {
        return "XTVERSION".to_string();
    }
    if reply.starts_with(b"\x1bP1$r") || reply.starts_with(b"\x1bP0$r") {
        return "DECRQSS".to_string();
    }
    if reply.starts_with(b"\x1bP1+r") || reply.starts_with(b"\x1bP0+r") {
        return "XTGETTCAP".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"c") {
        return "DA1".to_string();
    }
    if reply.starts_with(b"\x1b[>0;") && reply.ends_with(b"c") {
        return "DA2".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"u") {
        return "KITTYKB".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"$y") {
        return "DECRQM".to_string();
    }
    if reply == b"\x1b[0n" {
        return "DSR".to_string();
    }
    if reply.starts_with(b"\x1b[") && reply.ends_with(b"R") {
        return "CPR".to_string();
    }
    format!("UNKNOWN({:?})", String::from_utf8_lossy(reply))
}

fn show(labels: &[String]) -> String {
    format!("[{}]", labels.join(", "))
}

// ---------- the queries --------------------------------------------

#[derive(Clone)]
struct Query {
    /// Human-readable name for failure messages.
    name: String,
    bytes: Vec<u8>,
    /// The label its single reply must classify as.
    expect: String,
}

impl Query {
    fn new(name: &str, bytes: &[u8], expect: &str) -> Query {
        Query {
            name: name.to_string(),
            bytes: bytes.to_vec(),
            expect: expect.to_string(),
        }
    }
}

/// The four colour query kinds: (OSC id, label tag, pushed theme colour).
const COLOUR_KINDS: [(&str, &str, u32); 4] = [
    ("10", "OSC10", THEME_FG),
    ("11", "OSC11", THEME_BG),
    ("12", "OSC12", THEME_CURSOR),
    ("4;1", "OSC4;1", THEME_ANSI1),
];

/// `ESC ] <id> ; ?` followed by `term` ("" = left unterminated).
fn colour_query(id: &str, tag: &str, theme: u32, term_name: &str, term: &str) -> Query {
    Query {
        name: format!("OSC {id} ? ({term_name})"),
        bytes: format!("\x1b]{id};?{term}").into_bytes(),
        expect: format!("{tag}={theme:#08x}"),
    }
}

/// Every colour kind with the given terminator spelling.
fn colour_queries_with(term_name: &str, term: &str) -> Vec<Query> {
    COLOUR_KINDS
        .iter()
        .map(|(id, tag, theme)| colour_query(id, tag, *theme, term_name, term))
        .collect()
}

/// Every colour kind, left UNTERMINATED (ended only by the next ESC).
fn unterminated_colour_queries() -> Vec<Query> {
    colour_queries_with("unterminated", "")
}

/// Every colour kind with both real terminators.
fn terminated_colour_queries() -> Vec<Query> {
    let mut out = colour_queries_with("BEL", "\x07");
    out.extend(colour_queries_with("ST", "\x1b\\"));
    out
}

fn da1() -> Query {
    Query::new("DA1 (CSI c)", b"\x1b[c", "DA1")
}
fn cpr() -> Query {
    Query::new("CPR (CSI 6 n)", b"\x1b[6n", "CPR")
}
fn xtversion() -> Query {
    Query::new("XTVERSION (CSI > q)", b"\x1b[>q", "XTVERSION")
}

/// Queries answered by the parser proper.
fn processor_queries() -> Vec<Query> {
    vec![
        da1(),
        Query::new("DA2 (CSI > c)", b"\x1b[>c", "DA2"),
        cpr(),
        Query::new("DSR (CSI 5 n)", b"\x1b[5n", "DSR"),
        Query::new("kitty kb (CSI ? u)", b"\x1b[?u", "KITTYKB"),
        Query::new("DECRQM (CSI ? 2004 $ p)", b"\x1b[?2004$p", "DECRQM"),
    ]
}

/// Queries answered by the side parser that scans the bytes before the main
/// parser sees them.
fn tap_queries() -> Vec<Query> {
    vec![
        xtversion(),
        Query::new("DECRQSS (DCS $ q m ST)", b"\x1bP$qm\x1b\\", "DECRQSS"),
        Query::new(
            "XTGETTCAP (DCS + q 544E ST)",
            b"\x1bP+q544E\x1b\\",
            "XTGETTCAP",
        ),
    ]
}

fn names(qs: &[Query]) -> String {
    qs.iter()
        .map(|q| q.name.as_str())
        .collect::<Vec<_>>()
        .join(" ; ")
}

fn expected_labels(qs: &[Query]) -> Vec<String> {
    qs.iter().map(|q| q.expect.clone()).collect()
}

fn stream(qs: &[Query]) -> Vec<u8> {
    qs.iter().flat_map(|q| q.bytes.iter().copied()).collect()
}

/// Deliver `qs` one query per `bb_term_input` call on a fresh terminal.
/// An UNTERMINATED colour query needs the next ESC to complete, so this
/// reference appends a lone `ESC \` (a harmless ST) after it in its own
/// chunk; that makes it a plain, properly terminated query.
fn reference_delivery(qs: &[Query]) -> Vec<String> {
    let rig = Rig::new();
    let mut out = Vec::new();
    for q in qs {
        let mut bytes = q.bytes.clone();
        if bytes.starts_with(b"\x1b]") && !bytes.ends_with(b"\x07") && !bytes.ends_with(b"\x1b\\") {
            bytes.extend_from_slice(b"\x1b\\");
        }
        out.extend(rig.labels(&bytes));
    }
    out
}

/// Judge one stream: the one-query-per-chunk reference must be in query
/// order (rig precondition, panics if not), then `deliver` (which feeds the
/// stream on a fresh terminal in some chunking) must equal it. Returns a
/// description of the mismatch, if any.
fn check_delivery<F: Fn(&Rig) -> Vec<String>>(
    qs: &[Query],
    how: &str,
    deliver: F,
) -> Option<String> {
    let want = expected_labels(qs);
    let reference = reference_delivery(qs);
    assert_eq!(
        show(&reference),
        show(&want),
        "RIG PRECONDITION: one-query-per-chunk delivery of `{}` must already \
         reply in query order with the expected labels",
        names(qs)
    );
    let rig = Rig::new();
    let got = deliver(&rig);
    if got == want {
        None
    } else {
        Some(format!(
            "`{}` ({how}): replies {} but queries were in order {}",
            names(qs),
            show(&got),
            show(&want)
        ))
    }
}

// ---------- the documented-residual escape hatch (shape 2 only) ----

/// Does `text` (the contents of `KNOWN_ISSUES.md`) carry an entry about the
/// synchronized-update reply-order limitation? An "entry" is a top-level
/// bullet / heading / bold-lead paragraph; it must name the DEC 2026
/// synchronized update, talk about replies and their order, and be long
/// enough to also carry the reason (a one-line stub does not count).
/// Returns the first line of the matching entry.
fn scan_known_issues(text: &str) -> Result<String, String> {
    let mut entries: Vec<String> = Vec::new();
    for line in text.lines() {
        let starts_entry = line.starts_with("- ")
            || line.starts_with("* ")
            || line.starts_with('#')
            || line.starts_with("**");
        if starts_entry || entries.is_empty() {
            entries.push(String::new());
        }
        let last = entries.len() - 1;
        entries[last].push_str(line);
        entries[last].push('\n');
    }

    const SYNC_MARKERS: [&str; 9] = [
        "?2026",
        "dec 2026",
        "dec mode 2026",
        "mode 2026",
        "synchronized update",
        "synchronised update",
        "synchronized-update",
        "synchronized output",
        "sync update",
    ];
    for entry in &entries {
        let lower = entry.to_lowercase();
        let names_sync = SYNC_MARKERS.iter().any(|m| lower.contains(m));
        if names_sync && lower.contains("repl") && lower.contains("order") && entry.len() >= 200 {
            return Ok(entry.lines().next().unwrap_or("").to_string());
        }
    }
    Err(format!(
        "KNOWN_ISSUES.md ({} entries scanned) has no entry that names the DEC 2026 \
         synchronized update, replies and their order, with an explanation (>= 200 chars)",
        entries.len()
    ))
}

fn known_issues_documents_sync_reply_order() -> Result<String, String> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../KNOWN_ISSUES.md");
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    scan_known_issues(&text)
}

// ---------- controls: the rig sees what the tests rely on ----------

#[test]
fn control_every_query_alone_yields_exactly_its_own_reply() {
    // Not the bug: with no ordering question in play, each query produces
    // exactly one reply and it classifies as the expected kind. Colour
    // queries are checked in their terminated spelling here.
    let mut all = terminated_colour_queries();
    all.extend(processor_queries());
    all.extend(tap_queries());
    let mut bad = Vec::new();
    for q in &all {
        let rig = Rig::new();
        let got = rig.labels(&q.bytes);
        if got != vec![q.expect.clone()] {
            bad.push(format!(
                "{}: replies {} (wanted [{}])",
                q.name,
                show(&got),
                q.expect
            ));
        }
    }
    assert!(
        bad.is_empty(),
        "{} of {} lone queries did not yield exactly their own reply:\n{}",
        bad.len(),
        all.len(),
        bad.join("\n")
    );
}

#[test]
fn control_esc_ended_unterminated_colour_query_still_yields_its_reply() {
    // Not the ordering bug: an OSC ended by the ESC of a following,
    // reply-less sequence (SGR reset) is dispatched like any other, so the
    // colour query it carried is answered exactly once, in the same chunk.
    // This is the premise of the unterminated-OSC tests below.
    let mut bad = Vec::new();
    for q in unterminated_colour_queries() {
        let rig = Rig::new();
        let mut chunk = q.bytes.clone();
        chunk.extend_from_slice(b"\x1b[m");
        let got = rig.labels(&chunk);
        if got != vec![q.expect.clone()] {
            bad.push(format!(
                "{} then ESC[m: replies {} (wanted [{}])",
                q.name,
                show(&got),
                q.expect
            ));
        }
    }
    assert!(
        bad.is_empty(),
        "an unterminated colour query ended by the next ESC must still be \
         answered exactly once:\n{}",
        bad.join("\n")
    );
}

#[test]
fn control_terminated_colour_query_then_cpr_in_one_chunk_is_in_order() {
    // Already-correct spelling of the shape-1 trigger (BEL and ST). If this
    // ever fails the earlier reply-order fix regressed, which is a different
    // bug from the one pinned below.
    let mut bad = Vec::new();
    for c in terminated_colour_queries() {
        let rig = Rig::new();
        let qs = vec![c, cpr()];
        let got = rig.labels(&stream(&qs));
        if got != expected_labels(&qs) {
            bad.push(format!(
                "`{}`: replies {} (wanted {})",
                names(&qs),
                show(&got),
                show(&expected_labels(&qs))
            ));
        }
    }
    assert!(
        bad.is_empty(),
        "terminated colour query then CPR must reply in query order:\n{}",
        bad.join("\n")
    );
}

#[test]
fn control_unterminated_colour_query_then_terminated_colour_query_keeps_query_order() {
    // Two colour queries, the first left to the next ESC to end: both are
    // colour replies so their relative order is whatever the queue holds;
    // it must stay the order asked. Guards a fix that flips the bug.
    let mut bad = Vec::new();
    for first in unterminated_colour_queries() {
        for second in terminated_colour_queries() {
            let qs = vec![first.clone(), second];
            let rig = Rig::new();
            let got = rig.labels(&stream(&qs));
            if got != expected_labels(&qs) {
                bad.push(format!(
                    "`{}`: replies {} (wanted {})",
                    names(&qs),
                    show(&got),
                    show(&expected_labels(&qs))
                ));
            }
        }
    }
    assert!(
        bad.is_empty(),
        "unterminated colour query then terminated colour query must reply \
         in query order:\n{}",
        bad.join("\n")
    );
}

// ---------- shape 1: unterminated OSC ended by ESC -----------------

#[test]
fn unterminated_osc11_query_then_cpr_in_one_chunk_replies_osc11_first() {
    // The exact trigger: `ESC ] 11 ; ?` with NO BEL / ST, immediately
    // followed by `ESC [ 6 n`. The ESC ends the OSC, which then counts as
    // a query: colour reply first, the CPR sentinel last.
    let rig = Rig::new();
    let writes = rig.feed_collect(b"\x1b]11;?\x1b[6n");
    let labels: Vec<String> = writes.iter().map(|w| classify(w)).collect();
    assert_eq!(
        show(&labels),
        format!("[OSC11={THEME_BG:#08x}, CPR]"),
        "unterminated OSC 11 ? followed by CPR in one chunk must reply OSC 11 \
         then CPR (like the BEL / ST spelling); raw replies: {writes:?}"
    );
    assert_eq!(
        writes.last().map(|w| w.as_slice()),
        Some(&b"\x1b[1;1R"[..]),
        "the CPR sentinel (cursor at 1;1) must be the last reply"
    );
}

#[test]
fn unterminated_colour_query_then_each_other_query_in_one_chunk_replies_in_order() {
    // Every colour kind (OSC 4;1 / 10 / 11 / 12), left unterminated, then
    // every processor-side and tap-side query, in ONE chunk. The sentinel
    // (or any later reply) must never overtake the colour answer.
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for c in unterminated_colour_queries() {
        for q in processor_queries().into_iter().chain(tap_queries()) {
            checked += 1;
            let qs = vec![c.clone(), q];
            let bytes = stream(&qs);
            if let Some(f) = check_delivery(&qs, "one chunk", |rig| rig.labels(&bytes)) {
                failures.push(f);
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {checked} one-chunk deliveries of `unterminated colour query ; \
         other query` answered out of query order (the ESC that starts the \
         second query ends the first):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn unterminated_colour_query_then_other_query_reply_order_does_not_depend_on_pty_split() {
    // `ESC ] 11 ; ? ESC [ 6 n` (and an XTVERSION variant) delivered (a) in
    // one chunk, (b) cut at every byte offset into two chunks, (c) one byte
    // per call. Every delivery must reply in query order.
    let mut failures = Vec::new();
    let mut deliveries = 0usize;
    for second in [cpr(), da1(), xtversion()] {
        let qs = vec![
            colour_query("11", "OSC11", THEME_BG, "unterminated", ""),
            second,
        ];
        let bytes = stream(&qs);

        deliveries += 1;
        if let Some(f) = check_delivery(&qs, "single chunk", |rig| rig.labels(&bytes)) {
            failures.push(f);
        }
        for cut in 1..bytes.len() {
            deliveries += 1;
            let how = format!("split at byte {cut}");
            if let Some(f) = check_delivery(&qs, &how, |rig| {
                let mut got = rig.labels(&bytes[..cut]);
                got.extend(rig.labels(&bytes[cut..]));
                got
            }) {
                failures.push(f);
            }
        }
        deliveries += 1;
        if let Some(f) = check_delivery(&qs, "byte at a time", |rig| {
            let mut got = Vec::new();
            for b in &bytes {
                got.extend(rig.labels(std::slice::from_ref(b)));
            }
            got
        }) {
            failures.push(f);
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {deliveries} deliveries of an unterminated colour query \
         followed by another query replied out of query order:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// ---------- shape 2: queries inside a DEC 2026 synchronized update -

/// Deliver `body` wrapped in BSU/ESU, as one chunk and as three chunks
/// (BSU | body | ESU), each on a fresh terminal, and collect every
/// out-of-order delivery.
fn sync_failures(qs: &[Query]) -> Vec<String> {
    let body = stream(qs);
    let mut one_chunk = Vec::new();
    one_chunk.extend_from_slice(BSU);
    one_chunk.extend_from_slice(&body);
    one_chunk.extend_from_slice(ESU);

    let mut failures = Vec::new();
    if let Some(f) = check_delivery(qs, "inside DEC 2026, one chunk", |rig| {
        rig.labels(&one_chunk)
    }) {
        failures.push(f);
    }
    if let Some(f) = check_delivery(qs, "inside DEC 2026, BSU | body | ESU chunks", |rig| {
        let mut got = rig.labels(BSU);
        got.extend(rig.labels(&body));
        got.extend(rig.labels(ESU));
        got
    }) {
        failures.push(f);
    }
    failures
}

/// Order must be right, or the residual must be recorded in KNOWN_ISSUES.md.
#[track_caller]
fn assert_sync_order_or_documented(what: &str, failures: Vec<String>, checked: usize) {
    if failures.is_empty() {
        return;
    }
    match known_issues_documents_sync_reply_order() {
        Ok(_entry) => {}
        Err(why) => panic!(
            "{what}: {} of {checked} synchronized-update deliveries answered out of query \
             order, and the residual is not documented ({why}). Either make replies inside \
             `ESC[?2026h ... ESC[?2026l` leave in query order, or add a KNOWN_ISSUES.md \
             entry explaining why they cannot.\n{}",
            failures.len(),
            failures.join("\n")
        ),
    }
}

#[test]
fn control_sync_update_loses_no_reply() {
    // Not the ordering bug: every query inside a sync block is still
    // answered exactly once (as a multiset), so the ordering tests below
    // judge order and not presence.
    let qs = vec![
        xtversion(),
        colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\"),
        da1(),
        cpr(),
    ];
    let mut want = expected_labels(&qs);
    want.sort();

    let mut input = Vec::new();
    input.extend_from_slice(BSU);
    input.extend_from_slice(&stream(&qs));
    input.extend_from_slice(ESU);
    let rig = Rig::new();
    let mut got = rig.labels(&input);
    got.sort();
    assert_eq!(
        show(&got),
        show(&want),
        "a sync block (one chunk) must answer each of its {} queries exactly once",
        qs.len()
    );
}

#[test]
fn colour_query_then_cpr_or_da1_inside_sync_update_replies_in_order_or_is_documented() {
    // The sentinel idiom inside a synchronized update: every colour query
    // kind and terminator, then CPR or DA1.
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for c in terminated_colour_queries() {
        for sentinel in [cpr(), da1()] {
            checked += 2; // one-chunk + three-chunk delivery
            failures.extend(sync_failures(&[c.clone(), sentinel]));
        }
    }
    assert_sync_order_or_documented("colour query ; CPR/DA1 in a sync block", failures, checked);
}

#[test]
fn processor_tap_and_colour_reply_pairs_inside_sync_update_reply_in_order_or_are_documented() {
    // Every ordered pair drawn from one reply of each class (colour,
    // processor-side, tap-side), inside a sync block.
    let reps = vec![
        colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\"),
        da1(),
        cpr(),
        xtversion(),
        Query::new("DECRQSS (DCS $ q m ST)", b"\x1bP$qm\x1b\\", "DECRQSS"),
    ];
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for (i, a) in reps.iter().enumerate() {
        for (j, b) in reps.iter().enumerate() {
            if i == j {
                continue;
            }
            checked += 2;
            failures.extend(sync_failures(&[a.clone(), b.clone()]));
        }
    }
    assert_sync_order_or_documented("reply pairs in a sync block", failures, checked);
}

#[test]
fn control_known_issues_scanner_accepts_only_a_real_sync_reply_order_entry() {
    // Guards the escape hatch used above: it must be picky enough that an
    // unrelated entry (or a date that merely contains "2026") cannot make the
    // sync tests pass, and generous enough to accept an honest write-up.
    let unrelated = "- **Rapid double-cmd-G can lose the find anchor.** Two findNext calls in \
                     one refresh window race the anchor rotation (cosmetic, no data loss). \
                     Reported 2026-06-21 during the pre-release audit; low severity.\n";
    assert!(
        scan_known_issues(unrelated).is_err(),
        "an unrelated entry that only contains the year 2026 must not count"
    );

    let stub = "- DEC 2026 reply order is wrong.\n";
    assert!(
        scan_known_issues(stub).is_err(),
        "a one-line stub without a reason must not count"
    );

    let honest = "- **Replies inside a DEC 2026 synchronized update can leave out of query \
                  order.** Bytes between `CSI ? 2026 h` and `CSI ? 2026 l` are replayed whole \
                  when the update closes, while XTVERSION / DECRQSS / XTGETTCAP are answered \
                  by the side parser the moment they arrive, so a DA1 sentinel can trail or \
                  overtake them. Reason: the replay is owned by the vendored vte handler.\n";
    assert_eq!(
        scan_known_issues(honest).map(|_| ()),
        Ok(()),
        "an entry naming the synchronized update, the replies, their order and a reason \
         must count"
    );
}

// ---------- shape 3: a flood of separate colour queries ------------

/// Number of separate `ESC ] 11 ; ? BEL` sequences in the flood chunk.
/// 1000 is well past the 256-entry per-drain colour queue and the 32/s
/// reply gate, and is only 7 KB.
const FLOOD: usize = 1000;
const CHILD_ENV: &str = "BB_VT_RESIDUAL_FLOOD_CHILD";

fn flood_chunk() -> Vec<u8> {
    b"\x1b]11;?\x07".repeat(FLOOD)
}

#[test]
fn control_flood_of_separate_colour_queries_in_one_chunk_is_bounded() {
    // Not the breadcrumb bug: the DoS bound itself. One chunk of FLOOD
    // separate colour queries may not amplify into FLOOD replies; some
    // replies must still come back (replies are enabled), and none may
    // be a malformed colour reply.
    let rig = Rig::new();
    let writes = rig.feed_collect(&flood_chunk());
    let labels: Vec<String> = writes.iter().map(|w| classify(w)).collect();
    let bad: Vec<&String> = labels
        .iter()
        .filter(|l| **l != format!("OSC11={THEME_BG:#08x}"))
        .collect();
    assert!(
        !labels.is_empty() && labels.len() <= 256 && bad.is_empty(),
        "{FLOOD} separate OSC 11 queries in one chunk must yield between 1 and 256 \
         well-formed replies; got {} replies, malformed/unexpected: {bad:?}",
        labels.len()
    );
}

/// Runs only in the child process spawned by
/// `flood_of_separate_colour_queries_in_one_chunk_leaves_a_breadcrumb`
/// (the parent sets `CHILD_ENV`); a no-op, instantly passing test otherwise.
/// The markers delimit what the core wrote to stderr during the flood.
#[test]
fn flood_child_runner() {
    if std::env::var_os(CHILD_ENV).is_none() {
        return;
    }
    let rig = Rig::new();
    let chunk = flood_chunk();
    eprintln!("BBFLOOD-BEGIN");
    let replies = rig.feed_collect(&chunk).len();
    eprintln!("BBFLOOD-END replies={replies}");
}

#[test]
fn flood_of_separate_colour_queries_in_one_chunk_leaves_a_breadcrumb() {
    // The core bounds a colour-query flood (see the control above). A bound
    // that drops silently is invisible: anyone diagnosing a client that
    // "never gets its colour answer" has nothing to find. So the flood must
    // leave at least one stderr line that talks about the colour queries.
    //
    // libtest captures the `eprintln!` of a test thread unless run with
    // `--nocapture`, so the flood runs in a child copy of this test binary
    // and the parent reads the child's real stderr.
    let exe = std::env::current_exe().expect("current_exe of the test binary");
    let out = Command::new(exe)
        .args([
            "--exact",
            "flood_child_runner",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_ENV, "1")
        .output()
        .expect("spawn child test binary");
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();

    // Preconditions: the child ran the flood and replies were live.
    assert!(
        out.status.success(),
        "child test binary failed ({:?})\nstdout:\n{stdout}\nstderr:\n{stderr}",
        out.status
    );
    let lines: Vec<&str> = stderr.lines().collect();
    let begin = lines.iter().position(|l| l.trim() == "BBFLOOD-BEGIN");
    let end = lines.iter().position(|l| l.starts_with("BBFLOOD-END"));
    let (begin, end) = match (begin, end) {
        (Some(b), Some(e)) if b < e => (b, e),
        _ => panic!(
            "PRECONDITION: child did not run the flood (no BEGIN/END markers)\n\
             stdout:\n{stdout}\nstderr:\n{stderr}"
        ),
    };
    let replies: usize = lines[end]
        .trim_start_matches("BBFLOOD-END replies=")
        .trim()
        .parse()
        .unwrap_or(usize::MAX);
    assert!(
        (1..=256).contains(&replies),
        "PRECONDITION: the flood child must see 1..=256 replies, saw {replies} \
         (marker line {:?})",
        lines[end]
    );

    // The breadcrumb: something written between the markers that mentions
    // the colour queries.
    let during: Vec<&str> = lines[begin + 1..end].to_vec();
    let mentions_colour = |l: &str| -> bool {
        let lower = l.to_lowercase();
        ["color", "colour", "osc", "query", "queries"]
            .iter()
            .any(|w| lower.contains(w))
    };
    let breadcrumbs: Vec<&str> = during
        .iter()
        .copied()
        .filter(|l: &&str| mentions_colour(l))
        .collect();
    assert!(
        !breadcrumbs.is_empty(),
        "a flood of {FLOOD} separate OSC 11 queries in one chunk ({replies} replies \
         let through) left no breadcrumb on stderr; lines written during the flood: \
         {during:?}"
    );
}
