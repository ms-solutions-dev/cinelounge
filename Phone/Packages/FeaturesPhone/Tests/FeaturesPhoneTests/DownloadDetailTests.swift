import Downloads
import Foundation
import Testing

@testable import FeaturesPhone

/// The detail page from what lies next to the file.
///
/// **The requirement of 2026-09-09:** even when only one episode is downloaded,
/// navigation in Downloads should be poster → detail view with the downloaded episodes
/// … all of it should be stored with OMDb, TMDb etc. ratings and so on.
/// This is exactly what is checked: one group, the downloaded
/// episodes, and the numbers without a single request.
@Suite("Downloads detail source")
struct DownloadsDetailSourceTests {

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// **Assembled from two pieces**, because `scripts/strings.py` takes every string
    /// of the form `word.word` for a catalog key — and rightly so: One cannot tell
    /// from a string what it is there for. The same pitfall as with
    /// ``DownloadLedger/stem``, and this time in a check.
    private static let posterName = "plakat" + ".jpg"
    private static let logoName = "logo" + ".png"

    private static func episode(_ number: Int) -> DownloadDescription {
        DownloadDescription(
            id: "morrowfeld-f\(number)", title: "Folge \(number)", beside: "Morrowfeld", year: 2019,
            description: "Worum es in Folge \(number) geht.",
            series: "morrowfeld", seriesTitle: "Morrowfeld", season: 1, episode: number, duration: 2820,
            ratings: ["imdb": "8,1"], ageRating: "16",
            genres: ["Science-Fiction", "Drama"],
            poster: Self.posterName, backdrop: "kopf" + ".jpg",
            cast: [.init(id: "p1", name: "Ilka Brandmoor", role: "Marelle")],
            ratingShares: ["imdb": 0.81], logo: Self.logoName,
            seriesDescription: "Zehntausend Menschen leben unter der Erde.",
            episodeImage: "still-\(number).jpg")
    }

    /// **Five episodes are one page** — that is the whole job in one check.
    @Test("Five episodes of a series make one page with five rows")
    func onePage() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)
        for number in 1...5 { ledger.create(Self.episode(number)) }

        let source = DownloadsDetailSource(folder: folder, rule: .pending)
        let content = try await source.detailInfo(zu: DownloadsDetailSource.identifier(forItem: "morrowfeld"))

        #expect(content.isSeries)
        #expect(content.seasons.count == 1)
        #expect(content.seasons.first?.episodes.count == 5)
        #expect(content.seasons.first?.episodes.map(\.number) == [1, 2, 3, 4, 5])
        #expect(content.title.tile.title == "Morrowfeld")
        #expect(content.title.description == "Zehntausend Menschen leben unter der Erde.")
        // The main button plays the first downloaded episode and not the series.
        #expect(content.next?.id == "morrowfeld-f1")
    }

    /// **A single episode is also a series page.** That is exactly what the requirement says:
    /// even when only one episode is downloaded.
    @Test("A single episode still opens the series")
    func oneEpisode() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(Self.episode(3))

        let source = DownloadsDetailSource(folder: folder, rule: .pending)
        // What is asked is the **episode**, what is answered is the series.
        let content = try await source.detailInfo(
            zu: DownloadsDetailSource.identifier(forItem: "morrowfeld-f3"))

        #expect(content.isSeries)
        #expect(content.seasons.first?.episodes.first?.title == "Folge 3")
    }

    /// **The numbers are there offline** — with OMDb, TMDb etc. ratings.
    @Test("Rating, traits and images come from the ledger")
    func details() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(Self.episode(1))

        let content = try await DownloadsDetailSource(folder: folder, rule: .pending)
            .detailInfo(zu: DownloadsDetailSource.identifier(forItem: "morrowfeld"))

        #expect(content.title.ratings.first?.origin == .imdb)
        #expect(content.title.ratings.first?.text == "8,1")
        #expect(content.title.ratings.first?.portion == 0.81)
        #expect(content.title.attributes == ["2019", "16", "Science-Fiction", "Drama"])
        #expect(content.cast.first?.characterName == "Marelle")
        // **File addresses and not server addresses** — otherwise the frame is empty on the plane.
        #expect(content.title.tile.image?.isFileURL == true)
        #expect(content.title.tile.image?.lastPathComponent == Self.posterName)
        #expect(content.title.logo?.lastPathComponent == Self.logoName)
        #expect(content.seasons.first?.episodes.first?.image?.lastPathComponent == "still-1.jpg")
    }

    @Test("A movie is a movie and not a series")
    func film() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(
            DownloadDescription(id: "lattice", title: "Lattice", year: 1997))

        let content = try await DownloadsDetailSource(folder: folder, rule: .pending)
            .detailInfo(zu: DownloadsDetailSource.identifier(forItem: "lattice"))

        #expect(!content.isSeries)
        #expect(content.seasons.isEmpty)
        #expect(content.next?.id == "lattice")
    }

    /// **A description without images still holds** — with portals that is the
    /// normal case.
    @Test("A description without images still works")
    func withoutImages() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(
            DownloadDescription(
                id: "portal-1", title: "No poster", description: "Still shown."))

        let content = try await DownloadsDetailSource(folder: folder, rule: .pending)
            .detailInfo(zu: "portal-1")

        #expect(content.title.tile.title == "No poster")
        #expect(content.title.tile.image == nil)
        #expect(content.title.description == "Still shown.")
    }

    @Test("Anything that is not stored throws")
    func unknown() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: DownloadsDetailSource.Missing.self) {
            try await DownloadsDetailSource(folder: folder, rule: .pending).detailInfo(zu: "does-not-exist")
        }
    }

    @Test("Its own identifier is recognized")
    func identifiers() {
        #expect(DownloadsDetailSource.key(from: "vorrat:morrowfeld") == "morrowfeld")
        #expect(DownloadsDetailSource.key(from: "morrowfeld") == nil)
        #expect(AggregateDetailSource.origin(DownloadsDetailSource.identifier(forItem: "x")) == .downloads)
    }
}

/// How the detail page is made from what lies next to the file.
@Suite("Downloads describer")
struct DownloadsDescriberTests {

    private static let poster = URL(string: "https://server/serie/plakat.jpg")!
    private static let still = URL(string: "https://server/folge/3.jpg")!

    private static func seriesPage() -> DetailContent {
        DetailContent(
            title: HeroContent(
                tile: TileContent(
                    id: "morrowfeld", title: "Morrowfeld", beside: "2019", image: poster,
                    backdrop: URL(string: "https://server/serie/kopf.jpg")),
                description: "Zehntausend Menschen leben unter der Erde.",
                attributes: ["2019", "16", "Science-Fiction"],
                ratings: [Rating.fromTen(7.2, .community)!]),
            isSeries: true,
            seasons: [
                Season(
                    id: 1,
                    episodes: [
                        EpisodeInfo(
                            id: "morrowfeld-f3", number: 3, title: "Wendetag",
                            description: "Worum es in Folge 3 geht.", image: still,
                            duration: 2820)
                    ])
            ],
            cast: [
                PersonDetail(id: "p1", name: "Ilka Brandmoor", characterName: "Marelle"),
                PersonDetail(id: "p2", name: "Corwin Haldane", task: .ledger),
            ])
    }

    private static func episodeJob() -> DownloadJob {
        DownloadJob(
            id: .init("morrowfeld-f3"), title: "Wendetag", beside: "Morrowfeld",
            source: .jellyfin, extent: .episode(season: 1, number: 3))
    }

    @Test("An episode carries its series, its image and the series text")
    func episode() {
        let result = DownloadDescriber.compose(
            Self.episodeJob(), from: Self.seriesPage(), series: "morrowfeld")
        let b = result.description

        #expect(b.id == "morrowfeld-f3")
        #expect(b.title == "Wendetag")
        #expect(b.series == "morrowfeld")
        #expect(b.seriesTitle == "Morrowfeld")
        #expect(b.season == 1)
        #expect(b.episode == 3)
        #expect(b.duration == 2820)
        // The episode's text on top, the series' text next to it — two places, two texts.
        #expect(b.description == "Worum es in Folge 3 geht.")
        #expect(b.year == 2019)
        #expect(b.ageRating == "16")
        #expect(b.genres == ["Science-Fiction"])
        // Cast only: An author under the heading "Cast" would be false
        // information, not missing information.
        #expect(b.cast.map(\.name) == ["Ilka Brandmoor"])
    }

    /// **Images are file names and not addresses** — the core of the contract.
    @Test("Addresses become file names, and the same address gives the same name")
    func frames() {
        let result = DownloadDescriber.compose(
            Self.episodeJob(), from: Self.seriesPage(), series: "morrowfeld")

        #expect(result.description.poster == DownloadImages.name(forItem: Self.poster))
        #expect(result.description.episodeImage == DownloadImages.name(forItem: Self.still))
        #expect(result.description.poster?.contains("server") == false)
        // Poster, backdrop and episode image — three addresses, three names.
        #expect(result.frames.count == 3)
        #expect(result.frames[result.description.poster ?? ""] == Self.poster)
    }

    /// **The number from outside replaces the server's, as on the detail page too.**
    @Test("An IMDb score displaces the community rating")
    func scores() {
        let info = ExternalInfo(ratings: [Rating.fromTen(8.1, .imdb)!])
        let b = DownloadDescriber.compose(
            Self.episodeJob(), from: Self.seriesPage(), info: info, series: "morrowfeld"
        ).description

        #expect(b.ratings["imdb"] == "8,1")
        #expect(b.ratings["gemeinde"] == nil)
        // The fraction is 8,1/10 — in floating point not exact to the last digit.
        #expect(abs((b.ratingShares["imdb"] ?? 0) - 0.81) < 0.0001)
    }

    @Test("Without outside information the server's number stays")
    func serverOnly() {
        let b = DownloadDescriber.compose(
            Self.episodeJob(), from: Self.seriesPage(), series: "morrowfeld"
        ).description

        #expect(b.ratings["gemeinde"] != nil)
    }

    @Test("A season identifier is built and read back")
    func seasonID() {
        let identifier = DownloadDescriber.seasonID(series: "morrowfeld", season: 2)
        #expect(DownloadDescriber.seriesID(from: identifier) == "morrowfeld")
        #expect(DownloadDescriber.seriesID(from: "morrowfeld-f3") == nil)
    }

    /// **The attribute line goes there and back.** It is the only place where
    /// guessing happens — and so the one where checking is needed.
    @Test("Year, rating and genres survive the round trip")
    func attributes() {
        let decomposed = DownloadDescriber.Traits(["2007", "FSK 12", "Komödie", "Drama"])
        #expect(decomposed.year == 2007)
        #expect(decomposed.ageRating == "FSK 12")
        #expect(decomposed.genres == ["Komödie", "Drama"])
        #expect(
            DownloadDescriber.Traits.row(
                year: decomposed.year, ageRating: decomposed.ageRating,
                genres: decomposed.genres) == ["2007", "FSK 12", "Komödie", "Drama"])
    }

    /// **Without an approval none is invented.** "Comedy" contains no digit and stays
    /// what it is.
    @Test("Without an age rating none is invented")
    func withoutApproval() {
        let decomposed = DownloadDescriber.Traits(["1999", "Action"])
        #expect(decomposed.year == 1999)
        #expect(decomposed.ageRating == nil)
        #expect(decomposed.genres == ["Action"])
    }

    /// For an episode the position ("S1 · E3") stands before the year — it is not a genre.
    @Test("The episode marker before the year is dropped")
    func positionBeforeYear() {
        let decomposed = DownloadDescriber.Traits(["S1 · F3", "2023", "Drama"])
        #expect(decomposed.year == 2023)
        #expect(decomposed.genres == ["Drama"])
    }
}
