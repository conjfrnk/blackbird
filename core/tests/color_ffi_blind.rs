//! Blind FFI contract tests for the color-palette surface
//! (`bb_term_set_color_query_enabled` + `bb_term_set_named_color`).
//!
//! Author had no access to `core/src/`; the only contract consulted was
//! `core/include/BBCore.h`. Tests verify documented invariants:
//!   - Default-disabled OSC 10/11/12 `?` reply (zsh-vi-mode mitigation).
//!   - Enable/disable toggle.
//!   - Null safety on both setters.
//!   - Slot mapping for 256/257/258 (foreground/background/cursor) via
//!     OSC 10/11/12 round-trip.
//!   - Silently-ignored slots >= COUNT (header says COUNT = 269).
//!   - 8-bit → 16-bit channel replication in the reply.
//!   - Idempotent re-set.
//!   - Set then disable then re-enable preserves the palette state.
//!
//! Reply format pinned by xterm spec and the existing
//! `color_query.rs` integration tests:
//!     `\x1b]<id>;rgb:RRRR/GGGG/BBBB\x1b\\`
//! (or `\x07` BEL-terminated for the older form, but every test here
//! uses ST since the query is sent by us.)

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

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

/// Collected PtyWrite payloads from a single closure-driven session.
/// `body` receives the live `*mut BBTerm` and may issue arbitrary FFI
/// calls. The callback is wired before `body` runs and the term is
/// freed after.
fn with_term<F>(body: F) -> Vec<Vec<u8>>
where
    F: FnOnce(*mut BBTerm),
{
    let sink = Sink::default();
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null(), "bb_term_new(80,24,1000) returned null");
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        body(term);
        bb_term_free(term);
    }
    sink.events
        .into_inner()
        .unwrap()
        .into_iter()
        .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
        .map(|(_, v)| v)
        .collect()
}

/// Feed `seq` to a term and collect PtyWrite payloads.
unsafe fn feed(term: *mut BBTerm, seq: &[u8]) {
    bb_term_input(term, seq.as_ptr(), seq.len());
}

/// Parse a `\x1b]<id>;rgb:RRRR/GGGG/BBBB\x1b\\` reply and return the
/// (id, r, g, b) tuple, where each channel is the full 16-bit value.
/// Panics with a descriptive message on any parse failure — these
/// tests want load-bearing assertions, not silent skips.
fn parse_rgb_reply(bytes: &[u8]) -> (u32, u16, u16, u16) {
    let s = std::str::from_utf8(bytes).unwrap_or_else(|_| panic!("reply not UTF-8: {bytes:?}"));
    let body = s
        .strip_prefix("\x1b]")
        .unwrap_or_else(|| panic!("missing OSC prefix: {s:?}"));
    let body = body
        .strip_suffix("\x1b\\")
        .or_else(|| body.strip_suffix('\x07'))
        .unwrap_or_else(|| panic!("missing OSC terminator: {s:?}"));
    let (id_str, rest) = body
        .split_once(';')
        .unwrap_or_else(|| panic!("missing ;: {s:?}"));
    let id: u32 = id_str
        .parse()
        .unwrap_or_else(|_| panic!("bad id {id_str:?} in {s:?}"));
    let rgb = rest
        .strip_prefix("rgb:")
        .unwrap_or_else(|| panic!("missing 'rgb:' in {s:?}"));
    let mut parts = rgb.split('/');
    let r = parts.next().expect("missing R");
    let g = parts.next().expect("missing G");
    let b = parts.next().expect("missing B");
    assert!(parts.next().is_none(), "extra channel in {s:?}");
    let r = u16::from_str_radix(r, 16).unwrap_or_else(|_| panic!("bad R hex {r:?}"));
    let g = u16::from_str_radix(g, 16).unwrap_or_else(|_| panic!("bad G hex {g:?}"));
    let b = u16::from_str_radix(b, 16).unwrap_or_else(|_| panic!("bad B hex {b:?}"));
    (id, r, g, b)
}

/// 8-bit → 16-bit channel replication (the xterm reply format
/// emits `0x12` as `0x1212`).
fn rep8(c: u8) -> u16 {
    ((c as u16) << 8) | c as u16
}

// ---------- behaviour 1: default disabled --------------------------

#[test]
fn osc10_query_is_silent_by_default() {
    let writes = with_term(|term| unsafe {
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(
        writes.len(),
        0,
        "fresh term must NOT reply to OSC 10 ? (zsh-vi-mode mitigation), got {writes:?}"
    );
}

#[test]
fn osc11_query_is_silent_by_default() {
    let writes = with_term(|term| unsafe {
        feed(term, b"\x1b]11;?\x1b\\");
    });
    assert_eq!(writes.len(), 0, "OSC 11 ? must be silent by default");
}

#[test]
fn osc12_query_is_silent_by_default() {
    let writes = with_term(|term| unsafe {
        feed(term, b"\x1b]12;?\x1b\\");
    });
    assert_eq!(writes.len(), 0, "OSC 12 ? must be silent by default");
}

// ---------- behaviour 2: enable then disable -----------------------

#[test]
fn enable_then_query_then_disable_then_query() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        feed(term, b"\x1b]10;?\x1b\\");
        bb_term_set_color_query_enabled(term, 0);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(
        writes.len(),
        1,
        "expected exactly one reply (from the enabled window), got {writes:?}"
    );
    let (id, _r, _g, _b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10, "reply id must be 10 (foreground)");
}

// ---------- behaviour 3: null term ---------------------------------

#[test]
fn null_term_is_noop_on_all_color_apis() {
    // Drive a real terminal alongside to confirm the null calls don't perturb
    // a coexisting term's state (i.e. the no-op is local-to-null, not a
    // global suppress). Verify no events fire from the null calls and the
    // real term still replies on query.
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        // null calls interleaved — must not crash, must not steal events.
        bb_term_set_color_query_enabled(std::ptr::null_mut(), 1);
        bb_term_set_color_query_enabled(std::ptr::null_mut(), 0);
        bb_term_set_named_color(std::ptr::null_mut(), 0, 0x00FF_0000);
        bb_term_set_named_color(std::ptr::null_mut(), 256, 0x0000_00FF);
        bb_term_set_named_color(std::ptr::null_mut(), u16::MAX, 0xFFFF_FFFF);
        // Real term remains responsive — query produces exactly one reply.
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(
        writes.len(),
        1,
        "real term must produce one OSC 10 reply unaffected by null sibling calls"
    );
}

// ---------- behaviour 4: enabled edge values -----------------------

// The header says "Pass `1` to enable replies"; the established C-API idiom
// "any non-zero is truthy" is pinned by these two tests. A mutation that
// flipped the impl to `enabled == 1` strict would cause both to fail.
#[test]
fn enabled_value_two_is_treated_as_truthy() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 2);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1, "enabled=2 must enable replies (got {writes:?})");
    let (id, _, _, _) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10, "reply identifier must match the OSC 10 query");
}

#[test]
fn enabled_value_ff_is_treated_as_truthy() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 0xFF);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1, "enabled=0xFF must enable replies (got {writes:?})");
    let (id, _, _, _) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10);
}

// ---------- behaviour 5: set then query, slot 256/257/258 ----------

#[test]
fn slot_256_foreground_roundtrips_via_osc10() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x12_34_56);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1, "expected one PtyWrite, got {writes:?}");
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10);
    assert_eq!(r, rep8(0x12));
    assert_eq!(g, rep8(0x34));
    assert_eq!(b, rep8(0x56));
}

#[test]
fn slot_257_background_roundtrips_via_osc11() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 257, 0xAB_CD_EF);
        feed(term, b"\x1b]11;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 11);
    assert_eq!(r, rep8(0xAB));
    assert_eq!(g, rep8(0xCD));
    assert_eq!(b, rep8(0xEF));
}

#[test]
fn slot_258_cursor_roundtrips_via_osc12() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 258, 0x00_80_FF);
        feed(term, b"\x1b]12;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 12);
    assert_eq!(r, rep8(0x00));
    assert_eq!(g, rep8(0x80));
    assert_eq!(b, rep8(0xFF));
}

#[test]
fn ansi_palette_slots_0_to_15_accept_writes_without_event() {
    // Only 10/11/12 are queryable; ANSI palette writes simply must
    // not crash, must not emit events, and must not interfere with
    // the foreground/background/cursor reads.
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        for slot in 0u16..=15 {
            bb_term_set_named_color(term, slot, 0x10_20_30 ^ (slot as u32));
        }
    });
    assert_eq!(
        writes.len(),
        0,
        "palette writes alone must not generate PtyWrite events"
    );
}

#[test]
fn extended_palette_slots_16_to_255_accept_writes_without_event() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        for slot in 16u16..=255 {
            bb_term_set_named_color(term, slot, 0x01_02_03);
        }
    });
    assert_eq!(writes.len(), 0);
}

#[test]
fn dim_and_bright_special_slots_accept_writes_without_event() {
    // 259..=266 = Dim{Black..White}, 267 = BrightForeground,
    // 268 = DimForeground. No query maps to these directly per the
    // header, so we only verify they don't panic and don't emit.
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        for slot in 259u16..=268 {
            bb_term_set_named_color(term, slot, 0x11_22_33);
        }
    });
    assert_eq!(writes.len(), 0);
}

// ---------- behaviour 6: out-of-range slots ------------------------

#[test]
fn out_of_range_slots_are_silently_ignored() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        // Header documents COUNT == 269 (alacritty 0.26).
        bb_term_set_named_color(term, 269, 0xFF_00_FF);
        bb_term_set_named_color(term, 270, 0xFF_00_FF);
        bb_term_set_named_color(term, 1000, 0xFF_00_FF);
        bb_term_set_named_color(term, u16::MAX, 0xFF_00_FF);
    });
    assert_eq!(
        writes.len(),
        0,
        "out-of-range slot writes must not emit events, got {writes:?}"
    );
}

#[test]
fn out_of_range_slot_does_not_corrupt_foreground() {
    // Set foreground to a known value, then bombard out-of-range slots,
    // then read foreground back. The OOR writes must not bleed into
    // adjacent palette memory.
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x44_55_66);
        for slot in [269u16, 300, 1000, u16::MAX] {
            bb_term_set_named_color(term, slot, 0xAA_BB_CC);
        }
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10);
    assert_eq!((r, g, b), (rep8(0x44), rep8(0x55), rep8(0x66)));
}

// ---------- behaviour 7: rgb boundary values -----------------------

#[test]
fn foreground_black_zero_zero_zero() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x00_00_00);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0x0000, 0x0000, 0x0000));
}

#[test]
fn foreground_white_ff_ff_ff_replicates_to_ffff() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0xFF_FF_FF);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0xFFFF, 0xFFFF, 0xFFFF));
}

#[test]
fn foreground_pure_red_only_r_channel() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0xFF_00_00);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0xFFFF, 0x0000, 0x0000));
}

#[test]
fn foreground_pure_green_only_g_channel() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x00_FF_00);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0x0000, 0xFFFF, 0x0000));
}

#[test]
fn foreground_pure_blue_only_b_channel() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x00_00_FF);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0x0000, 0x0000, 0xFFFF));
}

#[test]
fn channel_8_to_16_bit_replication_intermediate_value() {
    // 0xAA → 0xAAAA, not 0xAA00 — verifies a common off-by-implementation
    // (some terminals zero-extend instead of replicating).
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0xAA_AA_AA);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (0xAAAA, 0xAAAA, 0xAAAA));
}

// ---------- behaviour 8: high byte of rgb --------------------------

#[test]
fn high_byte_of_rgb_is_ignored() {
    // Header says "`rgb` is packed 0xRRGGBB" — 24 bits used. The
    // high byte (0xDE in 0xDEADBEEF) MUST NOT bleed into any channel
    // of the reply; otherwise a caller passing a flag in the high
    // byte could surprise-corrupt the palette.
    //
    // Lower 24 bits of 0xDEADBEEF = 0xAD_BE_EF, so the reply must be
    // exactly (0xADAD, 0xBEBE, 0xEFEF).
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0xDEAD_BEEF);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(
        (r, g, b),
        (rep8(0xAD), rep8(0xBE), rep8(0xEF)),
        "high byte 0xDE must not leak into any channel"
    );
}

// ---------- behaviour 9: idempotent set ----------------------------

#[test]
fn repeated_identical_set_is_idempotent_and_emits_no_events() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        for _ in 0..100 {
            bb_term_set_named_color(term, 256, 0x77_88_99);
        }
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(
        writes.len(),
        1,
        "100 identical sets + 1 query must yield exactly 1 PtyWrite"
    );
    let (_, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!((r, g, b), (rep8(0x77), rep8(0x88), rep8(0x99)));
}

// ---------- behaviour 10: state preserved across enable toggle -----

#[test]
fn palette_survives_disable_reenable_cycle() {
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 256, 0x1A_2B_3C);
        // Disable, query (must NOT reply), then re-enable + query.
        bb_term_set_color_query_enabled(term, 0);
        feed(term, b"\x1b]10;?\x1b\\");
        bb_term_set_color_query_enabled(term, 1);
        feed(term, b"\x1b]10;?\x1b\\");
    });
    assert_eq!(
        writes.len(),
        1,
        "exactly one reply (from the re-enabled query); got {writes:?}"
    );
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 10);
    assert_eq!(
        (r, g, b),
        (rep8(0x1A), rep8(0x2B), rep8(0x3C)),
        "palette state must be preserved across enable toggle"
    );
}

#[test]
fn re_enable_without_intermediate_set_still_returns_same_value() {
    // Set, disable, re-enable, query. No intervening writes — the
    // palette state at re-enable must equal the state at disable.
    let writes = with_term(|term| unsafe {
        bb_term_set_color_query_enabled(term, 1);
        bb_term_set_named_color(term, 257, 0x55_66_77); // background
        bb_term_set_color_query_enabled(term, 0);
        bb_term_set_color_query_enabled(term, 1);
        feed(term, b"\x1b]11;?\x1b\\");
    });
    assert_eq!(writes.len(), 1);
    let (id, r, g, b) = parse_rgb_reply(&writes[0]);
    assert_eq!(id, 11);
    assert_eq!((r, g, b), (rep8(0x55), rep8(0x66), rep8(0x77)));
}
