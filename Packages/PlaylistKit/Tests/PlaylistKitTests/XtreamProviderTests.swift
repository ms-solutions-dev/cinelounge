import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Tests run against **responses shaped like a real provider's**, not against
/// tidy examples.
///
/// The reason is experience: invented responses are tidy. The catalogs this app
/// has to run against are not — about one entry in fifty is not a channel at all,
/// numbers arrive in the same response both as a string and as a number, times
/// come twice and in different time zones, and nearly every title carries a
/// prefix that the provider never explains anywhere. A test case that does not
/// reflect this says nothing about the app.
///
/// The files under `Fixtures/` are synthetic: `intern/fixtures-synth/iptv.py`
/// writes them with the keys, types and quirks of shortened captures of a real
/// provider, and with invented names, hosts and identifiers. The counts asserted
/// below are counts of those files. **No test here touches the network**: the
/// access expires, and a test rig that depends on the provider fails one day
/// through no fault of its own — and then nobody trusts it any more.
@Suite("Xtream provider: data layer")
struct XtreamProviderTests {

    // MARK: - Hilfen

    let account = XtreamEndpoint(
        server: URL(string: "http://panel.example:8080")!,
        username: "benutzer",
        password: "geheim"
    )

    /// Loads a fixture from the test bundle.
    func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "Fixture \(name) is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    func liveStreams() throws -> [XtreamPayload.LiveStream] {
        try XtreamPayload.decoder.decode(
            [XtreamPayload.LiveStream].self,
            from: try fixture("get_live_streams.json")
        )
    }

    func liveCategories() throws -> [String: String] {
        let list = try XtreamPayload.decoder.decode(
            [XtreamPayload.Category].self,
            from: try fixture("get_live_categories.json")
        )
        return Dictionary(
            list.compactMap { category in
                category.categoryID.map { ($0, category.categoryName ?? "") }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func channels() throws -> [Channel] {
        let categories = try liveCategories()
        return try liveStreams().compactMap { stream in
            XtreamPayload.channel(
                from: stream,
                categories: categories,
                playlistID: "liste1",
                credentials: account
            )
        }
    }

    /// Parses a response exactly like ``XtreamClient/programmes(for:around:)``.
    ///
    /// The match is the point: this helper once queried the entries **one by one**
    /// while production did the same — and together they hid the encoding bug. Whoever
    /// changes it must change production too, otherwise nothing here checks the path
    /// the app really takes.
    func programmes(from data: Data) throws -> [Programme] {
        let payload = try XtreamPayload.decoder.decode(XtreamPayload.EPGResponse.self, from: data)
        return XtreamPayload.programmes(
            from: payload.epgListings ?? [],
            channelID: "liste1#xtream#771001"
        )
    }

    /// A point in time in UTC, independent of the time zone of the machine running the tests.
    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: 0
            )
        )!
    }

    // MARK: - What is not a channel at all

    @Test("Every group heading of the fixture drops out of the channel list")
    func sectionMarkersAreDropped() throws {
        let streams = try liveStreams()
        let channels = try channels()

        // The three headings in the fixture stand for the many of a whole
        // catalog. If one got through, the viewer would have an entry in the
        // list that shows a black picture on a button press — and they look for the
        // fault in themselves, not in the provider.
        #expect(streams.count == 75)
        #expect(channels.count == 72)
        #expect(!channels.contains { $0.isSectionMarker })
        #expect(!channels.contains { $0.name.contains("#") })
    }

    @Test("No real channel is mistaken for a group heading")
    func realChannelsSurvive() throws {
        let streams = try liveStreams()
        let channels = try channels()

        // The counter-check to the test above, and the more important of the two: a rule
        // that is too strict silently removes channels from the list, and
        // nobody notices — only one of thousands is missing. Both are therefore tested
        // against each other: every entry without a hash frame must arrive.
        let expected = streams.filter { stream in
            guard let name = stream.name else { return false }
            return !name.contains("#")
        }

        #expect(channels.count == expected.count)
        #expect(channels.contains { $0.name == "VELDA: HOFKANAL ᴿᴬᵂ" })
    }

    @Test("The text of a group heading is kept as the section name")
    func sectionTitlesRemain() throws {
        let titles = XtreamPayload.sectionTitles(in: try liveStreams())

        // Filtering out does not mean throwing away: in many cases the heading
        // names a subdivision that appears in no category of the provider — a
        // large sports category can be ordered by country exclusively through such
        // lines. If the text were lost here, this ordering could no longer be
        // rebuilt.
        #expect(titles.count == 3)
        #expect(titles.allSatisfy { !$0.contains("#") })
        #expect(titles.contains { $0.contains("VELDA") })
        #expect(titles.contains { $0.contains("SERPEK SPORTS GOLD") })
    }

    // MARK: - Flagging and catch-up

    @Test("Channels flagged as adult content arrive flagged")
    func adultFlagIsCarried() throws {
        let channels = try channels()
        let marked = channels.filter(\.isAdult)

        // Without this carry-over, ``LivePreferences.showsAdultChannels`` would be a
        // switch with no effect: 25 channels of this fixture — hundreds in a whole
        // catalog — would appear in the list despite the block being set. This is the one
        // mistake that cannot be made good again.
        #expect(marked.count == 25)
        #expect(marked.allSatisfy { $0.name.hasPrefix("ADULT:") })

        let preferences = LivePreferences(showsAdultChannels: false)
        #expect(LiveLibrary.visible(channels, preferences: preferences).count == 47)
    }

    @Test("The catch-up window is taken over in days, even when it comes as a string")
    func archiveDaysAreCarried() throws {
        // Shaped like an entry of the provider's response for a channel with
        // catch-up. Notable is the spelling: `tv_archive` arrives as a number,
        // `tv_archive_duration` as a string — in the same response. Whoever reads only
        // one of the two forms loses not the field but the whole
        // channel list, because decoding fails.
        let data = Data(
            #"""
            [{"num":255,"name":"KIRSO: DEMO CINEMA ᴴᴰ ◉","stream_type":"live",
              "stream_id":771001,"epg_channel_id":"democinema.de","is_adult":0,
              "category_id":"2105","tv_archive":1,"direct_source":"","tv_archive_duration":"3"}]
            """#.utf8
        )

        let streams = try XtreamPayload.decoder.decode([XtreamPayload.LiveStream].self, from: data)
        let stream = try #require(streams.first)

        #expect(stream.archiveDays == 3)

        let channel = try #require(
            XtreamPayload.channel(
                from: stream, categories: [:], playlistID: "liste1", credentials: account
            )
        )
        #expect(channel.archiveDays == 3)
    }

    @Test("Without an enabled catch-up window an entered duration is ignored")
    func archiveNeedsBothFields() throws {
        // The same channel with `tv_archive: 0`. Assuming the duration alone would mean
        // offering the viewer a time travel that the provider does not serve
        // — and the error message would come only after the button press.
        let data = Data(
            #"""
            [{"name":"KIRSO: DEMO CINEMA","stream_id":771001,
              "tv_archive":0,"tv_archive_duration":"3"}]
            """#.utf8
        )

        let stream = try #require(
            try XtreamPayload.decoder.decode([XtreamPayload.LiveStream].self, from: data).first
        )
        #expect(stream.archiveDays == nil)
    }

    @Test("In the fixture no channel without catch-up carries a duration")
    func archiveIsAbsentInFixture() throws {
        // Counter-check on all 75 entries: the provider's responses pair `tv_archive: 0` with
        // `tv_archive_duration: 0`. If this test failed, the parser would have invented
        // a catch-up where there is none — and the interface would show on every
        // channel a button that leads nowhere.
        #expect(try channels().allSatisfy { $0.archiveDays == nil })
    }

    // MARK: - Programmzeiten

    @Test("The broadcast time comes from the timestamp and is not two hours off")
    func programmeTimesComeFromTimestamp() throws {
        let programmes = try programmes(from: try fixture("short_epg.json"))
        let first = try #require(programmes.first)

        // The calculation on the fixture's values: for this programme it gives
        // `"start": "2026-07-28 14:25:00"` and `"start_timestamp": "1785248700"`.
        // Read as UTC, the string yields exactly 1785248700 — so both
        // values point to the same instant, 16:25 German local time.
        //
        // The mistake this test catches: whoever reads the string as local time
        // arrives at 1785241500 and thus at 14:25 local time. Then the channel list
        // consistently shows the wrong programme as "on now", and
        // shifted by exactly the time zone offset.
        #expect(first.start == Date(timeIntervalSince1970: 1_785_248_700))
        #expect(first.start == utc(2026, 7, 28, 14, 25))
        #expect(first.end == Date(timeIntervalSince1970: 1_785_256_200))
        #expect(first.end.timeIntervalSince(first.start) == 125 * 60)

        // And the counter-check: local time would be something else.
        #expect(first.start != utc(2026, 7, 28, 16, 25))
    }

    @Test("Without a timestamp the string counts as universal time")
    func stringTimeIsFallback() throws {
        // Not every provider sends `start_timestamp`. If this fallback were
        // dropped, such providers would have no programme at all — the channel view
        // would stay empty without anything looking faulty.
        let data = Data(
            #"""
            {"epg_listings":[{"id":"1","title":"QWJlbmRqb3VybmFs","start":"2026-07-28 14:25:00",
              "end":"2026-07-28 14:40:00"}]}
            """#.utf8
        )

        let first = try #require(try programmes(from: data).first)
        #expect(first.start == utc(2026, 7, 28, 14, 25))
        #expect(first.title == "Abendjournal")

        // The counter-check, and the real purpose of this test: the same
        // string read as German local time lies two hours earlier.
        // Calculated explicitly against `Europe/Berlin` and not against the time zone
        // of the machine running the tests — otherwise the test would be mute on a machine in UTC,
        // and that is exactly where it runs during the build.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let asLocalTime = try #require(
            berlin.date(
                from: DateComponents(year: 2026, month: 7, day: 28, hour: 14, minute: 25, second: 0)
            )
        )
        #expect(first.start.timeIntervalSince(asLocalTime) == 7200)
    }

    @Test("A timestamp of zero counts as no value")
    func zeroTimestampIsNoTime() throws {
        // Some entries carry `0`. Reading that as 1 January 1970 would not be
        // merely wrong but visible: the programme would sit 56 years before all the
        // others in the list and stretch the time axis of the channel view apart.
        let data = Data(
            #"""
            {"epg_listings":[{"id":"1","title":"QWJlbmRqb3VybmFs",
              "start_timestamp":"0","stop_timestamp":"0"}]}
            """#.utf8
        )

        #expect(try programmes(from: data).isEmpty)
    }

    @Test("Title and description of the programme come back from the encoding")
    func programmeTextIsDecoded() throws {
        let programmes = try programmes(from: try fixture("short_epg.json"))
        let first = try #require(programmes.first)

        // The provider encodes both in Base64. Without reversing it, the
        // TV shows `SGFyYm9yIFBhdHJvbCBJSUk=` instead of the film title — and that
        // does not look like a bug but like corrupt data.
        #expect(first.title == "Grauwacke III")
        #expect(first.description?.contains("Kartografinnen") == true)

        // Umlauts survive: the description is UTF-8 in Base64, and a
        // wrongly assumed character set turns it into "zurÃ¼ck".
        #expect(first.description?.contains("zurück") == true)
        #expect(programmes.count == 4)
    }

    @Test("A channel without a programme yields an empty list and no error")
    func emptyEPGIsNoFailure() throws {
        // This is how the provider answers for the majority of channels that carry no
        // programme ID — checked against a capture. If this were treated as an
        // error, the channel view would show a fault message for four of five
        // channels although everything is fine.
        #expect(try programmes(from: Data(#"{"epg_listings":[]}"#.utf8)).isEmpty)
    }

    @Test("An entry with reversed or missing times drops out, the others stay")
    func brokenTimesDropOnlyTheirOwnEntry() throws {
        // Three kinds of junk in one response, and all three occur: an end
        // before the start, an end exactly on the start, an entry with no time at all.
        //
        // What the viewer notices depends on how they are handled. If
        // they were not dropped, the channel view would show a programme that never runs —
        // ``Programme/isRunning(at:)`` requires `start <= now < end`, and for a
        // reversed pair that is true at no point in time. The "on now" row
        // would stay empty although a programme is there. Conversely, if the whole
        // response were dropped, the channel would lose its programme because of a single broken
        // line.
        let data = Data(
            #"""
            {"epg_listings":[
              {"id":"1","title":"Verkehrt","start_timestamp":1785253200,
               "stop_timestamp":1785249600},
              {"id":"2","title":"Nachrichten","start_timestamp":1785248700,
               "stop_timestamp":1785249600},
              {"id":"3","title":"Ohne Zeit"},
              {"id":"4","title":"Punktgleich","start_timestamp":1785249600,
               "stop_timestamp":1785249600}
            ]}
            """#.utf8
        )

        let programmes = try programmes(from: data)

        #expect(programmes.map(\.title) == ["Nachrichten"])
    }

    @Test("A plain-text title that happens to look like base characters stays readable")
    func plainTitleThatLooksEncodedSurvives() throws {
        // `Film` is the case where this is decided: four characters, all from the
        // base alphabet, length divisible by four. Reversed, it gives the three bytes
        // 16 29 66 — valid UTF-8 with one letter in it, so by every
        // single criterion "encoded". On the TV, instead of "Film", there would then be
        // a box, an at sign and an f.
        //
        // Seen over the whole response, the one chance hit tips nothing: of
        // four titles one is reversible, the two-thirds threshold is missed by a wide margin,
        // and all four stay as they came. This provider sends
        // plain text, and that has to be recognised from the response and not from the line.
        let data = Data(
            #"""
            {"epg_listings":[
              {"id":"1","title":"Abendjournal","start_timestamp":1785248700,
               "stop_timestamp":1785249600},
              {"id":"2","title":"Film","start_timestamp":1785249600,
               "stop_timestamp":1785253200},
              {"id":"3","title":"Ballzeit","start_timestamp":1785253200,
               "stop_timestamp":1785256800},
              {"id":"4","title":"Wetter","start_timestamp":1785256800,
               "stop_timestamp":1785257100}
            ]}
            """#.utf8
        )

        let titles = try programmes(from: data).map(\.title)

        #expect(titles == ["Abendjournal", "Film", "Ballzeit", "Wetter"])
    }

    @Test("With an encoding provider a non-reversible title does not tip the response")
    func oneOddTitleDoesNotFlipAnEncodedResponse() throws {
        // The opposite direction, and just as important: if three of four titles
        // arrive in Base64 and one does not — the provider writes a special broadcast
        // in by hand —, the response still counts as encoded. Two thirds
        // are reached. The three are reversed, the fourth stays as raw text
        // because it cannot be reversed.
        //
        // Asked line by line, the same would come out. The case is here anyway: it
        // records that the threshold does not hit the encoding providers — otherwise
        // `QWJlbmRqb3VybmFs` would appear in the programme, and that is the costlier mistake.
        let data = Data(
            #"""
            {"epg_listings":[
              {"id":"1","title":"QWJlbmRqb3VybmFs","start_timestamp":1785248700,
               "stop_timestamp":1785249600},
              {"id":"2","title":"QmFsbHplaXQ=","start_timestamp":1785249600,
               "stop_timestamp":1785253200},
              {"id":"3","title":"V2V0dGVy","start_timestamp":1785253200,
               "stop_timestamp":1785256800},
              {"id":"4","title":"Sondersendung zur Wahl","start_timestamp":1785256800,
               "stop_timestamp":1785257100}
            ]}
            """#.utf8
        )

        let titles = try programmes(from: data).map(\.title)

        #expect(titles == ["Abendjournal", "Ballzeit", "Wetter", "Sondersendung zur Wahl"])
    }

    // MARK: - Titel zerlegen

    /// Titles in the provider's spelling with what has to come out.
    ///
    /// 42 lines. The names are invented, the shapes are not: each line repeats a
    /// form found in a capture of the provider's catalog. Gathered here are the
    /// cases on which a title split fails:
    ///
    /// - **Prefixes of every kind:** `DE`, `4K-DE`, `DE-JO`, `4K-DE-DV`, `XXX`,
    ///   `007`, `MAX`, `AR-SUBS`, `CR`.
    /// - **Without a prefix** (rare in the catalog), among them three that look
    ///   like one: `Fogwick - Die Uhrensammler`, `Marsh Harbour - Ein Dorf am Wasser`,
    ///   `Spätes Laub - A Season at Ferris Mill`. Whoever cuts here invents the
    ///   language "Fogwick" and throws the film name away.
    /// - **Without a year** (about a third of the catalog), among them one with a
    ///   year in the middle of the name: `Demo Cup 2026 Halbfinale`. A parser that
    ///   takes years without parentheses turns it into "Demo Cup Halbfinale
    ///   (2026)".
    /// - **Lowercase in the prefix:** `Nf - Rainfall for Your Home` stays
    ///   whole, because `Nf` is not a label but could be a name.
    /// - **Two parentheses:** `(2026) (DE)` — the second is the country of origin and
    ///   not the audio language.
    static let providerTitles: [(raw: String, title: String, year: Int?, language: String?, tag: String?)] = [
        ("DE - The Velvet Ledger (2019)", "The Velvet Ledger", 2019, "DE", "DE"),
        ("4K-DE - Quiet Harbor (2026)", "Quiet Harbor", 2026, "DE", "4K-DE"),
        ("DE - 40 ZINNKRÜGE (2026)", "40 ZINNKRÜGE", 2026, "DE", "DE"),
        (
            "DE - Demo Cup 2026 Halbfinale: Nordland Vs Südland",
            "Demo Cup 2026 Halbfinale: Nordland Vs Südland", nil, "DE", "DE"
        ),
        ("DE - Der Schrank von Tante Wilma  (1972)", "Der Schrank von Tante Wilma", 1972, "DE", "DE"),
        (
            "DE - Kettle Point - Night of the Ferrymen", "Kettle Point - Night of the Ferrymen", nil,
            "DE", "DE"
        ),
        ("DE - Quendel 5: Copper Hill", "Quendel 5: Copper Hill", nil, "DE", "DE"),
        (
            "DE - Gallowmere - Erst Regen. Dann Ruhe.",
            "Gallowmere - Erst Regen. Dann Ruhe.", nil, "DE", "DE"
        ),
        ("DE - Wumpel!  (2019)", "Wumpel!", 2019, "DE", "DE"),
        (
            "DE - Señora Ibáñez pflanzt Zitronen",
            "Señora Ibáñez pflanzt Zitronen", nil, "DE", "DE"
        ),
        ("XXX - Adult Title 1 (2014)", "Adult Title 1", 2014, nil, "XXX"),
        ("XXX - Adult Title 13", "Adult Title 13", nil, nil, "XXX"),
        ("DE - Odila: Ein Sommer in Lärchenau (2026)", "Odila: Ein Sommer in Lärchenau", 2026, "DE", "DE"),
        ("DE - Plumfield Inquiries", "Plumfield Inquiries", nil, "DE", "DE"),
        ("Dr. Kowalczyk 2 (2001)", "Dr. Kowalczyk 2", 2001, nil, nil),
        ("Fogwick - Die Uhrensammler (1983)", "Fogwick - Die Uhrensammler", 1983, nil, nil),
        (
            "Spätes Laub - A Season at Ferris Mill (2014)",
            "Spätes Laub - A Season at Ferris Mill", 2014, nil, nil
        ),
        (
            "Marsh Harbour - Ein Dorf am Wasser (1990)", "Marsh Harbour - Ein Dorf am Wasser",
            1990, nil, nil
        ),
        ("Nf - Rainfall for Your Home", "Nf - Rainfall for Your Home", nil, nil, nil),
        ("Hedgerow (1942)", "Hedgerow", 1942, nil, nil),
        ("F1: 2024 GP Nordland Rennen", "F1: 2024 GP Nordland Rennen", nil, nil, nil),
        (
            "Wresling: Demo Ringfest XII - Samstag (2024)",
            "Wresling: Demo Ringfest XII - Samstag", 2024, nil, nil
        ),
        ("007 - Gravel Pit Waltz (2010)", "Gravel Pit Waltz", 2010, nil, "007"),
        ("AR-SUBS - Saffron Alley (2024)", "Saffron Alley", 2024, "AR", "AR-SUBS"),
        ("A+ Pellmore Junction (2025)", "A+ Pellmore Junction", 2025, nil, nil),
        ("NF: Tollgate Part II (2024)", "NF: Tollgate Part II", 2024, nil, nil),
        ("DE (2009) - Crumpet Lane  (2002)", "DE (2009) - Crumpet Lane", 2002, nil, nil),
        ("D+ The Gorsewood (2014) (US)", "D+ The Gorsewood", 2014, nil, nil),
        ("MAX - Ravel Street (2022) (US)", "Ravel Street", 2022, nil, "MAX"),
        ("TR - Moonhwa Station (2021) (KR)", "Moonhwa Station", 2021, "TR", "TR"),
        (
            "NF - Stone and Salt: The Old Roads (2020) (US)", "Stone and Salt: The Old Roads", 2020, nil,
            "NF"
        ),
        (
            "DE-JO - Das Kieselhaus (2026) (DE)", "Das Kieselhaus", 2026, "DE",
            "DE-JO"
        ),
        (
            "DE-JO - Hagen und Hilde - Zwei Koffer für Sizilien (2025) (DE)",
            "Hagen und Hilde - Zwei Koffer für Sizilien", 2025, "DE", "DE-JO"
        ),
        (
            "DE-JO - Das Kieselhaus (2026) (DE) - S01E01 - Episode 1",
            "Das Kieselhaus", 2026, "DE", "DE-JO"
        ),
        ("DE - Porchlight Avenue (1985) (US)", "Porchlight Avenue", 1985, "DE", "DE"),
        ("DE-DO - The Ploughmen (2025)", "The Ploughmen", 2025, "DE", "DE-DO"),
        ("3D-DE - Coral Cartographers 3D (2017)", "Coral Cartographers 3D", 2017, "DE", "3D-DE"),
        ("DE-TOP - 01. Gravelmoor (1994)", "01. Gravelmoor", 1994, "DE", "DE-TOP"),
        ("CR - Hanabatake Patrol (2024) (JP)", "Hanabatake Patrol", 2024, nil, "CR"),
        ("4K-DE-DV - Thimbleton (2021) (US)", "Thimbleton", 2021, "DE", "4K-DE-DV"),
        (
            "TR - Kuyudaki Taşlar Şarkı Söyler (2015) (TR)", "Kuyudaki Taşlar Şarkı Söyler",
            2015, "TR", "TR"
        ),
        ("NF - Ember Street", "Ember Street", nil, nil, "NF"),
    ]

    @Test("42 titles in the provider's spelling are split without losing a name", arguments: providerTitles)
    func providerTitlesAreParsed(
        row: (raw: String, title: String, year: Int?, language: String?, tag: String?)
    ) {
        let parsed = XtreamTitle.parse(row.raw)

        #expect(parsed.title == row.title, "Title from \(row.raw)")
        #expect(parsed.year == row.year, "Year from \(row.raw)")
        #expect(parsed.language == row.language, "Language from \(row.raw)")
        #expect(parsed.tag == row.tag, "Prefix from \(row.raw)")
    }

    @Test("A series episode title yields series, year, season, episode and episode name")
    func episodeTitleIsSplit() {
        // The test case from the catalog. Without the split, this line would appear
        // in full in each of the twelve episodes of a season, and the only
        // difference — the number — would sit in the middle, where nobody reads it.
        let parsed = XtreamTitle.parse(
            "DE-JO - Das Kieselhaus (2026) (DE) - S01E01 - Episode 1"
        )

        #expect(parsed.title == "Das Kieselhaus")
        #expect(parsed.year == 2026)
        #expect(parsed.language == "DE")
        #expect(parsed.originCountry == "DE")
        #expect(parsed.seasonNumber == 1)
        #expect(parsed.episodeNumber == 1)
        #expect(parsed.episodeTitle == "Episode 1")
    }

    @Test("The episode marker is also found behind a series title with a dash")
    func episodeMarkerAfterDashInSeriesTitle() {
        // There are series with a dash in the name — `Hagen und Hilde - Zwei
        // Koffer für Sizilien` stands for them. Whoever splits at the first dash takes
        // "Zwei Koffer für Sizilien - S02E03 - …" for the episode name and shows the
        // episode under the wrong season.
        let parsed = XtreamTitle.parse(
            "DE-JO - Hagen und Hilde - Zwei Koffer für Sizilien (2025) (DE) - S02E03 - Der Umzug"
        )

        #expect(parsed.title == "Hagen und Hilde - Zwei Koffer für Sizilien")
        #expect(parsed.seasonNumber == 2)
        #expect(parsed.episodeNumber == 3)
        #expect(parsed.episodeTitle == "Der Umzug")
    }

    @Test("A title without an episode name keeps its number as the label")
    func episodeWithoutTitleKeepsNumber() {
        // Happens when the provider writes only the ID. An empty line
        // in the episode list would tell nothing — the number does.
        let parsed = XtreamTitle.parse("DE - Lindenhof (1988) (DE) - S35E07")

        #expect(parsed.title == "Lindenhof")
        #expect(parsed.episodeNumber == 7)
        #expect(parsed.episodeTitle == nil)
        #expect(parsed.episodeDisplayTitle == "Episode 7")
    }

    @Test("No title of the fixtures loses text that is not prefix or year")
    func nothingIsLostAcrossFixtures() throws {
        let movies = try XtreamVOD.movies(from: try fixture("get_vod_streams.json"))
        let series = try XtreamVOD.series(from: try fixture("get_series.json"))

        // The blanket licence for the rules above, tested on all 69 titles of the
        // fixtures: the cleaned title must appear **verbatim** in the original.
        // That catches every kind of mangling — a swallowed
        // letter, a double space in the wrong place, a
        // truncated subtitle —, without maintaining 69 expectations individually.
        for raw in try rawTitles() {
            let parsed = XtreamTitle.parse(raw)
            #expect(!parsed.title.isEmpty, "empty title from \(raw)")
            #expect(
                XtreamTitle.collapsed(raw).contains(parsed.title),
                "\(parsed.title) is not in \(raw)"
            )
            // A leading dash is the mark of a cut in the
            // wrong place.
            #expect(!parsed.title.hasPrefix("-"), "cut edge in \(raw)")
        }

        #expect(movies.count == 45)
        #expect(series.count == 24)
        #expect(movies.allSatisfy { !$0.title.isEmpty })
        #expect(series.allSatisfy { !$0.title.isEmpty })
    }

    @Test("No title without a separator dash loses a prefix")
    func titlesWithoutSeparatorKeepEverything() throws {
        // The other direction of the same concern: without ` - ` there is no prefix
        // that may be cut off. If this failed, the split would rob
        // titles like `Hedgerow (1942)` of their first word.
        for raw in try rawTitles() where !raw.contains("-") {
            let parsed = XtreamTitle.parse(raw)
            #expect(parsed.tag == nil, "invented prefix in \(raw)")
        }
    }

    func rawTitles() throws -> [String] {
        let live = try JSONSerialization.jsonObject(with: try fixture("get_vod_streams.json"))
        let shows = try JSONSerialization.jsonObject(with: try fixture("get_series.json"))
        let entries = ((live as? [Any]) ?? []) + ((shows as? [Any]) ?? [])
        return entries.compactMap { ($0 as? [String: Any])?["name"] as? String }
    }

    // MARK: - Container and engine choice

    @Test("The container comes along so MKV does not fail at the system player")
    func containerReachesTheEngineChoice() throws {
        let movies = try XtreamVOD.movies(from: try fixture("get_vod_streams.json"))

        // The core of the matter, and the reason why the **engine choice** is tested
        // here and not just the field: in the provider's catalog more than four in
        // five films are MKV. If the container is missing from the ``MediaSource``,
        // ``PlaybackEngineSelector`` takes it as unknown — for most of the catalog
        // a black picture with no message.
        let containers = movies.compactMap { $0.source?.container }
        #expect(containers.count == movies.count)
        #expect(containers.filter { $0 == .mkv }.count == 25)
        #expect(containers.filter { $0 == .mp4 }.count == 19)
        #expect(containers.filter { $0 == .avi }.count == 1)

        for movie in movies {
            let source = try #require(movie.source)
            let decision = PlaybackEngineSelector.decide(for: source)

            switch source.container {
            case .mkv:
                // **Since 2026-08-10 the app remuxes MKV itself** — Apple's engine
                // plays the result, a second engine is no longer needed for it. Nobody can
                // transcode here anyway: an
                // Xtream provider delivers the file as it lies.
                #expect(decision.delivery == .remuxInApp, "\(movie.title)")
            case .avi:
                // For AVI there is no reader — and since the VLC removal also
                // no second engine. The native attempt is the last
                // resort; if it fails, the message is honest.
                #expect(decision.delivery == .directPlay)
            default:
                // Everything else — MP4 and relatives — goes out unchanged.
                // **Here stood `engine == .native`**, which since the
                // VLC removal was true in every case (AP8, added 2026-09-02).
                #expect(decision.delivery == .directPlay, "\(movie.title)")
            }
        }
    }

    @Test("With a series episode container, codec, audio track and bitrate come along")
    func episodeSourceIsComplete() throws {
        let episodes = try XtreamVOD.episodes(
            from: try fixture("series_info.json"),
            seriesID: "5678",
            playlistID: "liste1"
        )
        let first = try #require(episodes.first)
        let source = try #require(first.source)

        #expect(source.container == .mkv)
        #expect(source.videoCodec == "h264")
        #expect(source.audioTracks.first?.language == "ger")

        // The provider reports `"bitrate": 8453` — kilobits per second, verified
        // on 1920×1080 in H.264. Whoever takes the number unchanged reports
        // 8 kbit/s: every bandwidth limit would consider the film effortlessly
        // transmittable, and the decision "transcode because the line does not
        // suffice" would never fire — not even over the tunnel with 0.3 Mbit/s.
        #expect(source.bitrate == 8_453_000)
    }

    @Test("The episodes of the fixture carry season, number and short name")
    func episodesAreNamedShort() throws {
        let episodes = try XtreamVOD.episodes(
            from: try fixture("series_info.json"),
            seriesID: "5678",
            playlistID: "liste1"
        )

        // Tested together because it belongs together: the series title is shown above
        // the list, and it must not appear another twenty times in the rows.
        #expect(episodes.count == 20)
        #expect(episodes.first?.title == "Episode 1")
        #expect(episodes.first?.parentTitle == "Das Kieselhaus")
        #expect(episodes.first?.seasonNumber == 1)
        #expect(episodes.first?.episodeNumber == 1)
        #expect(episodes.allSatisfy { !($0.title).contains("S0") })
    }

    @Test("The runtime comes from the clock time and not from the minute count")
    func runtimeComesFromClock() throws {
        let movie = try #require(
            try XtreamVOD.movieDetail(from: try fixture("vod_info.json"), playlistID: "liste1")
        )

        // The provider gives for this 90-minute film `"duration_secs": "90"`
        // next to `"duration": "01:30:00"`. The field is called "seconds" and contains
        // minutes. Whoever takes it by its name shows "1 min", and the
        // progress bar is at the end after one second — for every film.
        #expect(movie.runtime == 5400)
        #expect(movie.title == "The Velvet Ledger")
        #expect(movie.year == 2019)
        #expect(movie.source?.container == .mkv)
    }

    // MARK: - Einstellungen des Zuschauers

    @Test("Group selection and adult lock work together in one place")
    func preferencesFilterTogether() throws {
        let channels = try channels()
        let group = try #require(channels.first(where: { $0.isAdult })?.group)

        var preferences = LivePreferences(showsAdultChannels: true)
        preferences.setVisible(false, group: group)

        // Both conditions must run through **one** place. If the
        // channel list applied the group selection and search only the block, a
        // channel would appear in search that is in no list — and that looks like
        // a bug of the app, not like a setting.
        let visible = LiveLibrary.visible(channels, preferences: preferences)
        #expect(!visible.contains { $0.group == group })
        #expect(visible.count == channels.count - 25)
    }

    @Test("Group headings do not reach the collection from an M3U list either")
    func libraryDropsSectionMarkers() throws {
        // The Xtream parser already filters them out; for M3U lists there is
        // no such protection, and the same lines are there. ``LiveLibrary`` is
        // the only place every list runs through.
        let url = URL(string: "http://panel.example/live/benutzer/geheim/1.ts")!
        let mixed = [
            Channel(id: "1", name: "##### PAYTV HEVC #####", streamURL: url, playlistID: "liste1"),
            Channel(id: "2", name: "VELDA: HOFKANAL ᴿᴬᵂ", streamURL: url, playlistID: "liste1"),
        ]

        let usable = LiveLibrary.usable(mixed)
        #expect(usable.map(\.id) == ["2"])
    }
}
