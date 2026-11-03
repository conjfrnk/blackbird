//! Blind regression tests for bug `uni5-title-scrub-strips-joiners`
//! (merged: `uni5-title-invalid-utf8-segment-dropped`), written from the
//! observable contract without sight of the scrubber / handler bodies.
//!
//! Contract under test (BBCore.h `Title` / `Notification` events):
//!   - OSC 0 / OSC 2 window titles and OSC 9 / OSC 777 notification text are
//!     scrubbed of C0 / C1 controls and of bidi-override scalars (the
//!     `safe<RLO>txt` spoof), and nothing else that is user-visible text.
//!   - ZERO WIDTH JOINER (U+200D), ZERO WIDTH NON-JOINER (U+200C) and the
//!     variation selectors (U+FE00..=U+FE0F, U+E0100..=U+E01EF) are NOT
//!     spoofing payload: they are part of the spelling of emoji sequences
//!     (`U+26A0 U+FE0F`, family ZWJ sequences) and of Persian / Indic words
//!     (ZWNJ in `می‌خواهم`, ZWJ / ZWNJ around a virama). Dropping them
//!     changes orthography and glyph shaping, so the tab pill / window
//!     title / notification would disagree with the grid, which draws the
//!     very same bytes correctly.
//!   - A title that carries a non-UTF-8 byte must not be dropped wholesale
//!     (nor lose a whole `;`-separated segment): the valid text around the
//!     bad byte survives. Whether the bad byte becomes U+FFFD or vanishes
//!     is left open, so the assertions strip U+FFFD before comparing.
//!
//! Pre-flight cost: one 20x3 BBTerm per case (16-line scrollback, a few
//! KiB), at most ~20 terminals created in the largest test, inputs of a
//! few dozen bytes, no sleeps, no I/O. Title events are rate-capped at
//! 32 per second and notifications at 4 per window; every case here uses
//! a fresh terminal and emits at most one control event plus one probe
//! event, so the caps are never approached.
//!
//! Non-vacuity: each title case first feeds a plain `OSC 2 ; ctl BEL` and
//! asserts the rig delivered exactly that, so a silent event pipeline can
//! never make a case pass; every case then asserts the probe produced
//! exactly one more event.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const KIND_TITLE: u32 = 1;
const KIND_NOTIFICATION: u32 = 8;
const SEP: char = '\u{1F}';

#[derive(Clone, Debug, PartialEq)]
struct Captured {
    kind: u32,
    payload: Vec<u8>,
}

#[derive(Default)]
struct Sink {
    events: Vec<Captured>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    // Header contract: `payload == NULL <=> len == 0`.
    if ev.payload.is_null() {
        assert_eq!(ev.len, 0, "BBEvent contract: null payload must have len 0");
    } else {
        assert!(
            ev.len > 0,
            "BBEvent contract: non-null payload must have len > 0"
        );
    }
    let bytes: Vec<u8> = if ev.payload.is_null() || ev.len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    };
    let sink = &*(ctx as *const Mutex<Sink>);
    sink.lock().unwrap().events.push(Captured {
        kind: ev.kind as u32,
        payload: bytes,
    });
}

struct Harness {
    term: *mut bc::BBTerm,
    sink: Arc<Mutex<Sink>>,
    ctx: *mut c_void,
}

impl Harness {
    fn new() -> Self {
        let sink: Arc<Mutex<Sink>> = Arc::new(Mutex::new(Sink::default()));
        let ctx = Arc::into_raw(sink.clone()) as *mut c_void;
        let term = unsafe { bc::bb_term_new(20, 3, 16) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Harness { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn events_of(&self, kind: u32) -> Vec<Captured> {
        self.sink
            .lock()
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == kind)
            .cloned()
            .collect()
    }

    /// Every Title payload delivered so far, in order. Panics (with the
    /// raw bytes) if a payload is not valid UTF-8: the header promises
    /// UTF-8 and a lossy decode here could hide the very corruption under
    /// test.
    fn titles(&self) -> Vec<String> {
        self.events_of(KIND_TITLE)
            .into_iter()
            .map(|e| {
                String::from_utf8(e.payload.clone())
                    .unwrap_or_else(|_| panic!("Title payload is not UTF-8: {:02x?}", e.payload))
            })
            .collect()
    }

    /// Decoded `(title, body)` of every Notification event, in order.
    fn notification_pairs(&self) -> Vec<(String, String)> {
        self.events_of(KIND_NOTIFICATION)
            .into_iter()
            .map(|e| {
                let s = String::from_utf8(e.payload.clone()).unwrap_or_else(|_| {
                    panic!("Notification payload is not UTF-8: {:02x?}", e.payload)
                });
                let mut halves = s.splitn(2, SEP);
                let title = halves.next().unwrap_or("").to_string();
                let body = halves
                    .next()
                    .unwrap_or_else(|| panic!("payload {s:?} lacks the U+001F separator"))
                    .to_string();
                (title, body)
            })
            .collect()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        unsafe {
            bc::bb_term_set_event_cb(self.term, None, std::ptr::null_mut());
            bc::bb_term_free(self.term);
            drop(Arc::from_raw(self.ctx as *const Mutex<Sink>));
        }
    }
}

/// `ESC ] <num> ; <text> BEL` as bytes.
fn osc_bel(num: &str, text: &str) -> Vec<u8> {
    let mut v: Vec<u8> = Vec::new();
    v.extend_from_slice(b"\x1b]");
    v.extend_from_slice(num.as_bytes());
    v.push(b';');
    v.extend_from_slice(text.as_bytes());
    v.push(0x07);
    v
}

/// Feed `osc` on a fresh terminal (after a rig-sanity control title) and
/// return the single Title payload the probe produced.
fn title_after(osc: &[u8]) -> String {
    let h = Harness::new();
    h.feed(b"\x1b]2;ctl\x07");
    assert_eq!(
        h.titles(),
        vec!["ctl".to_string()],
        "rig precondition: a plain OSC 2 must deliver exactly one Title"
    );
    h.feed(osc);
    let titles = h.titles();
    assert_eq!(
        titles.len(),
        2,
        "the probe OSC {:02x?} must deliver exactly one more Title event \
         (not be dropped, not be duplicated); all titles so far: {:?}",
        osc,
        titles
    );
    titles[1].clone()
}

/// Feed `osc` on a fresh terminal and return the single `(title, body)`
/// Notification pair it produced.
fn notification_after(osc: &[u8]) -> (String, String) {
    let h = Harness::new();
    h.feed(osc);
    let pairs = h.notification_pairs();
    assert_eq!(
        pairs.len(),
        1,
        "OSC {:02x?} must deliver exactly one Notification; got {:?}",
        osc,
        pairs
    );
    pairs[0].clone()
}

// ------------------------------------------------------------------ titles

/// The exact trigger from the bug report: `printf '\e]2;\xe2\x9a\xa0\xef\xb8\x8f build failed\a'`.
#[test]
fn osc2_title_keeps_vs16_emoji_presentation_selector() {
    let got = title_after(b"\x1b]2;\xe2\x9a\xa0\xef\xb8\x8f build failed\x07");
    assert_eq!(
        got,
        "\u{26A0}\u{FE0F} build failed",
        "OSC 2 title lost its VS16 (U+FE0F); measured {got:?} ({:x?})",
        got.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

#[test]
fn osc0_title_keeps_vs16_emoji_presentation_selector() {
    let got = title_after(&osc_bel("0", "\u{26A0}\u{FE0F} build failed"));
    assert_eq!(
        got, "\u{26A0}\u{FE0F} build failed",
        "OSC 0 title lost its VS16 (U+FE0F); measured {got:?}"
    );
}

#[test]
fn osc2_st_terminated_title_keeps_vs16_emoji_presentation_selector() {
    // ESC \ (ST) terminator instead of BEL: same scrub, different path out
    // of the parser.
    let got = title_after(b"\x1b]2;\xe2\x9d\xa4\xef\xb8\x8f love\x1b\\");
    assert_eq!(
        got, "\u{2764}\u{FE0F} love",
        "ST-terminated OSC 2 title lost its VS16 (U+FE0F); measured {got:?}"
    );
}

#[test]
fn osc2_title_keeps_zwj_emoji_sequence() {
    // MAN ZWJ WOMAN ZWJ GIRL: three pictographs glued by two ZWJs into one
    // family glyph. Without the ZWJs it shows as three separate people.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    let got = title_after(&osc_bel("2", &format!("{family} home")));
    assert_eq!(
        got,
        format!("{family} home"),
        "OSC 2 title must keep the ZWJ family sequence intact; measured {got:?} ({:x?})",
        got.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

#[test]
fn osc2_title_keeps_zwnj_in_persian_word() {
    // "mikhaham" (I want): U+200C separates the prefix `mi-` from the stem;
    // without it the letters join into the wrong word shape.
    let word = "\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}";
    let got = title_after(&osc_bel("2", word));
    assert_eq!(
        got,
        word,
        "OSC 2 Persian title lost its ZWNJ (U+200C); measured {got:?} ({:x?})",
        got.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

#[test]
fn osc2_title_keeps_zwj_and_zwnj_around_devanagari_virama() {
    // KA + VIRAMA + ZWJ + SSA (half-form request) and
    // KA + VIRAMA + ZWNJ + SSA (explicit-virama request).
    let text = "\u{915}\u{94D}\u{200D}\u{937} \u{915}\u{94D}\u{200C}\u{937}";
    let got = title_after(&osc_bel("2", text));
    assert_eq!(
        got,
        text,
        "OSC 2 Devanagari title lost its ZWJ/ZWNJ; measured {got:?} ({:x?})",
        got.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

#[test]
fn osc2_title_keeps_vs15_text_presentation_selector() {
    // HEAVY BLACK HEART + VS15 asks for the monochrome text glyph.
    let text = "\u{2764}\u{FE0E} text";
    let got = title_after(&osc_bel("2", text));
    assert_eq!(
        got, text,
        "OSC 2 title lost its VS15 (U+FE0E); measured {got:?}"
    );
}

#[test]
fn osc2_title_keeps_every_bmp_variation_selector() {
    // U+FE00..=U+FE0F after a base that accepts them. One fresh terminal
    // per selector (16 tiny terminals).
    let mut mismatches: Vec<(u32, String)> = Vec::new();
    for vs in 0xFE00u32..=0xFE0F {
        let sel = char::from_u32(vs).expect("BMP variation selector is a valid scalar");
        let text = format!("a\u{2205}{sel}b");
        let got = title_after(&osc_bel("2", &text));
        if got != text {
            mismatches.push((vs, got));
        }
    }
    assert_eq!(
        mismatches,
        Vec::<(u32, String)>::new(),
        "variation selectors (selector, measured title) that were stripped from an OSC 2 title"
    );
}

#[test]
fn osc2_title_keeps_supplementary_variation_selectors() {
    // Ideographic variation sequences: U+845B + VS17 (U+E0100) is the
    // "tsu" variant of 葛 used in Japanese place names; U+E01EF is VS256.
    for vs in ['\u{E0100}', '\u{E01EF}'] {
        let text = format!("\u{845B}{vs}\u{5E02}");
        let got = title_after(&osc_bel("2", &text));
        assert_eq!(
            got, text,
            "OSC 2 title lost supplementary variation selector U+{:X}; measured {got:?}",
            vs as u32
        );
    }
}

/// Guard against over-correction: keeping the joiners must not re-open the
/// bidi-spoof hole the scrubber exists for (audit H-5). The RLO / LRI are
/// still removed while the ZWJ sequence next to them survives.
#[test]
fn osc2_title_still_strips_bidi_override_but_keeps_joiners() {
    let input = "a\u{202E}\u{1F468}\u{200D}\u{1F469}\u{2066}\u{26A0}\u{FE0F}";
    let got = title_after(&osc_bel("2", input));
    assert_eq!(
        got,
        "a\u{1F468}\u{200D}\u{1F469}\u{26A0}\u{FE0F}",
        "bidi overrides (U+202E, U+2066) must be stripped while ZWJ (U+200D) and \
         VS16 (U+FE0F) are kept; measured {got:?} ({:x?})",
        got.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

/// Merged bug `uni5-title-invalid-utf8-segment-dropped`: one non-UTF-8 byte
/// in the title must cost at most that byte, not the whole title.
#[test]
fn osc2_title_with_non_utf8_byte_keeps_the_surrounding_text() {
    let got = title_after(b"\x1b]2;build\xFFdone\x07");
    let without_replacement: String = got.chars().filter(|c| *c != '\u{FFFD}').collect();
    assert_eq!(
        without_replacement, "builddone",
        "a title with one stray 0xFF byte must keep its valid text (the bad byte may \
         become U+FFFD or vanish); measured {got:?}"
    );
}

/// Same bug, `;`-separated shape: OSC params split on `;`, so a bad byte in
/// the middle segment must not take the whole segment with it.
#[test]
fn osc2_title_with_non_utf8_byte_in_one_semicolon_segment_keeps_every_segment() {
    let got = title_after(b"\x1b]2;left;mid\xFF;right\x07");
    let without_replacement: String = got.chars().filter(|c| *c != '\u{FFFD}').collect();
    assert_eq!(
        without_replacement, "left;mid;right",
        "a stray 0xFF inside one `;` segment must cost only that byte, not the segment; \
         measured {got:?}"
    );
}

/// Same bug, truncated multi-byte sequence (a UTF-8 lead byte with its
/// continuation cut off, as a byte-oriented `cut -c` / buffer split makes).
#[test]
fn osc2_title_with_truncated_utf8_sequence_keeps_the_surrounding_text() {
    // U+26A0 is E2 9A A0; keep only E2 9A, then plain text.
    let got = title_after(b"\x1b]2;pre \xE2\x9A post\x07");
    let without_replacement: String = got.chars().filter(|c| *c != '\u{FFFD}').collect();
    assert!(
        without_replacement.starts_with("pre") && without_replacement.ends_with("post"),
        "a title with a truncated UTF-8 sequence must keep both the text before and \
         after it; measured {got:?}"
    );
}

// ----------------------------------------------------------- notifications

#[test]
fn osc9_notification_keeps_vs16_emoji_presentation_selector() {
    let (title, body) = notification_after(b"\x1b]9;\xe2\x9a\xa0\xef\xb8\x8f build failed\x07");
    assert_eq!(title, "", "OSC 9 carries no title; measured {title:?}");
    assert_eq!(
        body,
        "\u{26A0}\u{FE0F} build failed",
        "OSC 9 notification body lost its VS16 (U+FE0F); measured {body:?} ({:x?})",
        body.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

#[test]
fn osc777_notification_title_keeps_zwj_emoji_sequence() {
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    let (title, body) =
        notification_after(&osc_bel("777", &format!("notify;{family} Deploy;done")));
    assert_eq!(
        title,
        format!("{family} Deploy"),
        "OSC 777 notification title lost its ZWJs (U+200D); measured {title:?} ({:x?})",
        title.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
    assert_eq!(body, "done", "body must be unaffected; measured {body:?}");
}

#[test]
fn osc777_notification_body_keeps_zwnj_and_zwj_and_title_keeps_vs16() {
    // Persian body with ZWNJ, Devanagari body fragment with ZWJ, title with
    // an emoji-presentation symbol.
    let persian = "\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}";
    let devanagari = "\u{915}\u{94D}\u{200D}\u{937}";
    let (title, body) = notification_after(&osc_bel(
        "777",
        &format!("notify;\u{26A0}\u{FE0F} Alert;{persian} {devanagari}"),
    ));
    assert_eq!(
        title, "\u{26A0}\u{FE0F} Alert",
        "OSC 777 notification title lost its VS16 (U+FE0F); measured {title:?}"
    );
    assert_eq!(
        body,
        format!("{persian} {devanagari}"),
        "OSC 777 notification body lost its ZWNJ / ZWJ; measured {body:?} ({:x?})",
        body.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}

/// Over-correction guard for notifications: bidi overrides still go, the
/// joiner / selector next to them stays.
#[test]
fn osc9_notification_still_strips_bidi_override_but_keeps_joiners() {
    let (title, body) = notification_after(&osc_bel(
        "9",
        "x\u{202E}\u{1F468}\u{200D}\u{1F469}\u{2066}\u{2764}\u{FE0F}",
    ));
    assert_eq!(title, "", "OSC 9 carries no title; measured {title:?}");
    assert_eq!(
        body,
        "x\u{1F468}\u{200D}\u{1F469}\u{2764}\u{FE0F}",
        "bidi overrides must be stripped while ZWJ and VS16 are kept; measured {body:?} ({:x?})",
        body.chars().map(|c| c as u32).collect::<Vec<u32>>()
    );
}
