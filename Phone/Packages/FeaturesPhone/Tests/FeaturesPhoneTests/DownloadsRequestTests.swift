import Downloads
import Testing

@testable import FeaturesPhone

/// The scope comes from the trigger.
///
/// **That was not so until 2026-09-08**, and nobody saw it: The button passed only one ID
/// upward, and the switch built a movie from it — even on a season. The design has said
/// otherwise since the first day, and the difference is 4.9 GB against 1.2.
@Suite("Download request")
struct DownloadsRequestTests {

    /// **A request carries everything that is fixed without the sheet** — and nothing that is
    /// decided there.
    @Test("The job from a request is not yet complete")
    func notYetComplete() {
        let request = DownloadRequest(
            identifier: "a", title: "Selvin", extent: .season(number: 2, episodes: 8),
            source: .jellyfin)
        let job = request.job
        #expect(job.extent == .season(number: 2, episodes: 8))
        #expect(job.title == "Selvin")
        // Without a tier: that one is chosen by ``DownloadChoice`` in the sheet. Filling it here would
        // mean making the choice and then asking for it.
        #expect(job.tier == nil)
        #expect(!job.complete)
    }

    /// **A portal job needs a host and a version**, and both come from the sheet.
    @Test("A portal request is not complete without a version")
    func portalNeedsVersion() {
        let request = DownloadRequest(
            identifier: "p", title: "Elvaran", extent: .episode(season: 1, number: 12),
            source: .portal)
        #expect(!request.job.complete)
    }

    // MARK: - Welche Herkunft laden darf

    /// **A channel has no beginning and no end.** What one would download from it would be a
    /// recording and not a copy — a different process with different questions.
    @Test("Channels and downloads are not download sources")
    func noLoadSources() {
        #expect(SourceKind(.channelList) == nil)
        #expect(SourceKind(.downloads) == nil)
    }

    /// **Portals since 2026-09-08 — that is the reversed decision.**
    @Test("Media server, providers and portals may download")
    func mayLoad() {
        #expect(SourceKind(.jellyfin) == .jellyfin)
        #expect(SourceKind(.provider) == .provider)
        #expect(SourceKind(.portals) == .portal)
    }

    /// **Every origin has exactly one answer.** A `default` here would be the place where a
    /// new origin silently passed as "not downloadable".
    @Test("Every origin is answered")
    func allAnswered() {
        let isDownloadable = Catalog.Origin.allCases.compactMap { SourceKind($0) }
        #expect(isDownloadable.count == 3)
        #expect(Set(isDownloadable).count == 3)
    }

    // MARK: - Die Staffelkennung

    /// **A season is stored under its own ID.** Without it, it would sit under the ID of its
    /// first episode — and a tap on the episode would afterwards show the season as queued.
    @Test("Season and episode share no identifier")
    func ownIdentifier() {
        let season = DownloadRequest(
            identifier: "serie#staffel#2", title: "Selvin",
            extent: .season(number: 2, episodes: 8), source: .jellyfin)
        let episode = DownloadRequest(
            identifier: "folge-4", title: "Folge 4", extent: .episode(season: 2, number: 4),
            source: .jellyfin)
        #expect(season.identifier != episode.identifier)
        #expect(season.job.extent.episodeCount == 8)
        #expect(episode.job.extent.episodeCount == 1)
    }
}
