import Core
import Downloads
import Foundation
import Testing

@testable import FeaturesPhone

/// **A fully downloaded title can be played.**
///
/// The finding of 2026-09-09: 466 MB lay in `Application Support/Vorrat/`, and there was
/// no path from the file into the player. What these checks pin down is not the path
/// itself but the three decisions on it — when the disk wins, when it explicitly does
/// **not**, and that the file name comes from ``Downloads/Store``.
@Suite("Downloads play from disk")
struct DownloadsPlayerTests {

    /// A source that only says it was asked — as in ``SpielerTests``.
    private struct NetworkSource: PlayerSource {
        let tag: String

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: tag,
                address: URL(string: "https://server" + ".example/x.m3u8")!,
                origin: job.origin)
        }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob,
            isPaused: Bool
        ) async throws {}
    }

    /// A separate folder per check — **nothing in `Application Support`.**
    private static func folder() throws -> URL {
        let location = FileManager.default.temporaryDirectory
            .appending(path: "downloads-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        return location
    }

    /// Creates a file of this name. The content does not matter — what is tested is who
    /// decides, not what is played.
    private static func create(_ name: String, in folder: URL) throws {
        try Data("x".utf8).write(to: folder.appending(path: name))
    }

    private static func switchPoint(_ location: URL) -> CompositePlayerSource {
        CompositePlayerSource(
            downloads: DownloadsPlayerSource(folder: location),
            jellyfin: NetworkSource(tag: "server"),
            provider: NetworkSource(tag: "catalog"),
            portals: NetworkSource(tag: "portal"))
    }

    // MARK: - When the disk wins

    /// **The precedence applies to all three origins, not just one.** What is downloaded is
    /// played from there — that is the point of a download and the reason it works without a
    /// network.
    @Test("A finished file beats every origin")
    func finishedFileWins() async throws {
        let location = try Self.folder()
        let identifiers: [(String, Catalog.Origin)] = [
            ("8dec87ad", .jellyfin),
            ("serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1", .portals),
        ]

        for (identifier, origin) in identifiers {
            try Self.create(Store.fileName(forItem: .init(identifier)), in: location)
            let target = try await Self.switchPoint(location).target(
                zu: PlaybackJob(identifier: identifier, origin: origin))
            #expect(target.address.isFileURL, "\(origin.rawValue) still went to the network")
            #expect(target.address.lastPathComponent == Store.fileName(forItem: .init(identifier)))
        }
    }

    /// **Also from the downloads screen** — there ``Catalog/Origin/downloads`` travels along,
    /// and until 2026-09-09 it had no branch at all.
    @Test("A start from downloads finds its file")
    func startFromDownloads() async throws {
        let location = try Self.folder()
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)

        let target = try await Self.switchPoint(location).target(
            zu: PlaybackJob(identifier: "8dec87ad", origin: .downloads))
        #expect(target.address.isFileURL)
    }

    /// **Downloads are a place of storage, not an origin.** If `.downloads` were in the
    /// ``PlaybackRequest``, the history entry at the end of playback would carry it too — and
    /// ``CatalogState/hasKey(_:)`` throws it out again, leaving "Continue Watching" empty.
    @Test("The origin is read back and not set to downloads")
    func originStaysTheReal() async throws {
        let location = try Self.folder()
        let portal = "serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1"
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)
        try Self.create(Store.fileName(forItem: .init(portal)), in: location)
        let source = DownloadsPlayerSource(folder: location)

        let film = try await source.target(
            zu: PlaybackJob(identifier: "8dec87ad", origin: .downloads))
        #expect(film.origin == .jellyfin)

        let episode = try await source.target(zu: PlaybackJob(identifier: portal, origin: .downloads))
        #expect(episode.origin == .portals)
    }

    // MARK: - When it does not win

    /// **A partial state is not a download.** It has its own name because a half-loaded file
    /// looks playable and stops in the middle of the movie — on a plane the worst moment to
    /// notice. Whoever let it count would turn the protection into a detour.
    @Test("A partially downloaded file does not win")
    func partialStateDoesNotWin() async throws {
        let location = try Self.folder()
        try Self.create(Store.partialName(forItem: .init("8dec87ad")), in: location)

        let target = try await Self.switchPoint(location).target(zu: PlaybackJob(identifier: "8dec87ad"))
        #expect(target.title == "server", "the partial file took precedence")
        #expect(!target.address.isFileURL)
    }

    /// **Without a file everything stays as it was.** The precedence is a right of way, not a
    /// replacement: whoever has nothing to show does not block the way.
    @Test("Without a file the previous path applies")
    func withoutFileTheOldWay() async throws {
        let location = try Self.folder()

        let fromServer = try await Self.switchPoint(location).target(zu: PlaybackJob(identifier: "8dec87ad"))
        #expect(fromServer.title == "server")

        let fromPortal = try await Self.switchPoint(location).target(
            zu: PlaybackJob(identifier: "serieshub|morrowfeld-1-1|https://serieshub.example/x"))
        #expect(fromPortal.title == "portal")
    }

    /// **A downloads title without a file keeps throwing and does not guess.** The row in the
    /// ledger alone is nothing to play — a branch to the media server would be the error of
    /// 2026-09-06.
    @Test("Listed in the ledger but not downloaded, there is nothing to play")
    func listedButNotLoaded() async throws {
        let location = try Self.folder()
        DownloadLedger(folder: location).write([
            DownloadJob(id: .init("8dec87ad"), title: "Morrowfeld", source: .jellyfin, extent: .film)
        ])

        await #expect(throws: CompositePlayerSource.Missing.self) {
            try await Self.switchPoint(location).target(
                zu: PlaybackJob(identifier: "8dec87ad", origin: .downloads))
        }
    }

    // MARK: - The name comes from the store

    /// **Not assembled by hand.** Since 2026-09-09 the name is capped: a portal ID is
    /// `portal|key|address`, and the address for "Ironbell" has over four hundred characters —
    /// every file system iOS offers stops at 255 bytes. ``Downloads/Store/fileName(forItem:)``
    /// cuts and appends a checksum. Whoever rebuilt the name here would miss exactly the
    /// titles the cap was built for.
    @Test("A very long portal identifier is also found again")
    func longIdentifierIsFound() async throws {
        let location = try Self.folder()
        let long =
            "serieshub|1-pilot|https://serieshub.example/redirect/showHosts"
            + String(repeating: "-and-another-piece-of-address", count: 20)
        #expect(long.count > 400, "the identifier must exceed the limit")

        try Self.create(Store.fileName(forItem: .init(long)), in: location)
        let source = DownloadsPlayerSource(folder: location)
        #expect(source.isHere(long))

        let target = try await source.target(zu: PlaybackJob(identifier: long, origin: .portals))
        #expect(target.address.isFileURL)
        // The name is capped — the raw ID is not in it.
        #expect(target.address.lastPathComponent.count < 200)
    }

    // MARK: - What the playback job brings along

    /// **Title, second line and runtime are in the ledger** — they come from the detail page,
    /// which knew them when the button was pressed. Everything else does not exist locally
    /// and is therefore not set.
    @Test("Title, second line and runtime come from the download ledger")
    func detailsFromLedger() async throws {
        let location = try Self.folder()
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)
        DownloadLedger(folder: location).write([
            DownloadJob(
                id: .init("8dec87ad"), title: "Wendetag", beside: "Morrowfeld",
                source: .jellyfin, extent: .episode(season: 1, number: 1),
                runtime: 2820)
        ])

        let target = try await DownloadsPlayerSource(folder: location).target(
            zu: PlaybackJob(identifier: "8dec87ad", origin: .downloads))
        #expect(target.title == "Wendetag")
        #expect(target.beside == "Morrowfeld")
        #expect(target.duration == 2820)

        // **Not invented but empty** — it does not exist locally.
        #expect(target.image == nil)
        #expect(target.chapters.isEmpty)
        #expect(target.audioTracks.isEmpty)
        #expect(target.subtitles.isEmpty)
        #expect(!target.isAnime)
    }

    /// **Unchanged from the disk.** Without this decision ``PlaybackRequest/deliveryRoute`` would
    /// set "native over hls" — a claim about a server that does not appear at all for a file
    /// in the app's own folder.
    /// **`@MainActor`, because ``RepackagerRun`` is** — not because the check would need a
    /// screen.
    @Test("A file on disk is played directly")
    @MainActor
    func directAndNotChunked() async throws {
        let location = try Self.folder()
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)

        let target = try await DownloadsPlayerSource(folder: location).target(
            zu: PlaybackJob(identifier: "8dec87ad"))
        #expect(target.decision?.delivery == .directPlay)
        #expect(target.target.decision.delivery == .directPlay)
        #expect(!RepackagerRun.isNeeded(target.target), "a local file needs no repackager")
    }

    /// **Without a server, `nil` is a zero.** ``PlaybackJob/startAt`` otherwise means "the
    /// server should say where" — here there is none to ask.
    @Test("Without a carried-over position a downloaded title starts at zero")
    func withoutPositionFromStart() async throws {
        let location = try Self.folder()
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)
        let source = DownloadsPlayerSource(folder: location)

        let fromStart = try await source.target(zu: PlaybackJob(identifier: "8dec87ad"))
        #expect(fromStart.startAt == 0)

        let next = try await source.target(
            zu: PlaybackJob(identifier: "8dec87ad", origin: .jellyfin, startAt: 900))
        #expect(next.startAt == 900, "the carried-over position was lost")
    }

    // MARK: - What lies here is not fetched again

    /// **A `file://` address would be worse than the error.** The download run demands a `206`
    /// for every range request; `URLSession` does not answer ranges on `file://`. The screen
    /// would show "Loading · 0 KB" above a complete file.
    @Test("What is stored locally has no download address")
    func noLoadAddressForOwnFiles() async throws {
        let location = try Self.folder()
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)

        await #expect(throws: DownloadsPlayerSource.Missing.self) {
            try await Self.switchPoint(location).loadTarget(zu: PlaybackJob(identifier: "8dec87ad"))
        }
    }

    /// **And the download path stays open as long as nothing is finished.** Otherwise the
    /// precedence would break exactly what fills it.
    @Test("Without a finished file the download address goes on to the origin")
    func loadAddressPassesOn() async throws {
        let location = try Self.folder()
        try Self.create(Store.partialName(forItem: .init("8dec87ad")), in: location)

        let target = try await Self.switchPoint(location).loadTarget(zu: PlaybackJob(identifier: "8dec87ad"))
        #expect(target.title == "server")
    }

    // MARK: - Child profile (tvOS roadmap AP45)

    /// **A blocked portal title does not play from the disk either** — neither through its
    /// origin nor through ``Catalog/Origin/downloads``, with which the downloads screen
    /// starts. A media server title keeps playing; the boundary there is checked by the
    /// filter.
    @Test("In child mode a downloaded portal title does not play")
    func lockedDisk() async throws {
        let location = try Self.folder()
        let portal = "serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1"
        try Self.create(Store.fileName(forItem: .init(portal)), in: location)
        try Self.create(Store.fileName(forItem: .init("8dec87ad")), in: location)
        let switchPoint = CompositePlayerSource(
            downloads: DownloadsPlayerSource(folder: location),
            jellyfin: NetworkSource(tag: "server"),
            portals: NetworkSource(tag: "portal"),
            locked: [.portals, .provider, .channelList])

        for origin in [Catalog.Origin.portals, .downloads] {
            await #expect(throws: (any Error).self, "\(origin.rawValue) played") {
                try await switchPoint.target(zu: PlaybackJob(identifier: portal, origin: origin))
            }
        }
        let isAllowed = try await switchPoint.target(
            zu: PlaybackJob(identifier: "8dec87ad", origin: .downloads))
        #expect(isAllowed.address.isFileURL)
    }
}
