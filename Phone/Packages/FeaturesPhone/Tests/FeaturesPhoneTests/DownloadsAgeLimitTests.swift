import Core
import Downloads
import Foundation
import NetworkStatus
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The downloads are also filtered by the age limit** — strand G, 2026-09-25.
///
/// The finding: Downloaded **media server** titles were filtered only by origin.
/// A child saw the downloaded 18-rated movie in the downloads and played it from disk. Both
/// are checked — the list and the player —, because whoever closes only the list leaves the
/// Continue Watching entry and every other start with the ID open.
@MainActor
@Suite("Downloads and age limit")
struct DownloadsAgeLimitTests {

    /// A child with the limit "from 12".
    private static let childRule = ProtectionRule(
        deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12,
        blocksUnrecognized: true, assignments: [:])

    private static func film(_ identifier: String, _ title: String) -> DownloadJob {
        DownloadJob(
            id: .init(identifier), title: title, beside: nil, source: .jellyfin,
            extent: .film, tier: .low, estimatedSize: 1_000)
    }

    private static func description(_ identifier: String, approval: String?) -> DownloadDescription {
        DownloadDescription(id: identifier, title: identifier, ageRating: approval)
    }

    private static func folder() throws -> URL {
        let location = FileManager.default.temporaryDirectory
            .appending(path: "downloads-age-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        return location
    }

    // MARK: - The list

    @Test("A downloaded 18-rated movie is not among a child's downloads")
    func listFilters() {
        let model = DownloadsModel(networkMonitor: NetworkStatus.NetworkWatch(), rule: Self.childRule)
        model.set(
            downloads: Downloads(
                items: [
                    Self.film("m-18", "Eighteen"), Self.film("m-6", "Six"),
                    Self.film("m-old", "No rating"), Self.film("m-tvma", "Foreign"),
                ], isRunning: []),
            household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:], seen: [])
        model.set(descriptions: [
            Self.description("m-18", approval: "FSK 18"),
            Self.description("m-6", approval: "6"),
            // Old download: no approval recorded — like a title without a rating on the TV,
            // it gets through.
            Self.description("m-old", approval: nil),
            Self.description("m-tvma", approval: "TV-MA"),
        ])

        #expect(model.rows(forItem: .everything).map(\.title) == ["Six", "No rating"])
        #expect(model.finishedGroups(forItem: .everything).count == 2)
    }

    // MARK: - The player

    @Test("A downloaded 18-rated movie does not play for a child, not even over the network")
    func playerFilters() async throws {
        let location = try Self.folder()
        for identifier in ["m-18", "m-6", "m-old"] {
            try Data("x".utf8).write(to: location.appending(path: Store.fileName(forItem: .init(identifier))))
        }
        DescriptionLedger(folder: location).write([
            Self.description("m-18", approval: "18"),
            Self.description("m-6", approval: "FSK 6"),
        ])
        let switchPoint = CompositePlayerSource(
            downloads: DownloadsPlayerSource(folder: location), jellyfin: NetworkStub(),
            locked: [.provider, .portals, .channelList], rule: Self.childRule)

        for origin in [Catalog.Origin.downloads, .jellyfin] {
            await #expect(throws: (any Error).self, "\(origin.rawValue) played") {
                try await switchPoint.target(zu: PlaybackJob(identifier: "m-18", origin: origin))
            }
        }
        let six = try await switchPoint.target(zu: PlaybackJob(identifier: "m-6", origin: .downloads))
        #expect(six.address.isFileURL)
        let old = try await switchPoint.target(zu: PlaybackJob(identifier: "m-old", origin: .downloads))
        #expect(old.address.isFileURL)
    }

    /// **The wrapper passes the rule down to the switch** — without this line it would stand there as
    /// `.pending`, and the check above it would stay green.
    @Test("Source assembly passes the rule to the switch")
    func setupSufficesRule() throws {
        let text = try SourceText.read("SourceAssembly.swift", in: .featuresPhone)
        let call = try #require(text.range(of: "return CompositePlayerSource("))
        #expect(text[call.upperBound...].prefix(300).contains("rule: rule"))
    }

    // MARK: - What is recorded when storing

    /// **The server's wording, not the attribute line.** "TV-MA" has no digit and
    /// was lost as a genre until now.
    @Test("The approval is recorded verbatim, even without a digit")
    func approvalInWording() {
        let content = DetailContent(
            title: HeroContent(
                tile: TileContent(id: "m-tvma", title: "Foreign", beside: nil, image: nil),
                attributes: ["2021", "TV-MA", "Drama"], identifier: RatingID(),
                approval: "TV-MA"))
        let b = DownloadDescriber.compose(
            Self.film("m-tvma", "Foreign"), from: content, series: nil
        ).description
        #expect(b.ageRating == "TV-MA")
        #expect(b.genres == ["Drama"])
    }
}

/// A media server that answers every question — **the fallback to the network that must not
/// exist.**
private struct NetworkStub: PlayerSource {
    func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
        PlaybackRequest(
            identifier: job.identifier, title: "network",
            address: URL(string: "https://server" + ".example/x.m3u8")!,
            origin: job.origin)
    }

    func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
    ) async throws {}
}
