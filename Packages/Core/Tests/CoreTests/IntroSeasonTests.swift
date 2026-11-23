import Foundation
import Testing

@testable import Core

/// **Seasonal intros via app update** (AP51, decision 4, 2026-09-25) — and the
/// ringtone (decision 5).
///
/// Testing goes through ``IntroCatalog/select(on:calendar:available:using:)``, the same call
/// the TV makes at startup: The date must get from there through to the season.
@Suite("AP51 · Seasons and ringtone")
struct IntroSeasonTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func tag(_ month: Int, _ tag: Int, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: tag, hour: 20))!
    }

    static func clip(_ id: String) -> String {
        ##"{"id":"\##(id)","file":"\##(id).mp4","bellAt":1,"reactionAt":1.2,"exitAt":4,"trimStart":0.5,"cardsAt":4.2}"##
    }

    static let catalog = try! IntroCatalog.read(
        Data(
            ##"""
            {"fallbackStill":"set.jpg","ringRingPosition":{"x":0.78,"y":0.4},
             "clips":[\##(clip("waschbaer")),\##(clip("katze"))],
             "saisons":[
               {"id":"weihnachten","von":"12-20","bis":"12-26","clips":[\##(clip("wb-weihnachten")),\##(clip("katze-weihnachten"))]},
               {"id":"silvester","von":"12-31","bis":"01-01","clips":[\##(clip("opa-silvester"))]},
               {"id":"kaputt","von":"13-40","bis":"12-31","clips":[\##(clip("nie"))]}
             ]}
            """##.utf8))

    /// Alle Dateien liegen da.
    static let everything: @Sendable (String) -> Bool = { _ in true }

    func drawn(
        on datum: Date, available: (String) -> Bool = IntroSeasonTests.everything
    ) -> Set<String> {
        var random = IntroCatalogTests.FixedRandom(state: 4)
        var ids: Set<String> = []
        for _ in 0..<100 {
            if let clip = Self.catalog.select(
                on: datum, calendar: Self.calendar, available: available, using: &random)
            {
                ids.insert(clip.id)
            }
        }
        return ids
    }

    @Test("A date inside the season picks the season clips, otherwise the default")
    func seasonOrDefault() {
        #expect(drawn(on: Self.tag(12, 24)) == ["wb-weihnachten", "katze-weihnachten"])
        #expect(drawn(on: Self.tag(12, 20)) == ["wb-weihnachten", "katze-weihnachten"], "first day")
        #expect(drawn(on: Self.tag(12, 26)) == ["wb-weihnachten", "katze-weihnachten"], "last day")
        #expect(drawn(on: Self.tag(12, 19)) == ["waschbaer", "katze"])
        #expect(drawn(on: Self.tag(12, 27)) == ["waschbaer", "katze"])
        #expect(drawn(on: Self.tag(7, 1)) == ["waschbaer", "katze"])
    }

    @Test("A period across New Year's applies on both sides")
    func yearChange() {
        #expect(drawn(on: Self.tag(12, 31)) == ["opa-silvester"])
        #expect(drawn(on: Self.tag(1, 1, 2027)) == ["opa-silvester"])
        #expect(drawn(on: Self.tag(1, 2, 2027)) == ["waschbaer", "katze"])
    }

    /// **The fallback:** An entry whose file is missing does not leave the start without an intro.
    @Test("An entry with a missing file falls back cleanly")
    func missingFile() {
        let withoutChristmas: (String) -> Bool = { !$0.contains("weihnachten") }
        #expect(drawn(on: Self.tag(12, 24), available: withoutChristmas) == ["waschbaer", "katze"])

        let half: (String) -> Bool = { $0 != "katze-weihnachten.mp4" }
        #expect(drawn(on: Self.tag(12, 24), available: half) == ["wb-weihnachten"])

        let catOnly: (String) -> Bool = { $0 == "katze.mp4" }
        #expect(drawn(on: Self.tag(7, 1), available: catOnly) == ["katze"])

        #expect(drawn(on: Self.tag(7, 1), available: { _ in false }).isEmpty, "then the still frame")
    }

    @Test("An unreadable period never applies")
    func unreadable() {
        let broken = try! #require(Self.catalog.seasons?.first { $0.id == "kaputt" })
        #expect(!broken.applies(on: Self.tag(12, 31), calendar: Self.calendar))
    }

    @Test("A catalog without seasons stays readable")
    func withoutSeasons() throws {
        let old = try IntroCatalog.read(
            Data(
                ##"{"fallbackStill":"a.jpg","ringRingPosition":{"x":0,"y":0},"clips":[\##(Self.clip("x"))]}"##
                    .utf8))
        #expect(old.seasons == nil)
        var random = IntroCatalogTests.FixedRandom(state: 1)
        #expect(
            old.select(
                on: Self.tag(12, 24), calendar: Self.calendar, available: Self.everything, using: &random)?
                .id
                == "x")
    }

    // MARK: - Die echte Datei

    /// **The file in the bundle:** Every season names only files that are there, and the
    /// raccoon rings — with the sound from `scripts/doorbell.py`.
    @Test("intros.json: seasons with existing files, raccoon with ringtone")
    func realFile() throws {
        let catalog = try IntroCatalogTests.catalog()
        let folder = IntroCatalogTests.folder
        func isPresent(_ file: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: file).path)
        }
        #expect(catalog.seasons != nil, "the field is in the file, even if empty")
        for saison in catalog.seasons ?? [] {
            #expect(IntroCatalog.Season.dayNumber(saison.from) != nil, "\(saison.id)")
            #expect(IntroCatalog.Season.dayNumber(saison.until) != nil, "\(saison.id)")
            for clip in saison.clips { #expect(isPresent(clip.file), "\(clip.file) is missing") }
        }
        let raccoon = try #require(catalog.clips.first { $0.id == "waschbaer" })
        let audio = try #require(raccoon.audio)
        #expect(isPresent(audio))
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: folder.appending(path: audio).path)[.size]
                as? Int)
        #expect((2_000...60_000).contains(size), "about one second of AAC")
        for clip in catalog.clips { if let audio = clip.audio { #expect(isPresent(audio)) } }
    }
}
