import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The answers of the sports sources — the substitute for the network.
///
/// **No test in this project may touch the network.** A test that did would be
/// green or red depending on time of day, schedule and the provider's mood,
/// and a red one would then not say whether the source is broken or it is
/// just the summer break.
///
/// **Two sets of answers, one stretch.** The tests run on a **synthetic** set
/// that `intern/fixtures-synth/sport.py` writes to `Fixtures/sport/`: invented
/// clubs, channels and tournaments in the exact form the four sources deliver
/// (ESPN scoreboard, TheSportsDB, XMLTV guide, broadcast plan page). Every case
/// the tests check is built into it on purpose. Next to it, where present, runs
/// a **real** recording under `intern/aufnahmen/sport/` (`scripts/record-espn.sh`,
/// `scripts/record-schedule.sh`) with its expected figures in `expected.json`. It
/// stays private, and a checkout without it simply runs the synthetic set alone.
///
/// The fetch here forms the same addresses as on the TV and answers
/// them from the files. That way the **whole** stretch runs in the test:
/// address building, state key, parsing, counter, merge.
final class SportRecording: Sendable, CustomTestStringConvertible {

    let name: String
    /// The time zone of the viewer — the day boundary is midnight in Berlin.
    let timeZone: TimeZone
    /// The day the answers belong to, at midnight.
    let day: Date
    let espnFolder: URL
    let tsdbFolder: URL
    let guideFile: URL
    let planFile: URL
    /// What this set yields, station by station.
    let expected: Expected

    /// The guide, parsed once — one parser run per test would be pure waiting time.
    let broadcasts: [Programme]
    /// `<channel id="…"><display-name>…</display-name>` of the guide.
    let names: [String: String]
    /// The broadcast plan as the parser reads it.
    let slots: [SportBroadcastPlan.BroadcastSlot]

    var testDescription: String { name }

    init(
        name: String, folder: URL, espn: String, tsdb: String, guide: String, plan: String,
        year: Int, month: Int, dayOfMonth: Int, expected: Expected
    ) {
        self.name = name
        let zone = TimeZone(identifier: "Europe/Berlin")!
        timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        day = calendar.date(
            from: DateComponents(timeZone: zone, year: year, month: month, day: dayOfMonth))!
        espnFolder = folder.appendingPathComponent(espn)
        tsdbFolder = folder.appendingPathComponent(tsdb)
        guideFile = folder.appendingPathComponent(guide)
        planFile = folder.appendingPathComponent(plan)
        self.expected = expected
        broadcasts = XMLTVParser.parse(fileURL: guideFile)
        names = Self.channelNames(in: guideFile)
        slots = SporEkraniSource.read((try? Data(contentsOf: planFile)) ?? Data())
    }

    // MARK: - The two sets

    /// The set every checkout carries: invented, built case by case.
    static let synthetic = SportRecording(
        name: "synthetic 2030-08-17",
        folder: Bundle.module.url(forResource: "Fixtures/sport", withExtension: nil)!,
        espn: "espn", tsdb: "tsdb", guide: "epg.xml", plan: "broadcast-plan.html",
        year: 2030, month: 8, dayOfMonth: 17, expected: .synthetic)

    /// The real recording, if this checkout has it.
    ///
    /// **Why it is still read.** Its figures are a measurement against the
    /// world — how many ESPN fixtures find a channel in a real guide, what the
    /// channel board brings on a real Saturday. The synthetic set proves that the
    /// stretch behaves; only the recording says how much that is worth. It
    /// lies outside the package because it quotes foreign services verbatim,
    /// and it is not exported — and so are its file names, its day and its
    /// expected figures: all of them come from `expected.json` next to the
    /// answers, and without that file the case does not exist.
    static let real: SportRecording? = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlaylistKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PlaylistKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()
            .appendingPathComponent("intern/aufnahmen/sport")
        guard
            let bytes = try? Data(contentsOf: folder.appendingPathComponent("expected.json")),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
            manifest.day.count == 3
        else { return nil }
        return SportRecording(
            name: manifest.name, folder: folder,
            espn: manifest.files.espn, tsdb: manifest.files.tsdb,
            guide: manifest.files.guide, plan: manifest.files.plan,
            year: manifest.day[0], month: manifest.day[1], dayOfMonth: manifest.day[2],
            expected: manifest.expected)
    }()

    /// `expected.json` of a private recording: where its answers lie, which
    /// day they belong to and what they yield.
    private struct Manifest: Decodable {
        struct Files: Decodable {
            let espn: String
            let tsdb: String
            let guide: String
            let plan: String
        }
        let name: String
        let files: Files
        /// Year, month, day.
        let day: [Int]
        let expected: Expected
    }

    /// What the parameterised tests run on: the synthetic set always, the real
    /// recording when it is there.
    static let all: [SportRecording] = [synthetic] + (real.map { [$0] } ?? [])

    /// The larger of the two for the stopwatch (``ScheduleTimingTests``).
    static var largest: SportRecording { real ?? synthetic }

    // MARK: - The fixed clock

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    var dayStart: Date { day }
    var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: day)! }

    /// A clock time on the day of the set.
    func at(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: day)!
    }

    /// The programmes of the day — the day window the view opens.
    var dayWindow: [Programme] {
        broadcasts.filter { $0.start >= dayStart && $0.start < dayEnd }
    }

    /// The channels of the guide. On the device they come from the channel list;
    /// here from the guide, and there every one carries a programme ID.
    var sportChannels: [SportChannel] {
        names.map { SportChannel(id: $0.key, name: $0.value, epgID: $0.key) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - The fetch

    /// Answers an address from the files.
    ///
    /// If the file is missing, that means "no answer" (`nil`) — exactly like a
    /// silent server. A file with `{"fehlschlag": 400}` returns the
    /// state key that the fetch got back then; that way the case
    /// "the source does not know this ID" is testable without inventing it.
    var fetch: SportFixtureSource.Fetch {
        { [self] address in
            guard let file = path(forItem: address),
                let bytes = try? Data(contentsOf: file)
            else { return nil }
            if let failure = try? JSONDecoder().decode(Failure.self, from: bytes) {
                return (bytes, failure.failure)
            }
            return (bytes, 200)
        }
    }

    /// A fetch where ESPN never answers — for the fallback.
    var muted: SportFixtureSource.Fetch {
        let fetch = fetch
        return { address in
            address.host == "site.api.espn.com" ? nil : await fetch(address)
        }
    }

    /// The fixtures of the fixture source over `days` days from the day of the set.
    func fixtures(days: Int = 3, fetch: SportFixtureSource.Fetch? = nil) async -> [SportFixture] {
        await SportFixtureSource(fetch: fetch ?? self.fetch)
            .fixtures(from: day, days: days, timeZone: timeZone).fixtures
    }

    private struct Failure: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case failure = "fehlschlag"
        }
        let failure: Int
    }

    func path(forItem address: URL) -> URL? {
        let text = address.absoluteString
        if text.contains("site.api.espn.com") {
            // …/sports/soccer/ger.1/scoreboard?dates=20300817
            guard let area = text.range(of: "/sports/"),
                let until = text.range(of: "/scoreboard"),
                let tag = address.query?.replacingOccurrences(of: "dates=", with: "")
            else { return nil }
            let slug = String(text[area.upperBound..<until.lowerBound])
            return espnFolder.appendingPathComponent(
                slug.replacingOccurrences(of: "/", with: "-") + "-" + tag + ".json")
        }
        if text.contains("thesportsdb.com") {
            guard let identifier = address.query?.replacingOccurrences(of: "id=", with: "")
            else { return nil }
            return tsdbFolder.appendingPathComponent("eventsnextleague-" + identifier + ".json")
        }
        return nil
    }

    /// Reads `<channel id="…"><display-name>…</display-name>` from the
    /// guide. On the device the names come from the channel list; for the
    /// measurement those of the guide suffice, and they are the same.
    static func channelNames(in file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let expression = try? NSRegularExpression(
                pattern: "<channel id=\"([^\"]+)\">\\s*<display-name[^>]*>([^<]*)</display-name>")
        else { return [:] }
        var names: [String: String] = [:]
        let area = NSRange(text.startIndex..., in: text)
        expression.enumerateMatches(in: text, range: area) { match, _, _ in
            guard let match, let identifier = Range(match.range(at: 1), in: text),
                let name = Range(match.range(at: 2), in: text)
            else { return }
            if names[String(text[identifier])] == nil {
                names[String(text[identifier])] = String(text[name])
            }
        }
        return names
    }
}

// MARK: - What each set yields

extension SportRecording {

    /// Fixtures, rows and channels per competition on the day: what the
    /// fixture source schedules, what the schedule shows, and how many
    /// heuristic rows name a scheduled match a second time.
    struct Tally: Sendable, Equatable, Decodable, CustomStringConvertible {
        let fixtures: Int
        let rows: Int
        let duplicate: Int
        var description: String { "(\(fixtures), \(rows), \(duplicate))" }
    }

    /// The figures of one set, station by station.
    ///
    /// They are **measured, not set**. If a filter change alters one of them,
    /// that is the evidence — and whoever adjusts them without naming the
    /// change next to it has switched the test rig off. The synthetic figures
    /// stand below; those of a real recording in its `expected.json`.
    struct Expected: Sendable, Decodable {
        // The guide (SchedulePrototypeTests)
        var read: Int
        var channels: Int
        var onDay: Int
        var detected: Int
        var passedThrough: Int
        var events: Int
        var rowsWithoutLookback: Int
        var rowsWithLookback: Int
        var settled: [String]
        var notSettled: [String]
        var duplicateGroups: [String: Int]
        var tabToday: Int
        var window24: Int
        /// Year, month, day, hour, minute of the last programme start.
        var reach: [Int]

        // The fixture source (SportFixtureSourceTests)
        var benchmark: [String: Int]
        var fixturesToday: Int
        var fixturesThreeDays: Int
        var fixturesFirstThreeLocalDays: Int
        var emptyCompetition: String
        var fallbackFixtures: Int
        var fallbackEmpty: String
        var responseFile: String
        var responseLeague: String
        var responseShort: String
        var responseCount: Int
        var responseFirstID: String
        var responseFirstHome: String
        var responseFirstAway: String
        var responseFirstStart: TimeInterval
        var responseHomeVariants: [String]

        // Fixtures against the guide (ScheduleFixturesTests)
        var withChannel: Int
        var verified: Int
        var todayWithChannel: Int
        var todayVerified: Int
        var fallbackWithChannel: Int
        var fallbackVerified: Int
        var placeholderRows: Int
        var scheduleWithoutFixtures: Int
        var scheduleWithFixtures: Int

        // The channel board (ChannelBoardMeasurementTests)
        var singlePassRows: Int
        var singlePassChannels: Int
        var fromNames: Int
        var namesHit: [String: Set<String>]
        var namesMiss: [String]
        var withoutBoard: Int
        var namesOnlyBoard: Int
        var fullBoard: Int
        var sealed: Int
        var gained: Int
        var assignments: Int
        var tallies: [String: Tally]
        var scheduleWithBoard: Int
        var conferenceEntries: Int
        var conferenceTime: String
        var conferenceMatches: Int
        var conferenceChannels: [String]

        // The broadcast plan (ScheduleTests)
        var slots: Int
        var multiChannelMatch: String
        var turkishHome: String
        var turkishAway: String
        var turkishLeague: String
        var turkishKickoff: TimeInterval
        var turkishChannel: String
        var turkishEPG: String
        /// How the provider mangles the display name of that channel.
        var turkishMangledName: String
        var waterPolo: String
        var volleyball: String
        var volleyballCompetition: String
        var shows: [String]
        var ownRows: Int
        var ownTitles: [String]
    }
}

extension SportRecording.Expected {

    /// The synthetic set, built case by case in `intern/fixtures-synth/sport.py`.
    static let synthetic = Self(
        read: 1100, channels: 27, onDay: 529, detected: 317, passedThrough: 25, events: 24,
        rowsWithoutLookback: 17, rowsWithLookback: 18,
        settled: [
            "Ronde van Kesteren", "Nordhafen Open", "Lindmar Open", "Großer Preis von Valmont",
            "Jadeport Open", "Valmorin / Clairbois", "Fichtenhain / Rabenfels",
        ],
        notSettled: [
            "Sendepause", "alle Tore", "World Cup", "Highlight-Show", "Avant-match", "Pitchside",
        ],
        duplicateGroups: [
            "motorsport#grandprixdevalmont": 3, "tennis#nordhafenopen": 2,
            "tennis#tournoiatpdekerlouan2etour": 2,
        ],
        tabToday: 18, window24: 20, reach: [2030, 8, 18, 9, 18],
        benchmark: ["soccer/tur.1": 3, "soccer/ger.1": 6, "soccer/eng.1": 4],
        fixturesToday: 28, fixturesThreeDays: 51, fixturesFirstThreeLocalDays: 50,
        emptyCompetition: "soccer/uefa.champions", fallbackFixtures: 19,
        fallbackEmpty: "soccer/eng.fa",
        responseFile: "soccer-ger.1-20300817.json", responseLeague: "Bundesliga (Germany)",
        responseShort: "Bundesliga", responseCount: 6, responseFirstID: "espn#7001006",
        responseFirstHome: "SC Fichtenhain 08", responseFirstAway: "FC Rabenfels",
        responseFirstStart: 1_913_203_800, responseHomeVariants: ["Fichtenhain", "FIC"],
        withChannel: 17, verified: 12, todayWithChannel: 17, todayVerified: 12,
        fallbackWithChannel: 8, fallbackVerified: 6, placeholderRows: 5,
        scheduleWithoutFixtures: 24, scheduleWithFixtures: 29,
        singlePassRows: 12, singlePassChannels: 10, fromNames: 7,
        namesHit: [
            "arenabundesliga1.de": ["soccer/ger.1"], "arenapremierleague.de": ["soccer/eng.1"],
        ],
        namesMiss: ["arenamix.de", "arenanews.de"],
        withoutBoard: 17, namesOnlyBoard: 29, fullBoard: 39, sealed: 12, gained: 22, assignments: 71,
        tallies: [
            "soccer/ger.1": .init(fixtures: 6, rows: 6, duplicate: 0),
            "soccer/eng.1": .init(fixtures: 4, rows: 4, duplicate: 0),
            "soccer/tur.1": .init(fixtures: 3, rows: 3, duplicate: 0),
        ],
        scheduleWithBoard: 52, conferenceEntries: 31, conferenceTime: "15:30",
        conferenceMatches: 5, conferenceChannels: ["arenabundesliga1.de", "zenit1.de"],
        slots: 13, multiChannelMatch: "Pampa Juniors",
        turkishHome: "Taşlıyurtspor", turkishAway: "Kızılkayaspor", turkishLeague: "Süper Lig",
        turkishKickoff: 1_913_216_400, turkishChannel: "Arena Spor 1", turkishEPG: "arenaspor1.tr",
        turkishMangledName: "TR: A**** S*** 1 RAW",
        waterPolo: "Marovia - Talessa", volleyball: "Marovia - Veldoria",
        volleyballCompetition: "Kıyı Oyunları",
        shows: ["Gol Saati", "Maç Önü", "Analiz Kervanspor"],
        ownRows: 6, ownTitles: ["Kayalıdere 1969 - Rüzgarlıspor", "Petrolköy - Gümüşovaspor"])
}
