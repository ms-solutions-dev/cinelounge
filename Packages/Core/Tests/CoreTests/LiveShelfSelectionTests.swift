import Foundation
import Testing

@testable import Core

/// **The live shelf choice and the country groups — one rule for both devices** (AP58 R5,
/// findings L2 and L3). The tests of the surfaces (`LiveShelfTests` on the TV,
/// `HomeScreenTests` on the phone) call the same rule through their wrappers; this one pins it down
/// without a wrapper.
@Suite("Live shelf selection")
struct LiveShelfSelectionTests {

    private static func channels(
        _ id: String, _ name: String, favorite: Bool = false, group: String? = nil
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://x/\(id)")!, playlistID: "liste",
            group: group, isFavorite: favorite)
    }

    // MARK: - Reihenfolge

    @Test("Without a choice: recently watched, then favorites, then the rest")
    func preset() {
        let catalog = [
            Self.channels("a", "Eins"), Self.channels("b", "Zwei", favorite: true),
            Self.channels("c", "Drei"), Self.channels("d", "Vier", favorite: true),
        ]
        let ordered = LiveShelfChoice.order(from: catalog, chosen: [], recent: ["Drei"])
        #expect(ordered.map(\.id) == ["c", "b", "d", "a"])
    }

    @Test("A choice displaces the default, one that points at nothing does not")
    func choice() {
        let catalog = [Self.channels("a", "Eins", favorite: true), Self.channels("b", "Zwei")]
        #expect(
            LiveShelfChoice.order(from: catalog, chosen: ["Zwei"], recent: ["Eins"])
                .map(\.id) == ["b"])
        #expect(
            LiveShelfChoice.order(from: catalog, chosen: ["Weg"], recent: [])
                .map(\.id) == ["a", "b"])
    }

    /// **One name, one channel — in the rest too.** On the TV, versions of the same
    /// channel stood side by side on the shelf until 2026-09-26.
    @Test("The same channel in two versions and groups appears once")
    func oneNameOneChannel() {
        let catalog = [
            Self.channels("a1", "Das Nordlicht HD", group: "DE"),
            Self.channels("a2", "Das Nordlicht", group: "HD"),
            Self.channels("b", "ZINNE"),
        ]
        let ordered = LiveShelfChoice.order(from: catalog, chosen: [], recent: [])
        #expect(ordered.map(\.id) == ["a1", "b"])
    }

    @Test("Separator rows do not reach the shelf")
    func withoutSeparatorRows() {
        let catalog = [Self.channels("a", "===== SPORT ====="), Self.channels("b", "Zwei")]
        #expect(
            LiveShelfChoice.order(from: catalog, chosen: [], recent: []).map(\.id) == ["b"])
    }

    // MARK: - Auswahl

    @Test("The default needs a programme, a choice does not")
    func programmeRequirement() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let isRunning = Programme(
            id: "p", channelID: "b", title: "Tagesfunke", start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600))
        let catalog = [Self.channels("a", "Eins"), Self.channels("b", "Zwei")]
        let program: (Channel) -> Programme? = { $0.id == "b" ? isRunning : nil }

        let preset = LiveShelfChoice.selection(catalog, chosen: [], isRunning: program)
        #expect(preset.map(\.channels.id) == ["b"])

        let chosen = LiveShelfChoice.selection(catalog, chosen: ["Eins"], isRunning: program)
        #expect(chosen.map(\.channels.id) == ["a", "b"])
        #expect(chosen.first?.isRunning == nil)
    }

    // MARK: - Selecting

    @Test("At most six, the oldest yields, a second press takes it back")
    func select() {
        var list: [String] = []
        for number in 1...7 { list = LiveShelfChoice.select("S\(number)", on: true, in: list) }
        #expect(list == ["S2", "S3", "S4", "S5", "S6", "S7"])
        #expect(LiveShelfChoice.select("S4", on: false, in: list) == ["S2", "S3", "S5", "S6", "S7"])
        #expect(LiveShelfChoice.select("S7", on: true, in: list).last == "S7")
    }

    // MARK: - Country groups (finding L2)

    @Test("The code: at the first bar, 1–4 characters, uppercase")
    func countryCode() {
        #expect(ChannelName.countryCode(fromGroup: "DE| PRIME") == "DE")
        #expect(ChannelName.countryCode(fromGroup: "de | Sport") == "DE")
        #expect(ChannelName.countryCode(fromGroup: "DE|SPORT") == "DE")
        #expect(ChannelName.countryCode(fromGroup: "8K| SPORT") == "8K")
        #expect(ChannelName.countryCode(fromGroup: "UFC * MMA | FIGHT") == nil)
        #expect(ChannelName.countryCode(fromGroup: "SPORT | PPV EXCLUSIVE") == nil)
        #expect(ChannelName.countryCode(fromGroup: "FOR ADULTS") == nil)
        #expect(ChannelName.countryCode(fromGroup: "| OHNE") == nil)
    }

    @Test("The remainder after the code — without a code the whole group")
    func groupRemainder() {
        #expect(ChannelName.groupRemainder(fromGroup: "DE | SOLA") == "SOLA")
        #expect(ChannelName.groupRemainder(fromGroup: "DE|SOLA") == "SOLA")
        #expect(ChannelName.groupRemainder(fromGroup: "UFC * MMA | FIGHT") == "UFC * MMA | FIGHT")
        #expect(ChannelName.groupRemainder(fromGroup: "SS: SCREENSAVER") == "SS: SCREENSAVER")
    }

    // MARK: - Sportfilter (Befund L4)

    /// **One key for both devices**: The old phone choice transfers once
    /// and is deleted over there; a later choice never overwrites it again.
    @Test("The phone's sport choice is adopted once")
    func sportSelectionCarryOver() {
        let bucket = InMemoryStore()
        try? bucket.set("darts\ntennis", for: LivePreferences.sportsKey)

        let read = SportFilterSettings.load(from: bucket)
        #expect(read.disabled == ["darts", "tennis"])
        #expect((try? bucket.value(for: LivePreferences.sportsKey)) == nil)
        #expect(SportFilterSettings.load(from: bucket) == read, "saved under the new key")

        var fresh = read
        fresh.toggle(.darts)
        fresh.save(to: bucket)
        try? bucket.set("football", for: LivePreferences.sportsKey)
        #expect(SportFilterSettings.load(from: bucket).disabled == ["tennis"], "the new choice applies")
    }
}
