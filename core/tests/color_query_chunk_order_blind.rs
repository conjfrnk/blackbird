//! Blind regression tests for bug `color-query-reply-after-chunk`: an
//! OSC 4 / 10 / 11 / 12 `?` query must be answered with the colour the
//! terminal had AT THE MOMENT THE QUERY WAS PARSED, not with whatever the
//! colour has become by the end of the input chunk.
//!
//! Author had no access to the implementation; the contract consulted was
//! `core/include/BBCore.h` / the FFI doc comments, the sibling suites
//! (`color_query.rs`, `color_ffi_blind.rs`, `osc_reset_theme_blind.rs`) and
//! the xterm control-sequence conventions.
//!
//! Contract under test
//! -------------------
//! A terminal processes its input byte stream strictly in order. A program
//! that writes
//!
//! ```text
//!     printf '\e]11;?\a\e]11;rgb:ff/00/00\a'
//! ```
//!
//! is asking "what is the background right now?" and, immediately after,
//! "change the background to red". The reply to the question is the
//! background BEFORE the change. The answer must not depend on whether the
//! PTY layer happened to deliver those two sequences in one `read(2)` (one
//! `bb_term_input` call) or in two. Same for:
//!   * OSC 10 (foreground) and OSC 12 (cursor) query followed by a set,
//!   * OSC 4;N;? followed by OSC 4;N;#rrggbb,
//!   * a query followed by OSC 104 / 110 / 111 / 112 (reset), where the
//!     reply must still report the colour that was live when asked (the
//!     program's override), not the theme the reset reverts to,
//!   * several queries interleaved with several sets in one chunk: each
//!     reply reflects the state at its own position in the stream.
//!
//! Real-world impact (the reason this matters): a TUI that saves the
//! "original" colour via a query and restores it on exit. If query and set
//! arrive in one read, the pre-fix core answers with the TUI's own override,
//! so the "restore" re-installs the override forever.
//!
//! Observable surface used: `bb_term_input` chunks in, `PtyWrite` event
//! payloads out (`ESC ] id ; rgb:RRRR/GGGG/BBBB ST|BEL`). Colour-query
//! replies are opted in explicitly with `bb_term_set_color_query_enabled`.
//!
//! Cost: every test uses one or a few 80x24 terminals and a handful of
//! short escape sequences. The chunk-split sweep builds ~40 terminals of
//! 1 920 cells x ~20 B each, sequentially (each dropped before the next):
//! microseconds and well under a MiB at any instant.

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

// ---------- the theme the "host app" pushes ------------------------

/// Every value differs from the built-in xterm defaults and from every
/// colour a program sets below, so a wrong answer can be attributed.
const THEME_FG: u32 = 0x2B3A4C;
const THEME_BG: u32 = 0xF5F0E1;
const THEME_CURSOR: u32 = 0x336699;
/// ANSI slot 1, pushed through `bb_term_set_named_color(1, ..)`.
const THEME_ANSI1: u32 = 0xB3261E;

/// Colours the "program" sets / expects.
const RED: u32 = 0xFF0000;
const OVERRIDE_BG: u32 = 0x102030;
const OVERRIDE_FG: u32 = 0x304050;
const OVERRIDE_CURSOR: u32 = 0x0A0B0C;
const OVERRIDE_ANSI1: u32 = 0xAABBCC;

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
    /// A fresh 80x24 terminal, colour-query replies enabled, theme pushed.
    fn with_theme() -> Rig {
        let sink = Box::new(Sink::default());
        let term = unsafe { bb_term_new(80, 24, 1000) };
        assert_ne!(term as usize, 0, "bb_term_new(80,24,1000) returned null");
        unsafe {
            bb_term_set_event_cb(term, Some(cb), &*sink as *const Sink as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);
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

    /// Feed one chunk, return every reply decoded as an 8-bit 0xRRGGBB.
    /// `prefix` is the reply's id field: "10", "11", "12" or "4;1".
    fn replies(&self, seq: &[u8], prefix: &str) -> Vec<Result<u32, String>> {
        self.feed_collect(seq)
            .iter()
            .map(|w| parse_rgb_reply(w, prefix))
            .collect()
    }

    /// A query alone in its own chunk: the colour the terminal has now.
    fn probe(&self, query: &[u8], prefix: &str) -> u32 {
        let r = self.replies(query, prefix);
        assert_eq!(
            r.len(),
            1,
            "a lone {:?} must produce exactly one reply, got {r:?}",
            String::from_utf8_lossy(query)
        );
        r.into_iter()
            .next()
            .unwrap()
            .unwrap_or_else(|e| panic!("undecodable reply to lone query: {e}"))
    }

    fn feed(&self, seq: &[u8]) {
        let _ = self.feed_collect(seq);
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
    let mut rgb = 0u32;
    let chans: Vec<&str> = body.split('/').collect();
    if chans.len() != 3 {
        return Err(format!("expected 3 channels in {s:?}"));
    }
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

/// `ESC ] <body> <term>`; `term` is "\x07" (BEL) or "\x1b\\" (ST).
fn osc(body: &str, term: &str) -> Vec<u8> {
    format!("\x1b]{body}{term}").into_bytes()
}

fn cat(parts: &[Vec<u8>]) -> Vec<u8> {
    parts.iter().flat_map(|p| p.iter().copied()).collect()
}

fn show(rgb: u32) -> String {
    format!("{rgb:#08x}")
}

fn show_all(r: &[Result<u32, String>]) -> String {
    r.iter()
        .map(|x| match x {
            Ok(v) => show(*v),
            Err(e) => format!("<{e}>"),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

const TERMINATORS: [(&str, &str); 2] = [("BEL", "\x07"), ("ST", "\x1b\\")];

// ---------- controls: the rig sees what the tests rely on ----------

#[test]
fn control_lone_queries_answer_with_the_pushed_theme() {
    // Not the bug: proves each query kind produces a decodable reply that
    // reflects the host-pushed colour, so later failures are attributable
    // to ordering and not to a deaf or mis-parsing harness.
    let rig = Rig::with_theme();
    assert_eq!(
        show(rig.probe(&osc("10;?", "\x07"), "10")),
        show(THEME_FG),
        "OSC 10 ? alone"
    );
    assert_eq!(
        show(rig.probe(&osc("11;?", "\x07"), "11")),
        show(THEME_BG),
        "OSC 11 ? alone"
    );
    assert_eq!(
        show(rig.probe(&osc("12;?", "\x07"), "12")),
        show(THEME_CURSOR),
        "OSC 12 ? alone"
    );
    assert_eq!(
        show(rig.probe(&osc("4;1;?", "\x07"), "4;1")),
        show(THEME_ANSI1),
        "OSC 4;1;? alone"
    );
}

#[test]
fn control_a_set_in_an_earlier_chunk_is_seen_by_a_later_query() {
    // Not the bug: proves every SET used below is live, so the
    // "query then set" tests cannot pass vacuously by the set being
    // ignored. Set and query are in SEPARATE chunks here.
    let rig = Rig::with_theme();
    rig.feed(&osc("10;rgb:30/40/50", "\x07"));
    assert_eq!(
        show(rig.probe(&osc("10;?", "\x07"), "10")),
        show(OVERRIDE_FG)
    );
    rig.feed(&osc("11;rgb:10/20/30", "\x07"));
    assert_eq!(
        show(rig.probe(&osc("11;?", "\x07"), "11")),
        show(OVERRIDE_BG)
    );
    rig.feed(&osc("12;rgb:0a/0b/0c", "\x07"));
    assert_eq!(
        show(rig.probe(&osc("12;?", "\x07"), "12")),
        show(OVERRIDE_CURSOR)
    );
    rig.feed(&osc("4;1;rgb:aa/bb/cc", "\x07"));
    assert_eq!(
        show(rig.probe(&osc("4;1;?", "\x07"), "4;1")),
        show(OVERRIDE_ANSI1)
    );
}

// ---------- the bug: query, then set, in ONE chunk -----------------

/// Shared body: `query` and `mutation` are concatenated into one
/// `bb_term_input` call. The single reply must equal `at_query_time`; a
/// following lone probe must equal `after_mutation` (proving the mutation
/// really happened).
#[track_caller]
#[allow(clippy::too_many_arguments)]
fn assert_query_then_mutation(
    rig: &Rig,
    label: &str,
    prefix: &str,
    query: Vec<u8>,
    mutation: Vec<u8>,
    at_query_time: u32,
    after_mutation: u32,
    probe_query: Vec<u8>,
) {
    // Precondition: the state the query is supposed to observe.
    let before = rig.probe(&probe_query, prefix);
    assert_eq!(
        show(before),
        show(at_query_time),
        "{label}: precondition - colour before the chunk"
    );

    let chunk = cat(&[query, mutation]);
    let got = rig.replies(&chunk, prefix);
    assert_eq!(
        got.len(),
        1,
        "{label}: one query in the chunk must yield exactly one reply, got [{}]",
        show_all(&got)
    );
    let got = got
        .into_iter()
        .next()
        .unwrap()
        .unwrap_or_else(|e| panic!("{label}: {e}"));
    assert_eq!(
        show(got),
        show(at_query_time),
        "{label}: reply must report the colour at query time ({}), not the \
         post-chunk colour ({})",
        show(at_query_time),
        show(after_mutation)
    );

    // The mutation was not vacuous: it did take effect.
    let after = rig.probe(&probe_query, prefix);
    assert_eq!(
        show(after),
        show(after_mutation),
        "{label}: the trailing mutation must still take effect"
    );
}

#[test]
fn osc11_query_then_set_in_one_chunk_replies_with_the_pre_set_background() {
    // The exact trigger from the report:
    //   printf '\e]11;?\a\e]11;rgb:ff/00/00\a'
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        assert_query_then_mutation(
            &rig,
            &format!("OSC 11 ? then OSC 11 set ({name})"),
            "11",
            osc("11;?", term),
            osc("11;rgb:ff/00/00", term),
            THEME_BG,
            RED,
            osc("11;?", term),
        );
    }
}

#[test]
fn osc10_query_then_set_in_one_chunk_replies_with_the_pre_set_foreground() {
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        assert_query_then_mutation(
            &rig,
            &format!("OSC 10 ? then OSC 10 set ({name})"),
            "10",
            osc("10;?", term),
            osc("10;rgb:ff/00/00", term),
            THEME_FG,
            RED,
            osc("10;?", term),
        );
    }
}

#[test]
fn osc12_query_then_set_in_one_chunk_replies_with_the_pre_set_cursor_color() {
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        assert_query_then_mutation(
            &rig,
            &format!("OSC 12 ? then OSC 12 set ({name})"),
            "12",
            osc("12;?", term),
            osc("12;rgb:ff/00/00", term),
            THEME_CURSOR,
            RED,
            osc("12;?", term),
        );
    }
}

#[test]
fn osc4_query_then_set_in_one_chunk_replies_with_the_pre_set_palette_entry() {
    // OSC 4;N;? followed by OSC 4;N;#rrggbb.
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        assert_query_then_mutation(
            &rig,
            &format!("OSC 4;1;? then OSC 4;1;#ff0000 ({name})"),
            "4;1",
            osc("4;1;?", term),
            osc("4;1;#ff0000", term),
            THEME_ANSI1,
            RED,
            osc("4;1;?", term),
        );
    }
}

// ---------- the bug: query, then reset, in ONE chunk ---------------

#[test]
fn osc11_query_then_osc111_reset_in_one_chunk_replies_with_the_override() {
    // The program overrode the bg earlier. Asking and then resetting in
    // one write: the answer is the override that was live when asked; the
    // reset only affects later queries (which then see the theme).
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        rig.feed(&osc("11;rgb:10/20/30", term));
        assert_query_then_mutation(
            &rig,
            &format!("OSC 11 ? then OSC 111 reset ({name})"),
            "11",
            osc("11;?", term),
            osc("111", term),
            OVERRIDE_BG,
            THEME_BG,
            osc("11;?", term),
        );
    }
}

#[test]
fn osc10_query_then_osc110_reset_in_one_chunk_replies_with_the_override() {
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        rig.feed(&osc("10;rgb:30/40/50", term));
        assert_query_then_mutation(
            &rig,
            &format!("OSC 10 ? then OSC 110 reset ({name})"),
            "10",
            osc("10;?", term),
            osc("110", term),
            OVERRIDE_FG,
            THEME_FG,
            osc("10;?", term),
        );
    }
}

#[test]
fn osc12_query_then_osc112_reset_in_one_chunk_replies_with_the_override() {
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        rig.feed(&osc("12;rgb:0a/0b/0c", term));
        assert_query_then_mutation(
            &rig,
            &format!("OSC 12 ? then OSC 112 reset ({name})"),
            "12",
            osc("12;?", term),
            osc("112", term),
            OVERRIDE_CURSOR,
            THEME_CURSOR,
            osc("12;?", term),
        );
    }
}

#[test]
fn osc4_query_then_osc104_reset_of_that_entry_replies_with_the_override() {
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        rig.feed(&osc("4;1;rgb:aa/bb/cc", term));
        assert_query_then_mutation(
            &rig,
            &format!("OSC 4;1;? then OSC 104;1 reset ({name})"),
            "4;1",
            osc("4;1;?", term),
            osc("104;1", term),
            OVERRIDE_ANSI1,
            THEME_ANSI1,
            osc("4;1;?", term),
        );
    }
}

#[test]
fn osc4_query_then_bare_osc104_reset_replies_with_the_override() {
    // Bare OSC 104 resets the whole palette.
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        rig.feed(&osc("4;1;rgb:aa/bb/cc", term));
        assert_query_then_mutation(
            &rig,
            &format!("OSC 4;1;? then bare OSC 104 reset ({name})"),
            "4;1",
            osc("4;1;?", term),
            osc("104", term),
            OVERRIDE_ANSI1,
            THEME_ANSI1,
            osc("4;1;?", term),
        );
    }
}

// ---------- ordering inside a chunk with several queries -----------

#[test]
fn interleaved_queries_and_sets_each_see_the_state_at_their_own_position() {
    // Q  set(0x111111)  Q  set(0x222222)  Q   in a single chunk.
    // Correct replies, in stream order: theme, 0x111111, 0x222222.
    for (name, term) in TERMINATORS {
        let rig = Rig::with_theme();
        let chunk = cat(&[
            osc("11;?", term),
            osc("11;rgb:11/11/11", term),
            osc("11;?", term),
            osc("11;rgb:22/22/22", term),
            osc("11;?", term),
        ]);
        let got = rig.replies(&chunk, "11");
        assert_eq!(
            show_all(&got),
            [show(THEME_BG), show(0x111111), show(0x222222)].join(", "),
            "({name}) three OSC 11 queries separated by two sets must \
             each reply with the background current at their own position"
        );
        // And the terminal ends in the last-set state.
        assert_eq!(show(rig.probe(&osc("11;?", term), "11")), show(0x222222));
    }
}

#[test]
fn a_set_before_the_query_in_the_same_chunk_is_visible_but_a_set_after_is_not() {
    // set(0x111111)  Q  set(0x222222)   -> the query must answer 0x111111:
    // neither the theme (the earlier set was ignored) nor 0x222222 (the
    // later set leaked backwards).
    let rig = Rig::with_theme();
    let chunk = cat(&[
        osc("11;rgb:11/11/11", "\x07"),
        osc("11;?", "\x07"),
        osc("11;rgb:22/22/22", "\x07"),
    ]);
    let got = rig.replies(&chunk, "11");
    assert_eq!(
        show_all(&got),
        show(0x111111),
        "set-query-set in one chunk must reply with the FIRST set"
    );
}

#[test]
fn queries_of_different_kinds_in_one_chunk_each_see_their_own_pre_set_color() {
    // Query fg, bg, cursor, palette 1, THEN change all four, one chunk.
    // Replies come back in query order with the theme values.
    let rig = Rig::with_theme();
    let t = "\x07";
    let chunk = cat(&[
        osc("10;?", t),
        osc("11;?", t),
        osc("12;?", t),
        osc("4;1;?", t),
        osc("10;rgb:ff/00/00", t),
        osc("11;rgb:ff/00/00", t),
        osc("12;rgb:ff/00/00", t),
        osc("4;1;#ff0000", t),
    ]);
    let writes = rig.feed_collect(&chunk);
    let decoded: Vec<Result<u32, String>> = writes
        .iter()
        .zip(["10", "11", "12", "4;1"])
        .map(|(w, p)| parse_rgb_reply(w, p))
        .collect();
    assert_eq!(
        writes.len(),
        4,
        "four queries must yield four replies, got {writes:?}"
    );
    assert_eq!(
        show_all(&decoded),
        [THEME_FG, THEME_BG, THEME_CURSOR, THEME_ANSI1]
            .map(show)
            .join(", "),
        "fg/bg/cursor/ansi1 replies must all be the pre-set theme colours"
    );
}

// ---------- chunking must not change the answer --------------------

#[test]
fn reply_does_not_depend_on_where_the_pty_split_the_bytes() {
    // The same byte stream, cut at every possible offset into two
    // `bb_term_input` calls, and also delivered one byte at a time. The
    // reply must be the pre-set background in every delivery.
    let stream = cat(&[osc("11;?", "\x07"), osc("11;rgb:ff/00/00", "\x07")]);
    let mut wrong: Vec<String> = Vec::new();

    // Whole stream in one chunk (the report's trigger).
    {
        let rig = Rig::with_theme();
        let got = rig.replies(&stream, "11");
        if show_all(&got) != show(THEME_BG) {
            wrong.push(format!("single chunk -> [{}]", show_all(&got)));
        }
    }

    for cut in 1..stream.len() {
        let rig = Rig::with_theme();
        let mut got = rig.replies(&stream[..cut], "11");
        got.extend(rig.replies(&stream[cut..], "11"));
        if show_all(&got) != show(THEME_BG) {
            wrong.push(format!("split at byte {cut} -> [{}]", show_all(&got)));
        }
    }

    // One byte per call.
    {
        let rig = Rig::with_theme();
        let mut got = Vec::new();
        for b in &stream {
            got.extend(rig.replies(std::slice::from_ref(b), "11"));
        }
        if show_all(&got) != show(THEME_BG) {
            wrong.push(format!("byte-at-a-time -> [{}]", show_all(&got)));
        }
    }

    assert!(
        wrong.is_empty(),
        "every delivery of `OSC 11 ? ; OSC 11 set red` must reply with the \
         pre-set background {} (stream length {} bytes); wrong deliveries:\n{}",
        show(THEME_BG),
        stream.len(),
        wrong.join("\n")
    );
}

#[test]
fn osc4_reply_does_not_depend_on_where_the_pty_split_the_bytes() {
    let stream = cat(&[osc("4;1;?", "\x1b\\"), osc("4;1;#ff0000", "\x1b\\")]);
    let mut wrong: Vec<String> = Vec::new();

    {
        let rig = Rig::with_theme();
        let got = rig.replies(&stream, "4;1");
        if show_all(&got) != show(THEME_ANSI1) {
            wrong.push(format!("single chunk -> [{}]", show_all(&got)));
        }
    }
    for cut in 1..stream.len() {
        let rig = Rig::with_theme();
        let mut got = rig.replies(&stream[..cut], "4;1");
        got.extend(rig.replies(&stream[cut..], "4;1"));
        if show_all(&got) != show(THEME_ANSI1) {
            wrong.push(format!("split at byte {cut} -> [{}]", show_all(&got)));
        }
    }

    assert!(
        wrong.is_empty(),
        "every delivery of `OSC 4;1;? ; OSC 4;1;#ff0000` must reply with \
         the pre-set entry {} (stream length {} bytes); wrong deliveries:\n{}",
        show(THEME_ANSI1),
        stream.len(),
        wrong.join("\n")
    );
}

// ---------- the user-visible consequence ---------------------------

#[test]
fn save_original_then_override_then_restore_returns_to_the_original() {
    // A TUI's startup: one write that saves the original background (query)
    // and installs its own (set). On exit it writes the saved colour back.
    // If the saved colour is the TUI's own override, the terminal is stuck
    // with it after the TUI exits.
    let rig = Rig::with_theme();

    let startup = cat(&[osc("11;?", "\x07"), osc("11;rgb:ff/00/00", "\x07")]);
    let replies = rig.replies(&startup, "11");
    assert_eq!(
        replies.len(),
        1,
        "startup query must reply once: {replies:?}"
    );
    let saved = replies
        .into_iter()
        .next()
        .unwrap()
        .unwrap_or_else(|e| panic!("undecodable startup reply: {e}"));
    assert_eq!(
        show(saved),
        show(THEME_BG),
        "the 'original' background the TUI saves must be the theme's"
    );

    // TUI is running with red; sanity-check that.
    assert_eq!(show(rig.probe(&osc("11;?", "\x07"), "11")), show(RED));

    // Exit: write the saved colour back (8-bit hex per channel).
    let restore = format!(
        "11;rgb:{:02x}/{:02x}/{:02x}",
        (saved >> 16) & 0xFF,
        (saved >> 8) & 0xFF,
        saved & 0xFF
    );
    rig.feed(&osc(&restore, "\x07"));
    assert_eq!(
        show(rig.probe(&osc("11;?", "\x07"), "11")),
        show(THEME_BG),
        "after the TUI restores the colour it saved, the terminal must be \
         back at the theme background, not stuck on the TUI's override"
    );
}
