import Core
import Foundation
import Testing

@testable import PlaylistKit

/// What is hidden does not belong in the schedule either.
///
/// **On-device finding 2026-08-29:** with a number of groups hidden so that currently
/// only Turkish and German groups are available, Sport should consider
/// only the visible ones; French or Portuguese channels are not needed.
///
/// Since 2026-08-29 the filter has been at the channel list and at the player's overlay,
/// explicitly as a rule at the source instead of in every view —
/// so that it is not forgotten in a third place. In the schedule it was
/// forgotten anyway.
@Suite("The schedule sees only the visible channels")
struct ScheduleVisibilityTests {

    private func channels(_ id: String, group: String?) -> Channel {
        Channel(
            id: id, name: id.uppercased(),
            streamURL: URL(string: "http://host/live/u/p/\(id).m3u8")!,
            playlistID: "p1", group: group, epgID: id)
    }

    private func broadcast(_ channel: String, _ title: String) -> Programme {
        Programme(
            id: "\(channel)#1#\(title)", channelID: channel, title: title,
            start: Date(timeIntervalSince1970: 1_788_012_900),
            end: Date(timeIntervalSince1970: 1_788_020_100), description: nil)
    }

    private var catalog: [Channel] {
        [
            channels("arenabundesliga1.de", group: "Deutschland"),
            channels("arenaspor1.tr", group: "Türkei"),
            channels("arenaspor2.fr", group: "Frankreich"),
            channels("arenasport1.pt", group: "Portugal"),
        ]
    }

    private var broadcasts: [Programme] {
        [
            broadcast("arenabundesliga1.de", "Fußball: Bundesliga"),
            broadcast("arenaspor1.tr", "Tarlaspor - Tepelispor"),
            broadcast("arenaspor2.fr", "Westfalia Erzfeld / Elbhavre"),
            broadcast("arenasport1.pt", "Belavista - Serrano"),
        ]
    }

    @Test("Without hiding everything stays")
    func nothingHidden() {
        let ingredients = LiveLibrary.visibleIngredients(
            channels: catalog, programmes: broadcasts, preferences: LivePreferences())

        #expect(ingredients.sportChannels.count == 4)
        #expect(ingredients.broadcasts.count == 4)
        #expect(ingredients.names.count == 4)
    }

    /// **The core of the finding.** Hidden means: the channel is gone — and
    /// so are its programmes.
    @Test("Hidden groups do not appear in the schedule")
    func hiddenIsGone() {
        let preferences = LivePreferences(hiddenGroups: ["Frankreich", "Portugal"])

        let ingredients = LiveLibrary.visibleIngredients(
            channels: catalog, programmes: broadcasts, preferences: preferences)

        #expect(ingredients.sportChannels.map(\.id).sorted() == ["arenabundesliga1.de", "arenaspor1.tr"])
        #expect(ingredients.names.keys.sorted() == ["arenabundesliga1.de", "arenaspor1.tr"])
    }

    /// **The programmes must go too**, otherwise a hidden group would
    /// still bring its rows into the schedule — only with no channel below them. The
    /// sport detection and the placeholder stage read the programmes, not
    /// the channel list.
    @Test("The broadcasts of the hidden channels drop out too")
    func broadcastsFallAlong() {
        let preferences = LivePreferences(hiddenGroups: ["Frankreich", "Portugal"])

        let ingredients = LiveLibrary.visibleIngredients(
            channels: catalog, programmes: broadcasts, preferences: preferences)

        #expect(ingredients.broadcasts.count == 2)
        #expect(!ingredients.broadcasts.contains { $0.title.contains("Elbhavre") })
        #expect(!ingredients.broadcasts.contains { $0.title.contains("Belavista") })
    }

    /// **What the app does not know, it does not throw away.** The first attempt
    /// filtered against the *visible* IDs — and thereby emptied the whole
    /// schedule as long as the channel list was not yet loaded. The
    /// tests of E3 deliberately build the model without a channel list and
    /// showed it immediately.
    @Test("Without a channel list the schedule stays")
    func withoutChannelList() {
        let ingredients = LiveLibrary.visibleIngredients(
            channels: [], programmes: broadcasts, preferences: LivePreferences())

        #expect(ingredients.broadcasts.count == 4)
        #expect(ingredients.sportChannels.isEmpty)
    }

    /// If two versions share a programme ID and only one is
    /// hidden, the ID stays visible — otherwise the
    /// hidden UHD version would take the HD version with it.
    @Test("An identifier counts as hidden only when no version is visible")
    func oneVersionSuffices() {
        let two = [
            channels("arenaspor1.tr", group: "Türkei"),
            Channel(
                id: "arenaspor1uhd", name: "ARENA 1 UHD",
                streamURL: URL(string: "http://host/live/u/p/uhd.m3u8")!,
                playlistID: "p1", group: "Türkei UHD", epgID: "arenaspor1.tr"),
        ]

        let ingredients = LiveLibrary.visibleIngredients(
            channels: two, programmes: broadcasts,
            preferences: LivePreferences(hiddenGroups: ["Türkei UHD"]))

        #expect(ingredients.broadcasts.contains { $0.channelID == "arenaspor1.tr" })
    }

    /// Several versions of the same channel share one programme ID;
    /// for the channel board that is one.
    @Test("HD and UHD of the same channel count once")
    func versionsCountOnce() {
        let two = [
            channels("arenabundesliga1.de", group: "Deutschland"),
            Channel(
                id: "arenabl1uhd", name: "ARENA BUNDESLIGA 1 UHD",
                streamURL: URL(string: "http://host/live/u/p/uhd.m3u8")!,
                playlistID: "p1", group: "Deutschland", epgID: "arenabundesliga1.de"),
        ]

        let ingredients = LiveLibrary.visibleIngredients(
            channels: two, programmes: broadcasts, preferences: LivePreferences())

        #expect(ingredients.sportChannels.count == 1)
    }
}

/// The calculated schedule survives the restart.
///
/// **On-device finding 2026-08-29:** every time the app is opened, why is
/// everything reloaded? Something like that should only have to happen once a day — the
/// programme run does not change over the course of the day.
///
/// The result cache from E5 lived exclusively in working memory. It
/// saved the second tab switch, but not the second start — and the
/// app is opened more often than the tab is switched.
@Suite("The schedule survives the restart")
struct ScheduleStorageTests {

    private func event(_ title: String, taken: Bool = false) -> SportEvent {
        SportEvent(
            id: "fixture#espn#\(title)", kind: .football, competition: "Bundesliga",
            title: title,
            start: Date(timeIntervalSince1970: 1_788_012_900),
            end: Date(timeIntervalSince1970: 1_788_020_100),
            epgIDs: ["arenabundesliga1.de"], competitionPath: "soccer/ger.1", isVerified: taken)
    }

    private func fresh() -> (LiveCache, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("spielplan-\(UUID().uuidString)")
        return (LiveCache(directory: folder), folder)
    }

    @Test("A computed schedule comes back completely")
    func survived() async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        let plan = [event("Erzfeld - Elbhafen", taken: true), event("Bergland - Rebenfeld")]
        await cache.setSchedule(plan, forItem: "a")

        #expect(await cache.schedule("a") == plan, "the seal and the channels too")
        #expect(await cache.schedule("b") == nil, "a foreign key does not hit")
    }

    /// **What the key does not see is discarded by hand.** Fresh
    /// fixtures change the schedule without a programme being added; a
    /// newly delivered guide with the same counts likewise. A
    /// cache that keeps quiet about that would be worse than none.
    @Test("Clearing throws everything away")
    func clear() async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        await cache.setSchedule([event("Erzfeld - Elbhafen")], forItem: "a")
        await cache.clearSchedules()

        #expect(await cache.schedule("a") == nil)
    }

    /// Four, for the same reason as in working memory: at most three
    /// day tabs and a reserve for the change of the download state.
    @Test("At most four schedules are kept")
    func atMostFour() async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        for number in 1...6 {
            await cache.setSchedule([event("Spiel \(number)")], forItem: "s\(number)")
        }

        var available = 0
        for number in 1...6 where await cache.schedule("s\(number)") != nil { available += 1 }
        #expect(available == LiveCache.maxSchedules)
        #expect(await cache.schedule("s6") != nil, "the newest stays")
    }

    /// Two different states must never get the same ID — otherwise the
    /// app would show the schedule of another day.
    @Test("Different states have different identifiers")
    func identifierSeparates() {
        let from = Date(timeIntervalSince1970: 1_788_000_000)
        let end = Date(timeIntervalSince1970: 1_788_086_400)
        func key(
            from: Date = from, end: Date = end, broadcasts: Int = 100, newest: Date? = end,
            syncEnabled: Bool = true
        ) -> String {
            ScheduleCalculator.Key(
                from: from, end: end, broadcasts: broadcasts, newest: newest,
                syncEnabled: syncEnabled
            ).identifier
        }

        #expect(key() == key(), "same state, same identifier")
        #expect(key() != key(end: end.addingTimeInterval(60)))
        #expect(key() != key(broadcasts: 101))
        #expect(key() != key(newest: nil))
        #expect(key() != key(syncEnabled: false))
    }
}
