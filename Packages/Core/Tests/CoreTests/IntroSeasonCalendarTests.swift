import Foundation
import Testing

@testable import Core

/// **Calendar, broken entries and the still-frame deadline** (counter-check strand D, 3.1–3.4).
///
/// The review reproduced the cases on a copy; here they are stated the other way round. Cases
/// 3.1, 3.3 and 3.4 were red at the state of `a8a4326`.
@Suite("Intro seasons: calendar and leniency")
struct IntroSeasonCalendarTests {

    static let catalog = try! IntroCatalog.read(
        Data(
            ##"""
            {"fallbackStill":"set.jpg","ringRingPosition":{"x":0.78,"y":0.4},
             "clips":[\##(IntroSeasonTests.clip("std"))],
             "saisons":[
               {"id":"weihnachten","von":"12-20","bis":"12-26","clips":[\##(IntroSeasonTests.clip("wx"))]},
               {"id":"schalttag","von":"02-29","bis":"02-29","clips":[\##(IntroSeasonTests.clip("st"))]}
             ]}
            """##.utf8))

    static func day(_ m: Int, _ d: Int, _ year: Int, hour: Int = 20) -> Date {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k.date(from: DateComponents(year: year, month: m, day: d, hour: hour))!
    }

    static func calendar(_ kind: Calendar.Identifier, _ zone: String = "Europe/Berlin") -> Calendar {
        var k = Calendar(identifier: kind)
        k.timeZone = TimeZone(identifier: zone)!
        return k
    }

    func ids(_ datum: Date, _ calendar: Calendar) -> Set<String> {
        Set(Self.catalog.clips(on: datum, calendar: calendar, available: { _ in true }).map(\.id))
    }

    @Test("3.1: Christmas also with an Islamic, Japanese or Buddhist device calendar")
    func nonGregorian() {
        let christmasEve = Self.day(12, 24, 2026)
        #expect(ids(christmasEve, Self.calendar(.islamicUmmAlQura)) == ["wx"])
        #expect(ids(christmasEve, Self.calendar(.japanese)) == ["wx"])
        #expect(ids(christmasEve, Self.calendar(.buddhist)) == ["wx"])
        #expect(IntroCatalog.deviceCalendar.identifier == .gregorian)
        #expect(IntroCatalog.deviceCalendar.timeZone == .current)
    }

    @Test("The time zone counts: 8 pm Berlin on 26 Dec is already 27 Dec in Auckland")
    func timeZone() {
        let late = Self.day(12, 26, 2026)
        #expect(ids(late, Self.calendar(.gregorian)) == ["wx"])
        #expect(ids(late, Self.calendar(.gregorian, "Pacific/Auckland")) == ["std"])
    }

    @Test("29 Feb: only in a leap year, otherwise default")
    func leapDay() {
        let k = Self.calendar(.gregorian)
        #expect(ids(Self.day(2, 29, 2028), k) == ["st"])
        #expect(ids(Self.day(2, 28, 2027), k) == ["std"])
        #expect(ids(Self.day(3, 1, 2027), k) == ["std"])
    }

    @Test("3.3: A broken season entry drops out on its own, the rest stays")
    func brokenEntry() throws {
        let raw = ##"""
            {"fallbackStill":"a.jpg","ringRingPosition":{"x":0,"y":0},
             "clips":[\##(IntroSeasonTests.clip("x"))],
             "saisons":[{"id":"w","von":12,"bis":"12-26","clips":[]},
                        {"id":"s","von":"06-01","bis":"06-30","clips":[\##(IntroSeasonTests.clip("sommer"))]}]}
            """##
        let catalog = try IntroCatalog.read(Data(raw.utf8))
        #expect(catalog.clips.map(\.id) == ["x"])
        #expect(catalog.seasons?.map(\.id) == ["s"])
    }

    @Test("3.3: A broken default set stays an error")
    func brokenDefault() {
        let raw = ##"{"fallbackStill":"a.jpg","ringRingPosition":{"x":0,"y":0},"clips":[{"id":"a"}]}"##
        #expect(throws: (any Error).self) { try IntroCatalog.read(Data(raw.utf8)) }
    }

    @Test("3.4: The still-frame deadline is computed from the clips of the day")
    func stillFrameDeadline() throws {
        let raw =
            ##"{"fallbackStill":"a.jpg","ringRingPosition":{"x":0,"y":0},"clips":[{"id":"a","file":"a.mp4","bellAt":1,"reactionAt":1,"exitAt":4,"trimStart":0,"cardsAt":4.4}],"saisons":[{"id":"w","von":"12-20","bis":"12-26","clips":[{"id":"b","file":"b.mp4","bellAt":1,"reactionAt":1,"exitAt":4,"trimStart":0,"cardsAt":9.0}]}]}"##
        let k = try IntroCatalog.read(Data(raw.utf8))
        let calendar = Self.calendar(.gregorian)
        let all: (String) -> Bool = { _ in true }
        #expect(k.stillFrameDeadline(on: Self.day(12, 24, 2026), calendar: calendar, available: all) == 9.0)
        #expect(k.stillFrameDeadline(on: Self.day(7, 1, 2026), calendar: calendar, available: all) == 4.4)
        #expect(
            k.deadline(forItem: nil, on: Self.day(12, 24, 2026), calendar: calendar, available: all) == 9.0)
    }
}
