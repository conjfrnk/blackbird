import Foundation
import Darwin
import os

/// A child process behind a pseudo-terminal master fd. A dedicated queue runs the read loop, writes go
/// through a serial queue, and `onBytes` is invoked on the read queue.
public final class PTY {

    public struct Size: Equatable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case forkFailed(errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .forkFailed(let code):
                return "Couldn't create the shell process or its terminal: "
                    + "\(String(cString: strerror(code))) (errno \(code))."
            }
        }
    }

    /// Guards `_onBytes` / `_onExit`. A lock, not a hop to `readQueue`: the read loop occupies that serial
    /// queue with one block until EOF, so a setter enqueued there would not run for the life of the session.
    private let handlerLock = NSLock()
    private var _onBytes: ((Data) -> Void)?
    private var _onExit: ((Int32) -> Void)?

    /// Called on the read queue. The loop loads the closure under `handlerLock` but invokes it outside (never hold the lock
    /// across the callback), so one already-loaded chunk may still reach the previous closure after `setOnBytes` returns.
    public var onBytes: ((Data) -> Void)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return _onBytes
    }

    /// Wire before `startReading()`, or the first bytes race the installation.
    public func setOnBytes(_ closure: ((Data) -> Void)?) {
        handlerLock.lock()
        _onBytes = closure
        handlerLock.unlock()
    }

    /// Called on the main queue exactly once, after the child has been reaped, for a natural exit and `terminate()` alike.
    public var onExit: ((Int32) -> Void)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return _onExit
    }

    public func setOnExit(_ closure: ((Int32) -> Void)?) {
        handlerLock.lock()
        _onExit = closure
        handlerLock.unlock()
    }

    public static let scrubbedParentEnvVars: [String] = [
        "XPC_SERVICE_NAME",
        "XPC_FLAGS",
        "__CF_USER_TEXT_ENCODING",
        "OS_ACTIVITY_DT_MODE",
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        "__XPC_DYLD_LIBRARY_PATH",
        "LaunchInstanceID",
        "SECURITYSESSIONID",
        // dyld injection surface: a leak means the first `sudo` / `curl` in the shell inherits the injected library.
        "DYLD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_PRINT_TO_FILE",
        "DYLD_PRINT_APIS",
        "DYLD_PRINT_STATISTICS",
        "MallocNanoZone",
        "OS_ACTIVITY_MODE",
        "CA_DEBUG_TRANSACTIONS",
        "CA_ASSERT_MAIN_THREAD_TRANSACTIONS",
    ]

    /// Case-insensitive: the kernel does not enforce uppercase env names, so a lowercase `bb_token` must not slip past.
    internal static func isBlackbirdNamespacedEnvKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.hasPrefix("BLACKBIRD_") || upper.hasPrefix("BB_")
    }

    /// Not reaped ⇒ -1. WIFEXITED (low 7 bits clear) ⇒ `(status >> 8) & 0xff`. WIFSIGNALED (low 7 bits
    /// neither 0 nor 0x7f) ⇒ `128 + signum`. WIFSTOPPED or unclassifiable ⇒ -1.
    internal static func decodeExitStatus(_ status: Int32, reaped: Bool) -> Int32 {
        if !reaped { return -1 }
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        if (status & 0x7f) != 0x7f && (status & 0x7f) != 0 {
            let signum = status & 0x7f
            return 128 + signum
        }
        return -1
    }

    private let masterFD: Int32
    private let childPID: pid_t
    /// `pbi_start_tvsec` / `pbi_start_tvusec` captured at spawn: identifies the process even if
    /// its pid is later recycled. Nil when the read failed at spawn.
    private let childStartTime: (sec: UInt64, usec: UInt64)?
    private let readQueue = DispatchQueue(label: "blackbird.pty.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "blackbird.pty.write", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "blackbird.pty.state")

    /// Guarded by `stateQueue`. POSIX reserves a dead child's pid until its parent reaps it and the read-loop teardown is the sole
    /// reaper, so `childPID` is safe to signal only while `.running`; after `waitpid` the pid may be recycled within milliseconds.
    private enum ReapState {
        case running
        case reaping
        case reaped
    }
    private var reapState: ReapState = .running
    private var _isRunning = true
    /// Darwin's PTY master returns only ~1 KiB per `read(2)`, so the loop reads until EAGAIN or this buffer fills and
    /// delivers one chunk. 32 KiB, not larger: a keystroke waits for the chunk being parsed (~1 ms at the throughput floor).
    private let readBufferSize = 32 * 1024

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    private func shouldKeepRunning() -> Bool {
        stateQueue.sync { _isRunning }
    }

    private func markStopped() {
        stateQueue.sync { _isRunning = false }
    }

    private static func bsdProcessStartTime(pid: pid_t) -> (sec: UInt64, usec: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return (sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec)
    }

    /// Every value the post-fork child needs, pre-converted to raw C strings in the parent. `freeAll()` is
    /// parent-only: `free` is not async-signal-safe, and the child either `execv`s or `_exit`s.
    private struct SpawnContext {
        let scrubKeys: [UnsafeMutablePointer<CChar>?]
        /// One array of (key, value) pairs, not two parallel arrays: index alignment is structural, and the
        /// trivial element keeps `withUnsafeBufferPointer` retain-free in the post-fork child.
        let env: [(key: UnsafeMutablePointer<CChar>?, value: UnsafeMutablePointer<CChar>?)]
        let argv: [UnsafeMutablePointer<CChar>?]
        let term: UnsafeMutablePointer<CChar>?
        let version: UnsafeMutablePointer<CChar>?
        let home: UnsafeMutablePointer<CChar>?
        let initialCwd: UnsafeMutablePointer<CChar>?
        let executable: UnsafeMutablePointer<CChar>?

        func freeAll() {
            scrubKeys.forEach { if let p = $0 { Darwin.free(p) } }
            env.forEach { pair in
                if let p = pair.key { Darwin.free(p) }
                if let p = pair.value { Darwin.free(p) }
            }
            argv.forEach { if let p = $0 { Darwin.free(p) } }
            if let p = term { Darwin.free(p) }
            if let p = version { Darwin.free(p) }
            if let p = home { Darwin.free(p) }
            if let p = initialCwd { Darwin.free(p) }
            if let p = executable { Darwin.free(p) }
        }
    }

    internal static func validatedEnvOverrides(
        _ envOverrides: [String: String]
    ) -> [(key: String, value: String)] {
        var survivors: [(key: String, value: String)] = []
        for (k, v) in envOverrides {
            if k.isEmpty || k.contains("\0") || k.contains("=") {
                Self.logger.log(
                    "PTY.spawn rejecting envOverride: invalid key (empty / contains NUL or '=')"
                )
                continue
            }
            if v.contains("\0") {
                // Env-key names can themselves be sensitive (`AWS_SECRET_ACCESS_KEY`), so the key is hashed in the log.
                Self.logger.log(
                    "PTY.spawn rejecting envOverride for key=\(k, privacy: .private(mask: .hash)): value contains NUL"
                )
                continue
            }
            survivors.append((k, v))
        }
        return survivors
    }

    internal static func blackbirdNamespacedScrubKeys() -> [String] {
        var matchedPrefixedKeys: [String] = []
        let envPtr = environ
        var i = 0
        while let entry = envPtr[i] {
            let s = String(cString: entry)
            if let eq = s.firstIndex(of: "=") {
                let key = String(s[..<eq])
                if Self.isBlackbirdNamespacedEnvKey(key) {
                    if !Self.scrubbedParentEnvVars.contains(key) {
                        matchedPrefixedKeys.append(key)
                    }
                }
            }
            i += 1
        }
        return matchedPrefixedKeys
    }

    /// All ARC / Foundation work happens here, before fork. In the post-fork child any call that takes a runtime lock the parent
    /// held at fork time can deadlock: Swift collections (ARC), `os.Logger`, `getpwuid` (an XPC connection to opendirectoryd).
    private static func prepareSpawnContext(
        executable: String,
        arguments: [String],
        envOverrides: [String: String],
        initialWorkingDirectory: String?
    ) throws -> SpawnContext {
        let termValue = KittyTerminfo.availableForSpawn() ? "xterm-kitty" : "xterm-256color"
        let versionStr = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"

        let scrubKeys: [UnsafeMutablePointer<CChar>?] =
            (Self.scrubbedParentEnvVars + Self.blackbirdNamespacedScrubKeys()).map { strdup($0) }

        let env: [(key: UnsafeMutablePointer<CChar>?, value: UnsafeMutablePointer<CChar>?)] =
            Self.validatedEnvOverrides(envOverrides).map { (strdup($0.key), strdup($0.value)) }

        let home: UnsafeMutablePointer<CChar>? = {
            if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
                return strdup(pwDir)
            }
            return nil
        }()

        let initialCwd: UnsafeMutablePointer<CChar>? = {
            guard let cwd = initialWorkingDirectory, !cwd.isEmpty else { return nil }
            return strdup(cwd)
        }()

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]

        let executableC = strdup(executable)

        let ctx = SpawnContext(
            scrubKeys: scrubKeys,
            env: env,
            argv: argv,
            term: strdup(termValue),
            version: strdup(versionStr),
            home: home,
            initialCwd: initialCwd,
            executable: executableC
        )

        // Only the executable and argv strdups have no fallback: a NULL there makes the child `execv` a malformed
        // argv and `_exit(127)` with no cause. The child tolerates NULL for every other strdup.
        if ctx.executable == nil
            || ctx.argv.dropLast().contains(where: { $0 == nil })
        {
            Self.logger.error(
                "PTY.spawn: strdup returned NULL for executable / argv — out of memory; aborting fork attempt"
            )
            ctx.freeAll()
            throw Error.forkFailed(errno: ENOMEM)
        }
        if ctx.term == nil || ctx.version == nil {
            Self.logger.error(
                "PTY.spawn: strdup returned NULL for TERM/version under memory pressure — child falls back to static defaults"
            )
        }
        return ctx
    }

    /// Post-fork, pre-exec: async-signal-safe calls only, plus `setenv` / `getenv` / `unsetenv`, which take no cross-thread
    /// locks on Darwin. The all-raw-pointer signature is load-bearing: it leaves nothing here to ARC-retain.
    private static func execChild(
        scrubKeys: UnsafeBufferPointer<UnsafeMutablePointer<CChar>?>,
        env: UnsafeBufferPointer<(key: UnsafeMutablePointer<CChar>?, value: UnsafeMutablePointer<CChar>?)>,
        argv: UnsafeBufferPointer<UnsafeMutablePointer<CChar>?>,
        term: UnsafeMutablePointer<CChar>?,
        version: UnsafeMutablePointer<CChar>?,
        home: UnsafeMutablePointer<CChar>?,
        initialCwd: UnsafeMutablePointer<CChar>?,
        executable: UnsafeMutablePointer<CChar>?
    ) -> Never {
        var i = 0
        while i < scrubKeys.count {
            if let k = scrubKeys[i] { unsetenv(k) }
            i += 1
        }

        // The GUI app may have installed handlers and masked signals: a shell that inherits a blocked SIGINT
        // cannot be Ctrl+C'd. Unrolled so no Swift Array literal is allocated in the child.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
        signal(SIGINT, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGPIPE, SIG_DFL)
        signal(SIGCHLD, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
        signal(SIGTSTP, SIG_DFL)

        // Without IUTF8 the canonical-mode line discipline erases one byte per Backspace, leaving invalid UTF-8 after
        // é / CJK / emoji. Set before exec: a parent-side tcsetattr after forkpty races a fast-starting shell.
        var tio = termios()
        if tcgetattr(STDIN_FILENO, &tio) == 0 {
            tio.c_iflag |= tcflag_t(IUTF8)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &tio)
        }

        // Close every inherited fd above stderr; Darwin lacks `closefrom(3)`. Clamp the bound: `sysconf(_SC_OPEN_MAX)` is the
        // soft RLIMIT_NOFILE, and under `ulimit -Sn unlimited` the `Int32()` cast would trap and SIGILL the child.
        let rawMax = sysconf(Int32(_SC_OPEN_MAX))
        let openMax: Int = rawMax > 65_536 || rawMax <= 0 ? 65_536 : Int(rawMax)
        if openMax > 3 {
            var fd: Int32 = 3
            while fd < Int32(openMax) {
                _ = Darwin.close(fd)
                fd += 1
            }
        }

        var j = 0
        while j < env.count {
            if let k = env[j].key, let v = env[j].value {
                setenv(k, v, 1)
            }
            j += 1
        }

        // `term` can be NULL under OOM and Darwin `setenv` dereferences the value. The fallback
        // is deliberately not the parent's value, which may be xterm-kitty.
        if let t = term {
            setenv("TERM", t, 1)
        } else {
            setenv("TERM", "xterm-256color", 1)
        }
        setenv("COLORTERM", "truecolor", 1)
        setenv("TERM_PROGRAM", "Blackbird", 1)
        if let v = version {
            setenv("TERM_PROGRAM_VERSION", v, 1)
        } else {
            setenv("TERM_PROGRAM_VERSION", "0.0.0", 1)
        }

        // Apps launched from Finder inherit cwd `/` from launchd. Order: the requested cwd, the passwd
        // home, $HOME, /tmp; exit 127 before execv if every one fails.
        var chdired = false
        if let cwd = initialCwd {
            // No pre-`stat`: a symlink swap between the stat and the chdir is a TOCTOU window.
            if chdir(cwd) == 0 { chdired = true }
        }
        if !chdired, let h = home, chdir(h) == 0 {
            chdired = true
        }
        if !chdired,
           let envHome = getenv("HOME"),
           chdir(envHome) == 0 {
            chdired = true
        }
        if !chdired, chdir("/tmp") == 0 {
            chdired = true
        }
        if !chdired {
            _exit(127)
        }

        // `argv` always holds at least `[executable, nil]`, so `baseAddress` is non-nil.
        let argvPtr = UnsafeMutableRawPointer(mutating: argv.baseAddress!)
            .assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        _ = execv(executable, argvPtr)
        _exit(127)
    }

    public static func spawn(
        executable: String,
        arguments: [String],
        envOverrides: [String: String],
        size: Size,
        initialWorkingDirectory: String? = nil
    ) throws -> PTY {
        var master: Int32 = -1
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )

        let ctx = try prepareSpawnContext(
            executable: executable,
            arguments: arguments,
            envOverrides: envOverrides,
            initialWorkingDirectory: initialWorkingDirectory
        )
        defer { ctx.freeAll() }

        // A nil termios makes forkpty use the kernel's TTYDEF_* defaults, with correct c_cc values (VINTR=3, VEOF=4, …).
        // One built from `cfmakeraw()` leaves c_cc zeroed, and VINTR=0 means Ctrl+C is not the interrupt character.
        let pid = withUnsafeMutablePointer(to: &master) { masterPtr in
            withUnsafeMutablePointer(to: &winsize) { wPtr in
                forkpty(masterPtr, nil, nil, wPtr)
            }
        }

        if pid < 0 {
            // Not every forkpty closes the master when fork itself fails; close it, preserving errno.
            if master >= 0 {
                let savedErrno = errno
                _ = Darwin.close(master)
                errno = savedErrno
            }
            throw Error.forkFailed(errno: errno)
        }

        if pid == 0 {
            ctx.scrubKeys.withUnsafeBufferPointer { scrubBuf in
                ctx.env.withUnsafeBufferPointer { envBuf in
                    ctx.argv.withUnsafeBufferPointer { argvBuf in
                        Self.execChild(
                            scrubKeys: scrubBuf,
                            env: envBuf,
                            argv: argvBuf,
                            term: ctx.term,
                            version: ctx.version,
                            home: ctx.home,
                            initialCwd: ctx.initialCwd,
                            executable: ctx.executable
                        )
                    }
                }
            }
        }

        return PTY(masterFD: master, childPID: pid)
    }

    private init(masterFD: Int32, childPID: pid_t) {
        self.masterFD = masterFD
        self.childPID = childPID
        // Without F_SETNOSIGPIPE, a write to a master whose slave has closed delivers SIGPIPE, whose default
        // disposition terminates the whole process. With it the write returns EPIPE.
        if Darwin.fcntl(masterFD, F_SETNOSIGPIPE, 1) < 0 {
            let savedErrno = errno
            Self.logger.error(
                "PTY.init: F_SETNOSIGPIPE failed errno=\(savedErrno, privacy: .public) fd=\(masterFD, privacy: .public) — process is at risk of SIGPIPE-termination on master writes after slave close"
            )
        }
        // With a blocking fd, a child that stops reading stdin fills the ~1 KB tty input queue and the next write parks in
        // `Darwin.write` holding `writeQueue`; `writeImmediate`'s `.sync` callers (the main thread) then hang behind it.
        let fdFlags = Darwin.fcntl(masterFD, F_GETFL, 0)
        if fdFlags < 0 || Darwin.fcntl(masterFD, F_SETFL, fdFlags | O_NONBLOCK) < 0 {
            let savedErrno = errno
            Self.logger.error(
                "PTY.init: O_NONBLOCK failed errno=\(savedErrno, privacy: .public) fd=\(masterFD, privacy: .public) — writes degrade to blocking; a non-reading child can wedge the write queue (audit S1-001 mitigation inactive)"
            )
        }
        self.childStartTime = Self.bsdProcessStartTime(pid: childPID)
        // `startReading()` is not called here: the consumer must `setOnBytes(_:)` first or the shell's first bytes are dropped.
    }

    deinit {
        terminate()
    }

    // MARK: - Reading

    private var readLoopStarted = false

    public func startReading() {
        let shouldStart = stateQueue.sync { () -> Bool in
            if readLoopStarted { return false }
            readLoopStarted = true
            return true
        }
        guard shouldStart else { return }
        readQueue.async { [weak self] in
            guard let self else { return }
            #if DEBUG
            assert(self.onBytes != nil,
                   "PTY.startReading() called before setOnBytes(_:); bytes will be silently dropped. Wire the closure first.")
            #endif
            var buffer = [UInt8](repeating: 0, count: self.readBufferSize)
            let cap = self.readBufferSize
            // The master is O_NONBLOCK, so reads park in poll; a bare retry on EAGAIN would spin on an idle shell.
            func waitReadable() -> Bool {
                var pfd = pollfd(fd: self.masterFD, events: Int16(POLLIN), revents: 0)
                let rc = poll(&pfd, 1, -1)
                if rc < 0 && errno != EINTR {
                    let pollErrno = errno
                    Self.logger.log(
                        "PTY.read poll error errno=\(pollErrno, privacy: .public) fd=\(self.masterFD, privacy: .public) — tearing down"
                    )
                    self.markStopped()
                    return false
                }
                return true
            }
            var wouldBlock = false
            while self.shouldKeepRunning() {
                if wouldBlock {
                    wouldBlock = false
                    if !waitReadable() { break }
                }
                // Read until EAGAIN, EOF, a fatal errno or a full buffer, then deliver one chunk. EOF and fatal
                // errnos are acted on only after the accumulated bytes are delivered, so tail output is never dropped.
                var off = 0
                var eof = false
                var fatalErrno: Int32 = 0
                while off < cap {
                    let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                        read(self.masterFD, buf.baseAddress! + off, cap - off)
                    }
                    if n > 0 {
                        off += n
                        continue
                    }
                    if n == 0 {
                        eof = true
                        break
                    }
                    let savedErrno = errno
                    if savedErrno == EINTR { continue }
                    if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                        wouldBlock = true
                        break
                    }
                    fatalErrno = savedErrno
                    break
                }
                if off > 0 {
                    self.onBytes?(Data(buffer[0..<off]))
                }
                if eof {
                    self.markStopped()
                    break
                }
                if fatalErrno != 0 {
                    Self.logger.log(
                        "PTY.read error errno=\(fatalErrno, privacy: .public) fd=\(self.masterFD, privacy: .public) — tearing down"
                    )
                    self.markStopped()
                    break
                }
            }
            // The loop's single exit path: the read queue is the sole owner of the fd close and the child reap.
            self.teardownAndReap()
        }
    }

    /// Called only from the read loop's exit path. `reapState` moves to `.reaping` before the first `waitpid` and to
    /// `.reaped` before decode; that is what makes the `terminate()` escalation rungs stand down.
    private func teardownAndReap() {
        // Wait out an in-flight write, cancel the drain source, and hold the close until its cancel handler
        // has run: a write source must not outlive the descriptor it watches.
        self.writeQueue.sync { self.cancelDrainSourceLocked() }
        self.drainSourceLive.wait()
        // The read queue is the sole owner of masterFD's close. `stateQueue` serialises it so an urgent
        // control byte in flight cannot land on a freshly closed, possibly reused fd.
        self.stateQueue.sync {
            _ = close(self.masterFD)
        }
        // A shell that ignores SIGHUP can outlive the slave close, and a blocking waitpid would wedge
        // the read queue: poll with WNOHANG, allow 200 ms, then SIGKILL and wait.
        var status: Int32 = 0
        let gracePeriod: useconds_t = 200_000
        var reaped = false
        // Announce before the first waitpid: from the instant it succeeds, the pid is free for kernel reuse.
        self.stateQueue.sync { self.reapState = .reaping }
        let waited = waitpid(self.childPID, &status, WNOHANG)
        if waited == self.childPID {
            reaped = true
        } else if waited < 0 && errno == ECHILD {
            reaped = false
        } else {
            usleep(gracePeriod)
            let retry = waitpid(self.childPID, &status, WNOHANG)
            if retry == self.childPID {
                reaped = true
            } else if retry < 0 && errno == ECHILD {
                reaped = false
            } else {
                let killRC = kill(self.childPID, SIGKILL)
                if killRC != 0 {
                    let savedErrno = errno
                    let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                    Self.logger.log(level: level, "PTY read-loop teardown: kill(\(self.childPID, privacy: .public), SIGKILL) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
                }
                let forced = waitpid(self.childPID, &status, 0)
                reaped = (forced == self.childPID)
            }
        }
        self.stateQueue.sync { self.reapState = .reaped }
        let exitCode = Self.decodeExitStatus(status, reaped: reaped)
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitCode)
        }
    }

    // MARK: - Writing

    public func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, self.shouldKeepRunning() else { return }
            self.sendLocked(data)
        }
    }

    /// Synchronous, for urgent control bytes. Enters `writeQueue` with `.sync` so a pending paste cannot interleave
    /// these bytes into its bracketed-paste frame. Lock order is `writeQueue → stateQueue`, the same as `write()`.
    public func writeImmediate(_ data: Data) {
        writeQueue.sync {
            guard self.shouldKeepRunning() else { return }
            self.sendLocked(data)
            if data.count == 1, self.pendingCount > 0, let byte = data.first,
               self.isSignalCharacterLocked(byte) {
                self.interruptPastBacklogLocked(data)
            }
        }
    }

    /// True when ISIG is on and `byte` is VINTR / VQUIT / VSUSP. Like every `…Locked` method, the caller must hold writeQueue.
    private func isSignalCharacterLocked(_ byte: UInt8) -> Bool {
        var attrs = termios()
        guard tcgetattr(masterFD, &attrs) == 0,
              attrs.c_lflag & tcflag_t(ISIG) != 0 else { return false }
        let signalSlots: [Int] = [Int(VINTR), Int(VQUIT), Int(VSUSP)]
        return withUnsafeBytes(of: attrs.c_cc) { (cc: UnsafeRawBufferPointer) -> Bool in
            signalSlots.contains { (slot: Int) -> Bool in cc[slot] == byte }
        }
    }

    /// macOS's pty master refuses every write, ^C included, once the tty input queue holds ~1 KiB behind a complete line. Like a real
    /// line discipline: drop the backlog, flush the kernel input queue, then write the byte again so the kernel does the echo and the signal.
    private func interruptPastBacklogLocked(_ data: Data) {
        discardPendingLocked()
        var flushRead = FREAD
        if ioctl(masterFD, TIOCFLUSH, &flushRead) < 0 {
            let savedErrno = errno
            Self.logger.error(
                "PTY.interruptPastBacklog: TIOCFLUSH failed errno=\(savedErrno, privacy: .public) fd=\(self.masterFD, privacy: .public)"
            )
        }
        sendLocked(data)
    }

    // MARK: Pending-write buffering

    /// Bytes the kernel would not take yet. All the pending-write state below is accessed only on `writeQueue`.
    private var pendingWrite = Data()
    /// Offset of the first undelivered byte. Partial writes advance this instead of `removeFirst`,
    /// which is a memmove per ~1 KiB write and quadratic over a multi-MiB paste.
    private var pendingHead = 0
    private var pendingCount: Int { pendingWrite.count - pendingHead }
    private var drainSource: DispatchSourceWrite?
    /// Entered when a drain source is created, left by its cancel handler, so teardown can wait until the fd is unregistered.
    private let drainSourceLive = DispatchGroup()
    private var pendingOverflowLogged = false
    /// A write is admitted whole or dropped whole: truncating would cut a paste mid-frame and lose the bracketed-paste end marker.
    /// One write larger than the room left is admitted as the "exempt" write, outside the cap, so input typed while it drains queues behind it.
    private static let pendingBacklogCap = 4 * 1024 * 1024
    private var exemptWriteLength = 0
    private var bytesBehindExemptWrite = 0
    /// Undelivered bytes of the exempt write; older backlog ahead of it still counts against the cap.
    private var exemptBacklog: Int {
        guard exemptWriteLength > 0 else { return 0 }
        return max(0, min(exemptWriteLength, pendingCount - bytesBehindExemptWrite))
    }

    private func sendLocked(_ data: Data) {
        if exemptBacklog == 0 {
            exemptWriteLength = 0
            bytesBehindExemptWrite = 0
        }
        let counted = pendingCount - exemptBacklog
        let room = Self.pendingBacklogCap - counted
        if data.count <= room {
            pendingWrite.append(data)
            if exemptWriteLength > 0 { bytesBehindExemptWrite += data.count }
        } else if room > 0 && exemptWriteLength == 0 {
            pendingWrite.append(data)
            exemptWriteLength = data.count
            bytesBehindExemptWrite = 0
        } else if !pendingOverflowLogged {
            pendingOverflowLogged = true
            Self.logger.error(
                "PTY.write backlog full (\(Self.pendingBacklogCap, privacy: .public) byte cap; child not reading or still draining an earlier large write) — dropping \(data.count, privacy: .public) byte write (one-shot log per backlog)"
            )
        }
        flushPendingLocked()
    }

    private func flushPendingLocked() {
        let fd = self.masterFD
        while pendingCount > 0 {
            let head = pendingHead
            let written: Int = pendingWrite.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + head, raw.count - head)
            }
            if written > 0 {
                pendingHead += written
                if pendingHead == pendingWrite.count {
                    pendingWrite.removeAll()
                    pendingHead = 0
                    pendingOverflowLogged = false
                } else if pendingHead >= pendingWrite.count / 2 {
                    pendingWrite.removeSubrange(0..<pendingHead)
                    pendingHead = 0
                }
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // Kernel tty queue full: return rather than park, and resume when the pty is writable again.
                scheduleDrainLocked()
                return
            }
            let savedErrno = errno
            Self.logger.error(
                "PTY.write FAILED with \(self.pendingCount, privacy: .public) bytes undelivered errno=\(savedErrno, privacy: .public) fd=\(fd, privacy: .public)"
            )
            discardPendingLocked()
            return
        }
    }

    private func discardPendingLocked() {
        pendingWrite.removeAll()
        pendingHead = 0
        exemptWriteLength = 0
        bytesBehindExemptWrite = 0
    }

    /// A level-triggered write source, not a retry timer: the tty input queue takes only ~1 KiB at a time,
    /// so a timer caps the drain at ~0.6 MiB/s however fast the child reads.
    private func scheduleDrainLocked() {
        guard drainSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: writeQueue)
        let live = drainSourceLive
        live.enter()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A writable pty fires continuously, so disarm before flushing; an EAGAIN inside the flush arms a fresh source.
            self.cancelDrainSourceLocked()
            guard self.shouldKeepRunning() else {
                self.discardPendingLocked()
                return
            }
            self.flushPendingLocked()
        }
        source.setCancelHandler { live.leave() }
        drainSource = source
        source.resume()
    }

    private func cancelDrainSourceLocked() {
        drainSource?.cancel()
        drainSource = nil
    }

    public func hasForegroundChild() -> Bool {
        // `stateQueue` serialises every `masterFD` use against the read loop's close: a syscall racing
        // the close could hit a kernel-recycled fd belonging to another subsystem.
        return stateQueue.sync {
            guard _isRunning else { return false }
            let fg = tcgetpgrp(masterFD)
            guard fg > 0 else { return false }
            let shellPgid = getpgid(childPID)
            if shellPgid <= 0 {
                return false
            }
            return fg != shellPgid
        }
    }

    public func foregroundWorkingDirectory() -> String? {
        let targetPID: pid_t? = stateQueue.sync {
            guard _isRunning else { return nil }
            let fg = tcgetpgrp(masterFD)
            return fg > 0 ? fg : childPID
        }
        guard let pid = targetPID else { return nil }
        return Self.workingDirectory(ofPID: pid)
    }

    /// `foregroundWorkingDirectory` cannot answer when the fg pgroup leader is setuid-root (`sudo`, `top`:
    /// `proc_pidinfo` gives EPERM) or already reaped (`ls | less`: ESRCH); the shell's cwd stays readable.
    public func shellWorkingDirectory() -> String? {
        let shellPID: pid_t? = stateQueue.sync { () -> pid_t? in
            guard _isRunning else { return nil }
            return childPID
        }
        guard let pid = shellPID else { return nil }
        return Self.workingDirectory(ofPID: pid)
    }

    private static func workingDirectory(ofPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let infoSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            infoSize
        )
        // The kernel contract permits a short return that leaves the tail zero-filled; treat it as failure.
        guard bytes > 0 else { return nil }
        guard bytes == infoSize else {
            Self.logger.error("workingDirectory(ofPID:): proc_pidinfo short read pid=\(pid, privacy: .public) got=\(bytes, privacy: .public) want=\(infoSize, privacy: .public) — kernel contract violation, returning nil")
            return nil
        }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuple -> String? in
            tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    #if DEBUG
    func _testGetNoSigPipeFlag() -> Int32 {
        return Darwin.fcntl(masterFD, F_GETNOSIGPIPE)
    }
    #endif

    /// The OSC 7 ingest gate trusts the shell-reported cwd only when the result is `.local`. Fails closed (`.unknown`)
    /// on any error, unlike the advisory `hasForegroundChild` / `foregroundWorkingDirectory`, which fail open.
    public func classifyForegroundNamespace() -> ForegroundNamespace {
        // Two roots: with job control a background job (`docker logs -f … &`) is a sibling of the foreground
        // command, not under it, so only the shell's subtree sees it while `vim` / `make` holds the terminal.
        let roots: [pid_t]? = stateQueue.sync {
            guard _isRunning else { return nil }
            let fg = tcgetpgrp(masterFD)
            guard fg > 0 else { return nil }
            return fg == childPID ? [fg] : [fg, childPID]
        }
        guard let roots else {
            return .unknown(reason: "PTY not running or tcgetpgrp ≤ 0")
        }
        return ForegroundProcessProbe.classify(rootPIDs: roots)
    }

    /// More reliable than writing 0x03 to the master fd: the shell may have turned off ISIG or changed VINTR.
    public func sendSignalToForeground(_ sig: Int32) {
        let pgrp: pid_t = stateQueue.sync {
            guard _isRunning else { return 0 }
            return tcgetpgrp(masterFD)
        }
        if pgrp > 0 {
            let rc = kill(-pgrp, sig)
            if rc < 0 {
                let savedErrno = errno
                let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                Self.logger.log(level: level, "sendSignalToForeground: kill(-\(pgrp, privacy: .public), \(sig, privacy: .public)) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
            }
        } else {
            let savedErrno = errno
            Self.logger.warning("sendSignalToForeground: tcgetpgrp returned \(pgrp, privacy: .public) errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
        }
    }

    // MARK: - Resize

    public func resize(to size: Size) {
        guard size.cols > 0, size.rows > 0 else {
            Self.logger.log(
                "PTY.resize refused degenerate dims cols=\(size.cols, privacy: .public) rows=\(size.rows, privacy: .public)"
            )
            return
        }
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )
        let result: Int32 = stateQueue.sync {
            guard _isRunning else { return 0 }
            return withUnsafeMutablePointer(to: &winsize) { ptr in
                ioctl(masterFD, TIOCSWINSZ, ptr)
            }
        }
        if result != 0 {
            let savedErrno = errno
            Self.logger.log(
                "PTY.resize TIOCSWINSZ failed errno=\(savedErrno, privacy: .public)"
            )
        }
    }

    // MARK: - Teardown

    #if DEBUG
    private(set) var _testTerminateBodyRanCount: Int = 0
    #endif

    /// True only while `reapState` is `.running` and, when a spawn-time baseline exists, the BSD start time still matches.
    private func escalationTargetIsStillOurChild(
        pid: pid_t, originalStartTime: (sec: UInt64, usec: UInt64)?, rung: StaticString
    ) -> Bool {
        let stillOurs = stateQueue.sync { reapState == .running }
        guard stillOurs else {
            Self.logger.log(
                "PTY.terminate \(rung, privacy: .public) rung stood down: child already reaped/reaping (pid \(pid, privacy: .public) may be recycled)"
            )
            return false
        }
        if let original = originalStartTime {
            guard let current = Self.bsdProcessStartTime(pid: pid),
                  current.sec == original.sec, current.usec == original.usec
            else {
                Self.logger.log(
                    "PTY.terminate \(rung, privacy: .public) rung stood down: pid \(pid, privacy: .public) identity unverifiable or mismatched"
                )
                return false
            }
        }
        return true
    }

    public func terminate() {
        // Atomic check-and-clear: concurrent callers must not both fire SIGHUP and start two escalations.
        let wasRunning: Bool = stateQueue.sync {
            let prev = _isRunning
            _isRunning = false
            return prev
        }
        guard wasRunning else { return }
        #if DEBUG
        stateQueue.sync { _testTerminateBodyRanCount += 1 }
        #endif
        // SIGHUP makes the read loop see EOF. The read queue stays the sole owner of masterFD's close
        // and the child's reap: closing here would race its read().
        let hupRC = kill(childPID, SIGHUP)
        if hupRC < 0 {
            let savedErrno = errno
            let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
            Self.logger.log(level: level, "terminate: kill(\(self.childPID, privacy: .public), SIGHUP) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
        }
        // A shell that ignores SIGHUP never closes the slave, so escalate. On a global queue: holding `stateQueue` or
        // `writeQueue` for the grace period would stall the read loop's close handshake or an in-flight write.
        let pid = childPID
        let originalStartTime = childStartTime
        // SIGTERM first, for a process that traps TERM but not HUP. Its default disposition terminates the receiver and
        // `kill(pid, 0)` succeeds for any process now owning the pid, so it takes the same identity guards as SIGKILL.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(100)
        ) { [weak self] in
            guard let self, self.escalationTargetIsStillOurChild(
                pid: pid, originalStartTime: originalStartTime, rung: "SIGTERM"
            ) else { return }
            guard kill(pid, 0) == 0 else { return }
            let termRC = kill(pid, SIGTERM)
            if termRC != 0 {
                let savedErrno = errno
                let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                Self.logger.log(level: level, "PTY.terminate intermediate SIGTERM: kill(\(pid, privacy: .public), SIGTERM) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(200)
        ) { [weak self] in
            // The reap-state gate also makes the no-baseline SIGKILL below safe: an un-reaped pid still names our child.
            guard let self, self.escalationTargetIsStillOurChild(
                pid: pid, originalStartTime: nil, rung: "SIGKILL-gate"
            ) else { return }
            guard kill(pid, 0) == 0 else { return }
            guard let original = originalStartTime else {
                // No baseline from spawn: send SIGKILL anyway. Skipping it would make a HUP-ignoring child
                // immortal (no EOF, no waitpid, a leaked master fd and a tab that cannot close).
                let killRC = kill(pid, SIGKILL)
                if killRC != 0 {
                    let savedErrno = errno
                    let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                    Self.logger.log(level: level, "PTY.terminate unverified SIGKILL: kill(\(pid, privacy: .public), SIGKILL) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public)) (no start-time captured at spawn)")
                } else {
                    Self.logger.log(
                        "PTY.terminate unverified SIGKILL pid=\(pid, privacy: .public) (no start-time captured at spawn — accepted PID-reuse risk in exchange for not leaking a HUP-ignoring child)"
                    )
                }
                return
            }
            guard let current = Self.bsdProcessStartTime(pid: pid) else {
                Self.logger.log(
                    "PTY.terminate skipped SIGKILL: pid=\(pid, privacy: .public) start-time unreadable, cannot verify identity"
                )
                return
            }
            guard current == original else {
                Self.logger.log(
                    "PTY.terminate skipped SIGKILL: pid=\(pid, privacy: .public) reused by another process"
                )
                return
            }
            let killRC = kill(pid, SIGKILL)
            if killRC != 0 {
                let savedErrno = errno
                let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                Self.logger.log(level: level, "PTY.terminate escalation: kill(\(pid, privacy: .public), SIGKILL) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
            } else {
                Self.logger.log(
                    "PTY.terminate escalated to SIGKILL pid=\(pid, privacy: .public) (HUP-ignoring child)"
                )
            }
        }
    }
}
