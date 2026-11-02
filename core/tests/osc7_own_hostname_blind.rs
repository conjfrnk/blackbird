//! Blind regression tests for settings-persistence-3: an OSC 7 URL whose
//! authority is THIS machine's own hostname must be accepted and reported
//! as a `CwdChanged` event, exactly like the empty-authority and
//! `localhost` forms already are.
//!
//! Author had no access to the implementation. Contract consulted:
//!   * `core/include/BBCore.h` (`BB_EVENT_KIND_CWD_CHANGED`: a local
//!     filesystem path decoded from an OSC 7 `file://` URL),
//!   * the sibling suite `osc7_parsing.rs` (empty / `localhost` accepted,
//!     non-file scheme dropped, host + scheme case-insensitive per
//!     RFC 3986, percent-escapes decoded), and
//!   * how real shells emit OSC 7.
//!
//! Convention under test
//! ---------------------
//! Shells report the cwd as `file://<gethostname()><percent-escaped-pwd>`:
//!   * fish (4.x built-in `__fish_update_cwd_osc`) always prints
//!     `ESC ] 7 ; file://$hostname$PWD BEL`,
//!   * Apple's Terminal.app `update_terminal_cwd` snippet, VTE's
//!     `vte.sh`, and the kitty / WezTerm / Ghostty shell-integration
//!     snippets all embed the local hostname the same way.
//!
//! A terminal is therefore expected to treat "authority == this machine's
//! hostname" as a LOCAL path (that is the whole point of carrying the
//! host: it lets a terminal distinguish its own machine from a remote one).
//!
//! Observed bug (pre-fix): the core only accepts an empty authority or
//! `localhost`, so every OSC 7 carrying the real hostname is silently
//! dropped. No `CwdChanged` fires, `lastKnownCwd` is never set, the
//! title-bar proxy icon never appears, and new-tab cwd inheritance via
//! OSC 7 is dead for fish and for the Apple-provided snippet.
//!
//! The machine's own name is what `gethostname(3)` returns (the same call the
//! shells make); the binary replaces it with a fixed name so the tests do not
//! depend on the machine / CI runner they run on.
//!
//! Cost: each `drive()` creates one 80x24 terminal (1 920 cells), feeds a
//! few short escape sequences and frees it. Microseconds, a few tens of KiB.

use std::ffi::c_void;
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;

use blackbird_core::*;

// ---------- harness (same shape as osc7_parsing.rs) ----------------

struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = unsafe { &*(ctx as *const Sink) };
    let bytes = if ev.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len).to_vec() }
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

fn drive(bytes: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        bb_term_input(term, bytes.as_ptr(), bytes.len());
        bb_term_free(term);
    }
    sink.events.into_inner().unwrap()
}

/// All `CwdChanged` payloads, in order, rendered lossily for messages.
fn cwd_payloads(events: &[(u32, Vec<u8>)]) -> Vec<Vec<u8>> {
    events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .map(|(_, p)| p.clone())
        .collect()
}

fn show(payloads: &[Vec<u8>]) -> Vec<String> {
    payloads
        .iter()
        .map(|p| String::from_utf8_lossy(p).into_owned())
        .collect()
}

// ---------- this machine's name ------------------------------------

/// The machine name every test here runs on. A CI runner's real hostname is
/// arbitrary (it may be `localhost`, empty, or contain characters that are
/// not URL-safe), so this binary REPLACES `gethostname(3)`: the
/// `#[no_mangle]` function below is linked in front of libc's, and the core's
/// own `gethostname` call sees exactly this name.
const MACHINE_NAME: &str = "bb-own-host-test.local";

/// POSIX `gethostname`: copies at most `len - 1` bytes plus a NUL.
///
/// # Safety
/// `name` must point to at least `len` writable bytes, as for libc.
#[no_mangle]
pub unsafe extern "C" fn gethostname(name: *mut c_char, len: usize) -> c_int {
    if name.is_null() || len == 0 {
        return -1;
    }
    let n = MACHINE_NAME.len().min(len - 1);
    std::ptr::copy_nonoverlapping(MACHINE_NAME.as_ptr(), name as *mut u8, n);
    *name.add(n) = 0;
    0
}

/// The machine's own hostname exactly as shells see it (`gethostname(3)`).
fn own_hostname() -> String {
    MACHINE_NAME.to_string()
}

fn expect_single_cwd(events: &[(u32, Vec<u8>)], what: &str) -> Vec<u8> {
    let cwds = cwd_payloads(events);
    assert_eq!(
        cwds.len(),
        1,
        "{what}: expected exactly one CwdChanged event, got {} {:?}",
        cwds.len(),
        show(&cwds)
    );
    cwds.into_iter().next().unwrap()
}

// ---------- the bug ------------------------------------------------

/// The literal fish shape: `ESC ] 7 ; file://<hostname>/<pwd> BEL`.
#[test]
fn osc7_own_hostname_bel_terminated_emits_cwd_changed() {
    let host = own_hostname();

    // Control (rig sanity, passes on pre-fix code too): the identical path
    // with an EMPTY authority fires, so the harness really observes
    // CwdChanged events and a missing event below is the hostname's fault.
    let control = drive(b"\x1b]7;file:///private/tmp\x07");
    assert_eq!(
        show(&cwd_payloads(&control)),
        vec!["/private/tmp".to_string()],
        "control: empty-authority OSC 7 must fire CwdChanged (harness precondition)"
    );

    let seq = format!("\x1b]7;file://{host}/private/tmp\x07");
    let events = drive(seq.as_bytes());
    let cwds = cwd_payloads(&events);
    assert_eq!(
        show(&cwds),
        vec!["/private/tmp".to_string()],
        "OSC 7 carrying this machine's own hostname {host:?} must fire CwdChanged \
         with the decoded path; measured payloads = {:?} (all events = {} total)",
        show(&cwds),
        events.len()
    );
}

/// Same, with the ST (`ESC \`) terminator and a percent-escaped path, the
/// way Apple's Terminal snippet / VTE / `string escape --style=url` emit it.
#[test]
fn osc7_own_hostname_st_terminated_percent_escaped_path_decodes() {
    let host = own_hostname();
    let seq = format!("\x1b]7;file://{host}/Users/me/My%20Project%C3%A9\x1b\\");
    let events = drive(seq.as_bytes());
    let payload = expect_single_cwd(
        &events,
        &format!("own-hostname {host:?} + ST terminator + percent-escaped path"),
    );
    assert_eq!(
        String::from_utf8_lossy(&payload),
        "/Users/me/My Projecté",
        "own-hostname OSC 7 must decode percent escapes just like the empty/localhost forms"
    );
}

/// fish re-emits OSC 7 on every `cd`; each one must update the cwd.
#[test]
fn osc7_own_hostname_successive_cds_each_report_their_cwd() {
    let host = own_hostname();
    let mut seq = Vec::new();
    seq.extend_from_slice(format!("\x1b]7;file://{host}/private/tmp\x07").as_bytes());
    seq.extend_from_slice(format!("\x1b]7;file://{host}/private/var\x07").as_bytes());
    let events = drive(&seq);
    let cwds = show(&cwd_payloads(&events));
    assert_eq!(
        cwds,
        vec!["/private/tmp".to_string(), "/private/var".to_string()],
        "two own-hostname OSC 7 reports (cd /private/tmp; cd /private/var) must yield \
         two CwdChanged events in order; measured = {cwds:?}"
    );
}

/// Hostnames are case-insensitive (RFC 3986 section 3.2.2; the sibling suite
/// already requires `File://LocalHost/...` to be accepted), so the own-name
/// match must not depend on the case the shell happened to print.
#[test]
fn osc7_own_hostname_match_is_case_insensitive() {
    let host = own_hostname();
    for variant in [host.to_ascii_uppercase(), host.to_ascii_lowercase()] {
        let seq = format!("\x1b]7;file://{variant}/private/tmp\x07");
        let events = drive(seq.as_bytes());
        let cwds = show(&cwd_payloads(&events));
        assert_eq!(
            cwds,
            vec!["/private/tmp".to_string()],
            "own hostname {host:?} written as {variant:?} must still be recognised as \
             this machine; measured CwdChanged payloads = {cwds:?}"
        );
    }
}

/// The scheme is also case-insensitive; combine with the own hostname and
/// confirm the PATH keeps its case (POSIX paths are case-sensitive).
#[test]
fn osc7_own_hostname_with_uppercase_scheme_preserves_path_case() {
    let host = own_hostname();
    let seq = format!("\x1b]7;FILE://{host}/Users/Foo/Bar\x07");
    let events = drive(seq.as_bytes());
    let payload = expect_single_cwd(&events, "FILE:// scheme + own hostname");
    assert_eq!(
        String::from_utf8_lossy(&payload),
        "/Users/Foo/Bar",
        "path case must be preserved verbatim for an own-hostname OSC 7"
    );
}

/// Byte-at-a-time delivery (PTY reads split sequences arbitrarily) must not
/// change the outcome for the own-hostname form.
#[test]
fn osc7_own_hostname_survives_byte_fragmented_input() {
    let host = own_hostname();
    let seq = format!("\x1b]7;file://{host}/private/tmp\x07");
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        for &byte in seq.as_bytes() {
            bb_term_input(term, &byte, 1);
        }
        bb_term_free(term);
    }
    let events = sink.events.into_inner().unwrap();
    let cwds = show(&cwd_payloads(&events));
    assert_eq!(
        cwds,
        vec!["/private/tmp".to_string()],
        "byte-fragmented own-hostname OSC 7 must fire exactly one CwdChanged; measured = {cwds:?}"
    );
}

// ---------- over-correction guard (passes before AND after the fix) ----

/// Accepting the own hostname must not turn into accepting ANY hostname: a
/// URL naming a different machine describes a path on THAT machine and must
/// not be reported as a local cwd (BBCore.h: "local filesystem path").
#[test]
fn osc7_foreign_hostname_is_still_dropped() {
    let host = own_hostname();
    let foreign_names = [
        "some-other-machine.invalid".to_string(),
        format!("not-{host}.invalid"),
    ];
    for foreign in &foreign_names {
        let seq = format!("\x1b]7;file://{foreign}/private/tmp\x07");
        let events = drive(seq.as_bytes());
        let cwds = show(&cwd_payloads(&events));
        assert!(
            cwds.is_empty(),
            "OSC 7 naming foreign host {foreign:?} (this machine is {host:?}) must NOT \
             produce a local CwdChanged; measured payloads = {cwds:?}"
        );
    }
}
