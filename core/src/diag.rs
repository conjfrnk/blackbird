//! Process-wide diagnostic sink for the core's one-shot breadcrumbs and panic
//! locations.
//!
//! These used to go straight to `eprintln!`, i.e. fd 2, which is `/dev/null`
//! for an app started from Finder / Dock / LaunchServices — so the support
//! symptoms the CHANGELOG advertises ("links stopped working") and the
//! `file:line` of a caught panic never reached anything an operator can read.
//! The host registers a log callback once (`bb_set_log_cb`, wired to
//! `os.Logger` by `BBTerm`) and every `breadcrumb!` is forwarded to it. With no
//! callback registered (cargo tests, fuzz targets, plain C consumers) it falls
//! back to stderr, exactly as before.

use std::sync::OnceLock;

use crate::guard::payload_to_string;

/// Host log sink: a UTF-8 message (not NUL-terminated, never empty) valid only
/// for the duration of the call. May be invoked from any thread that drives
/// the core, including from inside an event callback, so it must not call any
/// `bb_term_*` function.
pub(crate) type LogSink = unsafe extern "C" fn(*const u8, usize);

static LOG_SINK: OnceLock<LogSink> = OnceLock::new();

/// Forward one diagnostic line to the registered sink, or stderr without one.
pub(crate) fn emit(args: std::fmt::Arguments<'_>) {
    let Some(sink) = LOG_SINK.get() else {
        eprintln!("{args}");
        return;
    };
    let msg = args.to_string();
    if !msg.is_empty() {
        // SAFETY: `msg` outlives the call; the sink's contract is above.
        unsafe { sink(msg.as_ptr(), msg.len()) };
    }
}

/// Drop-in replacement for `eprintln!` at the core's diagnostic sites.
macro_rules! breadcrumb {
    ($($arg:tt)*) => {
        $crate::diag::emit(format_args!($($arg)*))
    };
}
pub(crate) use breadcrumb;

/// Install the process-wide sink. The first registration wins and also chains a
/// panic hook in front of the existing one: a caught panic's message reaches
/// the host as the `Fatal` event, but its `file:line` exists only in the
/// `PanicHookInfo`, which Rust's default hook prints to stderr alone.
pub(crate) fn install(sink: LogSink) {
    if LOG_SINK.set(sink).is_err() {
        return;
    }
    // Chain, never replace: other hooks (and the test harness's output
    // capture) must keep running, and dev runs keep their stderr line.
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let msg = payload_to_string(info.payload());
        match info.location() {
            Some(loc) => breadcrumb!(
                "[blackbird_core] panic at {}:{}:{}: {msg}",
                loc.file(),
                loc.line(),
                loc.column()
            ),
            None => breadcrumb!("[blackbird_core] panic: {msg}"),
        }
        prev(info);
    }));
}
