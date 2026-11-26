use std::sync::OnceLock;

use crate::guard::payload_to_string;

/// UTF-8, not NUL-terminated, valid only for the call; any core thread; must not call `bb_term_*`.
pub(crate) type LogSink = unsafe extern "C" fn(*const u8, usize);

static LOG_SINK: OnceLock<LogSink> = OnceLock::new();

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

macro_rules! breadcrumb {
    ($($arg:tt)*) => {
        $crate::diag::emit(format_args!($($arg)*))
    };
}
pub(crate) use breadcrumb;

pub(crate) fn install(sink: LogSink) {
    if LOG_SINK.set(sink).is_err() {
        return;
    }
    // Chain, never replace: other hooks (and the test harness's output capture) must keep running.
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
