import Core
import Foundation
import SQLite3
import Testing

@testable import PlaylistKit

/// Tested on built-in examples, never on the network: the test cases run
/// on every build, and fetching a programme guide of 50 MB would be
/// neither fast nor reliable.
///
/// The cases come from what such parsers fail on in reality:
/// wrongly set time zones, multilingual titles, truncated files.
@Suite("Parsing XMLTV")
struct XMLTVParserTests {

    // MARK: - Hilfen

    /// Builds a complete document around the entries.
    private func document(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv>\(body)</tv>"
    }

    /// A point in time from UTC values, independent of the time zone of the machine running the tests.
    private func utc(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!
    }

    // MARK: - Der Normalfall

    @Test("An ordinary entry is read completely")
    func standardEntry() throws {
        let xml = document(
            """
            <channel id="ahorn.de"><display-name>Das Nordlicht</display-name></channel>
            <programme start="20260728120000 +0200" stop="20260728133000 +0200" channel="ahorn.de">
              <title lang="de">Tagesfunke</title>
              <desc lang="de">Nachrichten</desc>
            </programme>
            """
        )

        let programmes = XMLTVParser.parse(xml)
        let first = try #require(programmes.first)

        #expect(programmes.count == 1)
        #expect(first.channelID == "ahorn.de")
        #expect(first.title == "Tagesfunke")
        #expect(first.description == "Nachrichten")
        #expect(first.start == utc(2026, 7, 28, 10, 0))
        #expect(first.end == utc(2026, 7, 28, 11, 30))
        #expect(first.isRunning(at: utc(2026, 7, 28, 10, 30)))
    }

    @Test("A missing description does not disturb the entry")
    func missingDescription() throws {
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title>Ohne Beschreibung</title>
            </programme>
            """
        )

        let first = try #require(XMLTVParser.parse(xml).first)

        #expect(first.title == "Ohne Beschreibung")
        #expect(first.description == nil)
    }

    // MARK: - Zeitangaben

    @Test("A time zone offset is converted to the correct universal time")
    func offsetIsApplied() {
        // Central European Summer Time: two hours ahead of UTC.
        #expect(XMLTVParser.date(from: "20260728120000 +0200") == utc(2026, 7, 28, 10, 0))
    }

    @Test("Without a time zone offset universal time applies")
    func missingOffsetMeansUTC() {
        // Not the device's local time: otherwise the entire
        // programme would shift as soon as someone watches TV on holiday.
        #expect(XMLTVParser.date(from: "20260728120000") == utc(2026, 7, 28, 12, 0))
    }

    @Test("A negative offset shifts in the other direction")
    func negativeOffset() {
        // East coast of the United States: five hours behind UTC,
        // so it is earlier there — UTC is correspondingly later.
        #expect(XMLTVParser.date(from: "20260728120000 -0500") == utc(2026, 7, 28, 17, 0))
    }

    @Test("A half-hour offset is computed to the minute")
    func halfHourOffset() {
        // India is five and a half hours ahead of UTC. Whoever reads only the hours
        // is off by thirty minutes for a whole country.
        #expect(XMLTVParser.date(from: "20260728120000 +0530") == utc(2026, 7, 28, 6, 30))
    }

    @Test("The offset may be written without a space and with a colon")
    func offsetSpellings() {
        let expected = utc(2026, 7, 28, 10, 0)

        #expect(XMLTVParser.date(from: "20260728120000+0200") == expected)
        #expect(XMLTVParser.date(from: "20260728120000 +02:00") == expected)
        #expect(XMLTVParser.date(from: "  20260728120000 +0200  ") == expected)
    }

    @Test("The conversion matches the calendar across years")
    func matchesCalendar() {
        // The calculation is done without a calendar, because two hundred thousand conversions
        // would otherwise noticeably cost time. This case records that the formula
        // delivers the same — across leap years, century turns and month ends.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for year in [1970, 1999, 2000, 2024, 2026, 2100] {
            for month in 1...12 {
                for day in [1, 15, 28] {
                    let text = String(format: "%04d%02d%02d%02d%02d%02d", year, month, day, 13, 45, 7)
                    let components = DateComponents(
                        year: year, month: month, day: day, hour: 13, minute: 45, second: 7
                    )
                    #expect(XMLTVParser.date(from: text) == calendar.date(from: components))
                }
            }
        }
    }

    @Test("February 29 applies only in a leap year")
    func leapDay() {
        #expect(XMLTVParser.date(from: "20240229120000") == utc(2024, 2, 29, 12, 0))
        #expect(XMLTVParser.date(from: "20260229120000") == nil)
        // 2100 is not a leap year despite being divisible by four.
        #expect(XMLTVParser.date(from: "21000229120000") == nil)
    }

    @Test("A day that does not exist is rejected instead of rolled over")
    func impossibleDay() {
        // Without this check the calendar would silently push 30 February
        // to 2 March — the programme would then sit on the wrong day in the grid.
        #expect(XMLTVParser.date(from: "20260230120000") == nil)
        #expect(XMLTVParser.date(from: "20260431120000") == nil)
        #expect(XMLTVParser.date(from: "20261301120000") == nil)
        #expect(XMLTVParser.date(from: "20260728250000") == nil)
        #expect(XMLTVParser.date(from: "20260728126100") == nil)
    }

    @Test("Too few or too many digits yield no point in time")
    func wrongDigitCount() {
        // The format does allow shorter values, but in real files they
        // do not occur. Padding with zeros would mean guessing the time.
        #expect(XMLTVParser.date(from: "20260728") == nil)
        #expect(XMLTVParser.date(from: "202607281200") == nil)
        #expect(XMLTVParser.date(from: "202607281200000") == nil)
        #expect(XMLTVParser.date(from: "") == nil)
        #expect(XMLTVParser.date(from: "keine Zeitangabe") == nil)
    }

    @Test("A misunderstood time zone name does not silently become universal time")
    func unknownTimeZoneName() {
        // Otherwise the programme would be five hours off without anyone noticing.
        #expect(XMLTVParser.date(from: "20260728120000 EST") == nil)
        #expect(XMLTVParser.date(from: "20260728120000 +02") == nil)
        #expect(XMLTVParser.date(from: "20260728120000 +9900") == nil)
    }

    @Test("A broken time value discards only that one entry")
    func brokenTimeSkipsOnlyOneEntry() {
        // The actual purpose: a file with four hundred channels must not fail on
        // a single faulty entry.
        let xml = document(
            """
            <programme start="völliger Unsinn" stop="20260728130000" channel="a">
              <title>Kaputt</title>
            </programme>
            <programme start="20260728130000" stop="unsinn" channel="b">
              <title>Auch kaputt</title>
            </programme>
            <programme start="20260728140000" stop="20260728150000" channel="c">
              <title>Heil</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).map(\.title) == ["Heil"])
    }

    // MARK: - Zwei Sendungen zur selben Sekunde

    /// **On-device finding 2026-08-29, 18:06.** The viewer reports that matches are shown as
    /// live, but when entering the channel something else is running …
    /// on Arena Spor 1 Tarla against Tepeli is currently on, and Sport shows
    /// a different pairing there.
    ///
    /// The ID consisted of channel and start time, justified by the idea that two
    /// programmes could not start at the same time on one channel. The
    /// tested provider does it en masse: in the guide of 2026-08-29,
    /// **898 of 30.157** rows dropped out at this point, of which only
    /// 94 carried the same title as the one kept. On `arenaspor1.tr` at
    /// 2026-08-29, 19:00 local time there were three entries; the first was kept,
    /// the third was played.
    @Test("Two broadcasts may start at the same time on one channel")
    func simultaneousBroadcasts() {
        let xml = document(
            """
            <programme start="20260829190000 +0300" stop="20260829210000 +0300" channel="arena1">
              <title>Ç.Bulutspor - Dumanspor</title>
            </programme>
            <programme start="20260829190000 +0300" stop="20260829193000 +0300" channel="arena1">
              <title>Göl Ligi Raporu</title>
            </programme>
            <programme start="20260829190000 +0300" stop="20260829210000 +0300" channel="arena1">
              <title>T.Tarlaspor - Tepelispor</title>
            </programme>
            """
        )

        let title = XMLTVParser.parse(xml).map(\.title)

        #expect(title.count == 3, "the match that was played must not disappear")
        #expect(title.contains("T.Tarlaspor - Tepelispor"))
    }

    /// A true duplicate stays one — otherwise the same programme would appear
    /// twice in the list. Exactly **that** was the intent of the ID, and
    /// it is preserved.
    @Test("The same title at the same time stays one entry")
    func trueDuplicatesStillDropOut() {
        let xml = document(
            """
            <programme start="20260728140000" stop="20260728150000" channel="a">
              <title>Tagesfunke</title>
            </programme>
            <programme start="20260728140000" stop="20260728150000" channel="a">
              <title>Tagesfunke</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).count == 1)
    }

    /// **The ID must be the same across program runs.** It is
    /// the key in the store; if it were random (for instance from `hashValue`,
    /// which Swift reshuffles on every run), the download store would carry the same programme
    /// a second time after every app start, and the schedule would show it twice.
    @Test("The same broadcast gets the same identifier twice")
    func identifierIsStable() {
        let xml = document(
            """
            <programme start="20260728140000" stop="20260728150000" channel="a">
              <title>Tagesfunke</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).map(\.id) == XMLTVParser.parse(xml).map(\.id))
        #expect(XMLTVParser.parse(xml).first?.id.contains("Tagesfunke") == true)
    }

    // MARK: - Titel in mehreren Sprachen

    @Test("With several titles the German one wins")
    func germanTitleWins() throws {
        // Even if it does not come first: the app is built for German-language
        // use.
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title lang="en">The Daily News</title>
              <title lang="de">Tagesfunke</title>
              <desc lang="en">News</desc>
              <desc lang="de">Nachrichten</desc>
            </programme>
            """
        )

        let first = try #require(XMLTVParser.parse(xml).first)

        #expect(first.title == "Tagesfunke")
        #expect(first.description == "Nachrichten")
    }

    @Test("A language code with a country counts like the language itself")
    func languageWithRegion() {
        // `de-DE` and `de-AT` are both German.
        let candidates: [(language: String?, text: String)] = [
            ("en-GB", "The Daily News"), ("de-AT", "Zeit im Bild"),
        ]

        #expect(XMLTVParser.preferredText(from: candidates) == "Zeit im Bild")
    }

    @Test("Without a German title the English one wins")
    func englishIsSecondChoice() {
        let candidates: [(language: String?, text: String)] = [
            ("fr", "Le Journal"), ("en", "The News"),
        ]

        #expect(XMLTVParser.preferredText(from: candidates) == "The News")
    }

    @Test("Without a known language the first title applies")
    func firstAsFallback() {
        // Any title is better than "untitled".
        let candidates: [(language: String?, text: String)] = [("fr", "Le Journal"), (nil, "Journal")]

        #expect(XMLTVParser.preferredText(from: candidates) == "Le Journal")
        #expect(XMLTVParser.preferredText(from: []) == nil)
    }

    @Test("A title in pieces is assembled completely")
    func titleAcrossEntities() throws {
        // The parser reports the text anew at every entity. Whoever takes only the last
        // piece turns "Kram & Krusel" into " Krusel".
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title>Kram &amp; Krusel</title>
            </programme>
            """
        )

        let first = try #require(XMLTVParser.parse(xml).first)

        #expect(first.title == "Kram & Krusel")
    }

    // MARK: - Incomplete entries

    @Test("An entry without a channel identifier is skipped")
    func missingChannelAttribute() {
        // Without a channel the entry could not be displayed anywhere.
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000">
              <title>Ohne Sender</title>
            </programme>
            <programme start="20260728120000" stop="20260728130000" channel="">
              <title>Leerer Sender</title>
            </programme>
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title>Mit Sender</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).map(\.title) == ["Mit Sender"])
    }

    @Test("An entry without a title is skipped")
    func missingTitle() {
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <desc>Beschreibung ohne Titel</desc>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).isEmpty)
    }

    @Test("An end before the start discards the entry")
    func endBeforeStart() {
        // Occurs in real files, mostly through a wrongly set
        // time zone offset. Such an entry never runs and hides the right one
        // in the grid.
        let xml = document(
            """
            <programme start="20260728130000" stop="20260728120000" channel="c">
              <title>Rückwärts</title>
            </programme>
            <programme start="20260728120000" stop="20260728120000" channel="c">
              <title>Ohne Dauer</title>
            </programme>
            <programme start="20260728140000" stop="20260728150000" channel="c">
              <title>Richtig herum</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml).map(\.title) == ["Richtig herum"])
    }

    @Test("A truncated document keeps the entries read up to that point")
    func truncatedDocument() {
        // With 50 MB over a slow line, no rarity. Turning half a
        // programme into none at all would be the worse answer.
        let truncated = """
            <tv>
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title>Vollständig</title>
            </programme>
            <programme start="20260728130000" stop="2026072
            """

        #expect(XMLTVParser.parse(truncated).map(\.title) == ["Vollständig"])
    }

    @Test("An empty or nonsensical document yields nothing instead of failing")
    func emptyInput() {
        #expect(XMLTVParser.parse("").isEmpty)
        #expect(XMLTVParser.parse("<tv></tv>").isEmpty)
        #expect(XMLTVParser.parse("das ist kein XML").isEmpty)
    }

    // MARK: - Filtern

    @Test("The filtering lets only the wanted channels through")
    func channelFilter() {
        // Whoever subscribed to sixty of four hundred channels should not have to
        // parse the remaining three hundred and forty.
        let xml = document(
            (1...5).map { index in
                """
                <programme start="20260728120000" stop="20260728130000" channel="s\(index)">
                  <title>Sendung \(index)</title>
                </programme>
                """
            }.joined()
        )

        let filtered = XMLTVParser.parse(xml, channelIDs: ["s2", "s4"])

        #expect(filtered.map(\.channelID) == ["s2", "s4"])
        #expect(XMLTVParser.parse(xml).count == 5, "without a filter all come through")
    }

    @Test("Filtering on unknown channels yields nothing")
    func filterWithoutMatches() {
        let xml = document(
            """
            <programme start="20260728120000" stop="20260728130000" channel="a">
              <title>Sendung</title>
            </programme>
            """
        )

        #expect(XMLTVParser.parse(xml, channelIDs: ["gibt-es-nicht"]).isEmpty)
        #expect(XMLTVParser.parse(xml, channelIDs: []).isEmpty)
    }

    // MARK: - Identifiers and scope

    @Test("The same entry twice in the file arrives only once")
    func duplicateEntries() {
        // Merged programme guides carry the same entry
        // several times. The display shows two entries with the same ID as
        // one, and focus jumps while scrolling.
        let entry = """
            <programme start="20260728120000" stop="20260728130000" channel="c">
              <title>Tagesfunke</title>
            </programme>
            """

        #expect(XMLTVParser.parse(document(entry + entry)).count == 1)
    }

    @Test("Every entry gets an identifier of its own")
    func uniqueIdentifiers() {
        var body = ""
        for channel in 0..<5 {
            for hour in 0..<10 {
                body += """
                    <programme start="20260728\(String(format: "%02d", hour))0000" \
                    stop="20260728\(String(format: "%02d", hour + 1))0000" channel="s\(channel)">
                      <title>Sendung \(channel)/\(hour)</title>
                    </programme>
                    """
            }
        }

        let ids = XMLTVParser.parse(document(body)).map(\.id)

        #expect(ids.count == 50)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A large program guide is read completely")
    func largeDocument() {
        // Four hundred channels with twenty-four entries each. The case records
        // that nothing is lost on the way — with stateful parsers
        // exactly that happens.
        var body = ""
        for channel in 1...400 {
            for hour in 0..<24 {
                let start = String(format: "20260728%02d0000 +0200", hour)
                let stop = String(format: "20260728%02d0000 +0200", hour + 1)
                body += """
                    <programme start="\(start)" stop="\(stop)" channel="s\(channel)">
                      <title lang="de">Sendung \(channel)/\(hour)</title>
                    </programme>
                    """
            }
        }

        let all = XMLTVParser.parse(document(body))

        // Hour 24 does not exist; the last entry of each channel
        // therefore rightly drops out.
        #expect(all.count == 400 * 23)
        #expect(Set(all.map(\.channelID)).count == 400)
        #expect(XMLTVParser.parse(document(body), channelIDs: ["s7"]).count == 23)
    }

    // MARK: - Datenstrom

    @Test("A data stream is read just like loaded data")
    func streamInput() throws {
        // The path for real files: the parser reads in chunks instead of loading the
        // whole file into memory.
        let xml = document(
            """
            <programme start="20260728120000 +0200" stop="20260728130000 +0200" channel="ahorn.de">
              <title lang="de">Tagesfunke</title>
            </programme>
            """
        )

        let programmes = XMLTVParser.parse(stream: InputStream(data: Data(xml.utf8)))
        let first = try #require(programmes.first)

        #expect(first.title == "Tagesfunke")
        #expect(first.start == utc(2026, 7, 28, 10, 0))
    }

    @Test("A non-existent file yields nothing instead of failing")
    func missingFile() {
        let url = URL(fileURLWithPath: "/gibt/es/nicht/epg.xml")

        #expect(XMLTVParser.parse(fileURL: url).isEmpty)
    }
}

/// Version stage 6: old programme IDs pull the title along.
///
/// **Why pull along and not throw away** (on-device finding 2026-08-29): the
/// guide is fetched only on demand. Deleting it on update would have
/// put every viewer in front of an empty sports area until they
/// refresh by hand. Because the ID carries the title in plain text, the
/// store can pull it along itself — it is in the same row.
@Suite("Version 6: the broadcast identifier carries the title")
struct BroadcastIdentifierMigrationTests {

    @Test("A database of version 5 gets its identifiers brought up to date")
    func oldIdentifiersAreMigrated() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kennung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var db: OpaquePointer?
        let file = folder.appendingPathComponent("cinelounge-live.sqlite")
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        for command in [
            "PRAGMA user_version=5;",
            "CREATE TABLE programmes (id TEXT PRIMARY KEY, epg TEXT NOT NULL, "
                + "title TEXT NOT NULL, detail TEXT, start INTEGER NOT NULL, "
                + "stop INTEGER NOT NULL);",
            "INSERT INTO programmes VALUES ('arena1#1788019200','arena1',"
                + "'Ç.Bulutspor - Dumanspor',NULL,1788019200,1788026400);",
        ] {
            #expect(sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)

        let cache = LiveCache(directory: folder)
        let from = Date(timeIntervalSince1970: 1_788_019_000)
        let until = Date(timeIntervalSince1970: 1_788_027_000)
        let found = await cache.programmes(from: from, to: until)

        // The programme survives the lift — it is not thrown away …
        #expect(found.count == 1)
        #expect(found.first?.title == "Ç.Bulutspor - Dumanspor")
        // … and afterwards carries the same ID that the parser would give it today.
        #expect(found.first?.id == "arena1#1788019200#Ç.Bulutspor - Dumanspor")
    }
}
