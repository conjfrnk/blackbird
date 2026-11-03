//! Blind regression tests for the maintainer-facing contract of the vendored
//! `alacritty_terminal` / `vte` forks (`vendor/`):
//!
//!   1. Every local deviation from upstream carries the repo's
//!      `Blackbird fix (re-apply on bump)` marker comment (also written
//!      `Blackbird addition (re-apply on bump)` / `Blackbird fork change
//!      (re-apply on bump)`; see `event.rs`, `term/cell.rs`, `grid/mod.rs`
//!      for the style). The marker is the only thing a re-vendor has to go
//!      on: after re-extracting the upstream crate, `grep "re-apply on bump"`
//!      against the old tree is the checklist of fixes to carry over. A
//!      deviation without the marker is dropped silently by the next bump,
//!      and the fix it carried quietly stops working.
//!   2. No inherent method of `Term<T>` shares a name with a method of a
//!      trait that `Term<T>` implements (`Handler`, `Dimensions`). Inside
//!      `impl Handler for Term<T>` a call `self.name(..)` resolves to the
//!      INHERENT method first, so an inherent `name` hides the trait method
//!      `name`; if the trait method ever forwards to "itself" the only thing
//!      that stops it from recursing forever is that resolution-priority
//!      accident. Distinct names make the forwarding explicit.
//!
//! The tests are static: they read the vendored sources as text. They never
//! build, run or link the code under test, so the cost is a few hundred
//! kilobytes of file reads (milliseconds, well under 1 MiB of memory).
//!
//! Patches covered (the ones added since v0.9.3), with the item(s) that hold
//! the local code. A site is "marked" when the item's attached doc/attribute
//! block (the contiguous non-blank lines directly above it) or its body
//! (through its closing brace) contains a comment line that mentions
//! `Blackbird` and the literal `(re-apply on bump)`, in that order:
//!
//!   display_offset clamp ........ `Grid::scroll_up`                (grid/mod.rs)
//!   title cap ................... `TITLE_MAX_BYTES`, `Handler::set_title`
//!   zero-width cap .............. `ZEROWIDTH_MAX`, `Cell::push_zerowidth`
//!   DCH clamp ................... `Handler::delete_chars`
//!   ED 1 fix .................... `Handler::clear_screen`
//!   OSC 8 live-byte budget ...... `HYPERLINK_LIVE_MAX`, `HyperlinkInner`,
//!                                 `Handler::set_hyperlink`, and the `Term` fields
//!                                 `hyperlink_live`, `hyperlink_live_max`,
//!                                 `hyperlink_over_budget` (declaration and initialiser)
//!   kitty `CSI = flags ; mode u`  `Handler::set_keyboard_mode`
//!   reflow cursor / wide char ... `Grid::shrink_columns`           (grid/resize.rs)
//!   VS16 at column 0 ............ `Handler::input`, plus the four `glyph_end`
//!                                 invalidation points `Term::resize`,
//!                                 `Term::swap_alt`, `Term::scroll_down_relative`,
//!                                 `Term::scroll_up_relative` (term/mod.rs)
//!   emoji ZWJ / skin-tone width . `is_pictographic`, `is_emoji_modifier`,
//!                                 `Term::prev_glyph_column`, `Term::can_widen_prev_glyph`,
//!                                 `Term::widen_prev_glyph`, `Term::joins_emoji_cluster`
//!                                 (term/mod.rs) and the `Handler::input` call sites
//!
//! Rig preconditions (so a green run cannot mean "looked at nothing"):
//! every site must resolve to exactly one item (its enclosing scope is also
//! unique), the marker predicate is pinned on positive and negative
//! examples, a control test proves the detector recognises markers that
//! already exist today (`Hyperlink::bounded`, `Cell::push_zerowidth`,
//! `Processor::abort_string`), and the shadowing test asserts it really
//! parsed a plausible number of trait and inherent methods.

use std::fs;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Source access
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core/ has a parent directory (the repo root)")
        .to_path_buf()
}

fn load(rel: &str) -> Vec<String> {
    let path = repo_root().join(rel);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read vendored source {}: {e}", path.display()));
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    assert!(
        lines.len() > 50,
        "{rel} has only {} lines; the vendored tree moved or was truncated",
        lines.len()
    );
    lines
}

// ---------------------------------------------------------------------------
// The marker predicate
// ---------------------------------------------------------------------------

const MARKER_PHRASE: &str = "(re-apply on bump)";

/// A canonical marker is a COMMENT line that names Blackbird and then carries
/// the literal `(re-apply on bump)`: `// Blackbird fix (re-apply on bump): ...`,
/// `/// Blackbird addition (re-apply on bump): ...`.
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

/// A comment that announces a Blackbird deviation but is NOT in the canonical
/// form (used only to make failure messages actionable).
fn is_unmarked_blackbird_comment(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("//")
        && trimmed.to_ascii_lowercase().contains("blackbird")
        && !is_marker(line)
}

// ---------------------------------------------------------------------------
// Locating items
// ---------------------------------------------------------------------------

/// One piece of local code, identified by file, optional `impl` scope and the
/// item's declaration (`fn name`, `const NAME`, `struct Name`).
struct Site {
    file: &'static str,
    /// Substring of a column-0 `impl ...` header that scopes the search.
    scope: Option<&'static str>,
    /// Declaration prefix after any visibility keyword, e.g. `fn set_title`.
    needle: &'static str,
}

struct Region {
    /// First line (0-based) of the attached doc/attribute block.
    start: usize,
    /// The declaration line.
    item: usize,
    /// Last line of the item (closing brace, or the `;` line for a const).
    end: usize,
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

fn declares(line: &str, needle: &str) -> bool {
    let rest = strip_visibility(line.trim_start());
    match rest.strip_prefix(needle) {
        Some(tail) => matches!(
            tail.chars().next(),
            Some('(') | Some('<') | Some(':') | Some(' ') | Some('{') | Some(';')
        ),
        None => false,
    }
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

/// `[start, end]` line range of the column-0 `impl` block whose header
/// contains `scope`; the block ends at the next line that is exactly `}`.
fn impl_scope(file: &str, lines: &[String], scope: &str) -> (usize, usize) {
    let headers: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("impl") && l.contains(scope))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        headers.len(),
        1,
        "{file}: expected exactly one column-0 `impl` header containing `{scope}`, found lines {:?} (1-based: {:?})",
        headers,
        headers.iter().map(|i| i + 1).collect::<Vec<_>>()
    );
    let start = headers[0];
    let end = (start + 1..lines.len())
        .find(|&i| lines[i] == "}")
        .unwrap_or_else(|| panic!("{file}: impl block at line {} never closes", start + 1));
    (start, end)
}

fn resolve(site: &Site, lines: &[String]) -> Region {
    let (lo, hi) = match site.scope {
        Some(scope) => impl_scope(site.file, lines, scope),
        None => (0, lines.len() - 1),
    };
    let hits: Vec<usize> = (lo..=hi)
        .filter(|&i| declares(&lines[i], site.needle))
        .collect();
    assert_eq!(
        hits.len(),
        1,
        "{}: expected exactly one declaration `{}` in scope {:?}, found 1-based lines {:?}",
        site.file,
        site.needle,
        site.scope,
        hits.iter().map(|i| i + 1).collect::<Vec<_>>()
    );
    let item = hits[0];

    // Attached block: contiguous non-blank lines directly above the item.
    let mut start = item;
    while start > 0 && !lines[start - 1].trim().is_empty() {
        start -= 1;
    }

    // Item extent: a `;`-terminated declaration is one line, anything else
    // runs to the closing brace at the declaration's own indentation.
    let end = if lines[item].trim_end().ends_with(';') {
        item
    } else {
        let indent = " ".repeat(indent_of(&lines[item]));
        let close = format!("{indent}}}");
        let close_semi = format!("{indent}}};");
        (item + 1..lines.len())
            .find(|&i| lines[i] == close || lines[i] == close_semi)
            .unwrap_or_else(|| {
                panic!(
                    "{}: `{}` at line {} has no closing brace at indent {}",
                    site.file,
                    site.needle,
                    item + 1,
                    indent.len()
                )
            })
    };

    Region { start, item, end }
}

/// `None` when the site carries a canonical marker, otherwise a one-line
/// description of what was found instead.
fn unmarked_report(site: &Site) -> Option<String> {
    let lines = load(site.file);
    let region = resolve(site, &lines);
    let span = &lines[region.start..=region.end];
    if span.iter().any(|l| is_marker(l)) {
        return None;
    }
    let near_misses: Vec<String> = span
        .iter()
        .enumerate()
        .filter(|(_, l)| is_unmarked_blackbird_comment(l))
        .map(|(off, l)| {
            let text: String = l.trim().chars().take(70).collect();
            format!("line {}: \"{}\"", region.start + off + 1, text)
        })
        .collect();
    Some(format!(
        "{}:{} `{}` (lines {}-{}) has no `Blackbird ... (re-apply on bump)` comment; non-canonical Blackbird comments inside it: {:?}",
        site.file,
        region.item + 1,
        site.needle,
        region.start + 1,
        region.end + 1,
        near_misses
    ))
}

fn assert_patch_marked(patch: &str, sites: &[Site]) {
    assert!(!sites.is_empty(), "patch `{patch}` lists no sites");
    let missing: Vec<String> = sites.iter().filter_map(unmarked_report).collect();
    assert_eq!(
        missing,
        Vec::<String>::new(),
        "patch `{patch}`: {} of {} vendored site(s) carry no canonical `Blackbird fix (re-apply on bump)` marker, \
         so a re-vendor of the crate would drop this fix silently",
        missing.len(),
        sites.len()
    );
}

const TERM: &str = "vendor/alacritty_terminal/src/term/mod.rs";
const CELL: &str = "vendor/alacritty_terminal/src/term/cell.rs";
const GRID: &str = "vendor/alacritty_terminal/src/grid/mod.rs";
const RESIZE: &str = "vendor/alacritty_terminal/src/grid/resize.rs";
const ANSI: &str = "vendor/vte/src/ansi.rs";
const HANDLER_IMPL: &str = "Handler for Term<T>";
const TERM_IMPL: &str = "impl<T> Term<T> {";

// ---------------------------------------------------------------------------
// Rig: the predicate and the locator are sound
// ---------------------------------------------------------------------------

#[test]
fn marker_predicate_matches_the_repo_style_and_nothing_looser() {
    let cases: [(&str, bool); 11] = [
        (
            "    /// Blackbird fix (re-apply on bump): upstream stores whatever",
            true,
        ),
        (
            "        // Blackbird fix (re-apply on bump): capture the slot now.",
            true,
        ),
        (
            "    /// Blackbird addition (re-apply on bump): flip the OSC 52 policy",
            true,
        ),
        (
            "    /// Blackbird fork change (re-apply on bump): the second field is",
            true,
        ),
        // Pre-campaign / ad-hoc spellings that give a re-vendor nothing to grep for.
        (
            "/// Blackbird fix: upstream stores whatever OSC 0/2 delivers (vte allows",
            false,
        ),
        (
            "            // BLACKBIRD PATCH (emoji-presentation / keycap width parity).",
            false,
        ),
        (
            "            // wrap. Re-apply this patch on any alacritty_terminal bump.",
            false,
        ),
        (
            "        // Blackbird fork addition (audit S5-004/S5-005): count every",
            false,
        ),
        // The phrase alone, or in the wrong order, is not a Blackbird marker.
        ("    // upstream quirk (re-apply on bump)", false),
        ("    // (re-apply on bump) Blackbird", false),
        // Code (a string literal) is not a comment.
        ("    let s = \"Blackbird fix (re-apply on bump)\";", false),
    ];
    for (line, want) in cases {
        assert_eq!(is_marker(line), want, "is_marker({line:?})");
    }
}

#[test]
fn detection_recognises_markers_that_already_exist_in_the_vendored_tree() {
    // These three carry the canonical marker today (and must keep doing so).
    // If the locator or predicate were broken, nothing else in this file
    // could be trusted: a vacuous "never found a marker anywhere" would make
    // every per-patch test below fail for the wrong reason.
    let controls = [
        Site {
            file: CELL,
            scope: None,
            needle: "fn bounded",
        },
        Site {
            file: CELL,
            scope: Some("impl Cell {"),
            needle: "fn push_zerowidth",
        },
        Site {
            file: ANSI,
            scope: None,
            needle: "fn abort_string",
        },
    ];
    for site in &controls {
        let lines = load(site.file);
        let region = resolve(site, &lines);
        assert!(
            region.end > region.item,
            "{}: `{}` resolved to a one-line region ({}..{}); the locator lost its body",
            site.file,
            site.needle,
            region.item + 1,
            region.end + 1
        );
        let marked = lines[region.start..=region.end]
            .iter()
            .filter(|l| is_marker(l))
            .count();
        assert!(
            marked >= 1,
            "{}: control `{}` (lines {}-{}) should carry a canonical marker, saw {marked}",
            site.file,
            site.needle,
            region.start + 1,
            region.end + 1
        );
    }
}

// ---------------------------------------------------------------------------
// One test per patch added since v0.9.3
// ---------------------------------------------------------------------------

#[test]
fn display_offset_clamp_carries_reapply_marker() {
    // Region scrolls with a top margin below row 0 must not bump
    // `display_offset` past `history_size()`.
    assert_patch_marked(
        "display_offset clamp",
        &[Site {
            file: GRID,
            scope: None,
            needle: "fn scroll_up",
        }],
    );
}

#[test]
fn title_cap_carries_reapply_marker() {
    assert_patch_marked(
        "title cap",
        &[
            Site {
                file: TERM,
                scope: None,
                needle: "const TITLE_MAX_BYTES",
            },
            Site {
                file: TERM,
                scope: Some(HANDLER_IMPL),
                needle: "fn set_title",
            },
        ],
    );
}

#[test]
fn zerowidth_cap_carries_reapply_marker() {
    assert_patch_marked(
        "zero-width cap",
        &[
            Site {
                file: CELL,
                scope: None,
                needle: "const ZEROWIDTH_MAX",
            },
            Site {
                file: CELL,
                scope: Some("impl Cell {"),
                needle: "fn push_zerowidth",
            },
        ],
    );
}

#[test]
fn dch_clamp_carries_reapply_marker() {
    assert_patch_marked(
        "DCH clamp",
        &[Site {
            file: TERM,
            scope: Some(HANDLER_IMPL),
            needle: "fn delete_chars",
        }],
    );
}

#[test]
fn ed1_fix_carries_reapply_marker() {
    assert_patch_marked(
        "ED 1 fix",
        &[Site {
            file: TERM,
            scope: Some(HANDLER_IMPL),
            needle: "fn clear_screen",
        }],
    );
}

#[test]
fn osc8_budget_carries_reapply_marker() {
    assert_patch_marked(
        "OSC 8 live-byte budget",
        &[
            Site {
                file: CELL,
                scope: None,
                needle: "const HYPERLINK_LIVE_MAX",
            },
            Site {
                file: CELL,
                scope: None,
                needle: "struct HyperlinkInner",
            },
            Site {
                file: TERM,
                scope: Some(HANDLER_IMPL),
                needle: "fn set_hyperlink",
            },
        ],
    );
}

/// The `Term` fields behind the OSC 8 budget. A field is not an item `Site` can resolve (its
/// declaration and its `Term::new` initialiser share a name), so each of the two lines is
/// checked directly: a marker on it or in the contiguous non-blank lines above it.
#[test]
fn osc8_budget_term_fields_carry_reapply_marker() {
    let lines = load(TERM);
    for field in [
        "hyperlink_live",
        "hyperlink_live_max",
        "hyperlink_over_budget",
    ] {
        let sites: Vec<usize> = (0..lines.len())
            .filter(|&i| {
                lines[i]
                    .trim_start()
                    .strip_prefix(field)
                    .is_some_and(|tail| tail.starts_with(':'))
            })
            .collect();
        assert_eq!(
            sites.len(),
            2,
            "{TERM}: expected `{field}` once in `struct Term` and once in its initialiser, \
             found 1-based lines {:?}",
            sites.iter().map(|i| i + 1).collect::<Vec<usize>>()
        );
        for item in sites {
            let mut start = item;
            while start > 0 && !lines[start - 1].trim().is_empty() {
                start -= 1;
            }
            assert!(
                lines[start..=item].iter().any(|l| is_marker(l)),
                "{TERM}:{} `{field}` has no `Blackbird fix (re-apply on bump)` comment in its \
                 attached block (lines {}-{}), so a re-vendor would drop the OSC 8 budget silently",
                item + 1,
                start + 1,
                item + 1
            );
        }
    }
}

#[test]
fn kitty_set_mode_carries_reapply_marker() {
    assert_patch_marked(
        "kitty `CSI = flags ; mode u` edits the top-of-stack entry",
        &[Site {
            file: TERM,
            scope: Some(HANDLER_IMPL),
            needle: "fn set_keyboard_mode",
        }],
    );
}

#[test]
fn reflow_cursor_wide_char_fix_carries_reapply_marker() {
    assert_patch_marked(
        "column-shrink reflow cursor / wide char",
        &[Site {
            file: RESIZE,
            scope: None,
            needle: "fn shrink_columns",
        }],
    );
}

#[test]
fn vs16_at_column_zero_fix_carries_reapply_marker() {
    // `glyph_end` is only trustworthy while nothing but `input` has touched the
    // cursor's neighbourhood. Dropping any one of the four invalidations still
    // compiles, and re-opens the bug: after a scroll, resize or screen swap the
    // cursor keeps its Point, a lone mark finds `glyph_end` still matching, and
    // promotes whatever cell is now left of the cursor. Each site must keep its
    // own marker so a re-vendor's `grep "re-apply on bump"` finds it.
    assert_patch_marked(
        "lone VS16 / keycap mark at column 0",
        &[
            Site {
                file: TERM,
                scope: Some(HANDLER_IMPL),
                needle: "fn input",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn resize",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn swap_alt",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn scroll_down_relative",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn scroll_up_relative",
            },
        ],
    );
}

#[test]
fn emoji_cluster_width_fix_carries_reapply_marker() {
    // ZWJ sequences and skin-tone modifiers advance the cursor by the width of
    // the whole cluster (2 columns, as `string-width` measures it), not the sum
    // of their parts. Every helper that makes up the fix keeps its own marker,
    // and `Handler::input` (which calls them) is covered by the VS16 test above.
    assert_patch_marked(
        "emoji ZWJ / skin-tone cluster width",
        &[
            Site {
                file: TERM,
                scope: None,
                needle: "fn is_pictographic",
            },
            Site {
                file: TERM,
                scope: None,
                needle: "fn is_emoji_modifier",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn prev_glyph_column",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn can_widen_prev_glyph",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn widen_prev_glyph",
            },
            Site {
                file: TERM,
                scope: Some(TERM_IMPL),
                needle: "fn joins_emoji_cluster",
            },
        ],
    );
}

// ---------------------------------------------------------------------------
// Name shadowing between inherent `Term<T>` methods and trait methods
// ---------------------------------------------------------------------------

/// `(1-based line, name)` of every item-level `fn` (exactly four spaces of
/// indentation, i.e. directly inside an `impl` or `trait` body) in the
/// inclusive line range.
fn method_names(lines: &[String], lo: usize, hi: usize) -> Vec<(usize, String)> {
    (lo..=hi)
        .filter_map(|i| {
            let line = &lines[i];
            if indent_of(line) != 4 {
                return None;
            }
            let rest = strip_visibility(line.trim_start()).strip_prefix("fn ")?;
            let name: String = rest
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if name.is_empty() {
                None
            } else {
                Some((i + 1, name))
            }
        })
        .collect()
}

/// Methods declared in `pub trait <name> { ... }` (ends at the first line
/// that is exactly `}`).
fn trait_methods(file: &str, trait_name: &str) -> Vec<(usize, String)> {
    let lines = load(file);
    let header = format!("pub trait {trait_name}");
    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with(&header))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        starts.len(),
        1,
        "{file}: expected exactly one `{header}`, found {starts:?}"
    );
    let lo = starts[0];
    let hi = (lo + 1..lines.len())
        .find(|&i| lines[i] == "}")
        .unwrap_or_else(|| panic!("{file}: trait {trait_name} never closes"));
    method_names(&lines, lo, hi)
}

/// Methods of every INHERENT `impl ... Term<..>` block (column-0 header
/// containing `Term<` and no ` for `) in `file`.
fn inherent_term_methods(file: &str) -> Vec<(usize, String)> {
    let lines = load(file);
    let mut out = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if l.starts_with("impl") && l.contains("Term<") && !l.contains(" for ") {
            let hi = (i + 1..lines.len())
                .find(|&j| lines[j] == "}")
                .unwrap_or_else(|| panic!("{file}: impl at line {} never closes", i + 1));
            out.extend(method_names(&lines, i, hi));
        }
    }
    out
}

#[test]
fn no_inherent_term_method_shadows_a_trait_method() {
    let mut inherent: Vec<(String, usize, String)> = Vec::new();
    for file in [TERM, "vendor/alacritty_terminal/src/term/search.rs"] {
        for (line, name) in inherent_term_methods(file) {
            inherent.push((file.to_owned(), line, name));
        }
    }

    let handler = trait_methods(ANSI, "Handler");
    let dimensions = trait_methods(GRID, "Dimensions");

    // Rig preconditions: the parse saw real, plausible method sets.
    let has = |set: &[(usize, String)], n: &str| set.iter().any(|(_, m)| m == n);
    assert!(
        handler.len() >= 50 && has(&handler, "input") && has(&handler, "clear_screen"),
        "parsed only {} Handler methods; the trait moved or the parser broke",
        handler.len()
    );
    assert!(
        dimensions.len() >= 3 && has(&dimensions, "screen_lines"),
        "parsed only {} Dimensions methods; the trait moved or the parser broke",
        dimensions.len()
    );
    assert!(
        inherent.len() >= 20
            && inherent.iter().any(|(_, _, n)| n == "swap_alt")
            && inherent.iter().any(|(_, _, n)| n == "scroll_display"),
        "parsed only {} inherent Term methods; an impl block moved or the parser broke",
        inherent.len()
    );

    let mut shadows: Vec<String> = Vec::new();
    for (file, line, name) in &inherent {
        for (trait_name, methods) in [("Handler", &handler), ("Dimensions", &dimensions)] {
            if has(methods, name) {
                shadows.push(format!(
                    "{file}:{line} inherent `Term::{name}` shadows `{trait_name}::{name}`"
                ));
            }
        }
    }
    shadows.sort();
    assert_eq!(
        shadows,
        Vec::<String>::new(),
        "inherent methods that hide a same-named trait method (a `self.{{name}}(..)` call inside the trait impl \
         resolves to the inherent one; rename the inherent method so the forwarding is explicit)"
    );
}
