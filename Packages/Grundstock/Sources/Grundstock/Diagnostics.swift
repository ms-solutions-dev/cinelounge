import Foundation
import OSLog
import Synchronization

/// Logging that actually helps when something fails.
///
/// On the TV nobody can look at logs, and a message like
/// "No response" does not reveal whether the address was wrong, the system refused
/// the connection from the start, or the server stayed silent. That is why
/// every attempt is recorded with **address, result and cause** —
/// and the cause translated into plain text instead of leaving only a number behind.
///
/// Read it out with (subsystem is the bundle ID, see ``AppBundleIdentifiers``):
/// ```
/// xcrun simctl spawn booted log show --predicate 'subsystem == "dev.ms-solutions.cinelounge"'
/// ```
///
/// **What lives here and what does not** (Grundstock split, 17.09.2026): network calls,
/// flow trace, ring buffer, profile sheet and the rules for redaction apply to
/// every program for the home lab. The playback and focus traces know
/// image and remote and therefore live as an extension in `Core`.
public enum Diagnostics {

    public static let network = Logger(
        subsystem: AppBundleIdentifiers.bundles,
        category: "network"
    )

    /// The course of a process — a trace of its own, not with the network calls.
    ///
    /// **Why separate:** A process rarely fails with an error. It
    /// fails because something does not happen — a state that does not arrive, a
    /// seek that lapses, a buffer that does not fill. Such a thing can only be recognized by
    /// the **order and the gaps**, and those get lost among
    /// server calls. Together in the same trace, the course reads like
    /// a log; scattered, it is unreadable.
    ///
    /// In `Core`, the same trace is called ``playback`` — there the process is a
    /// playback. The category stays `playback`, so that `log.sh` and the
    /// analyses keep working.
    public static let flow = Logger(
        subsystem: AppBundleIdentifiers.bundles,
        category: "playback"
    )

    /// Records one step of the process, with the time since the start.
    ///
    /// The time is the actual information here and not an extra: that a seek
    /// went out 0.6 seconds after loading was the whole bug — nothing was visible from the message
    /// alone, only from the gap to the line above.
    ///
    /// - Parameter bereich: What the trace entry calls the process — "Wiedergabe"
    ///   on the TV, "Lesen" in the reading app.
    public static func step(_ step: String, since start: Date?, area: String = "Ablauf") {
        flow.info("\(elapsed(since: start), privacy: .public) \(step, privacy: .public)")
        if let entry = verboseEntry(step, failed: false, area: area) {
            Task { @MainActor in Trace.record(entry) }
        }
    }

    /// Like ``step(_:since:area:)``, but as an error — so that it is visible
    /// without `--info`.
    ///
    /// The difference counts in practice: without further action, `log show` shows only
    /// errors. An anomaly stored as `info` is found only by someone who is
    /// already looking for it.
    public static func defect(_ step: String, since start: Date?, area: String = "Ablauf") {
        flow.error("\(elapsed(since: start), privacy: .public) \(step, privacy: .public)")
        if let entry = verboseEntry(step, failed: true, area: area) {
            Task { @MainActor in Trace.record(entry) }
        }
    }

    /// Like ``defect(_:since:area:)``, but with the error itself — **and a cancellation is
    /// not a defect** (CineLounge on-device test build 1332, finding 12, 2026-09-27).
    ///
    /// The cause comes from ``explain(_:)`` and follows the step. If the error
    /// is a cancellation (``isCancellation(_:)``), the line goes only into the verbose
    /// recording: a request nobody is waiting for any more has done nothing wrong.
    public static func defect(
        _ step: String, error: any Error, since start: Date?, area: String = "Ablauf"
    ) {
        guard let message = defectMessage(step, error: error) else {
            verbose("\(step): cancelled", since: start, area: area)
            return
        }
        defect(message, since: start, area: area)
    }

    /// The sentence for a defect with an error — `nil` for a cancellation. A calculation, so that
    /// it can be checked without the shared trace.
    static func defectMessage(_ step: String, error: any Error) -> String? {
        isCancellation(error) ? nil : "\(step): \(explain(error))"
    }

    /// Whether an error merely says that nobody is waiting for the answer any more — `URLError.cancelled`
    /// (-999), a `CancellationError`, or the same as an `NSError`.
    ///
    /// **The finding:** The always-kept error log contained "Bewertungen holen ✗ Netzwerkfehler
    /// -999" seven times per scroll and "Portalanfrage nicht erreichbar: Netzwerkfehler -999":
    /// anyone who scrolls on quickly cancels the requests of the previous tiles, and that is
    /// intended. Nobody soon reads red lines for the normal case — and then not
    /// the one line that matters either.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError { return url.code == .cancelled }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Records a step only with verbose recording.
    ///
    /// For the places that would be too much in normal operation: every buffer message, every
    /// seek decision, every built address. They are exactly what is missing when
    /// hunting a stutter — and exactly what would drown a trace of fifty
    /// slots in everyday use. The switch for it is in Settings
    /// under "Diagnostics", see ``DebugMode``.
    ///
    /// `@autoclosure`, so that the text is not built at all in the normal case —
    /// these calls sit in the rhythm of the process.
    ///
    /// `area` deliberately has no default value: `Core` puts a
    /// two-parameter `verbose(_:since:)` next to it, and two versions that both
    /// fit the same call would be an ambiguity waiting to happen.
    public static func verbose(
        _ stepName: @autoclosure () -> String, since start: Date? = nil, area: String
    ) {
        guard DebugMode.current.isOn else { return }
        step(stepName(), since: start, area: area)
    }

    /// The trace entry for a playback step — or `nil` if none
    /// belongs there.
    ///
    /// **The one rule of all logging** (requirement 2026-08-15):
    /// An **error** ALWAYS belongs in the trace — a diagnostic that records the error
    /// only if someone flipped a switch beforehand is empty at the
    /// real error. An ordinary **step**, by contrast, appears only with
    /// verbose recording: in everyday use it would displace the errors
    /// the trace exists for. In the system log both are always present.
    /// Extracted as a function of its own so that the rule can be checked
    /// without waiting for the detached entry task.
    static func verboseEntry(
        _ text: String,
        failed: Bool,
        enabled: Bool = DebugMode.current.isOn,
        area: String = "Ablauf"
    ) -> Trace.Entry? {
        guard enabled || failed else { return nil }
        return Trace.Entry(
            at: Date(),
            step: area,
            target: failed ? "" : text,
            outcome: failed ? .failed(text) : .succeeded("")
        )
    }

    /// Below this limit, `[%5.1fs]` renders only `0.0` anyway.
    ///
    /// The limit is thus tied to the resolution of the field and not to
    /// an opinion about what is fast.
    static let elapsedResolution: TimeInterval = 0.05

    /// The time since a reference point, as a fixed-width field.
    ///
    /// **Without information, no acquittal — even with your own timestamp.** Anyone who
    /// passes `since: Date()` fetches the reference point at the moment of reporting
    /// and gets a zero that nobody measured. Three patterns,
    /// each with exactly one meaning:
    ///
    /// - `[  —  ]` — no usable reference point: none passed, or one
    ///   that lies after the report.
    /// - `[ <0.1s]` — measured, but below the resolution of the field.
    /// - `[ 12.3s]` — a span that can be talked about.
    ///
    /// A dash and a zero must not look the same; otherwise
    /// a missing reference point reads like a lightning-fast step.
    ///
    /// `now` is passed in so that the function can be checked at all. The
    /// scope is limited: the field appears only in the line for the
    /// system log, never in the trace entry and thus never in the uploaded
    /// report.
    static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "[  —  ]" }
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 0 else { return "[  —  ]" }
        guard seconds >= elapsedResolution else { return "[ <0.1s]" }
        return String(format: "[%5.1fs]", seconds)
    }

    /// The latest messages, for display **on the TV**.
    ///
    /// **Because nobody can get at a log there.** On the Mac `log show` suffices; on the
    /// Apple TV it does not work: over the network macOS refuses collection ("Device
    /// not configured"), and with a cable you are standing in the living room. That is exactly when you need
    /// it, though — an error that occurs only on the TV can otherwise only be guessed.
    ///
    /// A ring buffer of fixed length and nothing more: it should carry the latest
    /// troubleshooting, not keep an operating diary. What is older no longer helps
    /// and would only hold memory.
    @MainActor
    public enum Trace {

        /// An entry as it appears in Settings.
        public struct Entry: Identifiable, Sendable, Equatable {
            public let id = UUID()
            public let at: Date
            public let step: String
            /// The address, already without credentials — see ``Diagnostics/loggable(_:)``.
            public let target: String
            public let outcome: Outcome

            /// Public, so that the extensions in `Core` (playback and
            /// focus traces) can build their entries themselves.
            public init(at: Date, step: String, target: String, outcome: Outcome) {
                self.at = at
                self.step = step
                self.target = target
                self.outcome = outcome
            }

            public enum Outcome: Sendable, Equatable {
                case started
                case succeeded(String)
                /// The translated cause, not the error number.
                case failed(String)
            }

            /// The line as it appears in the report and the disk trace — without
            /// timestamp, which ``TraceRecorder`` sets when appending.
            ///
            /// Here and not in the report: the report now reads the
            /// file, and two formattings of the same entry would
            /// drift apart.
            public var reportLine: String {
                let mark: String
                switch outcome {
                case .started: mark = "→"
                case .succeeded(let detail): mark = detail.isEmpty ? "✓" : "✓ \(detail)"
                case .failed(let reason): mark = "✗ \(reason)"
                }
                return "\(step)  \(target)  \(mark)"
            }
        }

        /// How many entries are kept.
        ///
        /// Fifty cover a sign-in attempt with everything attached to it several times over.
        /// More could not be read on a TV anyway.
        public static let capacity = 50

        /// How many there are with verbose recording.
        ///
        /// Fifty would be full there in seconds: every successful request and every
        /// playback step is added, and precisely the line for which the
        /// switch was flipped would fall off the end. Two hundred carry an
        /// entire playback test — such a trace is not read on the
        /// TV anyway, but in the uploaded report.
        public static let verboseCapacity = 200

        /// The limit currently in force — it follows the switch.
        static var currentCapacity: Int {
            DebugMode.current.isOn ? verboseCapacity : capacity
        }

        public private(set) static var entries: [Entry] = []

        /// The entries in chronological order, for display and report.
        ///
        /// **Not the same as ``entries``.** Entries are made via detached
        /// tasks, and nobody promises their order — two almost
        /// simultaneous messages can arrive swapped. Anyone who outputs the raw list
        /// then shows an "after" before its "before", and every troubleshooting here
        /// depends on exactly such gaps. For output, the clock counts,
        /// not the luck of the queueing.
        public static var chronological: [Entry] {
            entries.sorted { $0.at < $1.at }
        }

        /// Queues an entry — also for the extensions in `Core`
        /// (playback and focus traces), hence public.
        public static func record(_ entry: Entry) {
            entries.append(entry)
            if entries.count > currentCapacity {
                entries.removeFirst(entries.count - currentCapacity)
            }
            // To disk, and **separated by kind** (requirement
            // 2026-08-15): errors into the error trace, which always runs — the report
            // should carry it even if nobody ever flipped a switch.
            // Every line goes into the recording (the error too, the
            // context belongs there), but only while the switch is on.
            // Bounded on a rolling basis; the rules are at ``TraceRecorder``.
            let line = entry.reportLine
            let at = entry.at
            let isFailure = if case .failed = entry.outcome { true } else { false }
            let isRecording = DebugMode.current.isOn
            Task.detached(priority: .utility) {
                if isFailure { await TraceRecorder.errors.append(line, at: at) }
                if isRecording { await TraceRecorder.shared.append(line, at: at) }
            }
        }

        public static func clear() {
            entries = []
        }
    }

    /// Enters a message into the trace that is readable on the TV.
    ///
    /// Separate from the system log and in addition to it: one is for the
    /// Mac, the other for the living room.
    private static func trace(
        _ url: URL,
        step: String,
        outcome: Trace.Entry.Outcome
    ) {
        let entry = Trace.Entry(
            at: Date(),
            step: step,
            target: loggable(url),
            outcome: outcome
        )
        Task { @MainActor in Trace.record(entry) }
    }

    /// The profile sheet for the head of a submitted diagnostic.
    ///
    /// **The trace without state is half a trace** (requirement 2026-08-15): Every
    /// evaluation began with the question of whether the finding comes from the new or the old
    /// build — and the answer was nowhere. The build time is
    /// the actual identifier here: the version number does not change between
    /// two test builds on the same day, the timestamp of the
    /// program file always does.
    ///
    /// - Parameter zusatz: Lines that only a particular program knows — `Core`
    ///   appends engine and decoder here (NWRX-RP, 2026-09-03), the reading app nothing.
    public static func reportHeader(extras: [String]) -> [String] {
        let bundle = Bundle.main
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var built = "unknown"
        if let executable = bundle.executableURL,
            let date = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
        {
            built = date.formatted(date: .abbreviated, time: .standard)
        }

        var uts = utsname()
        uname(&uts)
        let model = withUnsafeBytes(of: &uts.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        return [
            "Version: \(version) (Build \(build)), built \(built)",
            "Device: \(model), \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Debug mode: \(DebugMode.current.isOn ? "on" : "off")",
        ] + extras
    }

    /// Writes the state marker into both traces — to be called at app launch.
    ///
    /// **Without it a multi-day trace cannot be attributed** (requirement
    /// 2026-08-15): The files carry three days and thus several build states; only
    /// the marker in between says which entry belongs to which build.
    public static func noteLaunch(extras: [String]) {
        let line = "— App launch · " + reportHeader(extras: extras).joined(separator: " · ") + " —"
        Task.detached(priority: .utility) {
            await TraceRecorder.errors.append(line)
            await TraceRecorder.shared.append(line)
        }
        // **The crash of the previous run, right after the state marker** —
        // as a defect, so that it appears in the error trace and travels with the diagnostics
        // to the server. Rationale at ``CrashGuard``.
        if let report = CrashGuard.takePreviousReport() {
            let (head, frames) = CrashGuard.lines(from: report)
            defect("Crash in the previous run: \(head)", since: nil)
            if !frames.isEmpty { defect("Call chain: \(frames)", since: nil) }
        }
    }

    /// Writes the switch change into the recording.
    ///
    /// So that a trace with a gap does not look like an error: between
    /// "switched off" and "switched on" the silence has an explanation.
    public static func noteRecordingSwitch(isOn: Bool) {
        let line = "— Recording \(isOn ? "switched on" : "switched off") —"
        Task.detached(priority: .utility) {
            await TraceRecorder.shared.append(line)
        }
    }

    /// Records a connection attempt.
    ///
    /// **In the trace only with verbose recording** — the rule is at
    /// ``verboseEntry(_:failed:enabled:)``: successes and starts are
    /// recording, not error history. In the system log it is always present.
    public static func attempt(_ url: URL, step: String) {
        network.info("→ \(step, privacy: .public): \(loggable(url), privacy: .public)")
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .started)
    }

    public static func success(_ url: URL, step: String, detail: String = "") {
        network.info(
            "✓ \(step, privacy: .public): \(loggable(url), privacy: .public) \(detail, privacy: .public)"
        )
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .succeeded(detail))
    }

    /// What is known about the **connection**, not about the request.
    ///
    /// **That is the difference between knowing and guessing.** A timeout
    /// says only that no answer came. It does not say whether a connection was
    /// established at all, whether an existing one was reused, and whether data flowed.
    /// This is exactly where a troubleshooting effort got stuck here: the same call takes 50 milliseconds
    /// from the Mac and runs into the timeout twice from the TV — with these
    /// numbers it can be told apart, without them it is a guess.
    ///
    /// The suspicion for which they are collected: tvOS releases network connections
    /// when an app goes to the background ("socket resource reclaim", TN2277), but
    /// the socket is still remembered. The next request on it then hangs until the
    /// timeout, without an error message. If ``reused`` is true on a failure and
    /// ``connectDuration`` is empty, that is exactly what happened.
    public struct ConnectionFacts: Sendable, Equatable {
        /// Whether an existing connection was used.
        public let reused: Bool
        /// `http/1.1`, `h2` — depending on what was negotiated.
        public let networkProtocol: String?
        /// The remote end, as actually reached. Reveals, among other things,
        /// whether IPv6 was used.
        public let remoteAddress: String?
        /// How long establishing the connection took. Empty on reuse.
        public let connectDuration: TimeInterval?
        /// How long it took until the first byte of the response.
        public let timeToFirstByte: TimeInterval?
        public let bytes: Int64

        public init(
            reused: Bool,
            networkProtocol: String?,
            remoteAddress: String?,
            connectDuration: TimeInterval?,
            timeToFirstByte: TimeInterval?,
            bytes: Int64
        ) {
            self.reused = reused
            self.networkProtocol = networkProtocol
            self.remoteAddress = remoteAddress
            self.connectDuration = connectDuration
            self.timeToFirstByte = timeToFirstByte
            self.bytes = bytes
        }

        /// A line that is readable on the TV.
        public var summary: String {
            var parts: [String] = [reused ? "connection reused" : "new connection"]
            if let networkProtocol { parts.append(networkProtocol) }
            if let connectDuration {
                parts.append("setup \(Self.millis(connectDuration))")
            }
            if let timeToFirstByte {
                parts.append("first byte after \(Self.millis(timeToFirstByte))")
            } else {
                // The most important case, and therefore spelled out: nothing ever came
                // back. An empty field would look like "not measured" here.
                parts.append("no response received")
            }
            if bytes > 0 { parts.append("\(bytes) Bytes") }
            return parts.joined(separator: ", ")
        }

        static func millis(_ seconds: TimeInterval) -> String {
            seconds < 1
                ? "\(Int(seconds * 1000)) ms"
                : String(format: "%.1f s", seconds)
        }
    }

    /// Records how a connection came about — regardless of whether the request
    /// succeeded.
    ///
    /// **Not every** request is recorded: a Home screen triggers dozens, and
    /// fifty entries would be full after the first image build-up. What is entered is what is
    /// conspicuous — a failure or a request that stalled unusually long.
    public static func connection(_ url: URL, step: String, facts: ConnectionFacts) {
        network.info(
            "◇ \(step, privacy: .public): \(loggable(url), privacy: .public) — \(facts.summary, privacy: .public)"
        )
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .succeeded(facts.summary))
    }

    /// How a measurement turned out.
    ///
    /// **Because a defect could not be recorded at all so far.** Every measurement went into the trace as a
    /// success; the session of 2026-08-23 produced 579 measurements and
    /// not a single error line — despite dropouts and a 415 s lead. A
    /// named outcome instead of a Boolean reads at the
    /// call site as a statement: `probe(text, verdict: .problem)`.
    public enum ProbeVerdict: Sendable, Equatable {
        /// Zahlenwerk ohne Mangel.
        case plain
        /// The measurement names a defect.
        case problem
    }

    /// Records the result of a measurement — of the connection or of a playback.
    ///
    /// Multi-line, unlike everything else in the trace: a measurement is not an event
    /// but a finding, and that cannot be squeezed into one line without leaving out exactly
    /// what the measurement was for.
    ///
    /// **A defect waits for no switch** (finding 2026-08-24). That is
    /// word for word the rule that ``verboseEntry(_:failed:enabled:)`` already
    /// enforces: a diagnostic that knows the defect only with the switch flipped
    /// is empty at the real defect. That is why `.problem` goes out as an error —
    /// visible in `log show` without `--info` — and into the trace without a detour via
    /// ``DebugMode``.
    ///
    /// The logger deliberately stays ``network`` and does not become ``playback``, so that
    /// existing evaluations and searches for `◆` keep working; only the
    /// level has changed.
    @MainActor
    public static func probe(_ text: String, verdict: ProbeVerdict = .plain) {
        switch verdict {
        case .plain:
            network.info("◆ Measurement:\n\(text, privacy: .public)")
            guard DebugMode.current.isOn else { return }
            Trace.record(
                Trace.Entry(at: Date(), step: "Messung", target: "", outcome: .succeeded(text))
            )
        case .problem:
            network.error("◆ Measurement — defect:\n\(text, privacy: .public)")
            Trace.record(
                Trace.Entry(at: Date(), step: "Messung", target: "", outcome: .failed(text))
            )
        }
    }

    /// Records a failure — with translated cause.
    ///
    /// **A cancellation is not a failure** (finding 12, see ``isCancellation(_:)``): It appears in the
    /// system log as info and in the trace only with verbose recording — never in the
    /// error log, which always runs.
    public static func failure(_ url: URL, step: String, error: Error) {
        guard !isCancellation(error) else {
            network.info(
                "↺ \(step, privacy: .public): \(loggable(url), privacy: .public) — cancelled")
            if let outcome = traceOutcome(forItem: error) { trace(url, step: step, outcome: outcome) }
            return
        }
        let explained = explain(error)
        network.error(
            "✗ \(step, privacy: .public): \(loggable(url), privacy: .public) — \(explained, privacy: .public)"
        )
        trace(url, step: step, outcome: .failed(explained))
    }

    /// What a failure leaves in the trace — `nil` if nothing: a cancellation appears
    /// in it only with verbose recording, and then not as a failure.
    static func traceOutcome(
        forItem error: any Error, recording: Bool = DebugMode.current.isOn
    ) -> Trace.Entry.Outcome? {
        guard isCancellation(error) else { return .failed(explain(error)) }
        return recording ? .succeeded("cancelled") : nil
    }

    /// The path segments behind which the access sits for an Xtream provider.
    ///
    /// **The form is recognized, not the password.** Which part of a foreign
    /// address is the access is not known to this package — but at which
    /// position it sits is: `XtreamEndpoint.streamURL` assembles every stream address as
    /// `/live|movie|series/USER/PASSWORD/ID[.ts]`
    /// (XtreamEndpoint.swift:165-176).
    ///
    /// The lowercase is deliberate and not carelessness: the own
    /// media server uses `/LiveTv/…`, and that is not a provider address.
    private static let credentialCarryingSections: Set<String> = ["live", "movie", "series"]

    /// The address as it may enter the log: without query part and without
    /// credentials in the address itself.
    ///
    /// **Why this is here and not at every caller:** The addresses of the
    /// IPTV world carry the access in the query part, and consistently —
    /// `get.php?username=…&password=…` for the channel list,
    /// `xmltv.php?username=…&password=…` for the program guide. Anyone who logs such an
    /// address in full writes the password in plain text
    /// into the system log, and as `.public`, so also into every
    /// error report that someone passes on. Providers block an access that is
    /// used from several places — the viewer then loses not one
    /// show but TV altogether.
    ///
    /// This rule could not be held at the individual caller: it was forgotten once
    /// as soon as a second place logged addresses. Here it applies
    /// to every caller, including the next one.
    ///
    /// Decompose instead of search: searching for the password would presuppose knowing it
    /// — with an M3U address that the user enters as a whole line, nobody knows
    /// which part of it is the access. What remains — host, port
    /// and path — suffices for the purpose: telling which call
    /// failed.
    ///
    /// **The path is the second place where the access sits.** The stream address
    /// of an Xtream provider has no query part at all; there, user and
    /// password sit between segment and ID — see
    /// ``credentialCarryingSections``. Only this form is masked, and the ID
    /// stays: without it one could no longer say which channel failed.
    public static func loggable(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // An address that cannot be decomposed is exactly the one where
            // it cannot be said where the access sits. Better nothing then.
            return "(address cannot be displayed)"
        }

        parts.query = nil
        parts.fragment = nil
        // `http://user:isSecret@server/list.m3u` kommt vor — manche Anbieter
        // geben ihre Adresse so heraus.
        parts.user = nil
        parts.password = nil

        // The placeholders are deliberately ASCII capital letters and not
        // `•••`: `URLComponents` encodes everything outside ASCII when
        // assembling, three dots would become `%E2%80%A2%E2%80%A2%E2%80%A2` and
        // the line would be unreadable.
        //
        // Everything between segment and ID is replaced, not just two fixed
        // positions: `XtreamEndpoint` explicitly does NOT encode a slash in the password
        // (otherwise the server would not find the path), and the
        // observed passwords are doubly nested Base64 — whose
        // alphabet contains the slash. Such a password yields more than
        // five segments, and the rest would otherwise remain in the log.
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count >= 5, segments[0].isEmpty,
            credentialCarryingSections.contains(String(segments[1]))
        {
            let section = String(segments[1])
            let id = String(segments[segments.count - 1])
            parts.path = "/\(section)/USER/PASSWORD/\(id)"
        }

        return parts.url?.absoluteString ?? "(address cannot be displayed)"
    }

    /// How much foreign text may go into a line at most.
    public static let borrowedTextLimit = 160

    /// Passes on foreign text only if no address is hidden in it.
    ///
    /// **Recognize the form, do not search for the access.** With an Xtream provider,
    /// username and password sit in the PATH
    /// (`/live/USER/PASSWORD/ID.ts`, XtreamEndpoint.swift:174).
    /// ``loggable(_:)`` handles this form but can only do so for a `URL` — in
    /// foreign running text (`localizedDescription`, an `NSError` dump, a
    /// comment from the engine's error log) the address sits somewhere
    /// in the middle and cannot be safely cut out. Hence the hard
    /// rule here: wherever `://` occurs, the whole text does not go out. What is in the report
    /// of 2026-08-23 at line 54 is the proof that foreign text passed
    /// through takes the access along in plain text.
    ///
    /// **Why in Core and not at the engine:** From 2026-08-26 the rule existed a
    /// second time in `NativePlaybackEngine`, because it was needed there and
    /// missing here — exactly the duplication the comment at
    /// ``loggable(_:)`` warns about. A rule that exists in two places gets forgotten in one
    /// of them.
    ///
    /// The line-break smoothing is an extra and not a necessity:
    /// `TraceRecorder.append` already replaces `\n` with a space
    /// (TraceRecorder.swift:64), so the submitted report does not fall apart.
    /// Two gaps remain, though — the trace display on the TV does not smooth at all
    /// (DiagnosticsSettings.swift:311), and `\r` leaves that line standing, while
    /// `isNewline` catches it.
    public static func withoutAddress(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard !text.contains("://") else { return "(contains an address — omitted)" }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > borrowedTextLimit else { return flat }
        return String(flat.prefix(borrowedTextLimit)) + "…"
    }

    /// Translates the usual network errors into a cause that
    /// can be acted on. The bare number otherwise forces a lookup every time —
    /// and -1022 in particular is regularly misread.
    public static func explain(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            // **The fallback is the quiet side entrance.** What arrives here is
            // foreign text — with an `NSError` the whole dump including
            // `NSErrorFailingURLStringKey`, and that carries the access in plain text.
            // Without this bolt, every switch from `String(describing:)` to
            // `explain` would only move the hole.
            return withoutAddress("\(error)") ?? "unknown error"
        }

        let cause: String =
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                """
                The system refused the connection before it was established \
                (App Transport Security, -1022). Unencrypted connections to this \
                address are not allowed. Check: Is NSAllowsArbitraryLoads in the \
                Info.plist — and is there NO NSAllowsLocalNetworking next to it? Both \
                together cancel each other out.
                """
            case .cannotFindHost:
                "The name could not be resolved (-1003). Check: Does the device use the home network's DNS?"
            case .cannotConnectToHost:
                "The host answers, but nothing is listening on this port (-1004)."
            case .timedOut:
                "Timeout (-1001). The server was reachable, but too slow or the connection dropped."
            case .notConnectedToInternet:
                "No network connection (-1009)."
            case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                "The certificate is not trusted — typical for self-issued certificates."
            case .networkConnectionLost:
                "The connection dropped in the middle of the transfer (-1005)."
            case .cancelled:
                "Cancelled (-999) — nobody was waiting for the answer any more."
            default:
                "Network error \(urlError.errorCode)"
            }

        return cause
    }
}
