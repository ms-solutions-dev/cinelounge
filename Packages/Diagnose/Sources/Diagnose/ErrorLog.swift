import Core
import Foundation

/// The persistent error log.
///
/// **Why it exists in addition to `Core.Diagnostics.Trace`:** that ring buffer lives in
/// memory and does not survive an app launch. On the TV that is enough — an
/// Apple TV is running or off. On the phone, termination is the normal case: the app
/// is cleaned up because someone is on a call, and the error from a moment ago is gone. Exactly the one
/// that one looks for afterwards.
///
/// **One line of JSON per entry, append only.** A file that is only
/// appended to survives a crash in the middle of writing: then the last
/// line is missing and not the file. Writing happens **immediately** and is not batched — a
/// log that loses its last entry in a crash loses exactly the one it
/// was about.
///
/// **One book per app version.** It starts over as soon as the version or
/// build number changes — not on every launch. Why this difference is not
/// petty is stated at ``VersionChange``.
public actor ErrorLog {

    public static let shared = ErrorLog()

    /// Whether ordinary steps get into the book too. Switch in Settings
    /// (area 8, Diagnostics).
    public private(set) var verbose = false

    private let location: URL?

    /// Whether this is **the** book of the program.
    ///
    /// Only the leading book checks the version, notes it in the standard store and also cleans
    /// up the trace files in `Core`. A test brings its own file — it
    /// should neither write to the computer's store nor delete the trace of the running
    /// program just because it wanted to write two lines.
    private let leading: Bool

    /// Whether the version has already been checked in this program run. Once per run suffices;
    /// it cannot change as long as the program runs.
    private var versionChecked = false

    /// The cleanup of the traces in `Core`, while it is still running.
    ///
    /// Whoever wants to **count** waits for it: otherwise the diagnostics name the number from a moment ago,
    /// and precisely at the first look after a build.
    private var traceCleanup: Task<Void, Never>?

    private let encoder: JSONEncoder = {
        let k = JSONEncoder()
        k.dateEncodingStrategy = .iso8601
        return k
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameter location: Where the book lives. Without it the usual place; the tests
    ///   pass their own file so that they do not read each other.
    public init(location: URL? = nil) {
        self.location = location ?? (try? StoreLocation.errorLog())
        self.leading = location == nil
    }

    /// Sets the switch — and is at the same time the **earliest door** into the book.
    ///
    /// `Startup.restoreRecording()` calls this in the app's `init`, before the first screen
    /// and before the first measured line. That is why it is also checked here whether the book still
    /// belongs to the running build: a reset that takes effect only at the first error message
    /// throws away the lines that had already been written by then.
    public func setVerbose(_ isOn: Bool) {
        checkVersion()
        verbose = isOn
    }

    /// Writes an entry if it belongs in according to the rule.
    ///
    /// The sentence is redacted here and not at the call site: a rule that every
    /// call site would have to apply itself gets forgotten at one of them.
    public func note(_ entry: ContentEntryRecord) {
        guard entry.severity.belongsInLog(verbose: verbose) else { return }
        let clean = ContentEntryRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            area: entry.area,
            severity: entry.severity,
            message: Redaction.sanitized(entry.message))
        append(clean)
    }

    /// What is in the book, oldest first.
    public func entries() -> [ContentEntryRecord] {
        guard let location = ledger(), let data = try? Data(contentsOf: location) else { return [] }
        let rows = data.split(separator: UInt8(ascii: "\n"))
        return rows.compactMap { try? decoder.decode(ContentEntryRecord.self, from: Data($0)) }
    }

    /// Throws away what is no longer supposed to remain after ``Cleanup``.
    ///
    /// Does not run on every write: rewriting the book costs more than an
    /// append, and it pays off only when there is really too much in it.
    @discardableResult
    public func cleanUp(now: Date = .now) -> Int {
        let allEntries = entries()
        let remains = Cleanup.remains(allEntries, now: now)
        guard remains.count < allEntries.count, let location else { return 0 }
        let data = remains.compactMap { try? encoder.encode($0) }
            .map { $0 + Data([UInt8(ascii: "\n")]) }
            .reduce(Data(), +)
        try? data.write(to: location, options: .atomic)
        return allEntries.count - remains.count
    }

    public func clear() {
        guard let location else { return }
        try? FileManager.default.removeItem(at: location)
    }

    // MARK: - Wie lange ein Buch gilt

    /// For which version this book is kept — **and since when.**
    ///
    /// Asks for the version first, so that the answer is already the new one: whoever opens the
    /// diagnostics first after a build should not read yesterday's version there
    /// and next to it today's numbers.
    public func versionState() async -> LogVersion? {
        checkVersion()
        await traceCleanup?.value
        return VersionChange.state()
    }

    /// Starts all three books over by hand — **for the targeted experiment.**
    ///
    /// Between two build runs there is no version change, and yet one wants to start from zero before
    /// an experiment ("now I'll break it, and everything that
    /// appears in the book afterwards belongs to it"). Without this path the only option would be to
    /// build once for nothing.
    ///
    /// **All three and not only its own.** The number that bothered the client
    /// ("266 errors") lives in ``Core/TraceRecorder/errors`` — a clearing that hit only
    /// its own book would leave exactly that standing and look like a broken button.
    @discardableResult
    public func restart(now: Date = .now) async -> LogVersion {
        if leading {
            await TraceRecorder.errors.clear()
            await TraceRecorder.shared.clear()
        }
        return begin(LogVersion(version: VersionChange.current(), started: now))
    }

    /// Checks once per program run whether the book still belongs to the running build.
    ///
    /// **Why by version and not at program launch** is stated at ``VersionChange``:
    /// a reset on every launch would lose the log exactly when the app
    /// crashes and restarts — in the only case in which it is needed.
    ///
    /// **Called from every door and not from one.** ``ledger()`` sits in front of every read
    /// and every write, ``setVerbose(_:)`` is the earliest. Which comes first
    /// is decided by the run; that is why each one checks, and the marker ensures that
    /// it still happens once.
    private func checkVersion() {
        guard !versionChecked, leading else { return }
        versionChecked = true

        let current = VersionChange.current()
        guard VersionChange.changes(to: current) else { return }
        begin(LogVersion(version: current, started: .now))

        // **The traces in `Core` in a task of their own.** They sit behind a
        // different actor; if waiting for them here, in the meantime a
        // line could fall into the book that was just cleared and stay in it without the
        // opening line standing before it. The book is by then already fully fresh — and whoever
        // counts waits for this task via ``versionState()``.
        traceCleanup = Task {
            await TraceRecorder.errors.clear()
            await TraceRecorder.shared.clear()
        }
    }

    /// Clears the book and writes the line that says what it applies to from now on.
    @discardableResult
    private func begin(_ state: LogVersion) -> LogVersion {
        versionChecked = true
        clear()
        if leading { VersionChange.memorize(state) }
        append(
            ContentEntryRecord(
                timestamp: state.started, area: .surface, severity: .hint,
                message: state.opening))
        return state
    }

    /// The location of the book — **and the place where it checks its age.**
    ///
    /// Reading and writing both pass through here. A check that instead stood at
    /// every public declaration would be missing at the next one that is added.
    private func ledger() -> URL? {
        checkVersion()
        return location
    }

    /// Appends a line — and tells the console if that does not work.
    ///
    /// An error book that conceals its own failure is the worst
    /// kind of tool: it reports nothing, and one takes that for "nothing happened".
    /// `os.log` is the only place that is still left here.
    private func append(_ entry: ContentEntryRecord) {
        guard let location = ledger(), var row = try? encoder.encode(entry) else { return }
        row.append(UInt8(ascii: "\n"))

        do {
            if FileManager.default.fileExists(atPath: location.path()) {
                let handle = try FileHandle(forWritingTo: location)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: row)
            } else {
                try row.write(to: location, options: .atomic)
            }
        } catch {
            Diagnostics.network.error(
                "Error log not writable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
