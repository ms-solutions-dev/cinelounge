import Downloads
import Foundation
import NetworkStatus
import Testing

@testable import FeaturesPhone

/// What the downloads screen calculates before it draws.
///
/// **What is checked is the model and not the picture.** The three questions this screen
/// must answer are decisions: which version applies, which rows remain after
/// the filter, and what stands in the header. A screenshot would prove none of them.
@Suite("Downloads view")
struct DownloadsViewTests {

    private static func job(
        _ name: String, extent: Extent = .film, bytes: Int64 = 1_000_000_000
    ) -> DownloadJob {
        DownloadJob(
            id: .init(name), title: name, beside: "Jellyfin · 720p",
            source: .jellyfin, extent: extent, tier: .low, estimatedSize: bytes)
    }

    @MainActor
    private static func model(
        items: [DownloadJob] = [], isRunning: [Transfer] = [], route: NetworkPath = NetworkPath(kind: .wifi),
        seen: Set<DownloadJob.Identifier> = []
    ) -> DownloadsModel {
        let watcher = NetworkStatus.NetworkWatch()
        watcher.adopt(route)
        let m = DownloadsModel(networkMonitor: watcher)
        m.set(
            downloads: Downloads(items: items, isRunning: isRunning),
            household: StorageBudget(items: [], unrestricted: 40_000_000_000),
            durations: Dictionary(uniqueKeysWithValues: items.map { ($0.id, 3600.0) }),
            seen: seen)
        return m
    }

    // MARK: - The three versions

    /// **Three and not two.** "Empty" is not a special case of "full", and "offline" is
    /// not an error message but the version in which this screen is the only one in the
    /// app that can do something.
    @Test("Full, empty and offline are three versions")
    @MainActor
    func threeVersions() {
        #expect(Self.model(items: [Self.job("A")]).version == .full)
        #expect(Self.model().version == .empty)
        #expect(Self.model(items: [Self.job("A")], route: .none).version == .offline)
    }

    /// **Offline, an empty download store also counts as "offline".** Whoever showed "empty" there
    /// would offer a way into the library that does not exist right now.
    @Test("Offline beats empty")
    @MainActor
    func withoutNetworkEmptyWins() {
        #expect(Self.model(route: .none).version == .offline)
    }

    /// **A running job makes the downloads visible.** Whoever has just queued something and
    /// wants to check how far it is would otherwise find the screen only when it is done
    /// — that is, exactly not when they look.
    @Test("A running job counts as catalog")
    @MainActor
    func runningOneCounts() {
        let m = Self.model(isRunning: [Transfer(id: .init("A"))])
        #expect(m.version == .full)
        #expect(m.downloads.hasContent)
    }

    // MARK: - The header

    /// **Hours before gigabytes.** Whoever packs for a flight calculates in hours; "14,8 GB"
    /// does not answer whether the return flight is covered.
    @Test("The header names titles and hours")
    @MainActor
    func headerNamesHours() {
        let m = Self.model(items: [Self.job("A"), Self.job("B")])
        #expect(m.headerCount.hasPrefix("2 · "))
        #expect(m.headerCount.count > 4)
    }

    /// **What is counted is what is really running.** A waiting and a paused job
    /// are two states with two sentences; adding them up into "downloading 4" would be the number
    /// nobody asked for.
    @Test("The download line counts only what is flowing")
    @MainActor
    func loadingRowCountsOnlyFlowing() {
        let m = Self.model(
            items: [Self.job("A")],
            isRunning: [
                Transfer(id: .init("A"), state: .isLoading, loaded: 1, total: 100),
                Transfer(id: .init("B"), state: .idle(.cellular)),
                Transfer(id: .init("C"), state: .waitingForConnection),
            ])
        #expect(m.downloadLine?.hasPrefix("1 · ") == true)
    }

    @Test("Without running jobs there is no download line")
    @MainActor
    func noLoadingRow() {
        #expect(Self.model(items: [Self.job("A")]).downloadLine == nil)
    }

    // MARK: - Search and filters

    /// **The search works within what is here** — no fetch, no waiting time, no
    /// error case. That is exactly why it works offline and the one in the neighboring tab does not.
    @Test("The search covers title and second line")
    @MainActor
    func searchTakesEffect() {
        let m = Self.model(items: [Self.job("Sallow Pier"), Self.job("Glass Meadow")])
        m.search = "glass"
        #expect(m.rows(forItem: .everything).map(\.title) == ["Glass Meadow"])
        m.search = "jellyfin"
        #expect(m.rows(forItem: .everything).count == 2)
    }

    /// Offline it searches just the same — that is the point of the whole version.
    /// **The season of a queued episode stands in neither of its two rows** — the
    /// title is the episode title, the second line the series. Without ``Downloads/Extent/searchText``
    /// "s2" would find nothing.
    @Test("The search also covers the season and episode label")
    @MainActor
    func searchFindsSeason() {
        let m = Self.model(items: [
            Self.job("Alpha", extent: .episode(season: 2, number: 4)),
            Self.job("Beta", extent: .episode(season: 3, number: 1)),
        ])
        m.search = "s2"
        #expect(m.rows(forItem: .everything).map(\.id.rawValue) == ["Alpha"])
        m.search = "f4"
        #expect(m.rows(forItem: .everything).map(\.id.rawValue) == ["Alpha"])
    }

    @Test("The search also works offline")
    @MainActor
    func searchWithoutNetwork() {
        let m = Self.model(items: [Self.job("Ezeval")], route: .none)
        m.search = "eze"
        #expect(m.rows(forItem: .everything).count == 1)
    }

    /// **The count stands on the chip.** A filter that one has to tap to see whether it is empty
    /// is one too many.
    @Test("Series and movies separate by extent")
    @MainActor
    func filtersSeparate() {
        let m = Self.model(items: [
            Self.job("Film"),
            Self.job("Serie", extent: .season(number: 2, episodes: 8)),
        ])
        #expect(m.count(.movies) == 1)
        #expect(m.count(.allSeries) == 1)
        #expect(m.count(.everything) == 2)
    }

    // MARK: - The row

    /// **Every reason carries its own sentence.** "Paused — you are on cellular" is
    /// information with a way forward next to it; "Error" would be a dead end.
    @Test("Every pause reason has its own key")
    @MainActor
    func reasonsOwnSentences() {
        let all = NetworkRule.Reason.allCases.map { TransferText.reasonText($0).raw }
        #expect(Set(all).count == all.count)
    }

    /// **The button disappears where there is nothing to press.** A dimmed button
    /// is an invitation whose answer is the same every time.
    @Test("Finished and waiting have no button")
    func noButtonWhereNothingWorks() {
        #expect(TransferControl.action(forItem: .done) == .none)
        #expect(TransferControl.action(forItem: .waitingForConnection) == .none)
    }

    /// **A ``CaptionLabel`` and no finished string** — under `swift test` there is
    /// no app bundle, and a check for German words would check the catalog instead of the
    /// statement.
    @Test("The state sentence comes as a key, the amount as wording")
    @MainActor
    func sentenceAsKey() {
        let idle = TransferText.message(forItem: Transfer(id: .init("A"), state: .idle(.cellular)))
        #expect(idle == .key("stock.pausedCellular"))

        let isLoading = TransferText.message(
            forItem: Transfer(id: .init("A"), state: .isLoading, loaded: 500, total: 1000))
        if case .wording(let text) = isLoading {
            #expect(text.contains("/"))
        } else {
            Issue.record("The amount is composed and must not be a key")
        }
    }

    /// **A load error yields a sentence and no raw text** (2026-09-09).
    ///
    /// **The finding from the simulator:** Under "Lenno Varsk und der Spiegel von Orbel" it said,
    /// in red, `network("CancellationError()")` — Swift internals under a warning triangle. A
    /// `.wording` at this place means exactly that: passed-through text, untranslatable
    /// and without a next step. That is why this line checks the **case** and not the
    /// wording: Every load error must come out as ``CaptionLabel/key(_:)``.
    @Test("Every download error becomes a sentence and not raw text")
    @MainActor
    func loadErrorAsSentence() {
        for error in LoadError.allCases {
            let message = TransferText.message(
                forItem: Transfer(id: .init("A"), state: .failed(error)))
            guard case .key = message else {
                Issue.record("\(error) comes out as raw text: \(message.raw)")
                continue
            }
        }
    }

    /// **And each carries its own — otherwise it would be the one error message again.**
    ///
    /// The exception is ``LoadError/wasCancelled``: Paused is not an error, and the
    /// honest sentence for it is the same as for pausing by hand (`stock.paused`).
    @Test("Download errors do not share a sentence")
    @MainActor
    func loadErrorOwnSentences() {
        let real = LoadError.allCases.filter { $0 != .wasCancelled }
        let wordings = real.map { TransferText.loadText($0).raw }
        #expect(Set(wordings).count == wordings.count)
        #expect(TransferText.loadText(.wasCancelled) == .key("stock.paused"))
    }

    // MARK: - The collective path

    /// **The "Watched" filter was always empty until 2026-09-08**, because it waited for a history
    /// that nobody connected. A filter that never shows anything is not a filter
    /// but a button that looks as if it were broken.
    @Test("The \"Watched\" filter shows what the history lists as finished")
    @MainActor
    func filterWatched() {
        let m = Self.model(
            items: [Self.job("a"), Self.job("b")], seen: [.init("b")])
        #expect(m.rows(forItem: .seen).map(\.id.rawValue) == ["b"])
        #expect(m.count(.seen) == 1)
    }

    /// **A filter change must not keep a selection that is no longer visible.** Otherwise
    /// the button below would count rows that are no longer shown — and take them along
    /// on tap.
    @Test("Switching the filter trims the selection")
    @MainActor
    func filterSwitchTrims() {
        let m = Self.model(
            items: [Self.job("a"), Self.job("serie", extent: .season(number: 1, episodes: 6))])
        m.selection.open()
        m.selection.select(m.visible)
        #expect(m.selection.count == 2)
        m.filter = .movies
        #expect(m.selection.chosen == [.init("a")])
    }

    /// The same rule for the search field — it narrows the list just like a filter.
    @Test("The search also trims the selection")
    @MainActor
    func searchTrims() {
        let m = Self.model(items: [Self.job("Alpha"), Self.job("Beta")])
        m.selection.select(m.visible)
        m.search = "alp"
        #expect(m.selection.chosen == [.init("Alpha")])
    }

    /// **Without a selection no sentence, and thus no button.** A "Remove · 0 titles" would be
    /// an invitation whose answer is the same every time.
    @Test("Without ticked items there is no collective sentence")
    @MainActor
    func noAggregateSentence() {
        let m = Self.model(items: [Self.job("a")])
        #expect(m.bulkText == nil)
        m.selection.toggle(.init("a"))
        #expect(m.bulkText != nil)
    }

    /// **The amount always stands with it** — the rule from ``Downloads/Cleanup``. What is checked is
    /// the number and not the German word: Under `swift test` there is no app bundle,
    /// and the key then stays where the sentence would otherwise stand.
    @Test("The collective sentence names the amount that is freed")
    @MainActor
    func aggregateSentenceNamesQuantity() throws {
        let m = Self.model(
            items: [Self.job("a", bytes: 2_100_000_000), Self.job("b")])
        m.selection.toggle(.init("a"))
        let message = try #require(m.bulkText)
        #expect(message.contains(DownloadsModel.members(2_100_000_000)))
    }

    /// **What is still loading does not go along with "Remove watched".** Whoever finished an episode
    /// and afterwards queued it for the flight would otherwise lose it in the middle of loading.
    @Test("\"Remove watched\" leaves running jobs alone")
    @MainActor
    func watchedSentenceLeavesRunningAlone() {
        let items = [Self.job("a"), Self.job("b")]
        let m = Self.model(
            items: items, isRunning: [Transfer(id: .init("a"), state: .isLoading)],
            seen: [.init("a"), .init("b")])
        #expect(m.watchedJobs.map(\.id.rawValue) == ["b"])
    }

    @Test("Without watched items the line does not exist")
    @MainActor
    func noWatchedSentence() {
        #expect(Self.model(items: [Self.job("a")]).watchedText == nil)
    }

    // MARK: - Where "watched" comes from

    private static func entry(
        _ identifier: String, _ origin: Catalog.Origin, progress: Double
    ) -> HistoryEntry {
        HistoryEntry(
            identifier: identifier, origin: origin, title: identifier, progress: progress)
    }

    /// **The threshold is the one from ``Core/PlaybackReporter/watchedFraction``** and not a
    /// second one next to it. A separate number here would be the place where a title counts as
    /// watched on the TV and not on the phone.
    @Test("Watched is what lies above the threshold")
    func threshold() {
        let history = History([
            Self.entry("a", .jellyfin, progress: 0.95),
            Self.entry("b", .jellyfin, progress: 0.5),
        ])
        let match = DownloadsManager.watchedSet(
            in: history, under: [Self.job("a"), Self.job("b")])
        #expect(match == [.init("a")])
    }

    /// **Origin and ID together.** Two services can assign the same number; a
    /// comparison by the bare ID would remove the wrong title — and exactly the one
    /// nobody has watched.
    @Test("The same number at another service does not count")
    func originCountsToo() {
        let history = History([Self.entry("42", .portals, progress: 1)])
        #expect(DownloadsManager.watchedSet(in: history, under: [Self.job("42")]).isEmpty)
    }

    /// A channel entry has no progress — and **`nil` is not zero percent**,
    /// but no information at all. It is therefore never watched.
    @Test("Without progress nothing counts as watched")
    func withoutProgress() {
        let history = History([Self.entry("a", .jellyfin, progress: 0)])
        #expect(DownloadsManager.watchedSet(in: history, under: [Self.job("a")]).isEmpty)
    }
}

extension NetworkRule.Reason {
    /// All reasons — `CaseIterable` would be wrong on the type: It is stored, and an
    /// enumeration that can be enumerated invites iterating over it instead of
    /// deciding it.
    static var allCases: [NetworkRule.Reason] { [.noNetwork, .cellular, .expensive, .frugal] }
}

extension LoadError {
    /// All load errors — **the same reasoning as above**, and one of its own: Two of the
    /// cases carry a wording, and `CaseIterable` cannot enumerate them anyway.
    static var allCases: [LoadError] {
        [
            .notResumable("Probe"), .differentFile, .noSpace, .wasCancelled,
            .network("Probe"), .notReady,
            // **Every refusal individually, not one as a representative** (2026-09-09). The check
            // above demands that no two errors share a sentence — with only
            // one representative exactly that would remain unchecked for which the enumeration was
            // built: that the next unknown host gets a sentence of **its own**.
            .notLoadable(.dash), .notLoadable(.endlessStream), .notLoadable(.liveWithoutEnd),
            .notLoadable(.rightsManagement), .notLoadable(.encrypted("AES-128")),
            .notLoadable(.unknownFormat("video/x-probe")),
            .notLoadable(.emptyList), .notLoadable(.accessBusy),
        ]
    }
}
