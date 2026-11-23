import Core
import Foundation
import SourceProbe
import Testing

@testable import PlaylistKit

/// **The channel block works at the source** (check before the on-device test, Live area,
/// finding 1, and Home area, S2/F4, 2026-09-27).
///
/// Until then only the Live area of the TV applied "Hide unlabeled".
/// Search, live shelf, "Continue Watching", the group list of the player, up/down, the
/// favorites and "Live Today" on the phone showed the hidden channel. All these paths get their channels from ``LiveLibrary`` —
/// so it filters every delivery, and the guard below reports a path that bypasses it.
@MainActor
@Suite("Channel lock at the source", .serialized)
struct ChannelSourceFilterTests {

    // MARK: - Hilfen

    private final class Switch: @unchecked Sendable {
        var lock = ChannelLock()
        var on: Bool {
            get { lock.hidesUnlabeled }
            set { lock.hidesUnlabeled = newValue }
        }
    }

    private struct FixedSource: ChannelSource {
        let playlist: Playlist
        let channelList: [Channel]
        func channels() async throws -> [Channel] { channelList }
        func programmes(for channelID: String, around date: Date) async throws -> [Programme] { [] }
    }

    private static func channelList(
        _ id: String, list: String, group: String, adult: Bool = false
    ) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://h/live/u/p/\(id).ts")!,
            playlistID: list, group: group, epgID: "\(id)-epg", isAdult: adult)
    }

    /// An Xtream access that labels, and next to it an M3U list that does not.
    private static let xtream = [
        channelList("ahorn", list: "x", group: "DE"),
        channelList("rot", list: "x", group: "XXX", adult: true),
    ]
    private static let m3u = [channelList("nacht", list: "m", group: "Mix")]

    private func library(_ toggle: Switch) async -> (LiveLibrary, LiveCache) {
        let listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let x = Playlist(
            id: "x", name: "Zugang",
            kind: .xtream(server: URL(string: "http://panel.example")!, username: "u"))
        let m = Playlist(id: "m", name: "Liste", kind: .m3u(URL(string: "http://liste.example")!))
        listen.add(x)
        listen.add(m)
        let downloads = LiveCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sieb-\(UUID().uuidString)"))
        let library = LiveLibrary(
            store: listen, cache: downloads, lock: { toggle.lock })
        await library.install(FixedSource(playlist: x, channelList: Self.xtream), for: "x")
        await library.install(FixedSource(playlist: m, channelList: Self.m3u), for: "m")
        return (library, downloads)
    }

    // MARK: - Verhalten

    @Test("Off: both lists come, the flagged channel only with the switch")
    func from() async {
        let toggle = Switch()
        let (library, _) = await library(toggle)
        let ids = await library.load(forceReload: true).channels.map(\.id)
        #expect(Set(ids) == ["ahorn", "nacht"])
        toggle.lock.showsAdult = true
        #expect(Set(await library.load().channels.map(\.id)) == ["ahorn", "rot", "nacht"])
    }

    /// The first rule at the source: a bookmarked adult channel does not come out via the
    /// favorites either once the switch is off (Home check F4).
    @Test("A flagged favorite does not appear while the switch is off")
    func adultFavorite() async {
        let toggle = Switch()
        toggle.lock.showsAdult = true
        let (library, _) = await library(toggle)
        #expect(await library.load(forceReload: true).channels.contains { $0.id == "rot" })
        toggle.lock.showsAdult = false
        #expect(!(await library.load()).channels.contains(where: \.isAdult))
        #expect(!(await library.downloadedChannels()).contains(where: \.isAdult))
        #expect(await library.channels(withEPGIDs: ["rot-epg"]).isEmpty)
    }

    @Test("On: the unflagged list is missing from catalog, groups and provider level")
    func on() async {
        let toggle = Switch()
        toggle.on = true
        let (library, _) = await library(toggle)
        let result = await library.load(forceReload: true)
        #expect(Set(result.channels.map(\.id)) == ["ahorn"])
        #expect(!result.groups.map(\.name).contains("Mix"))
        #expect(await library.providerGroups().map(\.id) == ["x"])
    }

    @Test("On: the cache too (Home, search, Continue Watching) and the program identifier")
    func downloadsAndIdentifier() async {
        let toggle = Switch()
        toggle.on = true
        let (library, _) = await library(toggle)
        _ = await library.load(forceReload: true)
        #expect(!(await library.downloadedChannels()).map(\.id).contains("nacht"))
        #expect(!(await library.downloadedChannels()).isEmpty)
        #expect(await library.channels(withEPGIDs: ["nacht-epg"]).isEmpty)
    }

    /// **Without reloading**: the remembered catalog is unfiltered, filtering happens on every query.
    @Test("A flipped switch applies on the next query, without a fetch")
    func flipped() async {
        let toggle = Switch()
        let (library, _) = await library(toggle)
        _ = await library.load(forceReload: true)
        toggle.on = true
        #expect(!(await library.load()).channels.map(\.id).contains("nacht"))
        toggle.on = false
        #expect((await library.load()).channels.map(\.id).contains("nacht"))
    }

    // MARK: - Guards

    /// Functions that may touch the **unfiltered** catalog — with a reason.
    ///
    /// - `loaded`, `rawDownloads`, `refreshedFavorites`: the raw version behind
    ///   ``LiveLibrary/load(forceReload:)`` and ``LiveLibrary/downloadedChannels()``.
    /// - `warmFromStore`, `invalidate`: fill and empty the remembered catalog.
    /// - `syncGuide`: reads only programme IDs for the guide sync.
    static let rawAccessAllowed: Set<String> = [
        "loaded", "rawDownloads", "refreshedFavorites", "warmFromStore", "invalidate", "syncGuide",
    ]

    static let rawAccesses = ["store.merged(", "cache.channels(for:", "lastResult"]

    /// The bodies of all functions in a file, by name.
    static func bodies(_ text: String) -> [(name: String, header: String, bodyContent: String)] {
        let character = Array(text)
        var found: [(String, String, String)] = []
        let patterns = try! NSRegularExpression(pattern: #"\bfunc\s+(\w+)"#)
        let nsText = text as NSString
        for match in patterns.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let name = nsText.substring(with: match.range(at: 1))
            let start = text.distance(
                from: text.startIndex,
                to: Range(match.range, in: text)!.lowerBound)
            var i = start
            while i < character.count, character[i] != "{" { i += 1 }
            let header = String(character[start..<i])
            var depth = 0
            var j = i
            while j < character.count {
                if character[j] == "{" { depth += 1 }
                if character[j] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            found.append((name, header, String(character[i..<min(j + 1, character.count)])))
        }
        return found
    }

    @Test("Guard: only the known places touch the unfiltered catalog")
    func guardInside() throws {
        let text = SourceText.strippingCommentLines(
            try SourceText.read("LiveLibrary.swift", in: .playlistKit))
        let functions = Self.bodies(text)
        let raw = Set(
            functions.filter { f in Self.rawAccesses.contains { f.bodyContent.contains($0) } }
                .map(\.name))
        #expect(
            raw.isSubset(of: Self.rawAccessAllowed),
            "Past the channel lock: \(raw.subtracting(Self.rawAccessAllowed).sorted())")

        for name in ["load", "downloadedChannels"] {
            let bodyContent = try #require(functions.first { $0.name == name }?.bodyContent)
            #expect(bodyContent.contains("delivered("), "\(name) delivers unfiltered")
        }
        for publicFunction in functions
        where publicFunction.header.contains("public") && !publicFunction.header.contains("static")
            && (publicFunction.header.contains("Channel]") || publicFunction.header.contains("-> Result"))
        {
            let bodyContent = publicFunction.bodyContent
            #expect(
                bodyContent.contains("delivered(") || bodyContent.contains("load(")
                    || bodyContent.contains("downloadedChannels("),
                "\(publicFunction.name) returns channels without going through the filter")
        }
    }

    @Test("Guard: outside the library nobody reads the catalog past it")
    func guardOutside() throws {
        let locations: [CodeLocation] = [.packets, .phonePackages, .tvApp, .phoneApp]
        var over: [String] = []
        for location in locations {
            for file in try SourceText.files(in: location)
            where file.name != "LiveLibrary.swift" && !file.path.contains("/Tests/") {
                let text = SourceText.strippingCommentLines(file.content)
                if text.contains("store.merged(") || text.contains("cache.channels(for:") {
                    over.append(file.path)
                }
            }
        }
        #expect(over.isEmpty, "Channel catalog read past LiveLibrary: \(over)")
    }
}
