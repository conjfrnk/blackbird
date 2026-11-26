//! Blind tests: how a byte stream is cut into `bb_term_input` calls is
//! invisible. One call, one byte per call and random-length pieces must give
//! the identical ordered event log (kind, payload, `i32_arg`, `cursor_row`,
//! `lines_scrolled`) and the identical final screen (viewport text + cursor).
//! Byte-per-call is the reference.
//!
//! Written without reading the implementation; contract taken from
//! `BBCore.h`, `event.rs` and the sibling suites.
//!
//! Cost: every terminal is 80x24 with 1000 lines of scrollback (~1.3 MiB),
//! is fed under 2 KiB and is freed before the next one is built. The two
//! properties build (256 + 128) x 3 terminals, each example test at most
//! ~200. No sleeps. Streams stay far below every per-second cap (128-token
//! reply bucket, 32/s colour replies, 32/s titles, 32/s OSC 7, 240/s prompt
//! marks), and a delivery takes far less than the 150 ms synchronized-update
//! timer, so nothing depends on wall-clock time.

use blackbird_core::*;
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;
use std::ffi::{c_void, CString};
use std::fmt;
use std::sync::Mutex;

const COLS: u16 = 80;
const ROWS: u16 = 24;
const SCROLLBACK: u32 = 1000;

const MAX_FRAGMENTS: usize = 40;
const MAX_STREAM_BYTES: usize = 2000;
const MAX_REPLY_FRAGMENTS: usize = 12;
const MAX_TITLE_FRAGMENTS: usize = 2;
const MAX_CWD_FRAGMENTS: usize = 4;
const MAX_SYNC_QUERIES: usize = 4;

/// DEC 2026 begin / end synchronized update.
const BSU: &str = "\x1b[?2026h";
const ESU: &str = "\x1b[?2026l";

const THEME_FG: u32 = 0x2B3A4C;
const THEME_BG: u32 = 0xF5F0E1;
const THEME_CURSOR: u32 = 0x336699;
const THEME_ANSI1: u32 = 0xB3261E;

// ---------- observation --------------------------------------------

#[derive(Clone, PartialEq, Eq)]
struct Ev {
    kind: u32,
    payload: Vec<u8>,
    i32_arg: i32,
    cursor_row: u16,
    lines_scrolled: u64,
}

impl fmt::Debug for Ev {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match self.kind {
            k if k == BBEventKind::Title as u32 => "Title",
            k if k == BBEventKind::Bell as u32 => "Bell",
            k if k == BBEventKind::CursorShape as u32 => "CursorShape",
            k if k == BBEventKind::Osc52Clipboard as u32 => "Osc52Clipboard",
            k if k == BBEventKind::PtyWrite as u32 => "PtyWrite",
            k if k == BBEventKind::CwdChanged as u32 => "CwdChanged",
            k if k == BBEventKind::PromptMark as u32 => "PromptMark",
            k if k == BBEventKind::Notification as u32 => "Notification",
            k if k == BBEventKind::Fatal as u32 => "Fatal",
            _ => "Unknown",
        };
        write!(
            f,
            "{kind}(\"{}\", arg={}, row={}, scrolled={})",
            self.payload.escape_ascii(),
            self.i32_arg,
            self.cursor_row,
            self.lines_scrolled
        )
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
struct Outcome {
    events: Vec<Ev>,
    text: String,
    cursor_row: u16,
    cursor_col: u16,
    cursor_pending_wrap: u8,
}

impl Outcome {
    fn of_kind(&self, kind: BBEventKind) -> Vec<&Ev> {
        self.events
            .iter()
            .filter(|e| e.kind == kind as u32)
            .collect()
    }

    /// Labels of the replies written back to the PTY, in order.
    fn replies(&self) -> Vec<String> {
        self.of_kind(BBEventKind::PtyWrite)
            .iter()
            .map(|e| classify(&e.payload))
            .collect()
    }

    /// (kind, payload, cursor_row, lines_scrolled) of every prompt mark.
    fn marks(&self) -> Vec<(i32, String, u16, u64)> {
        self.of_kind(BBEventKind::PromptMark)
            .iter()
            .map(|e| {
                (
                    e.i32_arg,
                    String::from_utf8_lossy(&e.payload).into_owned(),
                    e.cursor_row,
                    e.lines_scrolled,
                )
            })
            .collect()
    }

    fn fatal(&self) -> bool {
        !self.of_kind(BBEventKind::Fatal).is_empty()
    }
}

/// Short label naming the query a reply answers; a CPR label carries its
/// position.
fn classify(reply: &[u8]) -> String {
    for (head, tag) in [
        (&b"\x1b]10;rgb:"[..], "OSC10"),
        (b"\x1b]11;rgb:", "OSC11"),
        (b"\x1b]12;rgb:", "OSC12"),
        (b"\x1b]4;1;rgb:", "OSC4;1"),
        (b"\x1bP>|", "XTVERSION"),
        (b"\x1bP1$r", "DECRQSS"),
        (b"\x1bP0$r", "DECRQSS"),
        (b"\x1bP1+r", "XTGETTCAP"),
        (b"\x1bP0+r", "XTGETTCAP"),
    ] {
        if reply.starts_with(head) {
            return tag.to_string();
        }
    }
    if reply == b"\x1b[0n" {
        return "DSR".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"$y") {
        return "DECRQM".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"c") {
        return "DA1".to_string();
    }
    if reply.starts_with(b"\x1b[?") && reply.ends_with(b"u") {
        return "KITTYKB".to_string();
    }
    if reply.starts_with(b"\x1b[8;") && reply.ends_with(b"t") {
        return "SIZE".to_string();
    }
    if reply.starts_with(b"\x1b[") && reply.ends_with(b"R") {
        let pos = String::from_utf8_lossy(&reply[2..reply.len() - 1]).into_owned();
        return format!("CPR {pos}");
    }
    format!("RAW \"{}\"", reply.escape_ascii())
}

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<Ev>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let payload = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events.lock().unwrap().push(Ev {
        kind: ev.kind as u32,
        payload,
        i32_arg: ev.i32_arg,
        cursor_row: ev.cursor_row,
        lines_scrolled: ev.lines_scrolled,
    });
}

struct Rig {
    term: *mut BBTerm,
    // Boxed so the address handed to the C callback stays stable.
    sink: Box<Sink>,
}

impl Rig {
    fn new() -> Rig {
        let sink = Box::new(Sink::default());
        let term = unsafe { bb_term_new(COLS, ROWS, SCROLLBACK) };
        assert!(!term.is_null(), "bb_term_new returned null");
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

    fn viewport_text(&self) -> String {
        unsafe {
            let s = bb_term_text_range(self.term, 0, 0, (ROWS as i32) - 1, COLS - 1, 0);
            if s.is_null() {
                return "<bb_term_text_range returned null>".to_string();
            }
            let bytes = if (*s).bytes.is_null() || (*s).len == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts((*s).bytes, (*s).len).to_vec()
            };
            bb_string_release(s);
            String::from_utf8_lossy(&bytes).into_owned()
        }
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bb_term_free(self.term) };
    }
}

/// Feed `chunks` to a fresh terminal, one `bb_term_input` call per chunk.
fn deliver<'a>(chunks: impl IntoIterator<Item = &'a [u8]>) -> Outcome {
    let rig = Rig::new();
    for chunk in chunks {
        if !chunk.is_empty() {
            unsafe { bb_term_input(rig.term, chunk.as_ptr(), chunk.len()) };
        }
    }
    let text = rig.viewport_text();
    let (cursor_row, cursor_col, cursor_pending_wrap) = unsafe {
        let snap = bb_term_take_snapshot(rig.term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        let cursor = (
            (*snap).cursor_row,
            (*snap).cursor_col,
            (*snap).cursor_pending_wrap,
        );
        bb_snap_release(snap);
        cursor
    };
    let events = rig.sink.events.lock().unwrap().clone();
    Outcome {
        events,
        text,
        cursor_row,
        cursor_col,
        cursor_pending_wrap,
    }
}

fn whole(stream: &[u8]) -> Outcome {
    deliver([stream])
}

fn bytewise(stream: &[u8]) -> Outcome {
    deliver(stream.chunks(1))
}

/// Cut `stream` into pieces whose lengths cycle through `lens`.
fn pieces<'a>(stream: &'a [u8], lens: &[usize]) -> Vec<&'a [u8]> {
    let mut out = Vec::new();
    let mut rest = stream;
    let mut i = 0;
    while !rest.is_empty() {
        let n = lens[i % lens.len()].clamp(1, rest.len());
        let (head, tail) = rest.split_at(n);
        out.push(head);
        rest = tail;
        i += 1;
    }
    out
}

fn show_events(events: &[Ev]) -> String {
    if events.is_empty() {
        return "      (none)".to_string();
    }
    events
        .iter()
        .enumerate()
        .map(|(i, e)| format!("      {i:>3}: {e:?}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Description of how `got` differs from the byte-per-call `reference`.
fn mismatch(label: &str, reference: &Outcome, got: &Outcome) -> String {
    let mut out = format!("  {label} differs from byte-per-call:\n");
    if got.events != reference.events {
        out.push_str(&format!(
            "    events, byte-per-call:\n{}\n    events, {label}:\n{}\n",
            show_events(&reference.events),
            show_events(&got.events)
        ));
    }
    if got.text != reference.text {
        out.push_str(&format!(
            "    screen, byte-per-call: {:?}\n    screen, {label}: {:?}\n",
            reference.text, got.text
        ));
    }
    let cursor = |o: &Outcome| (o.cursor_row, o.cursor_col, o.cursor_pending_wrap);
    if cursor(got) != cursor(reference) {
        out.push_str(&format!(
            "    cursor (row, col, pending_wrap), byte-per-call: {:?}, {label}: {:?}\n",
            cursor(reference),
            cursor(got)
        ));
    }
    out
}

struct Lcg(u64);

impl Lcg {
    fn below(&mut self, n: usize) -> usize {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 33) as usize) % n
    }
}

/// Deliver `stream` byte-per-call (reference), in one call, cut in two at
/// every offset, and in 16 fixed pseudo-random cuttings. Returns the
/// reference and, if any delivery differs from it, a description.
fn chunking_report(stream: &[u8]) -> (Outcome, Option<String>) {
    let reference = bytewise(stream);
    if reference.fatal() {
        let report = format!(
            "Fatal event on byte-per-call delivery of \"{}\":\n{}",
            stream.escape_ascii(),
            show_events(&reference.events)
        );
        return (reference, Some(report));
    }
    let mut failures = Vec::new();
    let mut deliveries = 0usize;
    let mut check = |label: String, got: Outcome| {
        deliveries += 1;
        if got != reference {
            failures.push(mismatch(&label, &reference, &got));
        }
    };
    check("one call".to_string(), whole(stream));
    for cut in 1..stream.len() {
        check(
            format!("two calls cut at byte {cut}"),
            deliver([&stream[..cut], &stream[cut..]]),
        );
    }
    let mut rng = Lcg(0x9E37_79B9_7F4A_7C15);
    for _ in 0..16 {
        let lens: Vec<usize> = (0..stream.len().max(1)).map(|_| 1 + rng.below(9)).collect();
        let cut = pieces(stream, &lens);
        let used: Vec<usize> = cut.iter().map(|c| c.len()).collect();
        check(format!("pieces of lengths {used:?}"), deliver(cut));
    }
    if failures.is_empty() {
        return (reference, None);
    }
    let report = format!(
        "stream \"{}\": {} of {deliveries} deliveries differ from byte-per-call; first {}:\n{}",
        stream.escape_ascii(),
        failures.len(),
        failures.len().min(3),
        failures[..failures.len().min(3)].join("\n")
    );
    (reference, Some(report))
}

/// `chunking_report` must find no difference; returns the reference for
/// content assertions.
#[track_caller]
fn assert_chunking_invisible(stream: &[u8]) -> Outcome {
    let (reference, report) = chunking_report(stream);
    if let Some(report) = report {
        panic!("{report}");
    }
    reference
}

/// A stream with DEC 2026 synchronized updates: the byte-per-call reference
/// must report exactly `want_marks` (kind, payload, cursor_row,
/// lines_scrolled), and every other chunking must equal the reference. Both
/// verdicts are reported together.
#[track_caller]
fn assert_sync_case(stream: &[u8], want_marks: &[(i32, &str, u16, u64)]) {
    let (reference, chunking) = chunking_report(stream);
    let want: Vec<(i32, String, u16, u64)> = want_marks
        .iter()
        .map(|m| (m.0, m.1.to_string(), m.2, m.3))
        .collect();
    let mut problems = Vec::new();
    if reference.marks() != want {
        problems.push(format!(
            "stream \"{}\": byte-per-call marks (kind, payload, cursor_row, lines_scrolled) are \
             {:?}, want {want:?}",
            stream.escape_ascii(),
            reference.marks()
        ));
    }
    problems.extend(chunking);
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

fn labels(want: &[&str]) -> Vec<String> {
    want.iter().map(|s| s.to_string()).collect()
}

// ---------- stream generator ---------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    Free,
    Reply,
    Title,
    Cwd,
}

#[derive(Clone)]
struct Frag {
    bytes: Vec<u8>,
    class: Class,
}

impl fmt::Debug for Frag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "\"{}\"", self.bytes.escape_ascii())
    }
}

fn frag(class: Class, bytes: impl Into<Vec<u8>>) -> Frag {
    Frag {
        bytes: bytes.into(),
        class,
    }
}

fn free(bytes: impl Into<Vec<u8>>) -> Frag {
    frag(Class::Free, bytes)
}

#[derive(Clone, Debug)]
struct Stream(Vec<Frag>);

impl Stream {
    fn bytes(&self) -> Vec<u8> {
        self.0
            .iter()
            .flat_map(|f| f.bytes.iter().copied())
            .collect()
    }
}

fn arb_text() -> impl Strategy<Value = Frag> {
    arb_text_sized(23, 30)
}

/// A text run of at most `max_pieces` characters (4 bytes each at most) or
/// at most `max_lines` short CRLF-ended lines.
fn arb_text_sized(max_pieces: usize, max_lines: usize) -> impl Strategy<Value = Frag> {
    let piece = prop_oneof![
        12 => (0x20u8..0x7f).prop_map(|b| (b as char).to_string()),
        2 => prop::sample::select(vec!["é", "ñ", "€", "→", "中", "😀"]).prop_map(str::to_string),
        1 => Just("\r".to_string()),
        1 => Just("\n".to_string()),
        2 => Just("\r\n".to_string()),
        1 => Just("\t".to_string()),
    ];
    prop_oneof![
        5 => prop::collection::vec(piece, 1..=max_pieces).prop_map(|v| free(v.concat())),
        1 => (1usize..=max_lines).prop_map(|n| free("line\r\n".repeat(n))),
    ]
}

fn arb_styling_csi() -> impl Strategy<Value = Frag> {
    let sgr = prop::sample::select(vec![
        "\x1b[1;31m",
        "\x1b[38;5;244m",
        "\x1b[38:2::1:2:3m",
        "\x1b[48;2;10;20;30m",
        "\x1b[4m",
        "\x1b[7m",
        "\x1b[0m",
        "\x1b[m",
    ]);
    let opt = |n: Option<u16>| n.map(|n| n.to_string()).unwrap_or_default();
    prop_oneof![
        4 => sgr.prop_map(free),
        3 => (1u16..=30, 1u16..=90, prop::sample::select(vec!['H', 'f']))
            .prop_map(|(r, c, fin)| free(format!("\x1b[{r};{c}{fin}"))),
        1 => Just(free("\x1b[H")),
        3 => (
            prop::option::of(0u16..=30),
            prop::sample::select(vec!['A', 'B', 'C', 'D', 'E', 'F', 'G', 'd']),
        )
            .prop_map(move |(n, fin)| free(format!("\x1b[{}{fin}", opt(n)))),
        2 => (prop::option::of(0u16..=2), prop::sample::select(vec!['J', 'K']))
            .prop_map(move |(n, fin)| free(format!("\x1b[{}{fin}", opt(n)))),
        2 => (
            prop::option::of(1u16..=5),
            prop::sample::select(vec!['L', 'M', 'P', 'X', '@', 'S', 'T']),
        )
            .prop_map(move |(n, fin)| free(format!("\x1b[{}{fin}", opt(n)))),
        1 => (1u16..=24, 1u16..=24).prop_map(|(a, b)| {
            if a == b {
                free("\x1b[r")
            } else {
                free(format!("\x1b[{};{}r", a.min(b), a.max(b)))
            }
        }),
    ]
}

/// BEL, ST, or nothing (the next fragment's ESC ends the string).
fn arb_string_end() -> impl Strategy<Value = &'static str> {
    prop::sample::select(vec!["\x07", "\x1b\\", ""])
}

fn arb_query() -> impl Strategy<Value = Frag> {
    let wire = prop::sample::select(vec![
        &b"\x1b[c"[..],
        b"\x1b[6n",
        b"\x1b[5n",
        b"\x1b[?25$p",
        b"\x1b[?u",
        b"\x1b[>q",
        b"\x1bP$qm\x1b\\",
        b"\x1bP+q544e\x1b\\",
        b"\x1b[18t",
    ]);
    let colour = (
        prop::sample::select(vec!["10", "11", "12", "4;1"]),
        arb_string_end(),
    );
    prop_oneof![
        4 => wire.prop_map(|b| frag(Class::Reply, b)),
        2 => Just(frag(Class::Reply, "\x1b[6n")),
        3 => colour.prop_map(|(id, end)| frag(Class::Reply, format!("\x1b]{id};?{end}"))),
    ]
}

fn arb_shell_osc() -> impl Strategy<Value = Frag> {
    let terminated = || prop::sample::select(vec!["\x07", "\x1b\\"]);
    prop_oneof![
        6 => (
            prop::sample::select(vec!["A", "B", "C", "D", "D;0", "D;137"]),
            arb_string_end(),
        )
            .prop_map(|(mark, end)| free(format!("\x1b]133;{mark}{end}"))),
        1 => terminated()
            .prop_map(|end| frag(Class::Cwd, format!("\x1b]7;file://localhost/tmp{end}"))),
        1 => (0u8..4, terminated())
            .prop_map(|(n, end)| frag(Class::Title, format!("\x1b]0;title-{n}{end}"))),
    ]
}

fn arb_private_mode() -> impl Strategy<Value = Frag> {
    prop::sample::select(vec![
        "\x1b[?25l",
        "\x1b[?25h",
        "\x1b[?2004h",
        "\x1b[?1049h",
        "\x1b[?1049l",
    ])
    .prop_map(free)
}

fn arb_broken() -> impl Strategy<Value = Frag> {
    prop::sample::select(vec!["\x1b", "\x1b[", "\x1b[1;", "\x1b\x1b[0m"]).prop_map(free)
}

/// Drop fragments past the per-class budgets and stop at the byte budget.
fn within_budget(frags: Vec<Frag>) -> Stream {
    let (mut replies, mut titles, mut cwds, mut len) = (0usize, 0usize, 0usize, 0usize);
    let mut kept = Vec::new();
    for f in frags {
        if len + f.bytes.len() > MAX_STREAM_BYTES {
            break;
        }
        let (count, cap) = match f.class {
            Class::Free => {
                len += f.bytes.len();
                kept.push(f);
                continue;
            }
            Class::Reply => (&mut replies, MAX_REPLY_FRAGMENTS),
            Class::Title => (&mut titles, MAX_TITLE_FRAGMENTS),
            Class::Cwd => (&mut cwds, MAX_CWD_FRAGMENTS),
        };
        if *count < cap {
            *count += 1;
            len += f.bytes.len();
            kept.push(f);
        }
    }
    Stream(kept)
}

fn arb_stream() -> impl Strategy<Value = Stream> {
    let fragment = prop_oneof![
        5 => arb_text(),
        5 => arb_styling_csi(),
        5 => arb_query(),
        4 => arb_shell_osc(),
        2 => arb_private_mode(),
        1 => arb_broken(),
    ];
    prop::collection::vec(fragment, 1..=MAX_FRAGMENTS).prop_map(within_budget)
}

/// One synchronized update: BSU, up to 6 text / styling / cursor fragments
/// with 0-2 terminated OSC 133 marks among them, ESU. At most ~330 bytes.
fn arb_sync_update() -> impl Strategy<Value = Vec<Frag>> {
    let body = prop::collection::vec(prop_oneof![arb_text_sized(12, 6), arb_styling_csi()], 0..=6);
    let marks = prop::collection::vec(
        (
            prop::sample::select(vec!["A", "A", "A", "B", "C", "D;0"]),
            prop::sample::select(vec!["\x07", "\x1b\\"]),
            any::<prop::sample::Index>(),
        ),
        0..=2,
    );
    (body, marks).prop_map(|(mut body, marks)| {
        for (mark, end, at) in marks {
            let i = at.index(body.len() + 1);
            body.insert(i, free(format!("\x1b]133;{mark}{end}")));
        }
        let mut update = vec![free(BSU)];
        update.extend(body);
        update.push(free(ESU));
        update
    })
}

/// Optional text, then 1-3 synchronized updates, each followed by up to 4
/// text / styling / cursor / query fragments (at most `MAX_SYNC_QUERIES`
/// queries per stream). Under 2 KiB by construction.
fn arb_sync_stream() -> impl Strategy<Value = Stream> {
    let gap = prop::collection::vec(
        prop_oneof![
            2 => arb_text_sized(12, 6),
            3 => arb_styling_csi(),
            2 => arb_query(),
        ],
        0..=4,
    );
    (
        prop::collection::vec(arb_text_sized(12, 6), 0..=2),
        prop::collection::vec((arb_sync_update(), gap), 1..=3),
    )
        .prop_map(|(prefix, parts)| {
            let mut frags = prefix;
            let mut queries = 0usize;
            for (update, gap) in parts {
                frags.extend(update);
                for f in gap {
                    if f.class == Class::Reply {
                        if queries == MAX_SYNC_QUERIES {
                            continue;
                        }
                        queries += 1;
                    }
                    frags.push(f);
                }
            }
            Stream(frags)
        })
}

// ---------- properties ----------------------------------------------

/// One call and pieces cycling through `lens` must equal byte-per-call.
fn check_random_chunking(bytes: &[u8], lens: &[usize]) -> Result<(), TestCaseError> {
    let reference = bytewise(bytes);
    prop_assert!(
        !reference.fatal(),
        "Fatal event on byte-per-call delivery of \"{}\"",
        bytes.escape_ascii()
    );

    let one = whole(bytes);
    prop_assert!(
        one == reference,
        "stream \"{}\":\n{}",
        bytes.escape_ascii(),
        mismatch("one call", &reference, &one)
    );

    let cut = pieces(bytes, lens);
    let used: Vec<usize> = cut.iter().map(|c| c.len()).collect();
    let random = deliver(cut);
    prop_assert!(
        random == reference,
        "stream \"{}\":\n{}",
        bytes.escape_ascii(),
        mismatch(&format!("pieces of lengths {used:?}"), &reference, &random)
    );
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 256,
        ..ProptestConfig::default()
    })]

    /// For random interleavings of text, styling, queries, prompt marks,
    /// mode toggles and broken sequences: one call and random-length pieces
    /// give the same event log and final screen as one byte per call.
    #[test]
    fn chunking_is_invisible_for_random_streams(
        stream in arb_stream(),
        lens in prop::collection::vec(1usize..=24, 1..=48),
    ) {
        check_random_chunking(&stream.bytes(), &lens)?;
    }
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 128,
        ..ProptestConfig::default()
    })]

    /// The same for streams built around DEC 2026 synchronized updates that
    /// hold text, styling, cursor movement and prompt marks, with queries
    /// between and after the updates.
    #[test]
    fn chunking_is_invisible_for_streams_with_synchronized_updates(
        stream in arb_sync_stream(),
        lens in prop::collection::vec(1usize..=24, 1..=48),
    ) {
        let bytes = stream.bytes();
        prop_assert!(bytes.len() < 2048, "generator exceeded 2 KiB: {}", bytes.len());
        check_random_chunking(&bytes, &lens)?;
    }
}

// ---------- examples -------------------------------------------------

/// Non-vacuity: every observable fragment kind the generator emits produces
/// its event, so an empty log cannot make the comparisons pass trivially.
#[test]
fn every_generated_query_and_mark_is_observable_alone() {
    for (query, want) in [
        (&b"\x1b[c"[..], "DA1"),
        (b"\x1b[6n", "CPR 1;1"),
        (b"\x1b[5n", "DSR"),
        (b"\x1b[?25$p", "DECRQM"),
        (b"\x1b[?u", "KITTYKB"),
        (b"\x1b[>q", "XTVERSION"),
        (b"\x1bP$qm\x1b\\", "DECRQSS"),
        (b"\x1bP+q544e\x1b\\", "XTGETTCAP"),
        (b"\x1b[18t", "SIZE"),
        (b"\x1b]10;?\x07", "OSC10"),
        (b"\x1b]11;?\x1b\\", "OSC11"),
        (b"\x1b]12;?\x07", "OSC12"),
        (b"\x1b]4;1;?\x1b\\", "OSC4;1"),
    ] {
        let got = assert_chunking_invisible(query);
        assert_eq!(
            got.replies(),
            labels(&[want]),
            "\"{}\" alone must be answered exactly once",
            query.escape_ascii()
        );
    }

    for (mark, kind, payload) in [
        (&b"\x1b]133;A\x07"[..], 1, ""),
        (b"\x1b]133;B\x1b\\", 2, ""),
        (b"\x1b]133;C\x07", 3, ""),
        (b"\x1b]133;D\x1b\\", 4, ""),
        (b"\x1b]133;D;137\x07", 4, "137"),
    ] {
        let got = assert_chunking_invisible(mark);
        let marks: Vec<(i32, String)> = got.marks().into_iter().map(|m| (m.0, m.1)).collect();
        assert_eq!(
            marks,
            vec![(kind, payload.to_string())],
            "\"{}\" alone must fire exactly one prompt mark",
            mark.escape_ascii()
        );
    }

    let cwd = assert_chunking_invisible(b"\x1b]7;file://localhost/tmp\x07");
    let paths: Vec<&[u8]> = cwd
        .of_kind(BBEventKind::CwdChanged)
        .iter()
        .map(|e| e.payload.as_slice())
        .collect();
    assert_eq!(paths, vec![&b"/tmp"[..]], "OSC 7 must report /tmp once");

    let title = assert_chunking_invisible(b"\x1b]0;title-1\x1b\\");
    let titles: Vec<&[u8]> = title
        .of_kind(BBEventKind::Title)
        .iter()
        .map(|e| e.payload.as_slice())
        .collect();
    assert_eq!(
        titles,
        vec![&b"title-1"[..]],
        "OSC 0 must set the title once"
    );
}

/// Colour query, SGR, CPR: the colour answer precedes the cursor report.
#[test]
fn colour_query_then_sgr_then_cpr() {
    let got = assert_chunking_invisible(b"\x1b]11;?\x07\x1b[1m\x1b[6n");
    assert_eq!(got.replies(), labels(&["OSC11", "CPR 1;1"]));
}

/// A colour query with no terminator is ended by the SGR's ESC and is still
/// answered before the CPR that follows.
#[test]
fn unterminated_colour_query_ended_by_sgr_then_cpr() {
    let got = assert_chunking_invisible(b"\x1b]11;?\x1b[1m\x1b[6n");
    assert_eq!(got.replies(), labels(&["OSC11", "CPR 1;1"]));
}

/// Two CPRs around a cursor move report the two positions, in order.
#[test]
fn cpr_then_cursor_move_then_cpr() {
    let got = assert_chunking_invisible(b"\x1b[6n\x1b[5;10H\x1b[6n");
    assert_eq!(got.replies(), labels(&["CPR 1;1", "CPR 5;10"]));
    assert_eq!((got.cursor_row, got.cursor_col), (4, 9));
}

/// A prompt mark carries the row the cursor was on when the mark arrived,
/// not the row a later cursor move left it on.
#[test]
fn prompt_mark_row_is_the_row_before_a_following_cursor_move() {
    let got = assert_chunking_invisible(b"one\r\ntwo\r\n\x1b]133;A\x07\x1b[10;1Hmore");
    assert_eq!(got.marks(), vec![(1, String::new(), 2, 0)]);
    assert_eq!((got.cursor_row, got.cursor_col), (9, 4));
    assert_eq!(got.text.lines().nth(9), Some("more"));
}

/// Same, with the mark left unterminated so the CUP's ESC ends it.
#[test]
fn unterminated_prompt_mark_ended_by_cup_keeps_the_row_before_the_move() {
    let got = assert_chunking_invisible(b"ab\r\ncd\r\n\x1b]133;A\x1b[10;5Hx");
    assert_eq!(got.marks(), vec![(1, String::new(), 2, 0)]);
    assert_eq!((got.cursor_row, got.cursor_col), (9, 5));
}

/// An XTGETTCAP DCS ended by an SGR's ESC instead of ST: whatever it yields
/// arrives before the DA1 reply, which is last.
#[test]
fn xtgettcap_dcs_ended_by_sgr_then_da1() {
    let got = assert_chunking_invisible(b"\x1bP+q544e\x1b[1m\x1b[c");
    let replies = got.replies();
    assert_eq!(
        replies.last().map(String::as_str),
        Some("DA1"),
        "DA1 must be the last reply, got {replies:?}"
    );
    assert_eq!(
        replies.iter().filter(|l| *l == "DA1").count(),
        1,
        "exactly one DA1 reply, got {replies:?}"
    );
}

/// Three reply classes interleaved with text, styling and a cursor move
/// answer in stream order, and the CPR sees the move.
#[test]
fn text_styling_and_four_queries_reply_in_stream_order() {
    let got = assert_chunking_invisible(
        b"abc\x1b[1;31mdef\x1b[c\x1b[0m\x1b[>q\x1b[38;5;244m\x1b]10;?\x1b\\\x1b[3;7H\x1b[6n",
    );
    assert_eq!(
        got.replies(),
        labels(&["DA1", "XTVERSION", "OSC10", "CPR 3;7"])
    );
    assert_eq!(got.text.lines().next(), Some("abcdef"));
}

/// A full prompt cycle: marks A, B, C, D interleave with a CPR and a title
/// in exactly the order written.
#[test]
fn prompt_cycle_marks_interleave_with_replies_in_stream_order() {
    let got = assert_chunking_invisible(
        b"\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x1b\\out\r\n\x1b[6n\x1b]0;done\x07\x1b]133;D;0\x07",
    );
    let order: Vec<String> = got
        .events
        .iter()
        .map(|e| match e.kind {
            k if k == BBEventKind::PromptMark as u32 => format!("mark {}", e.i32_arg),
            k if k == BBEventKind::PtyWrite as u32 => classify(&e.payload),
            k if k == BBEventKind::Title as u32 => {
                format!("title {}", String::from_utf8_lossy(&e.payload))
            }
            _ => format!("{e:?}"),
        })
        .collect();
    assert_eq!(
        order,
        labels(&[
            "mark 1",
            "mark 2",
            "mark 3",
            "CPR 3;1",
            "title done",
            "mark 4"
        ])
    );
    assert_eq!(got.marks()[3].1, "0");
}

/// After the screen has scrolled, a mark reports the bottom row and the
/// lines-scrolled count of the moment it arrived, and the CPR agrees.
#[test]
fn prompt_mark_after_scrolling_carries_row_and_lines_scrolled() {
    let mut stream = b"row\r\n".repeat(30);
    stream.extend_from_slice(b"\x1b]133;A\x07\x1b[6n$ \x1b[H");
    let got = assert_chunking_invisible(&stream);
    assert_eq!(got.marks(), vec![(1, String::new(), 23, 7)]);
    assert_eq!(got.replies(), labels(&["CPR 24;1"]));
    assert_eq!((got.cursor_row, got.cursor_col), (0, 0));
}

/// Marks and cursor reports issued on the alternate screen and after
/// leaving it keep their order and their positions.
#[test]
fn alt_screen_round_trip_with_marks_and_cprs() {
    let got = assert_chunking_invisible(
        b"main\r\n\x1b[?1049h\x1b[4;4Halt\x1b]133;A\x1b[6n\x1b[?1049l\x1b[6n\x1b]133;B\x07\x1b[?25l",
    );
    assert_eq!(got.replies(), labels(&["CPR 4;7", "CPR 2;1"]));
    let kinds: Vec<i32> = got.marks().iter().map(|m| m.0).collect();
    assert_eq!(kinds, vec![1, 2]);
    assert_eq!(got.text.lines().next(), Some("main"));
}

// ---------- examples: DEC 2026 synchronized updates -------------------

/// A mark inside an update reports the row the grid has when the update is
/// applied (3), not the row a CUP + clear after the end marker leaves (0).
#[test]
fn sync_update_mark_keeps_its_row_when_cup_and_clear_follow_the_end_marker() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x1b\\$ \x1b[?2026l\x1b[H\x1b[2Jout",
        &[(1, "", 3, 0)],
    );
}

/// The same with the mark BEL-terminated.
#[test]
fn sync_update_bel_terminated_mark_keeps_its_row_when_cup_and_clear_follow() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x07$ \x1b[?2026l\x1b[H\x1b[2Jout",
        &[(1, "", 3, 0)],
    );
}

/// Two marks (A then B) inside one update arrive in order, A with its row.
#[test]
fn sync_update_with_marks_a_and_b_reports_both_in_order_with_the_row_of_a() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\\x1b[?2026l\x1b[H\x1b[2Jout",
        &[(1, "", 3, 0), (2, "", 0, 0)],
    );
}

/// A relative cursor-up after the end marker does not change the mark's row.
#[test]
fn sync_update_mark_keeps_its_row_when_cursor_up_follows_the_end_marker() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x1b\\$ \x1b[?2026l\x1b[5Aup",
        &[(1, "", 3, 0)],
    );
}

/// A CUP further down after the end marker does not change the mark's row.
#[test]
fn sync_update_mark_keeps_its_row_when_cup_down_follows_the_end_marker() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x1b\\$ \x1b[?2026l\x1b[10;1Hdown",
        &[(1, "", 3, 0)],
    );
}

/// An SGR and three line feeds after the end marker do not change the
/// mark's row.
#[test]
fn sync_update_mark_keeps_its_row_when_sgr_and_newlines_follow_the_end_marker() {
    assert_sync_case(
        b"a\r\nb\r\nc\r\n\x1b[?2026h\x1b]133;A\x1b\\$ \x1b[?2026l\x1b[1m\r\n\r\n\r\nbold",
        &[(1, "", 3, 0)],
    );
}

/// Text, SGR and a CUP inside the update precede the mark: the mark reports
/// the row that CUP put the cursor on (6), whatever follows the end marker.
#[test]
fn sync_update_mark_after_text_sgr_and_cup_inside_the_update_reports_the_cup_row() {
    assert_sync_case(
        b"x\r\n\x1b[?2026hhello\x1b[1;31m\x1b[7;3H\x1b]133;A\x1b\\$ \x1b[?2026l\x1b[0mtail",
        &[(1, "", 6, 0)],
    );
}

/// Two updates back to back, one mark each, a cursor move between them and
/// one after: each mark reports the row of its own update (2, then 11).
#[test]
fn two_sync_updates_each_report_their_own_mark_row() {
    assert_sync_case(
        b"a\r\nb\r\n\x1b[?2026h\x1b]133;A\x1b\\$ one\x1b[?2026l\x1b[12;1H\x1b[?2026h\x1b]133;A\x1b\\$ two\x1b[?2026l\x1b[H",
        &[(1, "", 2, 0), (1, "", 11, 0)],
    );
}

/// An update that is opened and never closed, followed by text: only the
/// chunking invariance is pinned.
#[test]
fn sync_update_left_open_is_chunking_invariant() {
    assert_chunking_invisible(b"a\r\n\x1b[?2026h\x1b]133;A\x1b\\$ never closed, then more text");
}
