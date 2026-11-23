import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The stopwatch on the schedule — E5.
///
/// **Why it does not run in the ordinary run.** A timing measurement is
/// not an expectation: it falls over on a busy machine without
/// anything being broken, and a check run that goes red now and then for no reason
/// soon stops being read at all. The figures belong in the source
/// text anyway and not in a note next to it, so that the next person can
/// reproduce them: `CINELOUNGE_MESSUNG=1 swift test -c release --filter
/// SpielplanMessung`.
///
/// **Release, not debug.** The calculation consists of string comparisons
/// over collections; in the debug build each of them costs a multiple. Measuring
/// is therefore done with `-c release` — that is the build that runs on the Apple TV.
///
/// **What E5 brought**, measured on 2026-08-29 on an Apple M4, every row
/// before and after on the same machine in the same session:
///
/// | Measurement                                    | before   | after    |
/// |------------------------------------------------|---------:|---------:|
/// | `SportPlan.events`, real recording             | 0,793 s  | 0,387 s  |
/// | `SportPlan.events`, device size (38.718)       | 7,353 s  | 3,446 s  |
/// | `SportMatch.events`, 600 fixtures (recording)  | 0,216 s  | 0,049 s  |
/// | `SportMatch.events`, 600 fixtures (38.718)     | 1,703 s  | 0,419 s  |
/// | Foreign query to ``LiveLibrary`` meanwhile     | 5,137 s  | 0,0001 s |
/// | Second pass on the same day                    | 5,139 s  | 0,0017 s |
/// | Read window from the download store, with/without text | 0,037 s  | 0,015 s  |
///
/// **How exact these figures are.** The same set ran twice, on the
/// same machine, one hour apart: the amounts differ by up to
/// 5 % (0,367 s and 0,387 s in the first row), the
/// ratios by less than 3 %. Whoever reproduces one of the rows and
/// expects the same amount to the third digit expects too much; whoever expects the
/// factor gets it.
///
/// **The hit count stays the same in every row** — 185 events, 600
/// evidenced fixtures, 177 rows from the whole stretch. A faster
/// calculation that finds less would be no improvement; the
/// equality is proved not here but in ``SchedulePrototypeTests`` (unchanged
/// 835 / 213 / 120 at the time), ``SportMatchTests`` (the baskets against the full
/// pass) and ``SportPlanTests`` (the channel signal per channel).
///
/// **Which guide.** The figures above were measured on the real recording of
/// 2026-08-29. The stopwatch takes it when the checkout has it
/// (``SportRecording/largest``) and the much smaller synthetic guide otherwise —
/// then the amounts are smaller and only the ratios compare.
///
/// **The last two rows are the ones that matter.** The calculation sat in the
/// body of ``LiveLibrary``, and an actor handles one request after the
/// other: whoever wanted anything else from the library during the schedule —
/// the channel list its "what is on now", the player its address —,
/// waited a measured **five seconds**. It was not the schedule that was slow, but
/// everything next to it.
///
/// **The target value of the concept for the comparison (5,8 s for 600 fixtures on
/// an M3) cannot be reproduced here:** the measured value before is
/// 1,703 s. The direction is right, the amount is not. What causes that cannot
/// be settled from here — the concept measured on the untrimmed dump
/// (30.157 programmes, 7.735 channels), and that is not in the test store. The
/// 4,5 s of the event calculation, on the other hand, were found again: 7,4 s in
/// device size, and the same factor.
@Suite("Schedule measurement", .serialized)
struct ScheduleTimingTests {

    static let isRunning = ProcessInfo.processInfo.environment["CINELOUNGE_MESSUNG"] != nil

    /// The read window, as ``SportModel/load()`` reads it: now minus
    /// look-back up to now plus 24 hours.
    static var recording: SportRecording { SportRecording.largest }

    static var readWindow: [Programme] {
        let window = SportWindow.span(now: recording.at(hour: 15))
        return recording.broadcasts.filter {
            $0.start >= window.readAlongFrom && $0.start < window.readUntil
        }
    }

    /// The competition part of a title — rebuilt here instead of fetched from
    /// ``SportPlan``, because the split is not public there and
    /// a measurement should not tear open visibility in the calculation core.
    static func league(_ title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return "" }
        return String(title[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Fixtures that really hit: built from the pairings of the recording,
    /// so that the comparison does not measure into the void.
    static func fixtures(count: Int) -> [SportFixture] {
        var found: [SportFixture] = []
        for broadcast in readWindow {
            guard let pairing = SportPlan.pairing(in: broadcast.title),
                let kind = SportKind.classify(title: broadcast.title)
            else { continue }
            found.append(
                SportFixture(
                    id: "mess:\(found.count)", kind: kind,
                    league: league(broadcast.title),
                    home: pairing.home, away: pairing.away, start: broadcast.start))
            if found.count >= count { break }
        }
        // If the recording is not enough, the existing ones are repeated —
        // the load per fixture is the same.
        var all = found
        var i = 0
        while all.count < count, !found.isEmpty {
            let template = found[i % found.count]
            all.append(
                SportFixture(
                    id: "mess:w\(all.count)", kind: template.kind, league: template.league,
                    home: template.home, away: template.away, start: template.start))
            i += 1
        }
        return all
    }

    /// The window **in device size**, extrapolated.
    ///
    /// On the Apple TV, 44.489 programmes were measured in the download store on 2026-08-29 and
    /// 38.595 in the three-day window — a trimmed recording has a tenth of that.
    /// The figures of the concept (4,5 s for the event calculation, 5,8 s for 600
    /// fixtures) were measured in this size, not in that of the recording;
    /// without the extrapolation nothing could be held against them.
    ///
    /// **Nine times the same guide, each time on its own channels.** The
    /// channel travels along, otherwise it would be the same channels
    /// ninefold — and then the channel-signal index would look better than
    /// it is on the device. Calculated this way it turns out worse (more channels
    /// than the provider has), and that is the right direction
    /// for an extrapolation.
    static let deviceWindow: [Programme] = {
        var all: [Programme] = []
        for walkthrough in 0..<9 {
            for broadcast in readWindow {
                all.append(
                    Programme(
                        id: "\(broadcast.id)#\(walkthrough)",
                        channelID: "\(broadcast.channelID)#\(walkthrough)",
                        title: broadcast.title, start: broadcast.start, end: broadcast.end,
                        description: broadcast.description))
            }
        }
        return all
    }()

    static let deviceNames: [String: String] = {
        var names: [String: String] = [:]
        for (identifier, name) in recording.names {
            for walkthrough in 0..<9 { names["\(identifier)#\(walkthrough)"] = name }
        }
        return names
    }()

    static func measure(_ name: String, _ iterations: Int = 1, _ work: () -> Int) {
        var match = 0
        let start = Date()
        for _ in 0..<iterations { match = work() }
        let duration = Date().timeIntervalSince(start) / Double(iterations)
        print(String(format: "  %-46s %7.3f s   Hits %d", (name as NSString).utf8String!, duration, match))
    }

    @Test(
        "What the event computation costs",
        .enabled(if: isRunning, "CINELOUNGE_MESSUNG is not set"))
    func eventCalculation() {
        let window = Self.readWindow
        let names = Self.recording.names
        print("Measurement: \(window.count) broadcasts in the three-day window, \(names.count) channels")
        Self.measure("SportPlan.events (three-day window)", 5) {
            SportPlan.events(from: window, channelNames: names).count
        }
        print("Measurement: \(Self.deviceWindow.count) broadcasts scaled up to device size")
        Self.measure("SportPlan.events (device size)", 3) {
            SportPlan.events(from: Self.deviceWindow, channelNames: Self.deviceNames).count
        }
    }

    /// What reading the window from the download store costs — the query that
    /// precedes every event calculation.
    /// **The two figures E5 is ultimately about.** Not how fast the
    /// calculation is, but what it costs the rest of the app — and what a
    /// second look at the same day costs.
    @Test(
        "What the schedule costs the rest of the app",
        .enabled(if: isRunning, "CINELOUNGE_MESSUNG is not set"))
    @MainActor
    func actorStaysFree() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-measurement-\(UUID().uuidString)")
        let downloads = LiveCache(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await downloads.save(programmes: Self.deviceWindow)

        let listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let library = LiveLibrary(store: listen, cache: downloads)

        let window = SportWindow.span(now: Self.recording.at(hour: 15))

        // The first pass runs, and **meanwhile** someone else
        // knocks — as the channel list does while the schedule is
        // open. What is measured is how long this other party waits.
        let calculation = Task {
            await library.sportEvents(from: window.readAlongFrom, to: window.readUntil)
        }
        try? await Task.sleep(for: .milliseconds(50))
        let knocked = Date()
        _ = await library.hasStoredGuide()
        let waitTime = Date().timeIntervalSince(knocked)

        let firstDuration = Date()
        let first = await calculation.value
        _ = Date().timeIntervalSince(firstDuration)

        let secondStart = Date()
        let second = await library.sportEvents(from: window.readAlongFrom, to: window.readUntil)
        let secondDuration = Date().timeIntervalSince(secondStart)

        print(
            String(
                format: "  %-46s %7.4f s   Hits %d",
                ("Foreign query during the computation" as NSString).utf8String!, waitTime,
                first.count))
        print(
            String(
                format: "  %-46s %7.4f s   Hits %d",
                ("Second pass (result store)" as NSString).utf8String!, secondDuration,
                second.count))
    }

    @Test(
        "What reading from the cache costs",
        .enabled(if: isRunning, "CINELOUNGE_MESSUNG is not set"))
    func readDownloads() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-measurement-\(UUID().uuidString)")
        let downloads = LiveCache(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        // **With invented text.** The recording carries no description in any of its
        // programmes — the tested provider does not fill `<desc>`.
        // On it the narrow query could not be measured, because there is
        // nothing to leave out. Other providers fill the field; 200
        // characters are an ordinary synopsis.
        let text = String(repeating: "Inhaltsangabe. ", count: 14)
        await downloads.save(
            programmes: Self.deviceWindow.map {
                Programme(
                    id: $0.id, channelID: $0.channelID, title: $0.title, start: $0.start,
                    end: $0.end, description: text)
            })

        let window = SportWindow.span(now: Self.recording.at(hour: 15))

        for withText in [true, false] {
            var read = 0
            let start = Date()
            for _ in 0..<10 {
                read = await downloads.programmes(
                    from: window.readAlongFrom, to: window.readUntil, withText: withText
                ).count
            }
            let duration = Date().timeIntervalSince(start) / 10
            let name = withText ? "Cache read WITH text" : "Cache read WITHOUT text (narrow)"
            print(
                String(
                    format: "  %-46s %7.4f s   Hits %d", (name as NSString).utf8String!, duration,
                    read))
        }
    }

    @Test(
        "What the sync costs",
        .enabled(if: isRunning, "CINELOUNGE_MESSUNG is not set"))
    func sync() {
        let window = Self.readWindow
        let names = Self.recording.names
        let guess = SportPlan.events(from: window, channelNames: names)
        for count in [100, 600] {
            let fixtures = Self.fixtures(count: count)
            Self.measure("SportMatch.events (\(fixtures.count) Termine)", 3) {
                SportMatch.events(
                    fixtures: fixtures, programmes: window
                ).count
            }
            let taken = SportMatch.events(
                fixtures: fixtures, programmes: window)
            Self.measure("SportMatch.combined (\(fixtures.count) Termine)", 3) {
                SportMatch.combined(verified: taken, heuristic: guess, fixtures: fixtures).count
            }
        }
        let sixHundred = Self.fixtures(count: 600)
        Self.measure("SportMatch.events (600 fixtures, device size)", 3) {
            SportMatch.events(
                fixtures: sixHundred, programmes: Self.deviceWindow
            ).count
        }
    }
}
