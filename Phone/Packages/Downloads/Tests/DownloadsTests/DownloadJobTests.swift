import Core
import Foundation
import Testing

@testable import Downloads

/// Scope, selection, completeness — **what a download job must know before it starts.**
@Suite("Download job")
struct JobTests {

    // MARK: - Scope

    /// **A season stays one row.** Eighteen rows for eighteen episodes would be
    /// the same information, just unreadable — and the temptation to draw them anyway arises
    /// in every list anew.
    @Test("Every scope is a row in the downloads")
    func singleRow() {
        let all: [Extent] = [
            .film, .episode(season: 2, number: 4), .season(number: 2, episodes: 8),
            .unwatched(episodes: 14, seasons: 2),
        ]
        #expect(all.allSatisfy { $0.downloadRowCount == 1 })
    }

    /// **Structured and not translated** — under `swift test` there is no app bundle,
    /// and a search text from the catalog would be the key here.
    @Test("The search text names season and episode, a movie neither")
    func searchText() {
        #expect(Extent.episode(season: 2, number: 4).searchText == "s2 f4 · s2 e4 · s2 b4")
        #expect(Extent.season(number: 2, episodes: 8).searchText == "s2")
        #expect(Extent.film.searchText.isEmpty)
        #expect(Extent.unwatched(episodes: 14, seasons: 2).searchText.isEmpty)
    }

    @Test("The episode count comes from the scope")
    func episodeCount() {
        #expect(Extent.film.episodeCount == 0)
        #expect(Extent.episode(season: 2, number: 4).episodeCount == 1)
        #expect(Extent.season(number: 2, episodes: 8).episodeCount == 8)
        #expect(Extent.unwatched(episodes: 14, seasons: 2).episodeCount == 14)
    }

    // MARK: - Selection

    /// **The media server has one file and not six tiers** — measured on 2026-09-08.
    ///
    /// The opposite stood here, and the reasoning ("the server transcodes") was even
    /// correct: it transcodes, and the result is a **stream**. The transcoded version
    /// answers a range request with `200` and `Accept-Ranges: none`, HLS
    /// segment 500 is byte-identical to segment 0, and `StartTimeTicks` gives `400`.
    /// A download over such an address starts from scratch after every disconnect.
    @Test("The media server delivers the file that is there")
    func jellyfinWithoutChoice() {
        #expect(SelectionRule.forItem(.jellyfin) == .asDelivered)
        #expect(!SelectionRule.choiceIsWorthwhile(.jellyfin))
    }

    /// **The tier ladder is still `StreamQuality` and not a second one.** Today it
    /// is chosen by no source, but it stands for the one that will someday
    /// carry real variants — and a separate enumeration would be the place where downloads and player
    /// drift apart.
    @Test("The quality ladder still comes from Core")
    func variantLadderFromCore() {
        #expect(SelectionRule.slots.count == 6)
        #expect(
            SelectionRule.slots
                == StreamQuality.allCases.sorted { ($0.bitrate ?? .max) > ($1.bitrate ?? .max) })
    }

    /// **The provider gets one sentence and not a list with one entry.**
    @Test("The provider delivers what it delivers")
    func providerWithoutChoice() {
        #expect(SelectionRule.forItem(.provider) == .asDelivered)
        #expect(!SelectionRule.choiceIsWorthwhile(.provider))
    }

    /// **Until 2026-09-08 this said "none at all".** Measured, Animehub has four hosts
    /// times three language versions — more than the provider, not fewer.
    @Test("A portal offers source and version for choosing")
    func portalWithChoice() {
        #expect(SelectionRule.forItem(.portal) == .sourcesAndVersion)
        #expect(SelectionRule.choiceIsWorthwhile(.portal))
    }

    /// **720p and not "as good as possible".** The higher tier stays visible, otherwise
    /// someone makes the decision by doing nothing.
    @Test("The middle tier is suggested, not the highest")
    func suggestion() {
        #expect(SelectionRule.suggestion == .low)
        #expect(SelectionRule.suggestion != SelectionRule.slots.first)
    }

    // MARK: - Completeness

    private static func job(_ source: SourceKind) -> DownloadJob {
        DownloadJob(id: .init("x"), title: "T", source: source, extent: .film)
    }

    /// **A portal job without a language version is not half a download job**, but one that
    /// takes the wrong audio track along — and the viewer notices that on the plane, where they cannot
    /// switch it any more.
    @Test("A portal job needs host and version")
    func portalNeedsBoth() {
        var a = Self.job(.portal)
        #expect(!a.complete)
        a.host = "HOSTA"
        #expect(!a.complete)
        a.version = "(DE)"
        #expect(a.complete)
    }

    @Test("A Jellyfin download job needs its tier")
    func jellyfinNeedsVariant() {
        var a = Self.job(.jellyfin)
        #expect(!a.complete)
        a.tier = .low
        #expect(a.complete)
    }

    /// **There is nothing to add for the provider** — which is exactly why no
    /// sheet is needed there either.
    @Test("A provider download job is complete immediately")
    func providerComplete() {
        #expect(Self.job(.provider).complete)
    }

    /// A download job survives the restart — otherwise "paused at 68 %" would be a fresh start after the
    /// next launch.
    @Test("A download job can be stored and repeated")
    func codable() throws {
        var a = Self.job(.jellyfin)
        a.tier = .high
        a.estimatedSize = 4_900_000_000
        let back = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }
}
