//! Pins the `Sync=` capability advertised in the bundled `kitty.terminfo`
//! file. vte 0.15 (the parser inside alacritty_terminal 0.26) honours the
//! DEC private mode 2026 form (`\x1b[?2026h` / `\x1b[?2026l`) for
//! synchronized output but does NOT recognize the legacy kitty DCS form
//! (`\EP=1s\E\\` / `\EP=2s\E\\`). Whichever form terminfo advertises is
//! the form TUIs will emit. If terminfo says "kitty DCS", apps emit DCS
//! and BBCore drops it — no buffering, visible flicker on partial frame
//! updates.
//!
//! The fix is to advertise the conditional `\E[?2026h` / `\E[?2026l` form
//! that vte actually understands. This test is a build-time guard against
//! a future terminfo regression that re-introduced the kitty-DCS form.
//!
//! Test is BLIND against the implementation — it asserts the literal
//! capability string, not whatever some helper would compute.

use std::fs;
use std::path::PathBuf;

/// Resolve the bundled kitty terminfo source relative to the Cargo manifest
/// directory (i.e., `core/`). Hardcoding `/Users/connor/...` would only pass
/// on one developer's machine and break CI; `CARGO_MANIFEST_DIR` is set by
/// Cargo at build time and points at the crate root regardless of where the
/// workspace lives. Same idiom as `core/tests/header_generated.rs`.
fn terminfo_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("CARGO_MANIFEST_DIR (core/) must have a parent (workspace root)")
        .join("Sources/Blackbird/Resources/Terminfo/kitty.terminfo")
}

#[test]
fn terminfo_advertises_dec_2026_sync_not_legacy_kitty_dcs() {
    let path = terminfo_path();
    let contents = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read terminfo file at {}: {}", path.display(), e));

    // Required: the conditional DEC mode 2026 form. `%?` ... `%t` ... `%e`
    // ... `%;` is terminfo's if/then/else; param 1 == 1 emits BSU, else
    // emits ESU. This is the form vte 0.15 parses.
    let dec_form = "Sync=%?%p1%{1}%=%t\\E[?2026h%e\\E[?2026l%;";
    assert!(
        contents.contains(dec_form),
        "terminfo {} must advertise the DEC mode 2026 Sync= form. \
         Expected substring: {:?}\nFile contents:\n{}",
        path.display(),
        dec_form,
        contents
    );

    // Forbidden: the legacy kitty DCS form. vte 0.15 drops this on the
    // floor; if terminfo continues to advertise it, sync is broken
    // even though the parser supports the DEC form.
    let legacy_form = "Sync=\\EP=%p1%ds\\E\\\\";
    assert!(
        !contents.contains(legacy_form),
        "terminfo {} must NOT advertise the legacy kitty DCS Sync= form \
         (vte 0.15 doesn't parse it). Forbidden substring: {:?}\nFile \
         contents:\n{}",
        path.display(),
        legacy_form,
        contents
    );
}
