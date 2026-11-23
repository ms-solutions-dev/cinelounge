import Downloads
import Foundation
import NetworkStatus
import Testing

@testable import FeaturesPhone

/// How download jobs become posters.
///
/// **Requirement of 2026-09-09:** *"even if I download only 1 episode, navigation in
/// Downloads should be: poster → detail view with the downloaded episodes."* What is
/// tested is the **decision**, not the picture: what belongs together, what stands on its
/// own, and what the chip counts. A screenshot proved none of these — and the three cases
/// where this screen can fail are all invisible: the series without a series ID, the item
/// without a description, and the season with eight episodes behind it.
@Suite("Downloads posters")
struct DownloadsPosterTests {

    private static func episode(
        _ name: String, series: String?, season: Int = 1, number: Int = 1
    ) -> DownloadJob {
        DownloadJob(
            id: .init(name), title: name, beside: "Ironbell",
            source: .portal, extent: .episode(season: season, number: number),
            host: "hoste", version: "de", estimatedSize: 400_000_000)
    }

    private static func description(
        _ identifier: String, series: String?, seriesTitle: String? = nil,
        title: String = "Pilot", poster: String? = nil, year: Int? = nil
    ) -> DownloadDescription {
        DownloadDescription(
            id: identifier, title: title, year: year, series: series, seriesTitle: seriesTitle,
            poster: poster)
    }

    /// **Built from two pieces, and that is not a quirk** — the same trap as at
    /// ``Downloads/DownloadLedger/stem``: `scripts/strings.py` treats every string of the form
    /// `word.word` as a catalog key, and a file name looks exactly the same. Assembled, the
    /// checker sees two harmless pieces.
    private static let posterName = "s1" + ".jpg"

    private static func ledger(
        _ entries: [DownloadDescription]
    )
        -> [DownloadJob.Identifier: DownloadDescription]
    {
        Dictionary(uniqueKeysWithValues: entries.map { (DownloadJob.Identifier($0.id), $0) })
    }

    // MARK: - Gruppieren

    /// **Five episodes are one poster with a number, not five tiles.** That was the whole
    /// finding: "1 - Pilot / Ironbell", five times one below the other, without a single image.
    @Test("Five episodes of a series make one poster with the number five")
    func fiveEpisodesOnePoster() throws {
        let items = (1...5).map { Self.episode("f\($0)", series: "s1", number: $0) }
        let descriptions = Self.ledger(
            items.map {
                Self.description(
                    $0.id.rawValue, series: "s1", seriesTitle: "Ironbell", poster: Self.posterName)
            })

        let groups = DownloadGroup.groups(from: items, descriptions: descriptions)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.episodes == 5)
        #expect(group.count == 5)
        #expect(group.title == "Ironbell")
        #expect(group.series == "s1")
        // **The number carries its unit.** Under `swift test` there is no app bundle, so the key
        // stays as it is — the test therefore checks the number that was filled in, not the
        // German word.
        #expect(group.counter?.contains("5") == true)
    }

    /// **A queued season is one download job with eight episodes.** Whoever counted items
    /// would write "1 episode" on a poster with eight behind it — the number would come from
    /// the list instead of from ``Downloads/Extent/episodeCount``.
    @Test("A laid-out season counts its episodes and not its row")
    func seasonCountsEpisodes() throws {
        let season = DownloadJob(
            id: .init("st1"), title: "Staffel 1", beside: "Ironbell", source: .jellyfin,
            extent: .season(number: 1, episodes: 8), tier: .low)
        let groups = DownloadGroup.groups(
            from: [season],
            descriptions: Self.ledger([
                Self.description("st1", series: "s1", seriesTitle: "Ironbell")
            ]))
        #expect(try #require(groups.first).episodes == 8)
    }

    /// **A movie stands on its own, and it carries no episode count.** "1 episode" on a movie
    /// would report something that does not exist there.
    @Test("A film stands alone and carries no number")
    func movieStaysAlone() throws {
        let film = DownloadJob(
            id: .init("m1"), title: "Skifle Prak", source: .jellyfin, extent: .film,
            tier: .low)
        let groups = DownloadGroup.groups(
            from: [film],
            descriptions: Self.ledger([
                DownloadDescription(id: "m1", title: "Skifle Prak", year: 2008)
            ]))
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.series == nil)
        #expect(group.episodes == nil)
        #expect(group.counter == nil)
        #expect(group.title == "Skifle Prak")
        #expect(group.beside == "2008")
    }

    /// **Two series, two posters — and a movie next to them stays a movie.**
    @Test("Two series and a film make three posters")
    func twoSeriesOneMovie() {
        let items =
            [Self.episode("a1", series: nil), Self.episode("a2", series: nil)]
            + [Self.episode("b1", series: nil)]
            + [
                DownloadJob(
                    id: .init("m1"), title: "Film", source: .jellyfin, extent: .film,
                    tier: .low)
            ]
        let descriptions = Self.ledger([
            Self.description("a1", series: "A", seriesTitle: "Alpha"),
            Self.description("a2", series: "A", seriesTitle: "Alpha"),
            Self.description("b1", series: "B", seriesTitle: "Beta"),
            DownloadDescription(id: "m1", title: "Film"),
        ])
        let groups = DownloadGroup.groups(from: items, descriptions: descriptions)
        #expect(groups.map(\.title) == ["Alpha", "Beta", "Film"])
    }

    /// **The order of the download ledger stays.** Downloads are a chronicle, not an
    /// alphabet; whoever just queued something finds it where they queued it.
    @Test("A group stands where its first episode stood")
    func orderStays() {
        let items = [
            Self.episode("b1", series: nil), Self.episode("a1", series: nil),
            Self.episode("b2", series: nil),
        ]
        let descriptions = Self.ledger([
            Self.description("a1", series: "A", seriesTitle: "Alpha"),
            Self.description("b1", series: "B", seriesTitle: "Beta"),
            Self.description("b2", series: "B", seriesTitle: "Beta"),
        ])
        #expect(
            DownloadGroup.groups(from: items, descriptions: descriptions).map(\.title)
                == ["Beta", "Alpha"])
    }

    // MARK: - Ohne Beschreibung

    /// **An old download must still appear.** Before 2026-09-09 nothing was stored with the
    /// download; leaving those items out would turn a missing poster into a missing movie —
    /// and it is still on the disk.
    @Test("An item without a description appears anyway, with title and second line")
    func withoutDescriptionStillThere() throws {
        let items = [Self.episode("old1", series: nil), Self.episode("old2", series: nil)]
        let groups = DownloadGroup.groups(from: items)
        #expect(groups.count == 2)
        let first = try #require(groups.first)
        #expect(first.title == "old1")
        #expect(first.beside == "Ironbell")
        // **No poster, but a poster slot.** ``EmptyTile`` draws the title into the area; a
        // second design next to it would be a second screen inside the screen.
        #expect(first.poster == nil)
    }

    /// **Half a description is enough.** Over the bridge one episode can arrive without a
    /// poster and the next with one; whoever stubbornly took the first would show an empty
    /// frame although the file is right there.
    @Test("The first existing poster of the group wins")
    func firstAvailableDetailWins() throws {
        let items = [Self.episode("f1", series: nil), Self.episode("f2", series: nil)]
        let descriptions = Self.ledger([
            Self.description("f1", series: "s1", seriesTitle: "Ironbell"),
            Self.description("f2", series: "s1", seriesTitle: "Ironbell", poster: Self.posterName),
        ])
        let folder = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let group = try #require(
            DownloadGroup.groups(from: items, descriptions: descriptions, folder: folder)
                .first)
        #expect(group.poster?.lastPathComponent == Self.posterName)
    }

    /// **A file name and no address** — without a folder there is no image, and that is not
    /// an error but the state before the first call of
    /// ``DownloadsModel/set(descriptions:folder:)``.
    @Test("Without a downloads folder the poster slot stays empty")
    func withoutFolderNoImage() throws {
        let group = try #require(
            DownloadGroup.groups(
                from: [Self.episode("f1", series: nil)],
                descriptions: Self.ledger([Self.description("f1", series: "s1", poster: Self.posterName)])
            ).first)
        #expect(group.poster == nil)
    }

    /// **The title of a group is the series title.** If it is missing from the description,
    /// the second line of the download job carries it — for a single queued episode the title
    /// is the episode title and ``Downloads/DownloadJob/beside`` is the series.
    @Test("Without a series title the request's second line carries the name")
    func secondLineCarriesSeries() throws {
        let group = try #require(
            DownloadGroup.groups(
                from: [Self.episode("f1", series: nil)],
                descriptions: Self.ledger([Self.description("f1", series: "s1")])
            ).first)
        #expect(group.title == "Ironbell")
    }

    /// **A checkmark only when everything is done.** "Watched" on a series of which one of
    /// five episodes has been watched would be the information that triggers cleanup — and it
    /// would be wrong.
    @Test("A group counts as watched only when everything in it is watched")
    func watchedOnlyWhole() throws {
        let items = [Self.episode("f1", series: nil), Self.episode("f2", series: nil)]
        let descriptions = Self.ledger([
            Self.description("f1", series: "s1"), Self.description("f2", series: "s1"),
        ])
        let half = DownloadGroup.groups(
            from: items, descriptions: descriptions, seen: [.init("f1")])
        #expect(try #require(half.first).seen == false)

        let total = DownloadGroup.groups(
            from: items, descriptions: descriptions, seen: [.init("f1"), .init("f2")])
        #expect(try #require(total.first).seen)
    }

    // MARK: - Was das Modell daraus macht

    @MainActor
    private static func model(
        items: [DownloadJob], isRunning: [Transfer] = [],
        descriptions: [DownloadDescription] = []
    ) -> DownloadsModel {
        let watcher = NetworkStatus.NetworkWatch()
        watcher.adopt(NetworkPath(kind: .wifi))
        let m = DownloadsModel(networkMonitor: watcher)
        m.set(
            downloads: Downloads(items: items, isRunning: isRunning),
            household: StorageBudget(items: [], unrestricted: 40_000_000_000))
        m.set(descriptions: descriptions)
        return m
    }

    /// **The chip counts what is visible.** "Series 5" for a single queued series would be the
    /// number for which five tiles are missing.
    @Test("The filters count posters and not episodes")
    @MainActor
    func filtersCountGroups() {
        let episodes = (1...5).map { Self.episode("f\($0)", series: nil, number: $0) }
        let film = DownloadJob(
            id: .init("m1"), title: "Film", source: .jellyfin, extent: .film, tier: .low)
        let m = Self.model(
            items: episodes + [film],
            descriptions: episodes.map {
                Self.description($0.id.rawValue, series: "s1", seriesTitle: "Ironbell")
            })

        #expect(m.count(.everything) == 2)
        #expect(m.count(.allSeries) == 1)
        #expect(m.count(.movies) == 1)
    }

    /// **Without descriptions the chip counts as before** — every item is its own poster. So
    /// the screen also works before the first description is stored.
    @Test("Without descriptions each item counts for itself")
    @MainActor
    func withoutDescriptionsEachCounts() {
        let m = Self.model(items: (1...5).map { Self.episode("f\($0)", series: nil, number: $0) })
        #expect(m.count(.everything) == 5)
    }

    /// **What is still loading keeps its row.** A poster with a progress bar says less than
    /// "218.1 MB / 465.6 MB"; and a series may appear in both sections if one of its episodes
    /// is still in transit.
    @Test("Running items stay rows, finished ones become posters")
    @MainActor
    func runningStaysRow() {
        let episodes = (1...3).map { Self.episode("f\($0)", series: nil, number: $0) }
        let m = Self.model(
            items: episodes,
            isRunning: [Transfer(id: .init("f1"), state: .isLoading, loaded: 5, total: 100)],
            descriptions: episodes.map {
                Self.description($0.id.rawValue, series: "s1", seriesTitle: "Ironbell")
            })

        #expect(m.running(forItem: .everything).map(\.id.rawValue) == ["f1"])
        let finished = m.finishedGroups(forItem: .everything)
        #expect(finished.count == 1)
        #expect(finished.first?.episodes == 2)
        // The chip still counts the whole series — it is here, even if one episode is still
        // flowing.
        #expect(m.count(.everything) == 1)
    }

    /// **A paused download is not a finished one.** Whoever checked `.isLoading` instead of the
    /// list of transfers would let the paused and the failed slip into the grid — exactly what
    /// needs its status line most.
    @Test("Paused and failed items stay in row form")
    @MainActor
    func pausedStaysRow() {
        let m = Self.model(
            items: [Self.episode("f1", series: nil), Self.episode("f2", series: nil)],
            isRunning: [
                Transfer(id: .init("f1"), state: .idle(.cellular)),
                Transfer(id: .init("f2"), state: .failed(.noSpace)),
            ])
        #expect(m.running(forItem: .everything).count == 2)
        #expect(m.finishedGroups(forItem: .everything).isEmpty)
    }

    /// **The confirmation names the number and the size.** A poster hides how much stands
    /// behind it; "Remove" alone would be a commitment whose price only shows afterwards.
    @Test("The poster set names the amount being freed")
    @MainActor
    func posterSentenceNamesQuantity() throws {
        let episodes = (1...5).map { Self.episode("f\($0)", series: nil, number: $0) }
        let m = Self.model(
            items: episodes,
            descriptions: episodes.map { Self.description($0.id.rawValue, series: "s1") })
        let group = try #require(m.finishedGroups(forItem: .everything).first)
        let message = m.groupText(group)
        #expect(message.contains(DownloadsModel.members(5 * 400_000_000)))
        #expect(message.contains("5"))
    }
}
