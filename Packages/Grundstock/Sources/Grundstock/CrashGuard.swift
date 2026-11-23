import Darwin
import Foundation
import MachO

/// The crash guard: writes, while dying, what the next launch is to read.
///
/// **Why it exists** (F-016 and F-009, 2026-09-03): TELVE 2 UHD crashed the
/// app twice, and both times the trace showed only a gap — the
/// recording ends with the last regular entry, and fetching a
/// crash log from the TV means Xcode, device window,
/// patience. MetricKit does not exist for tvOS. So the app catches the signal
/// itself, writes signal, activity and call chain to a file and
/// then dies as intended; the next launch enters the file into the
/// error trace, and the diagnostics take it along to the server.
///
/// **What is allowed inside a signal handler is little.** No Swift string, no
/// lock, no allocation: the thread that died may have been in the middle of `malloc`.
/// So everything is prepared — the file is open,
/// the header line is built, the activity sits in a fixed buffer —
/// and the handler only does `write` and `backtrace_symbols_fd`. Both
/// are made for this.
///
/// **What it does not see:** `SIGKILL` — the system terminating the app because of
/// memory does not ask. All that would remain is a marker that would have to be cleared on
/// every switch to the background, and it would have more
/// false alarms than hits.
public enum CrashGuard {

    /// The file in the cache folder — next to the traces.
    public static let filename = "\(AppBundleIdentifiers.shortName)-absturz.txt"
    static let activityCapacity = 256
    static let frameCapacity = 64
    static let alternateStackSize = 64 * 1024

    /// Which signals are caught: memory access, bus error, illegal
    /// instruction, abort (including Swift traps and exceptions), trap, arithmetic error.
    static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE]

    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var header: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let activity = UnsafeMutablePointer<CChar>.allocate(
        capacity: activityCapacity)
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>
        .allocate(capacity: frameCapacity)
    private static let activityLock = NSLock()

    /// What the previous run left behind — `nil` if it ended properly.
    /// ``Diagnostics/noteLaunch()`` picks it up and enters it into the trace.
    public nonisolated(unsafe) private(set) static var previousReport: String?

    /// Sets up the guard: reads what the previous run left behind,
    /// reopens the file and installs the handlers.
    ///
    /// - Parameters:
    ///   - directory: For tests only — otherwise the cache folder.
    ///   - catching: Whether the signal handlers are actually installed. A
    ///     test wants to see the file, not disarm the test runner.
    public static func install(directory: URL? = nil, catching: Bool = true) {
        let base =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: filename)

        if let text = try? String(contentsOf: url, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            previousReport = text
        }

        if fd >= 0 { close(fd) }
        fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) } ?? -1
        }

        // The header line now, with everything that can no longer be fetched later:
        // build state and the load address — without it, an
        // address in the call chain cannot be mapped to a source line.
        let slide = _dyld_get_image_vmaddr_slide(0)
        let loaded = _dyld_get_image_header(0).map { UInt(bitPattern: $0) } ?? 0
        let head =
            "Crash · " + Diagnostics.reportHeader(extras: []).joined(separator: " · ")
            + String(format: " · Image loaded at 0x%lx, slide 0x%lx", loaded, slide) + "\n"
        header?.deallocate()
        header = strdup(head)
        activity[0] = 0

        guard catching else { return }

        // A separate stack for the handler: a stack overflow would otherwise kill
        // the handler too, and exactly that case would stay silent. **tvOS
        // does not have `sigaltstack`** — there, stack overflow remains the
        // one kind of crash the guard does not see.
        var flags: Int32 = 0
        #if !os(tvOS)
            var stack = stack_t()
            stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: alternateStackSize, alignment: 16)
            stack.ss_size = alternateStackSize
            stack.ss_flags = 0
            if sigaltstack(&stack, nil) == 0 { flags = SA_ONSTACK }
        #endif

        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = fallen
            action.sa_flags = flags
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }

        NSSetUncaughtExceptionHandler { exception in
            CrashGuard.writeException(exception)
        }
    }

    /// Names what is currently running — the line that follows "during" in a crash.
    /// `nil` means: nothing worth mentioning.
    public static func note(activity text: String?) {
        let line = text.map { "during: " + $0.replacingOccurrences(of: "\n", with: " ") + "\n" } ?? ""
        activityLock.lock()
        defer { activityLock.unlock() }
        _ = line.withCString { strlcpy(activity, $0, activityCapacity) }
    }

    /// Takes the leftover — whoever has reported it deletes it with this.
    public static func takePreviousReport() -> String? {
        defer { previousReport = nil }
        return previousReport
    }

    // MARK: - The catcher

    /// Signal-safe: only `write`, `backtrace` and `backtrace_symbols_fd`.
    private static let fallen: @convention(c) (Int32) -> Void = { signal in
        // **Disarm first, then write.** If the handler itself stumbles —
        // `backtrace` over a destroyed stack — the same
        // signal would otherwise arrive in the same handler once more, and the app would hang until the
        // system terminates it: without chain, without signal, as if no one had ever been
        // there. With the default action restored, it dies immediately.
        for jedes in CrashGuard.signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = SIG_DFL
            sigaction(jedes, &action, nil)
        }
        CrashGuard.write(signal: signal)
        // Raise it once more: the system should see the crash as it would
        // see it without a guard.
        raise(signal)
    }

    static func write(signal: Int32) {
        guard fd >= 0 else { return }
        if let header { _ = Darwin.write(fd, header, strlen(header)) }
        let name = signalName(signal)
        _ = Darwin.write(fd, name.utf8Start, name.utf8CodeUnitCount)
        _ = Darwin.write(fd, activity, strlen(activity))
        let count = backtrace(frames, Int32(frameCapacity))
        backtrace_symbols_fd(frames, count, fd)
        fsync(fd)
    }

    private static func writeException(_ exception: NSException) {
        guard fd >= 0 else { return }
        // Everything is still allowed here: the exception handler runs before the
        // abort, not in the signal. The `SIGABRT` afterwards writes its
        // own chain behind it.
        let text =
            (header.map { String(cString: $0) } ?? "")
            + "Exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n"
            + String(cString: activity)
            + exception.callStackSymbols.joined(separator: "\n") + "\n"
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    static func signalName(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV: return "Signal 11 (SIGSEGV, memory access)\n"
        case SIGBUS: return "Signal 10 (SIGBUS)\n"
        case SIGILL: return "Signal 4 (SIGILL, illegal instruction)\n"
        case SIGABRT: return "Signal 6 (SIGABRT, abort — Swift trap or exception)\n"
        case SIGTRAP: return "Signal 5 (SIGTRAP, trap)\n"
        case SIGFPE: return "Signal 8 (SIGFPE, arithmetic error)\n"
        default: return "Signal (unknown)\n"
        }
    }

    // MARK: - Lesen

    /// Turns the leftover into two trace lines: the header (signal,
    /// activity) and the call chain, boiled down to what is readable.
    ///
    /// **Two lines, not forty:** The trace is line-based, and a
    /// crash is one event. The chain carries image and offset per frame
    /// (`CineLounge + 118784`) — enough to resolve it on the Mac with `atos`
    /// against the dSYM.
    public static func lines(from report: String, frameLimit: Int = 30) -> (head: String, frames: String) {
        var head: [String] = []
        var frames: [String] = []
        for raw in report.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.first?.isNumber == true, line.contains("0x") {
                if frames.count < frameLimit { frames.append(line) }
            } else if line.hasPrefix("Crash ·") {
                // The header only repeats what the diagnostics already
                // state — except for the load address, and that stays.
                if let range = line.range(of: "Image loaded") {
                    head.append(String(line[range.lowerBound...]))
                }
            } else {
                head.append(line)
            }
        }
        return (head.joined(separator: " · "), frames.joined(separator: " | "))
    }
}
