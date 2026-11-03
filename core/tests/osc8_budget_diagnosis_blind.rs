//! Blind regression tests for OSC8-c: the over-long `id=` handling and the
//! re-apply markers of the OSC 8 per-terminal live-byte budget.
//!
//! Written from the bug report, the public C surface (`BBCore.h`), the
//! existing OSC 8 tests and the vendor marker test only, without sight of the
//! implementation bodies.
//!
//! The refusal-log truthfulness tests that used to live here (OSC8-c part 1)
//! judged the log with a classifier that treated a hedge phrase ANYWHERE in
//! the log as a hedge on every remedy, so they could only pass. They are
//! replaced by `osc8_refusal_log_truth_blind.rs`, which reads each clause of
//! the log as a claim and compares it with what the core really frees.
//!
//! Contract under test
//! -------------------
//!   1. LONG `id=`. The core never reads the `id=` OSC 8 parameter. An
//!      OSC 8 whose `id=` is longer than 256 bytes but whose URI is
//!      acceptable must still produce a working link (the id may be ignored
//!      or truncated) and must not be refused silently. The parser accepts
//!      an OSC payload of up to ~8 MiB (see `osc8_uri_retention_blind.rs`),
//!      so ids of several KiB reach the grid.
//!   2. RE-APPLY MARKERS. Every `Term` field added for the budget
//!      (`hyperlink_live`, `hyperlink_live_max`, `hyperlink_over_budget`),
//!      at its declaration and at its initialiser, carries the repo's
//!      `Blackbird fix (re-apply on bump)` marker (so a re-vendor of
//!      `alacritty_terminal` can find it), and the vendor marker test
//!      (`vendor_markers_blind.rs`) lists the fields, so dropping a marker
//!      is caught.
//!
//! Pre-flight cost (memory x time): the in-process tests are a few KiB each
//! (the longest `id=` is 64 KiB) plus reading two source files of a few
//! hundred KiB.

use std::ffi::CStr;
use std::fs;
use std::path::{Path, PathBuf};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// FFI harness
// ---------------------------------------------------------------------------

/// A snapshot, released on drop.
struct Snap {
    ptr: *const bc::BBSnap,
}

impl Snap {
    fn rows(&self) -> usize {
        unsafe { (*self.ptr).rows as usize }
    }

    fn cols(&self) -> usize {
        unsafe { (*self.ptr).cols as usize }
    }

    /// Unicode scalar printed in the cell (0 = empty).
    fn ch(&self, row: usize, col: usize) -> u32 {
        assert!(
            row < self.rows() && col < self.cols(),
            "cell ({row},{col}) outside the {}x{} snapshot",
            self.rows(),
            self.cols()
        );
        unsafe {
            let len = (*self.ptr).cells_len;
            let idx = row * self.cols() + col;
            assert!(idx < len, "cell index {idx} outside cells_len {len}");
            let cells: &[bc::BBCell] = std::slice::from_raw_parts((*self.ptr).cells, len);
            cells[idx].ch
        }
    }

    /// The URL attributed to a cell, or `None` when it carries no link.
    fn link_url(&self, row: usize, col: usize) -> Option<String> {
        unsafe {
            let id = bc::bb_snap_link_id_at(self.ptr, row as u16, col as u16);
            if id == 0 {
                return None;
            }
            let c = bc::bb_snap_link_url(self.ptr, id);
            assert!(
                !c.is_null(),
                "link id {id} at ({row},{col}) must resolve to a URL"
            );
            Some(CStr::from_ptr(c as *const _).to_string_lossy().into_owned())
        }
    }
}

impl Drop for Snap {
    fn drop(&mut self) {
        unsafe { bc::bb_snap_release(self.ptr) };
    }
}

/// A terminal, freed on drop.
struct Term {
    ptr: *mut bc::BBTerm,
}

impl Term {
    fn new(cols: u16, rows: u16, scrollback: u32) -> Self {
        let ptr = unsafe { bc::bb_term_new(cols, rows, scrollback) };
        assert!(!ptr.is_null(), "bb_term_new returned null");
        Term { ptr }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.ptr, bytes.as_ptr(), bytes.len()) };
    }

    fn poisoned(&self) -> u8 {
        unsafe { bc::bb_term_is_poisoned(self.ptr) }
    }

    fn snapshot(&self) -> Snap {
        let ptr = unsafe { bc::bb_term_take_snapshot(self.ptr) };
        assert!(!ptr.is_null(), "bb_term_take_snapshot returned null");
        Snap { ptr }
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.ptr) };
    }
}

// ---------------------------------------------------------------------------
// Part 1: an over-long `id=` must not cost the link
// ---------------------------------------------------------------------------

/// `len` bytes of a legal `id=` value (printable ASCII with no `;` or `:`,
/// the OSC 8 separators), distinct per `salt`.
fn id_of_len(len: usize, salt: char) -> String {
    let alphabet: Vec<char> = format!("{salt}abcdefghijklmnopqrstuvwxyz0123456789-_")
        .chars()
        .collect();
    (0..len).map(|i| alphabet[i % alphabet.len()]).collect()
}

const URL_A: &str = "https://example.com/docs?page=7";
const URL_B: &str = "https://example.org/other/path#frag";
const URL_C: &str = "https://example.net/third";

/// Ids at and under the historical 256-byte limit: these worked before the
/// bug and are the rig's controls.
const SHORT_ID_LENS: [usize; 4] = [0, 1, 255, 256];
/// Ids over it: the report's trigger. 64 KiB is far cheaper than the 8 MiB
/// OSC payload the parser accepts.
const LONG_ID_LENS: [usize; 5] = [257, 300, 1_000, 4_096, 65_536];

/// Feeds `ESC ] 8 ; id=<id> ; URL_A ESC \ ab ESC ] 8 ; ; ESC \ c` into a fresh
/// terminal and returns the printed text and what the first three cells of
/// row 0 resolve to.
fn link_after_id(id_len: usize) -> (Vec<u32>, [Option<String>; 3]) {
    let id = id_of_len(id_len, 'q');
    let seq = format!("\x1b]8;id={id};{URL_A}\x1b\\ab\x1b]8;;\x1b\\c");
    let term = Term::new(80, 24, 100);
    term.feed(seq.as_bytes());
    assert_eq!(
        term.poisoned(),
        0,
        "an id= of {id_len} bytes poisoned the terminal"
    );
    let snap = term.snapshot();
    let text: Vec<u32> = (0..3).map(|c| snap.ch(0, c)).collect();
    let links = [
        snap.link_url(0, 0),
        snap.link_url(0, 1),
        snap.link_url(0, 2),
    ];
    (text, links)
}

/// The report's trigger: a URI that is acceptable keeps its link whatever the
/// (unread) id= looks like.
#[test]
fn overlong_osc8_id_param_does_not_drop_an_acceptable_link() {
    let want_text: Vec<u32> = vec![u32::from(b'a'), u32::from(b'b'), u32::from(b'c')];
    let want_links: [Option<String>; 3] = [Some(URL_A.to_owned()), Some(URL_A.to_owned()), None];

    // Rig: ids up to the old limit already work, and the text always prints
    // (so a missing link is a dropped attribution, not a lost payload).
    let mut control_failures: Vec<String> = Vec::new();
    for len in SHORT_ID_LENS {
        let (text, links) = link_after_id(len);
        if text != want_text || links != want_links {
            control_failures.push(format!("id={len}B -> text {text:?} links {links:?}"));
        }
    }
    assert_eq!(
        control_failures,
        Vec::<String>::new(),
        "rig precondition: an `ab` link with an id of <= 256 bytes must attribute both cells to \
         {URL_A:?} and leave the cell after the close unlinked"
    );

    let mut failures: Vec<String> = Vec::new();
    for len in LONG_ID_LENS {
        let (text, links) = link_after_id(len);
        assert_eq!(
            text, want_text,
            "an id= of {len} bytes must not swallow or reorder the printed text"
        );
        if links != want_links {
            failures.push(format!(
                "id={len}B: cells (0,0),(0,1),(0,2) resolve to {links:?}"
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "an OSC 8 with an over-long id= and the acceptable URI {URL_A:?} must still link `ab` \
         (the core never reads the id; ignore or truncate it) - expected {want_links:?} for every \
         length in {LONG_ID_LENS:?}"
    );
}

/// The refusal must not wedge or poison what follows: the next links (long id
/// again, then a short one) and the plain text between them keep their exact
/// attribution.
#[test]
fn overlong_osc8_id_param_leaves_following_links_and_text_intact() {
    let long_a = id_of_len(300, 'a');
    let long_b = id_of_len(2_000, 'b');
    let seq = format!(
        "\x1b]8;id={long_a};{URL_A}\x1b\\ab\
         \x1b]8;id={long_b};{URL_B}\x1b\\cd\
         \x1b]8;;\x1b\\e\
         \x1b]8;id=short;{URL_C}\x1b\\f\x1b]8;;\x1b\\"
    );
    let term = Term::new(80, 24, 100);
    term.feed(seq.as_bytes());
    assert_eq!(term.poisoned(), 0, "the stream poisoned the terminal");
    let snap = term.snapshot();

    let text: Vec<u32> = (0..6).map(|c| snap.ch(0, c)).collect();
    assert_eq!(
        text,
        "abcdef".bytes().map(u32::from).collect::<Vec<u32>>(),
        "all six characters must print in order"
    );
    let links: Vec<Option<String>> = (0..6).map(|c| snap.link_url(0, c)).collect();
    let want: Vec<Option<String>> = vec![
        Some(URL_A.to_owned()),
        Some(URL_A.to_owned()),
        Some(URL_B.to_owned()),
        Some(URL_B.to_owned()),
        None,
        Some(URL_C.to_owned()),
    ];
    assert_eq!(
        links, want,
        "cells a,b -> {URL_A} (id 300 B); c,d -> {URL_B} (id 2000 B); e unlinked; f -> {URL_C} \
         (short id). Measured per-cell links: {links:?}"
    );
}

// ---------------------------------------------------------------------------
// Part 2: the budget fields on Term carry the re-apply marker
// ---------------------------------------------------------------------------

const TERM_SRC: &str = "vendor/alacritty_terminal/src/term/mod.rs";
const MARKER_TEST_SRC: &str = "core/tests/vendor_markers_blind.rs";
const BUDGET_FIELDS: [&str; 3] = [
    "hyperlink_live",
    "hyperlink_live_max",
    "hyperlink_over_budget",
];
const MARKER_PHRASE: &str = "(re-apply on bump)";

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core/ has a parent directory (the repo root)")
        .to_path_buf()
}

fn load(rel: &str) -> Vec<String> {
    let path = repo_root().join(rel);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read source {}: {e}", path.display()));
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    assert!(
        lines.len() > 50,
        "{rel} has only {} lines; the file moved or was truncated",
        lines.len()
    );
    lines
}

/// A COMMENT that names Blackbird and then carries `(re-apply on bump)`
/// (the repo's marker, same predicate as `vendor_markers_blind.rs`).
fn is_marker(line: &str) -> bool {
    let trimmed = line.trim_start();
    if !trimmed.starts_with("//") {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    match (lower.find("blackbird"), lower.find(MARKER_PHRASE)) {
        (Some(who), Some(phrase)) => who < phrase,
        _ => false,
    }
}

fn strip_visibility(mut s: &str) -> &str {
    for prefix in ["pub(crate) ", "pub(super) ", "pub "] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
            break;
        }
    }
    s
}

/// Is `line` a struct field line (declaration `name: Type,` or initialiser
/// `name: expr,` / shorthand `name,`) for exactly `name`?
fn is_field_line(line: &str, name: &str) -> bool {
    let rest = strip_visibility(line.trim_start());
    match rest.strip_prefix(name) {
        Some(tail) => {
            tail.starts_with(':') || tail.starts_with(',') || tail.trim_start().starts_with(':')
        }
        None => false,
    }
}

/// Marked when a marker comment sits on the line itself (trailing comment) or
/// anywhere in the contiguous non-blank lines directly above it: the same
/// "attached block" the vendor marker test uses, so one comment may head a
/// group of adjacent fields.
fn is_attached_marker(lines: &[String], idx: usize) -> bool {
    if let Some(pos) = lines[idx].find("//") {
        if is_marker(&lines[idx][pos..]) {
            return true;
        }
    }
    let mut i = idx;
    while i > 0 && !lines[i - 1].trim().is_empty() {
        i -= 1;
        if is_marker(&lines[i]) {
            return true;
        }
    }
    false
}

/// `[start, end]` (0-based) of the column-0 `pub struct Term<..> {` block.
fn term_struct_block(lines: &[String]) -> (usize, usize) {
    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("pub struct Term<"))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        starts.len(),
        1,
        "{TERM_SRC}: expected exactly one `pub struct Term<`, found 0-based lines {starts:?}"
    );
    let end = (starts[0] + 1..lines.len())
        .find(|&i| lines[i] == "}")
        .unwrap_or_else(|| panic!("{TERM_SRC}: struct Term never closes"));
    (starts[0], end)
}

/// Rig: the marker predicate, the field-line matcher and the attached-block
/// rule are pinned on synthetic source, so a green marker test below cannot
/// mean "matched nothing".
#[test]
fn rig_marker_scan_helpers_behave_on_synthetic_source() {
    assert!(is_marker(
        "    /// Blackbird fix (re-apply on bump): bytes held by live hyperlinks"
    ));
    assert!(is_marker(
        "        // Blackbird addition (re-apply on bump): x"
    ));
    assert!(!is_marker("    /// Blackbird fix: no phrase"));
    assert!(!is_marker("    // (re-apply on bump) Blackbird"));
    assert!(!is_marker(
        "    let s = \"Blackbird fix (re-apply on bump)\";"
    ));

    assert!(is_field_line(
        "    hyperlink_live: Arc<AtomicUsize>,",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "            hyperlink_live: Default::default(),",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "            hyperlink_live,",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "    pub(crate) hyperlink_live: u8,",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    hyperlink_live_max: usize,",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    self.hyperlink_live.load()",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    let hyperlink_live = 1;",
        "hyperlink_live"
    ));

    let src: Vec<String> = [
        "    /// Blackbird fix (re-apply on bump): group marker",
        "    alpha: u8,",
        "    beta: u8,",
        "",
        "    /// ordinary doc",
        "    gamma: u8,",
        "    delta: u8, // Blackbird fix (re-apply on bump): trailing",
        "",
        "    epsilon: u8,",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    let names = ["alpha", "beta", "gamma", "delta", "epsilon"];
    let marked: Vec<bool> = (0..src.len())
        .filter(|&i| names.iter().any(|n| is_field_line(&src[i], n)))
        .map(|i| is_attached_marker(&src, i))
        .collect();
    assert_eq!(
        marked,
        vec![true, true, false, true, false],
        "attached-marker rule on alpha, beta, gamma, delta, epsilon"
    );
}

#[test]
fn budget_fields_on_term_carry_the_reapply_marker_at_declaration_and_initialiser() {
    let lines = load(TERM_SRC);
    let (lo, hi) = term_struct_block(&lines);

    let mut unmarked: Vec<String> = Vec::new();
    for name in BUDGET_FIELDS {
        let hits: Vec<usize> = (0..lines.len())
            .filter(|&i| is_field_line(&lines[i], name))
            .collect();
        let decls: Vec<usize> = hits.iter().copied().filter(|&i| i > lo && i < hi).collect();
        let inits: Vec<usize> = hits.iter().copied().filter(|&i| i < lo || i > hi).collect();
        // Rig: every field is declared once in `struct Term` and initialised
        // at least once elsewhere in the file.
        assert_eq!(
            decls.len(),
            1,
            "{TERM_SRC}: expected exactly one declaration of `{name}` in `struct Term`, found \
             1-based lines {:?}",
            decls.iter().map(|i| i + 1).collect::<Vec<usize>>()
        );
        assert!(
            !inits.is_empty(),
            "{TERM_SRC}: expected at least one initialiser of `{name}` outside `struct Term`"
        );
        for (kind, idxs) in [("declaration", &decls), ("initialiser", &inits)] {
            for &i in idxs {
                if !is_attached_marker(&lines, i) {
                    unmarked.push(format!(
                        "{TERM_SRC}:{} {kind} of `{name}`: `{}`",
                        i + 1,
                        lines[i].trim()
                    ));
                }
            }
        }
    }
    assert_eq!(
        unmarked,
        Vec::<String>::new(),
        "every OSC 8 budget field on Term (declaration and initialiser) must carry a \
         `Blackbird fix (re-apply on bump)` comment, directly or as the head of the adjacent \
         group, so a re-vendor of alacritty_terminal finds it"
    );
}

/// Whole-word occurrence of `word` in `line`.
fn mentions_word(line: &str, word: &str) -> bool {
    let is_ident = |c: char| c.is_alphanumeric() || c == '_';
    let mut from = 0;
    while let Some(pos) = line[from..].find(word) {
        let start = from + pos;
        let end = start + word.len();
        let before_ok = line[..start]
            .chars()
            .next_back()
            .is_none_or(|c| !is_ident(c));
        let after_ok = line[end..].chars().next().is_none_or(|c| !is_ident(c));
        if before_ok && after_ok {
            return true;
        }
        from = start + word.len();
    }
    false
}

/// "The marker test lists them": the vendor marker test names each budget
/// field in code (a `Site { needle: "hyperlink_live", .. }` entry), so
/// dropping a field's marker fails a test.
#[test]
fn vendor_marker_test_lists_every_budget_field() {
    let lines = load(MARKER_TEST_SRC);
    // Rig: the file is the marker test and its OSC 8 budget test still exists.
    assert!(
        lines
            .iter()
            .any(|l| l.contains("fn osc8_budget_carries_reapply_marker")),
        "{MARKER_TEST_SRC}: the OSC 8 budget marker test (osc8_budget_carries_reapply_marker) \
         moved or was renamed; update this rig"
    );
    let code: Vec<&String> = lines
        .iter()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect();
    let missing: Vec<&str> = BUDGET_FIELDS
        .iter()
        .copied()
        .filter(|f| !code.iter().any(|l| mentions_word(l, f)))
        .collect();
    assert_eq!(
        missing,
        Vec::<&str>::new(),
        "{MARKER_TEST_SRC} must list the Term fields added for the OSC 8 live budget (as `Site` \
         needles, next to HYPERLINK_LIVE_MAX / HyperlinkInner / set_hyperlink); not mentioned in \
         code: {missing:?}"
    );
}
