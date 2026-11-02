//! Blind regression tests for OSC7-b: OSC 7 acceptance of THIS machine's own
//! hostname must be correct for EVERY possible local hostname, must not
//! depend on the machine the tests run on, and a rejected OSC 7 must stay
//! cheap and leave a one-shot breadcrumb.
//!
//! Author had no access to the implementation. Contract consulted:
//!   * `core/include/BBCore.h` (`BB_EVENT_KIND_CWD_CHANGED`: emitted for
//!     scheme `file` with an empty authority, `localhost`, or this
//!     machine's own hostname; anything else names ANOTHER machine),
//!   * the sibling suites `osc7_parsing.rs` / `osc7_own_hostname_blind.rs`
//!     (host and scheme are case-insensitive per RFC 3986, percent-escapes
//!     are decoded, a foreign host is dropped),
//!   * how shells and macOS actually behave: fish / Apple's Terminal
//!     snippet / VTE print `file://<hostname><pwd>`; macOS flips
//!     `gethostname()` between `foo` and `foo.local`; hostnames compare
//!     case-insensitively; fish escapes the host with `--style=url`.
//!
//! Environment independence
//! ------------------------
//! CI runners have arbitrary hostnames, and a hostname test that reads the
//! real `gethostname(3)` either panics on an unlucky name or silently never
//! exercises the interesting shapes (a name that starts with `localhost`, an
//! upper-case name, ...). This file therefore REPLACES `gethostname` for the
//! whole test binary: the `#[no_mangle] gethostname` below is linked in front
//! of libc's, so the core's own `gethostname(3)` call (whenever it makes one)
//! sees exactly the name the test chose. The replacement also COUNTS its
//! calls, which makes "a foreign-host flood must not pay a syscall per
//! sequence" directly measurable. The rig is proven live by
//! `rig_control_*` (a made-up name only the replacement can return).
//!
//! The breadcrumb test re-executes this test binary as a child process with
//! `--nocapture` (libtest swallows `eprintln!` of the test thread otherwise)
//! and inspects the child's real stderr.
//!
//! Cost: every check creates an 80x24 terminal (1 920 cells, empty
//! scrollback), feeds one short sequence and frees it; about 500 such
//! terminals in total plus two floods of 600 x ~45 bytes (about 55 KiB of
//! input). Milliseconds and a few MiB at most.

use std::ffi::c_void;
use std::os::raw::{c_char, c_int};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

use blackbird_core::*;

// ---------- the replaced gethostname(3) ----------------------------

/// What the core's `gethostname` returns. `None` makes it fail (`-1`).
static FAKE_HOST: Mutex<Option<Vec<u8>>> = Mutex::new(None);
/// Number of times the core (or anything else in this binary) called it.
static HOSTNAME_CALLS: AtomicUsize = AtomicUsize::new(0);
/// Serialises every test that touches `FAKE_HOST` / `HOSTNAME_CALLS`
/// (libtest runs tests on parallel threads of one process).
static RIG: Mutex<()> = Mutex::new(());

/// POSIX `gethostname`: copies at most `len - 1` bytes plus a NUL.
///
/// # Safety
/// `name` must point to at least `len` writable bytes, as for libc.
#[no_mangle]
pub unsafe extern "C" fn gethostname(name: *mut c_char, len: usize) -> c_int {
    HOSTNAME_CALLS.fetch_add(1, Ordering::SeqCst);
    let guard = lock(&FAKE_HOST);
    match guard.as_ref() {
        None => -1,
        Some(host) => {
            if name.is_null() || len == 0 {
                return -1;
            }
            let n = host.len().min(len - 1);
            std::ptr::copy_nonoverlapping(host.as_ptr(), name as *mut u8, n);
            *name.add(n) = 0;
            0
        }
    }
}

fn lock<T>(m: &'static Mutex<T>) -> MutexGuard<'static, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn set_machine_name(name: Option<&str>) {
    let mut g = lock(&FAKE_HOST);
    *g = name.map(|n| n.as_bytes().to_vec());
}

fn hostname_calls() -> usize {
    HOSTNAME_CALLS.load(Ordering::SeqCst)
}

// ---------- harness (same shape as osc7_own_hostname_blind.rs) ------

struct Sink {
    cwds: Mutex<Vec<Vec<u8>>>,
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != BBEventKind::CwdChanged as u32 {
        return;
    }
    let sink = unsafe { &*(ctx as *const Sink) };
    let bytes = if ev.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len).to_vec() }
    };
    sink.cwds.lock().unwrap().push(bytes);
}

fn new_sink() -> Sink {
    Sink {
        cwds: Mutex::new(Vec::new()),
    }
}

fn osc7(authority: &str) -> Vec<u8> {
    format!("\x1b]7;file://{authority}/tmp/x\x07").into_bytes()
}

fn lossy(payloads: &[Vec<u8>]) -> Vec<String> {
    payloads
        .iter()
        .map(|p| String::from_utf8_lossy(p).into_owned())
        .collect()
}

/// A brand-new terminal on a machine called `machine` (`None` = the
/// `gethostname` call fails) receives one OSC 7 with the given authority.
/// Returns the decoded `CwdChanged` payloads.
fn cwds_on_machine(machine: Option<&str>, authority: &str) -> Vec<String> {
    set_machine_name(machine);
    let sink = new_sink();
    let seq = osc7(authority);
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const Sink as *mut c_void);
        bb_term_input(term, seq.as_ptr(), seq.len());
        bb_term_free(term);
    }
    let cwds = sink.cwds.lock().unwrap().clone();
    lossy(&cwds)
}

// ---------- hostname form generation --------------------------------

/// Percent-encodes `s`. `all == false` keeps RFC 3986 unreserved bytes
/// (`A-Za-z0-9-._~`) and escapes the rest (fish `--style=url`);
/// `all == true` escapes every byte. Hex digits are upper-case unless
/// `lower_hex`.
fn pct(s: &str, all: bool, lower_hex: bool) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        let keep = !all && (b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~'));
        if keep {
            out.push(b as char);
        } else if lower_hex {
            out.push_str(&format!("%{b:02x}"));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn strip_local(name: &str) -> &str {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".local") {
        &name[..name.len() - ".local".len()]
    } else {
        name
    }
}

/// The `.local` (mDNS) twin of a name: strip it when present, add it when not.
fn toggle_local(name: &str) -> String {
    let stripped = strip_local(name);
    if stripped.len() != name.len() {
        stripped.to_string()
    } else {
        format!("{name}.local")
    }
}

struct Machine {
    name: &'static str,
    /// May the raw (un-escaped) name appear in a URL authority?
    raw_ok: bool,
}

/// Every spelling of this machine's own name that a shell / macOS could put
/// in an OSC 7 authority: {name, `.local` twin} x {as-is, UPPER, lower} x
/// {raw, percent-escaped, fully percent-escaped (lower-case hex)}.
fn own_forms(m: &Machine) -> Vec<(String, String)> {
    let mut forms: Vec<(String, String)> = Vec::new();
    let bases = [
        ("name", m.name.to_string()),
        ("name.local-twin", toggle_local(m.name)),
    ];
    for (base_label, base) in bases.iter() {
        let cases = [
            ("as-is", base.clone()),
            ("UPPER", base.to_ascii_uppercase()),
            ("lower", base.to_ascii_lowercase()),
        ];
        for (case_label, text) in cases.iter() {
            let mut encodings: Vec<(&str, String)> = Vec::new();
            if m.raw_ok {
                encodings.push(("raw", text.clone()));
            }
            encodings.push(("percent-escaped", pct(text, false, false)));
            encodings.push(("fully-percent-escaped", pct(text, true, true)));
            for (enc_label, authority) in encodings {
                if forms.iter().any(|(_, a)| *a == authority) {
                    continue;
                }
                forms.push((format!("{base_label}/{case_label}/{enc_label}"), authority));
            }
        }
    }
    forms
}

/// Authorities that name some OTHER machine, whatever this machine is called.
fn foreign_forms(m: &Machine) -> Vec<(String, String)> {
    let core = strip_local(m.name).to_string();
    let enc = |s: String| -> String {
        if m.raw_ok {
            s
        } else {
            pct(&s, false, false)
        }
    };
    vec![
        (
            "unrelated host".to_string(),
            "other-host.example.com".to_string(),
        ),
        ("not-<name>".to_string(), enc(format!("not-{core}"))),
        ("<name>2".to_string(), enc(format!("{core}2"))),
        ("<name>2.local".to_string(), enc(format!("{core}2.local"))),
        ("x<name>".to_string(), enc(format!("x{core}"))),
        (
            "<name>.example.com".to_string(),
            enc(format!("{core}.example.com")),
        ),
        // Begins with the text `localhost` but is neither `localhost` nor
        // this machine.
        (
            "localhost-prefixed foreign".to_string(),
            "localhost-zzz-other".to_string(),
        ),
        (
            "localhost-dotted foreign".to_string(),
            "localhost.zzz-other.example".to_string(),
        ),
    ]
}

/// Authorities that are local no matter what the machine is called.
fn universal_local_forms() -> Vec<(&'static str, &'static str)> {
    vec![
        ("empty authority", ""),
        ("localhost", "localhost"),
        ("LOCALHOST", "LOCALHOST"),
        ("LocalHost", "LocalHost"),
    ]
}

/// Checks one machine name end to end; returns human-readable mismatches.
fn problems_for_machine(m: &Machine) -> Vec<String> {
    let mut problems = Vec::new();
    let expect = vec!["/tmp/x".to_string()];

    for (label, authority) in own_forms(m) {
        let got = cwds_on_machine(Some(m.name), &authority);
        if got != expect {
            problems.push(format!(
                "machine {:?}: OWN-host form [{label}] authority {authority:?} must fire exactly \
                 one CwdChanged(/tmp/x); measured {got:?}",
                m.name
            ));
        }
    }
    for (label, authority) in universal_local_forms() {
        let got = cwds_on_machine(Some(m.name), authority);
        if got != expect {
            problems.push(format!(
                "machine {:?}: local form [{label}] authority {authority:?} must fire exactly \
                 one CwdChanged(/tmp/x); measured {got:?}",
                m.name
            ));
        }
    }
    for (label, authority) in foreign_forms(m) {
        let got = cwds_on_machine(Some(m.name), &authority);
        if !got.is_empty() {
            problems.push(format!(
                "machine {:?}: FOREIGN host [{label}] authority {authority:?} must NOT fire \
                 CwdChanged; measured {got:?}",
                m.name
            ));
        }
    }
    problems
}

fn assert_no_problems(problems: Vec<String>, what: &str) {
    assert_eq!(
        problems.len(),
        0,
        "{what}: {} mismatch(es):\n  {}",
        problems.len(),
        problems.join("\n  ")
    );
}

// ---------- rig control (passes before AND after the fix) -----------

/// Proves the replaced `gethostname` is the one the core consults: a made-up
/// name no real machine has is accepted, its neighbour is not. Without this
/// the other tests could pass or fail for the wrong reason.
#[test]
fn rig_control_replaced_gethostname_is_what_the_core_sees() {
    let _rig = lock(&RIG);
    let fake = "bb-blind-rig-7f3a91";
    assert_eq!(
        cwds_on_machine(Some(fake), fake),
        vec!["/tmp/x".to_string()],
        "rig precondition: the core must see the replaced gethostname() = {fake:?}; \
         if this fails the interposition did not take effect and every other test here is meaningless"
    );
    assert_eq!(
        cwds_on_machine(Some(fake), "bb-blind-rig-7f3a92"),
        Vec::<String>::new(),
        "rig precondition: a neighbouring name that is NOT this machine must be dropped"
    );
}

// ---------- the bug: acceptance for every possible machine name -----

/// Ordinary and awkward machine names: plain, `.local`, mixed case, an
/// apostrophe, an underscore, a space, non-ASCII, and a maximum-length name.
/// No spelling of the machine's own name may be rejected, whichever form
/// `gethostname()` / scutil produced and whichever form the shell printed.
#[test]
fn every_spelling_of_own_hostname_is_accepted_for_ordinary_and_awkward_names() {
    let _rig = lock(&RIG);
    let long_name = format!(
        "{}.{}.{}.local",
        "a".repeat(63),
        "b".repeat(63),
        "c".repeat(63)
    );
    let long_name: &'static str = Box::leak(long_name.into_boxed_str());
    let machines = [
        Machine {
            name: "euler",
            raw_ok: true,
        },
        Machine {
            name: "euler.local",
            raw_ok: true,
        },
        Machine {
            name: "Connors-MacBook-Pro.local",
            raw_ok: true,
        },
        Machine {
            name: "MiXeD-Case-Host.Local",
            raw_ok: true,
        },
        Machine {
            name: "Connor's-MacBook.local",
            raw_ok: true,
        },
        Machine {
            name: "build_node_01",
            raw_ok: true,
        },
        Machine {
            name: "My Mac",
            raw_ok: false,
        },
        Machine {
            name: "m\u{e4}c.local",
            raw_ok: false,
        },
        Machine {
            name: long_name,
            raw_ok: true,
        },
    ];
    let mut problems = Vec::new();
    for m in &machines {
        problems.extend(problems_for_machine(m));
    }
    assert_no_problems(problems, "ordinary / awkward machine names");
}

/// THE reported shape: the machine's own name merely STARTS with the text
/// `localhost` (a dev box called `localhost-dev.local`). It is still a
/// specific machine, not the loopback name, so its own name must be accepted
/// in every spelling, `localhost` itself must stay accepted, and a different
/// `localhost-*` name must still be rejected.
#[test]
fn machine_whose_name_starts_with_localhost_gets_cwd_tracking() {
    let _rig = lock(&RIG);
    let machines = [
        Machine {
            name: "localhost-dev.local",
            raw_ok: true,
        },
        Machine {
            name: "localhost-dev",
            raw_ok: true,
        },
        Machine {
            name: "LocalHost-Dev",
            raw_ok: true,
        },
        Machine {
            name: "LOCALHOST-DEV.LOCAL",
            raw_ok: true,
        },
        Machine {
            name: "localhost.localdomain",
            raw_ok: true,
        },
        Machine {
            name: "localhost2",
            raw_ok: true,
        },
        Machine {
            name: "localhostile",
            raw_ok: true,
        },
    ];
    let mut problems = Vec::new();
    for m in &machines {
        problems.extend(problems_for_machine(m));
    }
    assert_no_problems(problems, "machine names that start with `localhost`");
}

/// The extreme cases of "every possible local hostname": the machine is
/// literally called `localhost` (any case), its name is empty, or
/// `gethostname()` fails outright. None of these may crash, the empty and
/// `localhost` authorities stay local, and everything else stays foreign.
#[test]
fn degenerate_machine_names_keep_local_forms_and_reject_foreign_hosts() {
    let _rig = lock(&RIG);
    let expect = vec!["/tmp/x".to_string()];
    let cases: [(&str, Option<&str>); 4] = [
        ("machine named localhost", Some("localhost")),
        ("machine named LOCALHOST", Some("LOCALHOST")),
        ("empty gethostname()", Some("")),
        ("failing gethostname()", None),
    ];
    let mut problems = Vec::new();
    for (case_label, machine) in cases.iter() {
        for (label, authority) in universal_local_forms() {
            let got = cwds_on_machine(*machine, authority);
            if got != expect {
                problems.push(format!(
                    "{case_label}: local form [{label}] authority {authority:?} must fire \
                     CwdChanged(/tmp/x); measured {got:?}"
                ));
            }
        }
        for authority in [
            "other-host.example.com",
            "localhost-zzz-other",
            "not-localhost",
            "x.local",
        ] {
            let got = cwds_on_machine(*machine, authority);
            if !got.is_empty() {
                problems.push(format!(
                    "{case_label}: foreign authority {authority:?} must NOT fire CwdChanged; \
                     measured {got:?}"
                ));
            }
        }
    }
    assert_no_problems(problems, "degenerate machine names");
}

/// A shell reads its hostname once at startup and keeps printing it; the
/// machine may be renamed afterwards. Both the name the terminal started with
/// and the current name must match, including when either begins with
/// `localhost`, and a third name must not.
#[test]
fn startup_name_and_current_name_both_match_when_one_starts_with_localhost() {
    let _rig = lock(&RIG);
    let pairs = [
        ("euler", "localhost-dev.local"),
        ("localhost-dev.local", "euler"),
        ("localhost-old", "localhost-new"),
    ];
    let mut problems = Vec::new();
    for (startup, current) in pairs.iter() {
        for (label, authority, want_accept) in [
            ("startup name", *startup, true),
            ("current name", *current, true),
            ("third name", "unrelated-third-machine", false),
        ] {
            set_machine_name(Some(*startup));
            let sink = new_sink();
            let seq = osc7(authority);
            unsafe {
                let term = bb_term_new(80, 24, 1000);
                // The machine is renamed after the shell was spawned.
                set_machine_name(Some(*current));
                bb_term_set_event_cb(term, Some(cb), &sink as *const Sink as *mut c_void);
                bb_term_input(term, seq.as_ptr(), seq.len());
                bb_term_free(term);
            }
            let got = lossy(&sink.cwds.lock().unwrap().clone());
            let want: Vec<String> = if want_accept {
                vec!["/tmp/x".to_string()]
            } else {
                Vec::new()
            };
            if got != want {
                problems.push(format!(
                    "terminal started on {startup:?}, machine renamed to {current:?}: [{label}] \
                     authority {authority:?} wanted {want:?}; measured {got:?}"
                ));
            }
        }
    }
    assert_no_problems(problems, "rename between terminal start and OSC 7");
}

// ---------- cheapness of the foreign-host reject path ---------------

/// A foreign host (a remote ssh session printing its own hostname on every
/// prompt) is the hot reject path. A flood of such sequences must be cut off
/// by the OSC 7 rate gate (32 per second per session) BEFORE any `gethostname`
/// syscall, so the number of syscalls is bounded by the gate, not by the
/// size of the flood.
#[test]
fn foreign_host_flood_does_not_call_gethostname_per_sequence() {
    let _rig = lock(&RIG);
    const FLOOD: usize = 600;
    // The gate admits 32 per window; allow three windows in case a heavily
    // loaded runner stretches the flood across window boundaries.
    const MAX_CALLS: usize = 96;

    for authority in ["other-host.example.com", "localhost-zzz-other"] {
        set_machine_name(Some("euler"));
        let sink = new_sink();
        let seq = osc7(authority);
        let calls_during_flood;
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const Sink as *mut c_void);

            // Rig precondition inside this very test: the terminal really
            // is on machine "euler" (its own name is accepted), so the
            // flood below is a flood of FOREIGN hosts on a known machine.
            let own = osc7("euler");
            bb_term_input(term, own.as_ptr(), own.len());
            let accepted = lossy(&sink.cwds.lock().unwrap().clone());
            assert_eq!(
                accepted,
                vec!["/tmp/x".to_string()],
                "precondition: own-name OSC 7 on machine \"euler\" must fire before the flood \
                 (measured {accepted:?})"
            );

            let before = hostname_calls();
            for _ in 0..FLOOD {
                bb_term_input(term, seq.as_ptr(), seq.len());
            }
            calls_during_flood = hostname_calls() - before;
            bb_term_free(term);
        }
        let cwds = lossy(&sink.cwds.lock().unwrap().clone());
        assert_eq!(
            cwds.len(),
            1,
            "a flood of {FLOOD} OSC 7 sequences naming foreign host {authority:?} must not \
             produce CwdChanged beyond the one own-name sequence; measured {cwds:?}"
        );
        assert!(
            calls_during_flood <= MAX_CALLS,
            "{FLOOD} foreign-host OSC 7 sequences ({authority:?}) caused {calls_during_flood} \
             gethostname() calls; the rate gate (32/s) must cut the flood off before the syscall, \
             so at most {MAX_CALLS} were allowed (a call per sequence = {FLOOD})"
        );
    }
}

// ---------- breadcrumb on reject -------------------------------------

const BREADCRUMB_TEST: &str = "foreign_host_reject_leaves_one_shot_breadcrumb_per_session";
const CHILD_ENV: &str = "BB_OSC7_HOSTNAME_BLIND_CHILD";

fn feed_n(term: *mut BBTerm, authority: &str, n: usize) {
    let seq = osc7(authority);
    for _ in 0..n {
        unsafe { bb_term_input(term, seq.as_ptr(), seq.len()) };
    }
}

/// Runs inside the re-executed child. Prints a phase marker to stderr
/// between steps; the core's own `eprintln!` breadcrumbs land in between.
fn breadcrumb_child() {
    set_machine_name(Some("euler"));
    let sink = new_sink();
    let sink_ptr = &sink as *const Sink as *mut c_void;
    unsafe {
        // A: first foreign-host reject of a session.
        let t1 = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(t1, Some(cb), sink_ptr);
        eprintln!("@@PHASE A");
        feed_n(t1, "other-host.example.com", 1);
        // B: a flood of the same reject on the same session.
        eprintln!("@@PHASE B");
        feed_n(t1, "other-host.example.com", 300);
        bb_term_free(t1);

        // C: a brand-new session, different foreign shape (`localhost-` prefix).
        let t2 = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(t2, Some(cb), sink_ptr);
        eprintln!("@@PHASE C");
        feed_n(t2, "localhost-zzz-other", 1);
        bb_term_free(t2);

        // D: accepted sequences must not log anything.
        let t3 = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(t3, Some(cb), sink_ptr);
        eprintln!("@@PHASE D");
        feed_n(t3, "", 1);
        feed_n(t3, "localhost", 1);
        feed_n(t3, "euler", 1);
        bb_term_free(t3);

        // E1..E4: a foreign host is rejected loudly on EVERY kind of
        // machine, including one whose name starts with `localhost`, one
        // with an empty name and one whose gethostname() fails.
        let machines: [Option<&str>; 4] =
            [Some("euler"), Some("localhost-dev.local"), Some(""), None];
        for (i, machine) in machines.iter().enumerate() {
            set_machine_name(*machine);
            let t = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(t, Some(cb), sink_ptr);
            eprintln!("@@PHASE E{}", i + 1);
            feed_n(t, "other-host.example.com", 1);
            bb_term_free(t);
        }
        eprintln!("@@PHASE END");
    }
    let accepted = sink.cwds.lock().unwrap().len();
    assert_eq!(
        accepted, 3,
        "child rig: phase D must accept exactly its 3 local sequences (measured {accepted})"
    );
}

fn is_osc7_breadcrumb(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    l.contains("osc 7") && l.contains("reject")
}

/// "A rejected OSC 7 must leave a one-shot breadcrumb like the other OSC
/// rejects": the first foreign-host reject of a session is logged exactly
/// once; a flood of identical rejects does not flood the log; a new session
/// gets its own breadcrumb; sequences that are accepted log nothing.
#[test]
fn foreign_host_reject_leaves_one_shot_breadcrumb_per_session() {
    if matches!(std::env::var(CHILD_ENV).as_deref(), Ok("1")) {
        breadcrumb_child();
        return;
    }

    let exe = std::env::current_exe().expect("current_exe");
    let out = Command::new(exe)
        .args([
            "--exact",
            BREADCRUMB_TEST,
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_ENV, "1")
        .output()
        .expect("re-exec the test binary as the breadcrumb child");
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert!(
        out.status.success(),
        "breadcrumb child failed ({:?}); stderr:\n{stderr}",
        out.status
    );

    let mut counts: Vec<(String, usize)> = Vec::new();
    let mut phase = String::from("(before)");
    counts.push((phase.clone(), 0));
    for line in stderr.lines() {
        if let Some(name) = line.strip_prefix("@@PHASE ") {
            phase = name.trim().to_string();
            counts.push((phase.clone(), 0));
        } else if is_osc7_breadcrumb(line) {
            if let Some(last) = counts.last_mut() {
                last.1 += 1;
            }
        }
    }
    let count = |name: &str| -> usize {
        counts
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, c)| *c)
            .unwrap_or(usize::MAX)
    };
    let phases_seen: Vec<String> = counts.iter().map(|(n, _)| n.clone()).collect();
    assert_eq!(
        phases_seen,
        vec!["(before)", "A", "B", "C", "D", "E1", "E2", "E3", "E4", "END"],
        "rig precondition: the child must walk every phase; child stderr:\n{stderr}"
    );

    assert_eq!(
        count("A"),
        1,
        "the first foreign-host OSC 7 reject of a session must leave exactly one breadcrumb \
         line mentioning `OSC 7` and `reject`; measured {} line(s). child stderr:\n{stderr}",
        count("A")
    );
    assert!(
        count("A") + count("B") <= 2,
        "300 more identical foreign-host rejects on the same session must not add a log line \
         each (one-shot / rate-limited); measured {} line(s) over phases A+B. child stderr:\n{stderr}",
        count("A") + count("B")
    );
    assert_eq!(
        count("C"),
        1,
        "a fresh session must leave its own breadcrumb for its first foreign-host reject \
         (per-session latch, not process-wide); measured {} line(s). child stderr:\n{stderr}",
        count("C")
    );
    for (phase_name, machine) in [
        ("E1", "euler"),
        ("E2", "localhost-dev.local"),
        ("E3", "(empty name)"),
        ("E4", "(gethostname fails)"),
    ] {
        assert_eq!(
            count(phase_name),
            1,
            "a foreign-host OSC 7 reject on machine {machine} must leave exactly one \
             breadcrumb; measured {} line(s). child stderr:\n{stderr}",
            count(phase_name)
        );
    }
    assert_eq!(
        count("D"),
        0,
        "accepted OSC 7 sequences (empty authority, localhost, own name) must not log a reject; \
         measured {} line(s). child stderr:\n{stderr}",
        count("D")
    );
}
