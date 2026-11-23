import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// Folding, grouping and the timestamps of the daily program.
///
/// **The test data has the shape of the real thing and not its content.** The names are
/// built the way the provider writes them — with prefix, tag and the superscript
/// decorative characters —, the addresses point nowhere.
@Suite("Channel bundles")
struct ChannelBundleTests {

    private static func channel(
        _ name: String, group: String? = "DE | SPORT", identifier: String? = nil,
        epg: String? = nil, favorite: Bool = false
    ) -> Channel {
        Channel(
            id: identifier ?? name, name: name,
            streamURL: URL(string: "https://example.test/\(UUID().uuidString)")!,
            playlistID: "probe", group: group, epgID: epg, isFavorite: favorite)
    }

    // MARK: - Folding

    /// **The case the folding was built for:** three rows that are all called "Zenit 1".
    @Test("Three qualities become one entry with three marks")
    func threeBecomeOne() {
        let folded = ChannelBundle.fold([
            Self.channel("IT: ZENIT 1 FHD"), Self.channel("IT: ZENIT 1 HD"),
            Self.channel("IT: ZENIT 1 SD"),
        ])
        #expect(folded.count == 1)
        #expect(folded[0].name == "IT: ZENIT 1")
        #expect(folded[0].marks.map(\.wording) == ["FHD", "HD", "SD"])
    }

    /// **The provider's order stays** — it is information and not carelessness. The
    /// provider lists it top to bottom anyway.
    @Test("The leader is the provider's first, not the best")
    func leaderIsTheFirst() {
        let folded = ChannelBundle.fold([
            Self.channel("ES: SOL 1 SD", identifier: "sd"), Self.channel("ES: SOL 1 FHD", identifier: "fhd"),
        ])
        #expect(folded[0].leader.id == "sd")
        #expect(folded[0].id == "sd")
    }

    /// **A bundle stands where its first feed stood.** Re-sorting would destroy the order
    /// the provider set.
    @Test("Folding happens in place, without reordering")
    func orderStays() {
        let folded = ChannelBundle.fold([
            Self.channel("DE: SPORTFELD HD", identifier: "a"),
            Self.channel("DE: ORBITSPORT", identifier: "b"),
            Self.channel("DE: SPORTFELD SD", identifier: "c"),
        ])
        #expect(folded.map(\.name) == ["DE: SPORTFELD", "DE: ORBITSPORT"])
        #expect(folded[0].feeds.map(\.id) == ["a", "c"])
    }

    /// **Folding happens per group.** Across groups, the real catalog would lose ten
    /// entries — too few to tear a channel out of the group the provider put it in.
    @Test("The same name in two groups stays twice")
    func groupSeparates() {
        let folded = ChannelBundle.fold([
            Self.channel("DE: SOLA SPORT HD", group: "DE | SOLA"),
            Self.channel("DE: SOLA SPORT SD", group: "DE | SPORT"),
        ])
        #expect(folded.count == 2)
        #expect(folded.allSatisfy { $0.marks.isEmpty })
    }

    /// **A single feed has no tags** — a switch with one position is not a switch, and
    /// "HD" alone only says that it is the only version.
    @Test("A lone channel carries no mark row")
    func oneHasNoChoice() {
        let folded = ChannelBundle.fold([Self.channel("DE: PHAROS HD")])
        #expect(folded[0].marks.isEmpty)
        #expect(folded[0].name == "DE: PHAROS")
    }

    /// The unnamed version does not drop out of the selection — it carries the dash.
    @Test("A feed without a mark gets the dash")
    func noBrand() {
        let folded = ChannelBundle.fold([
            Self.channel("ES: SOL 2 FHD"), Self.channel("ES: SOL 2"),
        ])
        #expect(folded[0].marks.map(\.wording) == ["FHD", "—"])
    }

    /// **The superscript decorative characters are folded** — 40 percent of the names carry
    /// them, and without folding `ᴴᴰ` would be a different tag than `HD`.
    @Test("Superscript marks fold along")
    func ornamentsFold() {
        let folded = ChannelBundle.fold([
            Self.channel("DE: AHORN ᴴᴰ"), Self.channel("DE: AHORN SD"),
        ])
        #expect(folded.count == 1)
        #expect(folded[0].marks.map(\.wording) == ["HD", "SD"])
    }

    // MARK: - Groups in two levels

    @Test("Prefix and subdivision come from the provider's name")
    func groupPath() {
        let routes = GroupPath.routes(from: [
            ChannelGroup(name: "DE | SOLA", count: 40),
            ChannelGroup(name: "DE | SPORT", count: 60),
            ChannelGroup(name: "AR | ARABIA", count: 644),
        ])
        #expect(routes.map(\.land) == ["DE", "AR"])
        #expect(routes[0].count == 100)
        #expect(routes[0].leadsDeeper)
        #expect(routes[0].subdivisions.map(\.name) == ["SOLA", "SPORT"])
        // **37 of the 40 prefixes have exactly one group** — there a tap on the country
        // is directly the selection, and a second level would decide nothing.
        #expect(!routes[1].leadsDeeper)
    }

    /// **Two groups of the real catalog do not fit the pattern**, and both stay
    /// as they are: `SS: SCREENSAVER` carries no dash, `UFC * MMA | FIGHT` a prefix
    /// that is not a country code.
    ///
    /// **Since AP58 R5 (finding L2) by the TV's rule**
    /// (``Core/ChannelName/countryCode(fromGroup:)``): Before, the second one stood under
    /// the "country" `UFC * MMA` — on the TV it was its own block. Now on both.
    @Test("A group without a country code is its own country")
    func groupWithoutDash() {
        let routes = GroupPath.routes(from: [
            ChannelGroup(name: "SS: SCREENSAVER", count: 3),
            ChannelGroup(name: "UFC * MMA | FIGHT", count: 12),
        ])
        #expect(routes.map(\.land) == ["SS: SCREENSAVER", "UFC * MMA | FIGHT"])
        #expect(routes.map { $0.subdivisions.map(\.name) } == [["SS: SCREENSAVER"], ["UFC * MMA | FIGHT"]])
        #expect(routes.allSatisfy { !$0.leadsDeeper })
    }

    /// **`DE|SPORT` and `de | Kino` are one country** — on the phone they were two until AP58 R5,
    /// because only `" | "` with spaces counted as a separator and the head was not capitalized.
    @Test("The dash separates even without spaces, and the code is uppercased")
    func abbreviationWithoutSpaces() {
        let routes = GroupPath.routes(from: [
            ChannelGroup(name: "DE|SPORT", count: 5),
            ChannelGroup(name: "de | Kino", count: 7),
        ])
        #expect(routes.map(\.land) == ["DE"])
        #expect(routes[0].subdivisions.map(\.name) == ["SPORT", "Kino"])
        #expect(routes[0].count == 12)
    }

    // MARK: - Recently watched

    @Test("The same channel moves to the front and does not appear twice")
    func historyMovesUp() {
        let history = ChannelHistory(store: InMemoryStore(), legacy: nil)
        history.memorize("Das Nordlicht")
        history.memorize("ZINNE")
        history.memorize("Das Nordlicht")
        #expect(history.names == ["Das Nordlicht", "ZINNE"])
    }

    /// **Per profile since AP58 R5 (finding L1).** Until then the list belonged to the device: whoever
    /// watched TV after a child profile found that profile's channels on top — and the child profile found the other's.
    @Test("Each profile has its own history, with no fallback to the device")
    func historyPerProfile() {
        let store = InMemoryStore()
        let parents = ChannelHistory(store: store, profile: { "parents" }, legacy: nil)
        let kind = ChannelHistory(store: store, profile: { "child" }, legacy: nil)
        let device = ChannelHistory(store: store, profile: { nil }, legacy: nil)
        device.memorize("From device")
        parents.memorize("Das Nordlicht")
        kind.memorize("KiMO")
        #expect(parents.names == ["Das Nordlicht"])
        #expect(kind.names == ["KiMO"])
        #expect(device.names == ["From device"])
    }

    /// **The old device list goes once to the profile that is watching right now** — and only
    /// to that one.
    @Test("The old device list is adopted once")
    func historyAdoption() throws {
        let old = try #require(UserDefaults(suiteName: "probe.\(UUID().uuidString)"))
        old.set(["ZINNE", "Avena"], forKey: "live.recentChannels")
        let store = InMemoryStore()
        let now = ChannelHistory(store: store, profile: { "parents" }, legacy: old)
        #expect(now.names == ["ZINNE", "Avena"])
        #expect(old.stringArray(forKey: "live.recentChannels") == nil, "deleted over there")
        let other = ChannelHistory(store: store, profile: { "child" }, legacy: old)
        #expect(other.names.isEmpty, "a second profile does not get it")
    }

    @Test("The history stays at eight entries")
    func historyStaysShort() {
        let history = ChannelHistory(store: InMemoryStore(), legacy: nil)
        for slot in 1...12 { history.memorize("Channel \(slot)") }
        #expect(history.names.count == ChannelHistory.length)
        #expect(history.names.first == "Channel 12")
    }

    // MARK: - The timestamps of the daily programme

    /// **After 20:15, "20:15" stays today.** Someone tapping it at 21:00 wants to see the
    /// main feature that is running — not tomorrow's.
    @Test("20:15 means today, even at 9 pm")
    func timestampEvening() throws {
        let atNine = try #require(
            Calendar.current.date(
                from: DateComponents(year: 2026, month: 9, day: 6, hour: 21)))
        let start = TimeMark.evening.start(um: atNine)
        #expect(Calendar.current.isDate(start, inSameDayAs: atNine))
        #expect(start < atNine)
    }

    @Test("Tomorrow begins at midnight and ends after one day")
    func timestampMorning() throws {
        let noon = try #require(
            Calendar.current.date(
                from: DateComponents(year: 2026, month: 9, day: 6, hour: 12)))
        let start = TimeMark.tomorrow.start(um: noon)
        let end = try #require(TimeMark.tomorrow.end(um: noon))
        #expect(start > noon)
        #expect(end.timeIntervalSince(start) == 24 * 3600)
        // The other two do not bound toward the end — there, what is known applies.
        #expect(TimeMark.now.end(um: noon) == nil)
        #expect(TimeMark.evening.end(um: noon) == nil)
    }
}
