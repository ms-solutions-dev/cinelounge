import Foundation
import Testing

@testable import Grundstock

/// The switch for verbose recording — and the trace attached to it.
///
/// Serial, because ``DebugMode/current`` and the trace are global state: two
/// checks that flip them at the same time would check each other instead of the subject.
@Suite("Verbose recording and trace", .serialized)
struct DiagnosticsTraceTests {

    /// A plain entry with a selectable time of day.
    private func entry(_ step: String, at date: Date = Date()) -> Diagnostics.Trace.Entry {
        Diagnostics.Trace.Entry(at: date, step: step, target: "", outcome: .started)
    }

    @Test("Launch picks up the stored state of the switch")
    func activateLoadsStoredState() throws {
        // The bug this check stands against: the only writer of
        // ``DebugMode/current`` was the key press in the settings — after
        // every restart the app recorded tersely, whatever the store said.
        let before = DebugMode.current
        defer { DebugMode.current = before }

        let store = InMemoryStore()
        DebugMode(isOn: true).save(to: store)
        DebugMode.activate(from: store)
        #expect(DebugMode.current.isOn)

        // And the opposite direction: an empty store means Off, not "stays as it was".
        DebugMode.activate(from: InMemoryStore())
        #expect(!DebugMode.current.isOn)
    }

    /// **The trace without a state is half a trace** (requirement 2026-08-15): every
    /// submitted diagnostic should say without asking back which build,
    /// which device and which mode it comes from.
    @Test("The profile header names build, device and mode")
    func reportHeaderCarriesTheEssentials() {
        let header = Diagnostics.reportHeader(extras: ["Shelf: 3 sources"])

        #expect(header.count == 4)
        #expect(header[0].hasPrefix("Version: "))
        #expect(header[0].contains("built"))
        #expect(header[1].hasPrefix("Device: "))
        #expect(header[2].hasPrefix("Debug mode: "))
        // What only the program knows, it attaches itself — the base lets
        // the line through without knowing it.
        #expect(header[3] == "Shelf: 3 sources")
    }

    @Test("Steps follow the switch — errors do not")
    func verboseEntryFollowsTheSwitch() {
        // In normal operation the trace is reserved for errors — otherwise
        // every tick of playback would displace exactly the lines it exists for.
        #expect(Diagnostics.verboseEntry("Jump to 90 s", failed: false, enabled: false) == nil)

        let step = Diagnostics.verboseEntry(
            "Jump to 90 s", failed: false, enabled: true, area: "Wiedergabe")
        #expect(step?.step == "Wiedergabe")
        #expect(step?.target == "Jump to 90 s")
        #expect(step?.outcome == .succeeded(""))

        // A problem carries its text as the cause, so that the display shows it in red
        // and at full width — like any other failure.
        let problem = Diagnostics.verboseEntry("Stream dropped", failed: true, enabled: true)
        #expect(problem?.outcome == .failed("Stream dropped"))

        // **An error does not wait for a switch** (requirement 2026-08-15):
        // a diagnostic that only knows the error with the switch flipped
        // is empty on the real error.
        let alwaysThere = Diagnostics.verboseEntry("Stream dropped", failed: true, enabled: false)
        #expect(alwaysThere?.outcome == .failed("Stream dropped"))
    }

    @Test("The trace grows with the switch and shrinks with it")
    @MainActor
    func capacityFollowsTheSwitch() {
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            Diagnostics.Trace.clear()
        }
        Diagnostics.Trace.clear()

        // Verbose: more than the fifty everyday slots, otherwise a
        // single playback test displaces itself before anyone uploads it.
        DebugMode.current = DebugMode(isOn: true)
        let overflow = Diagnostics.Trace.capacity + 10
        for i in 0..<overflow {
            Diagnostics.Trace.record(entry("Step \(i)"))
        }
        #expect(Diagnostics.Trace.entries.count == overflow)

        // Back to terse: the next entry trims to the small limit.
        DebugMode.current = DebugMode(isOn: false)
        Diagnostics.Trace.record(entry("after"))
        #expect(Diagnostics.Trace.entries.count == Diagnostics.Trace.capacity)
    }

    @Test("The output orders by clock, not by insertion")
    @MainActor
    func outputIsChronological() {
        defer { Diagnostics.Trace.clear() }
        Diagnostics.Trace.clear()

        // Deliberately queued in the wrong order — this is exactly how entries arrive when
        // two detached tasks overtake each other.
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        Diagnostics.Trace.record(entry("late", at: base.addingTimeInterval(2)))
        Diagnostics.Trace.record(entry("early", at: base))
        Diagnostics.Trace.record(entry("middle", at: base.addingTimeInterval(1)))

        #expect(Diagnostics.Trace.chronological.map(\.step) == ["early", "middle", "late"])
    }

    /// **A defect does not wait for a switch.** Until 2026-08-24 every
    /// measurement went into the trace as a success: 579 measurements in a session with
    /// dropouts, not a single error line. An outcome that can only
    /// take one value is no evidence.
    @Test("A defect from a measurement is in the trace even without the switch on")
    @MainActor
    func probeReportsAProblemWithoutTheSwitch() {
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            Diagnostics.Trace.clear()
        }
        Diagnostics.Trace.clear()
        DebugMode.current = DebugMode(isOn: false)

        // Numbers without a defect stay behind the switch — otherwise in everyday use they would displace
        // exactly the lines the trace exists for.
        Diagnostics.probe("Anlauf [native/direct]  bereit: 900 ms")
        #expect(Diagnostics.Trace.entries.isEmpty)

        Diagnostics.probe("14 dropouts, 23 s in total", verdict: .problem)
        #expect(Diagnostics.Trace.entries.count == 1)
        #expect(Diagnostics.Trace.entries[0].step == "Messung")
        #expect(Diagnostics.Trace.entries[0].outcome == .failed("14 dropouts, 23 s in total"))
    }

    /// **The timestamp is the actual information, not an accessory.** Whoever
    /// passes `since: Date()` fetches the reference point at the moment of reporting;
    /// the zero in it is computed and not measured. Each of the three
    /// renderings should say exactly one thing.
    @Test("A start time from the same instant does not give a zero")
    func elapsedTellsTheThreeCasesApart() {
        let now = Date(timeIntervalSince1970: 5_000)

        // No reference point — and a reference point from the future is none either.
        #expect(Diagnostics.elapsed(since: nil, now: now) == "[  —  ]")
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(0.2), now: now) == "[  —  ]")

        // The case `since: Date()`: measured, but below the resolution.
        #expect(Diagnostics.elapsed(since: now, now: now) == "[ <0.1s]")

        // Echte Spannen bleiben unangetastet.
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(-0.6), now: now) == "[  0.6s]")
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(-12.34), now: now) == "[ 12.3s]")
    }
}

/// A provider's credentials are in the **path**, not in the query part.
///
/// The second half of the rule from ``DiagnosticsRedactionTests``, and the one that was missing on
/// 2026-08-23: in line 54 of the submitted report the complete
/// stream address of a provider appeared twice in plain text — once as
/// `NSErrorFailingURLStringKey`, once as `NSErrorFailingURLKey`. It did not get
/// into the log via a `URL`, but as passed-through third-party text.
///
/// **All addresses here are made up.** A real credential in a check is
/// the same mistake as one in the log, only more lasting.
@Suite("Credentials in the path of an address")
struct DiagnosticsPathRedactionTests {

    @Test("User and password drop out of the path of a stream address")
    func streamPathCredentialsAreDropped() throws {
        // The form that `XtreamEndpoint.streamURL` produces: no query part, the
        // credentials between section and identifier.
        let url = try #require(
            URL(string: "http://panel.example:80/live/alice/Z2VoZWltZXNQYXNzd29ydA==/340873")
        )

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("Z2VoZWltZXNQYXNzd29ydA"))
        #expect(!logged.contains("alice"))
        // The identifier stays: without it it would no longer be possible to say which
        // channel failed.
        #expect(logged == "http://panel.example:80/live/USER/PASSWORD/340873")
    }

    @Test("Movies and series carry the credentials at the same place")
    func movieAndSeriesPathsAreMaskedToo() throws {
        let movie = try #require(URL(string: "http://panel.example:80/movie/alice/geheim/9911.ts"))
        let series = try #require(URL(string: "http://panel.example:80/series/alice/geheim/4711.mkv"))

        #expect(Diagnostics.loggable(movie) == "http://panel.example:80/movie/USER/PASSWORD/9911.ts")
        #expect(
            Diagnostics.loggable(series) == "http://panel.example:80/series/USER/PASSWORD/4711.mkv")
    }

    @Test("A password containing a slash still stays hidden")
    func aSlashInThePasswordDoesNotLeakTheRest() throws {
        // Base64 has the slash, and `XtreamEndpoint` deliberately does not
        // encode it — otherwise the server would not find the path. A mask at
        // fixed positions would leave the rest of the password standing.
        let url = try #require(URL(string: "http://panel.example:80/live/alice/ab/cd/ef/340873"))

        let logged = Diagnostics.loggable(url)

        #expect(logged == "http://panel.example:80/live/USER/PASSWORD/340873")
    }

    @Test("The address of the own media server stays complete")
    func theMediaServerAddressSurvives() throws {
        // The control test for lowercase: the media server serves `/LiveTv/…`,
        // and that is not a provider address. If the rule applied here, the log would lose
        // its most useful information.
        let url = try #require(URL(string: "http://media.example:8096/LiveTv/Programs"))

        #expect(Diagnostics.loggable(url) == "http://media.example:8096/LiveTv/Programs")
    }

    @Test("Foreign text containing an address does not go out at all")
    func borrowedTextWithAnAddressIsWithheld() throws {
        // An `NSError` dump, as `localizedDescription` and
        // `String(describing:)` deliver it.
        let dump =
            "Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\" "
            + "UserInfo={NSErrorFailingURLStringKey=http://panel.example/live/alice/geheim/1}"

        let text = try #require(Diagnostics.withoutAddress(dump))

        #expect(!text.contains("://"))
        #expect(!text.contains("secret"))
        // And the control test: whatever carries no address stays word for word.
        #expect(Diagnostics.withoutAddress("HTTP 404: File Not Found") == "HTTP 404: File Not Found")
    }

    /// An error whose description itself carries an address — the side door
    /// through which the credentials got into `Diagnostics.failure` until 2026-08-26.
    private struct Failure: Error, CustomStringConvertible {
        let description = "Abort at http://panel.example/live/user/secret/1"
    }

    @Test("The fallback of explain does not reveal an address either")
    func explainFallsBackWithoutAnAddress() {
        #expect(!Diagnostics.explain(Failure()).contains("://"))
        #expect(!Diagnostics.explain(Failure()).contains("secret"))

        // The control test: a known network error is still translated and
        // names its code — otherwise the line would be mute after the change.
        #expect(Diagnostics.explain(URLError(.networkConnectionLost)).contains("-1005"))
    }
}
