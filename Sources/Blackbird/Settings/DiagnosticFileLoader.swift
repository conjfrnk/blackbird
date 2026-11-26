import Foundation
import Darwin

enum DiagnosticFileLoader {
    static func loadAndSanitize(url: URL, cap: Int) async -> Result<String, LoadError> {
        let (result, _) = await loadAndSanitizeTraced(url: url, cap: cap)
        return result
    }

    static func loadAndSanitizeTraced(url: URL, cap: Int) async -> (Result<String, LoadError>, ranOffMain: Bool) {
        await Task.detached {
            // `Thread.isMainThread` is unavailable from async contexts; pthread_main_np is the same check.
            let ranOffMain = pthread_main_np() == 0
            // O_NOFOLLOW: a symlink swapped in after `reload()` fails with ELOOP instead of being followed.
            // O_NONBLOCK: `open` on a writer-less FIFO would block forever; the fstat gate below then rejects it.
            let fd = url.withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath = cPath else { return -1 }
                return Darwin.open(cPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            }
            if fd < 0 {
                let err = errno
                if err == ELOOP {
                    return (.failure(.symlinkRejected), ranOffMain)
                }
                let msg = String(cString: strerror(err))
                return (.failure(.read("open: \(msg)")), ranOffMain)
            }
            defer { Darwin.close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                let msg = String(cString: strerror(errno))
                return (.failure(.read("fstat: \(msg)")), ranOffMain)
            }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                return (.failure(.notRegularFile), ranOffMain)
            }
            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data: Data
            do {
                data = try fh.readToEnd() ?? Data()
            } catch {
                return (.failure(.read(error.localizedDescription)), ranOffMain)
            }
            // The file can grow between `reload()` and this read.
            if data.count > cap {
                return (.failure(.grewDuringRead(data.count)), ranOffMain)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return (.failure(.notUTF8), ranOffMain)
            }
            return (.success(Self.stripControlCharacters(text)), ranOffMain)
        }.value
    }

    enum LoadError: Error, Sendable, Equatable {
        case read(String)
        case grewDuringRead(Int)
        case notUTF8
        case symlinkRejected
        case notRegularFile
    }

    /// Replaces C0 / C1 controls and bidi / zero-width / invisible scalars (except `\n` and `\t`) with U+FFFD.
    /// The invisible set mirrors `stripBidiOverrides` in `TerminalView+Paste.swift`.
    internal static func stripControlCharacters(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.utf8.count)
        let replacement = Unicode.Scalar(0xFFFD)!
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // C1 (0x80-0x9F) carries VT control bytes that bypass ESC introducers.
            let isControl = (v < 0x20 && v != 0x0A && v != 0x09)
                || v == 0x7F
                || (v >= 0x80 && v <= 0x9F)
            // 200B-200F ZWSP..RLM, 2028/2029 LS/PS, 202A-202E bidi formatting, 2066-2069 isolates,
            // FE00-FE0F and E0100-E01EF variation selectors, E0000-E007F tags.
            let isInvisible = v == 0x00AD
                || v == 0x061C
                || v == 0x180E
                || (v >= 0x200B && v <= 0x200F)
                || (v >= 0x2028 && v <= 0x202E)
                || v == 0x2060
                || (v >= 0x2066 && v <= 0x2069)
                || (v >= 0xFE00 && v <= 0xFE0F)
                || v == 0xFEFF
                || (v >= 0xE0000 && v <= 0xE007F)
                || (v >= 0xE0100 && v <= 0xE01EF)
            if isControl || isInvisible {
                out.append(replacement)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
