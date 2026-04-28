//! Pins OSC 133 prompt/command-mark scanning. The BBTerm embeds a parallel
//! vte::Parser driving `Osc133Scanner`; each complete OSC 133 sequence fires
//! one PromptMark event with the kind (A/B/C/D) in i32_arg and the exit
//! code (for kind D) in the byte payload.

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

/// Capture every BBEvent emitted during a scenario. The callback copies
/// payloads eagerly because vte's slice borrows don't outlive the callback.
#[derive(Default)]
struct Capture {
    events: Vec<(u32, Vec<u8>, i32)>,
}

fn install_capture(term: *mut BBTerm) -> Box<Mutex<Capture>> {
    let cap = Box::new(Mutex::new(Capture::default()));
    let ctx = Box::as_ref(&cap) as *const Mutex<Capture> as *mut c_void;
    unsafe {
        bb_term_set_event_cb(term, Some(trampoline), ctx);
    }
    cap
}

unsafe extern "C" fn trampoline(ev: BBEvent, ctx: *mut c_void) {
    let m = &*(ctx as *const Mutex<Capture>);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    m.lock()
        .unwrap()
        .events
        .push((ev.kind as u32, bytes, ev.i32_arg));
}

fn collect_marks(events: &[(u32, Vec<u8>, i32)]) -> Vec<(i32, String)> {
    events
        .iter()
        .filter(|(k, _, _)| *k == 7) // BBEventKind::PromptMark
        .map(|(_, payload, arg)| (*arg, String::from_utf8_lossy(payload).to_string()))
        .collect()
}

#[test]
fn osc_133_a_fires_kind_a_with_empty_payload() {
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;A\x1b\\";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert_eq!(marks, vec![(1, String::new())]);
        bb_term_free(term);
    }
}

#[test]
fn osc_133_b_and_c_fire_kind_b_c() {
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;B\x1b\\\x1b]133;C\x1b\\";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert_eq!(marks, vec![(2, String::new()), (3, String::new())]);
        bb_term_free(term);
    }
}

#[test]
fn osc_133_d_with_exit_code_as_separate_param() {
    // `OSC 133 ; D ; 137 ST` — three parameters, exit code in param[2].
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;D;137\x1b\\";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert_eq!(marks, vec![(4, "137".to_string())]);
        bb_term_free(term);
    }
}

#[test]
fn osc_133_d_with_bel_terminator_also_works() {
    // Some emitters use BEL (0x07) as the OSC terminator instead of ST.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;D;0\x07";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert_eq!(marks, vec![(4, "0".to_string())]);
        bb_term_free(term);
    }
}

#[test]
fn osc_133_fragmented_across_feed_calls_resolves_once() {
    // The parallel parser is stateful, so splitting the sequence across
    // bb_term_input calls still produces a single event.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        bb_term_input(term, b"\x1b]13".as_ptr(), 4);
        bb_term_input(term, b"3;A\x1b".as_ptr(), 5);
        bb_term_input(term, b"\\".as_ptr(), 1);
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert_eq!(marks, vec![(1, String::new())]);
        bb_term_free(term);
    }
}

#[test]
fn unknown_sub_kind_is_silently_ignored() {
    // `OSC 133 ; Z ST` — shouldn't crash and shouldn't fire an event.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;Z\x1b\\";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert!(
            marks.is_empty(),
            "unknown sub-kind emitted event: {marks:?}"
        );
        bb_term_free(term);
    }
}

#[test]
fn osc_133_d_with_inline_semicolon_form() {
    // Some emitters combine the sub-kind and exit code into one parameter:
    // `OSC 133 ; D;0 ST` rather than `; D ; 0 ST`. Both must work.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        let cap = install_capture(term);
        let seq = b"\x1b]133;D;0\x1b\\";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        // Sub-param split gives us separate "D" and "0" — same outcome.
        assert_eq!(marks, vec![(4, "0".to_string())]);
        bb_term_free(term);
    }
}

/// Audit RC-02: `bb_term_clear_all` must also reset the parallel OSC
/// parser. Otherwise a partial pre-clear OSC sequence continues into
/// post-clear bytes, dispatching a PromptMark sourced from text that was
/// supposed to be a fresh shell prompt.
#[test]
fn clear_all_drops_partial_osc133_in_flight() {
    unsafe {
        let term = bb_term_new(20, 3, 100);
        let cap = install_capture(term);
        // Feed only the OSC introducer + 133 prefix. The osc_parser is
        // mid-sequence; no event should fire yet.
        let partial = b"\x1b]133";
        bb_term_input(term, partial.as_ptr(), partial.len());
        let pre = cap.lock().unwrap().events.len();
        // Wipe.
        bb_term_clear_all(term);
        // Feed the bytes that, if the partial parse survived, would
        // complete `OSC 133;A BEL` and fire a phantom PromptMark.
        let post = b";A\x07hello";
        bb_term_input(term, post.as_ptr(), post.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events[pre..]);
        assert!(
            marks.is_empty(),
            "post-clear bytes completed a pre-clear OSC sequence: {marks:?}"
        );
        bb_term_free(term);
    }
}

/// Audit RC-03: D marks were exempt from `prompt_mark_rate.allow()` on
/// the basis of a "1:1 with C" invariant the code never enforced. A
/// hostile remote could spam OSC 133;D;0 to rotate legitimate D events
/// out of Swift's bounded prompt ring. After the fix all four kinds
/// (A/B/C/D) are subject to the same per-second cap.
#[test]
fn d_marks_are_rate_limited_like_a_b_c() {
    unsafe {
        let term = bb_term_new(20, 3, 100);
        let cap = install_capture(term);
        // PROMPT_MARK_PER_SECOND = 16. Burst 50 D dispatches in one
        // input; the rate limiter must drop the excess.
        let mut burst = Vec::with_capacity(50 * 16);
        for _ in 0..50 {
            burst.extend_from_slice(b"\x1b]133;D;0\x07");
        }
        bb_term_input(term, burst.as_ptr(), burst.len());
        let events = cap.lock().unwrap().events.clone();
        let marks = collect_marks(&events);
        assert!(
            marks.len() <= 16,
            "D-mark rate limit not enforced: {} marks fired",
            marks.len()
        );
        // And we should still see at least one — the limiter is a cap,
        // not a kill-switch.
        assert!(!marks.is_empty(), "no D marks fired at all");
        bb_term_free(term);
    }
}
