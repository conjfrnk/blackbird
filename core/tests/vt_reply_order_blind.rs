//! Blind regression tests for bug `vt-reply-order`: when several terminal
//! queries arrive inside ONE `bb_term_input` chunk, the replies must reach
//! the PTY in the order the queries were written, exactly as they do when
//! the same bytes are delivered one query per chunk.
//!
//! Author had no access to the implementation; the contract consulted was
//! `core/include/BBCore.h`, the sibling suites (`terminal_replies.rs`,
//! `xtgettcap.rs`, `decrqm.rs`, `color_query.rs`,
//! `color_query_chunk_order_blind.rs`) and the xterm control-sequence
//! conventions.
//!
//! Contract under test
//! -------------------
//! A terminal processes its input byte stream strictly in order, and a
//! program that writes `query A` followed by `query B` reads the reply to A
//! before the reply to B. Real clients depend on this for the "sentinel"
//! idiom: send the question(s) you care about (OSC 10 / OSC 11 colour
//! queries, XTVERSION, ...), then send a query every terminal answers
//! (DA1 `ESC [ c`, or CPR `ESC [ 6 n`), and treat the sentinel's arrival as
//! "everything that was going to be answered has been answered".
//!
//! If the sentinel's reply overtakes a slower reply, the client concludes
//! the terminal does not support the question (wrong light/dark theme
//! detection), stops reading, and the genuine answer arrives after the tool
//! exits and is typed into the shell as `ESC ] 11 ; rgb:... ` garbage.
//!
//! The answer must not depend on whether the PTY layer happened to deliver
//! the queries in one `read(2)` (one `bb_term_input` call) or several. This
//! file pins:
//!   * every pairing of {OSC 4 / 10 / 11 / 12 colour query} with
//!     {DA1, DA2, CPR, DSR, kitty `?u`, DECRQM} in either order,
//!   * every pairing of {DA1, CPR, ...} with {XTVERSION, DECRQSS,
//!     XTGETTCAP} in either order, and of colour queries with those,
//!   * all 120 orderings of five representative queries (a colour query, a
//!     DA1, a CPR, an XTVERSION and an XTGETTCAP),
//!   * the sentinel idiom end to end, with nothing left over after it,
//!   * the same stream cut at every byte offset / delivered byte by byte.
//!
//! Observable surface used: `bb_term_input` chunks in, `PtyWrite` event
//! payloads out. Replies are classified by their leading bytes into a short
//! label (`DA1`, `CPR`, `OSC11=0xf5f0e1`, ...) so the order is asserted
//! without depending on the precise reply spelling; a colour reply's label
//! carries its decoded colour, so a reply with the wrong value also fails.
//! Colour-query replies are opted in explicitly with
//! `bb_term_set_color_query_enabled`.
//!
//! Non-vacuity: `control_*` tests assert, without involving any ordering
//! question, that every query kind produces exactly one reply of the
//! expected label when sent alone, and that one-query-per-chunk delivery
//! (the reference the bug tests compare against) yields query order. The
//! bug tests re-check that reference for every stream before judging the
//! single-chunk delivery.
//!
//! Cost: every terminal is 80x24 with 100 lines of scrollback
//! (~0.3 MiB), created, fed < 100 bytes, and dropped before the next one.
//! The heaviest test (the 120-permutation sweep) builds 240 such terminals
//! sequentially: well under a MiB resident at any instant and well under a
//! second. The 33-byte cut sweep builds ~35.

use blackbird_core::*;
use std::ffi::{c_void, CString};
use std::sync::Mutex;

// ---------- the theme the "host app" pushes ------------------------

/// Differs from the built-in xterm defaults, so a colour reply is
/// attributable to the pushed theme.
const THEME_FG: u32 = 0x2B3A4C;
const THEME_BG: u32 = 0xF5F0E1;
const THEME_CURSOR: u32 = 0x336699;
/// ANSI slot 1, pushed through `bb_term_set_named_color(1, ..)`.
const THEME_ANSI1: u32 = 0xB3261E;

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

/// `term` is "\x07" (BEL) or "\x1b\\" (ST).
fn colour_query(id: &str, tag: &str, theme: u32, term_name: &str, term: &str) -> Query {
    Query {
        name: format!("OSC {id} ? ({term_name})"),
        bytes: format!("\x1b]{id};?{term}").into_bytes(),
        expect: format!("{tag}={theme:#08x}"),
    }
}

/// OSC 4;1 / 10 / 11 / 12 `?` queries with both terminators.
fn colour_queries() -> Vec<Query> {
    let mut out = Vec::new();
    for (term_name, term) in [("BEL", "\x07"), ("ST", "\x1b\\")] {
        out.push(colour_query("10", "OSC10", THEME_FG, term_name, term));
        out.push(colour_query("11", "OSC11", THEME_BG, term_name, term));
        out.push(colour_query("12", "OSC12", THEME_CURSOR, term_name, term));
        out.push(colour_query("4;1", "OSC4;1", THEME_ANSI1, term_name, term));
    }
    out
}

fn osc11_st() -> Query {
    colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\")
}

/// Queries answered by the parser proper (alacritty's event path).
fn processor_queries() -> Vec<Query> {
    vec![
        Query::new("DA1 (CSI c)", b"\x1b[c", "DA1"),
        Query::new("DA2 (CSI > c)", b"\x1b[>c", "DA2"),
        Query::new("CPR (CSI 6 n)", b"\x1b[6n", "CPR"),
        Query::new("DSR (CSI 5 n)", b"\x1b[5n", "DSR"),
        Query::new("kitty kb (CSI ? u)", b"\x1b[?u", "KITTYKB"),
        Query::new("DECRQM (CSI ? 2004 $ p)", b"\x1b[?2004$p", "DECRQM"),
    ]
}

/// Queries answered by the side parser that runs over the bytes before
/// the main parser sees them.
fn tap_queries() -> Vec<Query> {
    vec![
        Query::new("XTVERSION (CSI > q)", b"\x1b[>q", "XTVERSION"),
        Query::new("DECRQSS (DCS $ q m ST)", b"\x1bP$qm\x1b\\", "DECRQSS"),
        Query::new(
            "XTGETTCAP (DCS + q 544E ST)",
            b"\x1bP+q544E\x1b\\",
            "XTGETTCAP",
        ),
    ]
}

fn da1() -> Query {
    Query::new("DA1 (CSI c)", b"\x1b[c", "DA1")
}
fn cpr() -> Query {
    Query::new("CPR (CSI 6 n)", b"\x1b[6n", "CPR")
}
fn dsr() -> Query {
    Query::new("DSR (CSI 5 n)", b"\x1b[5n", "DSR")
}
fn xtversion() -> Query {
    Query::new("XTVERSION (CSI > q)", b"\x1b[>q", "XTVERSION")
}
fn xtgettcap() -> Query {
    Query::new(
        "XTGETTCAP (DCS + q 544E ST)",
        b"\x1bP+q544E\x1b\\",
        "XTGETTCAP",
    )
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
fn reference_delivery(qs: &[Query]) -> Vec<String> {
    let rig = Rig::new();
    let mut out = Vec::new();
    for q in qs {
        out.extend(rig.labels(&q.bytes));
    }
    out
}

/// Deliver `qs` concatenated in ONE `bb_term_input` call on a fresh terminal.
fn single_chunk_delivery(qs: &[Query]) -> Vec<String> {
    Rig::new().labels(&stream(qs))
}

/// Judge one stream: the one-query-per-chunk reference must be in query
/// order (rig precondition, panics if not), then the single-chunk delivery
/// must equal it. Returns a description of the mismatch, if any.
fn check_single_chunk_order(qs: &[Query]) -> Option<String> {
    let want = expected_labels(qs);
    let reference = reference_delivery(qs);
    assert_eq!(
        show(&reference),
        show(&want),
        "RIG PRECONDITION: one-query-per-chunk delivery of `{}` must already \
         reply in query order with the expected labels",
        names(qs)
    );
    let got = single_chunk_delivery(qs);
    if got == want {
        None
    } else {
        Some(format!(
            "`{}` in one chunk: replies {} but queries were in order {}",
            names(qs),
            show(&got),
            show(&want)
        ))
    }
}

/// Single-stream wrapper around `check_single_chunk_order`.
#[track_caller]
fn assert_in_query_order(what: &str, qs: &[Query]) {
    if let Some(mismatch) = check_single_chunk_order(qs) {
        panic!("{what}: {mismatch}");
    }
}

#[track_caller]
fn assert_no_misorders(what: &str, failures: Vec<String>, checked: usize) {
    assert!(
        failures.is_empty(),
        "{what}: {} of {checked} one-chunk deliveries answered out of query \
         order (replies in one chunk must match one-query-per-chunk \
         delivery):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// ---------- controls: the rig sees what the tests rely on ----------

#[test]
fn control_every_query_alone_yields_exactly_its_own_reply() {
    // Not the bug: with no ordering question in play, each query produces
    // exactly one reply and it classifies as the expected kind. Proves the
    // classifier, the theme and the enabled-reply switches are live, so
    // the ordering tests below cannot pass or fail vacuously.
    let mut all = colour_queries();
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
fn control_one_query_per_chunk_delivery_is_in_query_order() {
    // Not the bug: the two-chunk delivery the report calls "in order".
    // Every colour/processor/tap pairing, in both orders, one query per
    // chunk, must reply in query order.
    let colours = colour_queries();
    let procs = processor_queries();
    let taps = tap_queries();
    let mut bad = Vec::new();
    let mut checked = 0usize;
    let mut pairs: Vec<(Query, Query)> = Vec::new();
    for c in &colours {
        for p in procs.iter().chain(taps.iter()) {
            pairs.push((c.clone(), p.clone()));
            pairs.push((p.clone(), c.clone()));
        }
    }
    for p in &procs {
        for t in &taps {
            pairs.push((p.clone(), t.clone()));
            pairs.push((t.clone(), p.clone()));
        }
    }
    for (a, b) in pairs {
        checked += 1;
        let qs = vec![a, b];
        let got = reference_delivery(&qs);
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
        "{} of {checked} two-chunk deliveries were out of order:\n{}",
        bad.len(),
        bad.join("\n")
    );
}

#[test]
fn control_processor_query_then_colour_query_is_in_order_in_one_chunk() {
    // Already-correct direction (query first, colour second): guards a fix
    // that merely flips the bug to the other side.
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for p in processor_queries() {
        for c in colour_queries() {
            checked += 1;
            if let Some(f) = check_single_chunk_order(&[p.clone(), c]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("processor query then colour query", failures, checked);
}

#[test]
fn control_tap_query_then_processor_query_is_in_order_in_one_chunk() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for t in tap_queries() {
        for p in processor_queries() {
            checked += 1;
            if let Some(f) = check_single_chunk_order(&[t.clone(), p]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("tap query then processor query", failures, checked);
}

#[test]
fn control_tap_query_then_colour_query_is_in_order_in_one_chunk() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for t in tap_queries() {
        for c in colour_queries() {
            checked += 1;
            if let Some(f) = check_single_chunk_order(&[t.clone(), c]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("tap query then colour query", failures, checked);
}

// ---------- the bug: colour query, then a processor-side reply -----

#[test]
fn osc11_query_then_cpr_in_one_chunk_replies_osc11_first() {
    // The exact trigger from the report: `ESC ] 11 ; ? ESC \ ESC [ 6 n`.
    // The colour was asked about first, so its answer comes first and the
    // CPR (sentinel) last.
    let rig = Rig::new();
    let writes = rig.feed_collect(b"\x1b]11;?\x1b\\\x1b[6n");
    let labels: Vec<String> = writes.iter().map(|w| classify(w)).collect();
    assert_eq!(
        show(&labels),
        format!("[OSC11={THEME_BG:#08x}, CPR]"),
        "OSC 11 ? followed by CPR in one chunk must reply OSC 11 then CPR; \
         raw replies: {writes:?}"
    );
    assert_eq!(
        writes.last().map(|w| w.as_slice()),
        Some(&b"\x1b[1;1R"[..]),
        "the CPR sentinel (cursor at 1;1) must be the last reply"
    );
}

#[test]
fn osc10_query_then_each_processor_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for term in [("BEL", "\x07"), ("ST", "\x1b\\")] {
        for p in processor_queries() {
            checked += 1;
            let c = colour_query("10", "OSC10", THEME_FG, term.0, term.1);
            if let Some(f) = check_single_chunk_order(&[c, p]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("OSC 10 ? then processor query", failures, checked);
}

#[test]
fn osc11_query_then_each_processor_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for term in [("BEL", "\x07"), ("ST", "\x1b\\")] {
        for p in processor_queries() {
            checked += 1;
            let c = colour_query("11", "OSC11", THEME_BG, term.0, term.1);
            if let Some(f) = check_single_chunk_order(&[c, p]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("OSC 11 ? then processor query", failures, checked);
}

#[test]
fn osc12_query_then_each_processor_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for term in [("BEL", "\x07"), ("ST", "\x1b\\")] {
        for p in processor_queries() {
            checked += 1;
            let c = colour_query("12", "OSC12", THEME_CURSOR, term.0, term.1);
            if let Some(f) = check_single_chunk_order(&[c, p]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("OSC 12 ? then processor query", failures, checked);
}

#[test]
fn osc4_query_then_each_processor_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for term in [("BEL", "\x07"), ("ST", "\x1b\\")] {
        for p in processor_queries() {
            checked += 1;
            let c = colour_query("4;1", "OSC4;1", THEME_ANSI1, term.0, term.1);
            if let Some(f) = check_single_chunk_order(&[c, p]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("OSC 4;1 ? then processor query", failures, checked);
}

// ---------- the bug: processor-side query, then a tap-side reply ---

#[test]
fn da1_then_xtversion_in_one_chunk_replies_da1_first() {
    // The exact tap-side trigger from the report: `ESC [ c ESC [ > q`.
    let rig = Rig::new();
    let writes = rig.feed_collect(b"\x1b[c\x1b[>q");
    let labels: Vec<String> = writes.iter().map(|w| classify(w)).collect();
    assert_eq!(
        show(&labels),
        "[DA1, XTVERSION]",
        "DA1 followed by XTVERSION in one chunk must reply DA1 then \
         XTVERSION; raw replies: {writes:?}"
    );
}

#[test]
fn each_processor_query_then_each_tap_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for p in processor_queries() {
        for t in tap_queries() {
            checked += 1;
            if let Some(f) = check_single_chunk_order(&[p.clone(), t]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("processor query then tap query", failures, checked);
}

// ---------- the bug: colour query, then a tap-side reply -----------

#[test]
fn each_colour_query_then_each_tap_query_in_one_chunk_replies_in_order() {
    let mut failures = Vec::new();
    let mut checked = 0usize;
    for c in colour_queries() {
        for t in tap_queries() {
            checked += 1;
            if let Some(f) = check_single_chunk_order(&[c.clone(), t]) {
                failures.push(f);
            }
        }
    }
    assert_no_misorders("colour query then tap query", failures, checked);
}

// ---------- the bug: three and more queries interleaved ------------

#[test]
fn colour_then_processor_then_tap_in_one_chunk_replies_in_query_order() {
    // Each class is displaced by a different mechanism in the buggy
    // ordering; all three must come back in the order asked.
    let qs = vec![osc11_st(), da1(), xtversion()];
    assert_in_query_order("OSC 11 ; DA1 ; XTVERSION in one chunk", &qs);
}

#[test]
fn tap_then_colour_then_processor_then_tap_in_one_chunk_replies_in_query_order() {
    let qs = vec![
        xtversion(),
        colour_query("10", "OSC10", THEME_FG, "BEL", "\x07"),
        da1(),
        Query::new("DECRQSS (DCS $ q m ST)", b"\x1bP$qm\x1b\\", "DECRQSS"),
        osc11_st(),
        cpr(),
        xtgettcap(),
        colour_query("4;1", "OSC4;1", THEME_ANSI1, "ST", "\x1b\\"),
        dsr(),
    ];
    assert_in_query_order(
        "nine interleaved queries of all three classes in one chunk",
        &qs,
    );
}

#[test]
fn every_ordering_of_five_representative_queries_replies_in_query_order() {
    // Exhaustive: all 5! = 120 orderings of one colour query, one
    // processor-side DA1, one processor-side CPR, one XTVERSION and one
    // XTGETTCAP. In every ordering the replies must follow the order the
    // queries were written.
    let base = vec![osc11_st(), da1(), cpr(), xtversion(), xtgettcap()];
    let mut perms: Vec<Vec<usize>> = Vec::new();
    permute(&mut (0..base.len()).collect::<Vec<usize>>(), 0, &mut perms);
    assert_eq!(perms.len(), 120, "permutation generator precondition");

    let mut failures = Vec::new();
    for perm in &perms {
        let qs: Vec<Query> = perm.iter().map(|&i| base[i].clone()).collect();
        if let Some(f) = check_single_chunk_order(&qs) {
            failures.push(f);
        }
    }
    assert_no_misorders("five-query permutation sweep", failures, perms.len());
}

fn permute(items: &mut Vec<usize>, k: usize, out: &mut Vec<Vec<usize>>) {
    if k == items.len() {
        out.push(items.clone());
        return;
    }
    for i in k..items.len() {
        items.swap(k, i);
        permute(items, k + 1, out);
        items.swap(k, i);
    }
}

#[test]
fn several_colour_queries_keep_their_order_before_a_trailing_sentinel() {
    // OSC 10, 11, 12 and 4;1 queries followed by DA1: four colour answers
    // in query order, then DA1.
    let qs = vec![
        colour_query("10", "OSC10", THEME_FG, "ST", "\x1b\\"),
        colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\"),
        colour_query("12", "OSC12", THEME_CURSOR, "ST", "\x1b\\"),
        colour_query("4;1", "OSC4;1", THEME_ANSI1, "ST", "\x1b\\"),
        da1(),
    ];
    assert_in_query_order("four colour queries then DA1 in one chunk", &qs);
}

// ---------- the user-visible consequence: the sentinel idiom -------

/// A sentinel-based client: it wrote `probe` then `sentinel` in a single
/// `write()` and reads replies until the sentinel's arrives. Returns
/// (labels read before the sentinel's, labels still arriving after it).
fn run_sentinel_client(probe: &[Query], sentinel: &Query) -> (Vec<String>, Vec<String>) {
    let mut qs: Vec<Query> = probe.to_vec();
    qs.push(sentinel.clone());
    let replies = single_chunk_delivery(&qs);
    match replies.iter().position(|l| *l == sentinel.expect) {
        Some(i) => (replies[..i].to_vec(), replies[i + 1..].to_vec()),
        None => (replies, Vec::new()),
    }
}

#[test]
fn sentinel_client_reads_every_colour_answer_before_the_sentinel() {
    // The theme-detection idiom: ask for the foreground and the background
    // and finish with DA1 (or CPR / DSR) as a sentinel. When the sentinel
    // wins the race the client believes colour queries are unsupported.
    let probe = vec![
        colour_query("10", "OSC10", THEME_FG, "ST", "\x1b\\"),
        colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\"),
    ];
    let want_before = expected_labels(&probe);
    let mut failures = Vec::new();
    for sentinel in [da1(), cpr(), dsr()] {
        let (before, after) = run_sentinel_client(&probe, &sentinel);
        if before != want_before || !after.is_empty() {
            failures.push(format!(
                "sentinel {}: read before sentinel {} (wanted {}), still \
                 arriving after the sentinel {} (wanted [])",
                sentinel.name,
                show(&before),
                show(&want_before),
                show(&after)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "a sentinel-based client must see both colour answers before the \
         sentinel's reply and nothing after it (late replies are typed into \
         the shell as `ESC ] 11 ; rgb:...` garbage):\n{}",
        failures.join("\n")
    );
}

#[test]
fn sentinel_client_reads_xtversion_before_a_trailing_sentinel_and_nothing_after() {
    // Same idiom with XTVERSION as the question, preceded by an unrelated
    // processor query the client also issued first.
    let probe = vec![cpr(), xtversion()];
    let (before, after) = run_sentinel_client(&probe, &da1());
    assert_eq!(
        (show(&before), show(&after)),
        (show(&expected_labels(&probe)), show(&[])),
        "CPR ; XTVERSION ; DA1(sentinel): the sentinel must be the last \
         reply and both earlier answers must precede it"
    );
}

// ---------- chunking must not change the order ---------------------

#[test]
fn reply_order_does_not_depend_on_where_the_pty_split_the_bytes() {
    // One stream mixing all three reply classes, delivered (a) in one
    // chunk, (b) cut at every byte offset into two chunks, and (c) one
    // byte per call. Every delivery must reply in query order.
    let qs = vec![
        xtversion(),
        colour_query("11", "OSC11", THEME_BG, "ST", "\x1b\\"),
        da1(),
        Query::new("DECRQSS (DCS $ q m ST)", b"\x1bP$qm\x1b\\", "DECRQSS"),
        colour_query("10", "OSC10", THEME_FG, "BEL", "\x07"),
        cpr(),
    ];
    let bytes = stream(&qs);
    let want = expected_labels(&qs);
    assert_eq!(
        show(&reference_delivery(&qs)),
        show(&want),
        "RIG PRECONDITION: one-query-per-chunk delivery must be in query order"
    );

    let mut wrong: Vec<String> = Vec::new();
    let mut deliveries = 0usize;

    // (a) whole stream, one chunk.
    deliveries += 1;
    let got = Rig::new().labels(&bytes);
    if got != want {
        wrong.push(format!("single chunk -> {}", show(&got)));
    }

    // (b) every two-way cut.
    for cut in 1..bytes.len() {
        deliveries += 1;
        let rig = Rig::new();
        let mut got = rig.labels(&bytes[..cut]);
        got.extend(rig.labels(&bytes[cut..]));
        if got != want {
            wrong.push(format!("split at byte {cut} -> {}", show(&got)));
        }
    }

    // (c) one byte per call.
    deliveries += 1;
    {
        let rig = Rig::new();
        let mut got = Vec::new();
        for b in &bytes {
            got.extend(rig.labels(std::slice::from_ref(b)));
        }
        if got != want {
            wrong.push(format!("byte-at-a-time -> {}", show(&got)));
        }
    }

    assert!(
        wrong.is_empty(),
        "{} of {deliveries} deliveries of the {}-byte stream `{}` replied \
         out of query order (wanted {}):\n{}",
        wrong.len(),
        bytes.len(),
        names(&qs),
        show(&want),
        wrong.join("\n")
    );
}
