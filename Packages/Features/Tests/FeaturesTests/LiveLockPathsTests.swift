import Core
import Foundation
import ParentalControls
import PlaylistKit
import SourceProbe
import Testing

@testable import Features

/// **"Hide unlabeled" on the TV's paths** (check before the
/// on-device test, Live area, finding 1, 2026-09-27).
///
/// Reproduced from the check: an M3U list carries no `is_adult`, the switch is on.
/// The Live area hid the "Nachtkanal", search found it and the Live shelf showed
/// it. Both paths now read the same filtered source (`LiveLibrary`); the others
/// (Continue Watching, the player's group list, up/down, "Live today") likewise, and the
/// guard in `ChannelSourceFilterTests` reports a path that goes past it.
@MainActor
@Suite("Live check: channel lock on all paths", .serialized)
struct LiveLockPathsTests {

    static let catalog = [
        Channel(
            id: "nacht", name: "Nachtkanal", streamURL: URL(string: "http://h/live/u/p/1.ts")!,
            playlistID: "l", group: "Mix", epgID: "nacht-epg")
    ]

    /// A library over an M3U list with the Nachtkanal in stock — including a running
    /// show, so that the Live shelf would show it as a tile.
    static func library(hidden: Bool) async -> LiveLibrary {
        let downloads = LiveCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pruefung-live-\(UUID().uuidString)"))
        let listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        listen.add(Playlist(id: "l", name: "Liste", kind: .m3u(URL(string: "http://liste.example")!)))
        let now = Date()
        await downloads.save(catalog, for: "l")
        await downloads.save(programmes: [
            Programme(
                id: "p", channelID: "nacht-epg", title: "Jetzt",
                start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600))
        ])
        return LiveLibrary(
            store: listen, cache: downloads,
            lock: { ChannelLock(hidesUnlabeled: hidden) })
    }

    @Test("The TV channel search does not find it with the switch set")
    func search() async {
        let library = await Self.library(hidden: true)
        let source = SearchModel.channelSource(
            { await library.downloadedChannels() }, rule: .pending, preferences: { LivePreferences() })
        let match = (await source("nacht", 20)).match.map(\.id)
        #expect(match.isEmpty, "search shows \(match), the Live section hides it")
    }

    @Test("The TV Live shelf does not show it with the switch set")
    func liveShelf() async {
        let library = await Self.library(hidden: true)
        let tiles = await ShellModels.liveShelf(
            channels: library, surface: .familiar, rule: .pending)()
        #expect(tiles.isEmpty, "Live shelf shows \(tiles.map(\.id))")
    }

    /// The opposite direction: without the switch the M3U list stays there — otherwise the two
    /// cases above would only check an empty setup.
    @Test("Without the switch, search and Live shelf find it")
    func withoutSwitch() async {
        let library = await Self.library(hidden: false)
        let source = SearchModel.channelSource(
            { await library.downloadedChannels() }, rule: .pending, preferences: { LivePreferences() })
        #expect((await source("nacht", 20)).match.map(\.id) == ["nacht"])
        let tiles = await ShellModels.liveShelf(
            channels: library, surface: .familiar, rule: .pending)()
        #expect(tiles.map(\.id) == ["nacht"])
    }

    /// **Favorites on the TV** (start check F4): the channels go through the preferences
    /// as in the Live area, and a press asks the same question as every other channel press.
    /// The callbacks live in `MainView`; what is checked is therefore the wiring.
    @Test("TV favorites: visible as in the Live section, play only through the channel question")
    func favoritesWiredUp() throws {
        let text = SourceText.strippingCommentLines(try SourceText.read("MainView.swift", in: .features))
        let area = try #require(text.range(of: "private var favoritesArea: some View"))
        let rest = text[area.upperBound...]
        let load = try #require(rest.range(of: "loadChannels: {"))
        let following = try #require(rest.range(of: "loadVOD:"))
        #expect(rest[load.upperBound..<following.lowerBound].contains("LiveCatalog.isVisible("))
        let press = try #require(rest.range(of: "onPlayChannel: { channel, channels in"))
        let end = try #require(rest.range(of: "onPlayVOD:"))
        #expect(rest[press.upperBound..<end.lowerBound].contains("rule.scope.isPlaying("))
    }
}
