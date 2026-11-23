import Core
import Foundation
import Testing

@testable import Features

/// **The findings of the "Player" check** (2026-09-27) on the TV — S5 to S8 and S10.
///
/// The shared rule behind it is checked by `AblaeufeTests/PlayerFindingsTests`; what stands here is that
/// it is wired up on the TV.
extension PlayerModelTests {

    private func episode2(delivery: Delivery = .directPlay) -> PlaybackTarget {
        PlaybackTarget(
            itemID: "folge-2", title: "Folge 2",
            url: URL(string: "https://server/Videos/folge-2/stream")!,
            decision: PlaybackDecision(engine: .native, delivery: delivery, reason: .nativeContainer),
            duration: 1_400, seriesID: "serie", kind: .recording)
    }

    // MARK: - S5

    /// After `.failed` the counter has signed off and stays silent for good; without a new one,
    /// "Try again" would report nothing more for the rest of the title.
    @Test("S5: After Try Again the title reports in again, and progress")
    func retryReportsAgain() async {
        let (model, host, source) = make()
        host.engine.status = .playing
        host.engine.position = 100
        await model.tick()
        #expect(source.begun == ["film"])

        host.engine.status = .failed
        await model.tick()
        #expect(source.ended.count == 1)

        model.retry()
        host.engine.status = .playing
        for location in stride(from: 100.0, through: 200, by: 10) {
            host.engine.position = location
            await model.tick()
        }
        #expect(source.begun.count == 2, "the second startup reports in")
        #expect(source.reports.count > 2, "and reports progress afterwards")
    }

    // MARK: - S6

    @Test("S6: The next episode starts at normal speed")
    func speedNextEpisode() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()
        model.setRate(1.5)
        #expect(host.engine.rates == [1.5])

        model.adopt(episode2())
        host.engine.status = .playing
        await model.tick()

        #expect(model.rate == 1, "the speed applies to the title, not to the next one")
        #expect(host.engine.rates == [1.5], "no speed is applied to the new episode")
    }

    /// A long jump in a Matroska rebuilds through the repackager — **on the same
    /// title**. Until then this path silently set the tempo back to 1.
    @Test("S6: A rebuild through the remuxer keeps the chosen speed and applies it again")
    func speedAfterRebuild() async {
        let (model, host, _) = make(delivery: .remuxInApp)
        host.engine.status = .playing
        await model.tick()
        model.setRate(1.5)

        let film = target(delivery: .remuxInApp)
        model.adopt(film.rerouted(to: film.url, startAt: 1_800))
        await model.engineStartTask?.value
        host.engine.status = .playing
        await model.tick()

        #expect(model.rate == 1.5)
        #expect(host.engine.rates == [1.5, 1.5], "the new engine receives the speed")
    }

    // MARK: - S7

    @Test("S7: If the title fails, the board is still done and shows the episodes")
    func boardWithoutTitle() async {
        let (model, _, source) = make()
        source.itemToReturn = nil
        source.episodesToReturn = [
            MediaItem(id: "film", kind: .episode, title: "1"),
            MediaItem(id: "f2", kind: .episode, title: "2"),
        ]
        await model.loadInfoIfNeeded()
        #expect(model.isInfoLoaded, "otherwise the info area says \"loading\" forever")
        #expect(model.siblingEpisodes.map(\.id) == ["f2"])
    }

    // MARK: - S8

    @Test("S8: The late answer for the previous title does not land on the new one")
    func lateResponseDiscarded() async {
        let (model, _, source) = make()
        source.segmentsToReturn = [MediaSegment(id: "v", kind: .intro, start: 30, end: 90)]
        source.nextEpisodeToReturn = MediaItem(id: "folge-2", kind: .episode, title: "Folge 2")
        var approval: CheckedContinuation<Void, Never>?
        source.beforeSegments = { await withCheckedContinuation { approval = $0 } }

        let old = Task { await model.loadContext() }
        while approval == nil { await Task.yield() }
        source.beforeSegments = nil
        model.adopt(episode2())
        approval?.resume()
        await old.value

        #expect(model.segments.isEmpty, "the segments belong to the previous title")
        #expect(model.nextEpisode == nil, "the \"next episode\" would be the one currently playing")
        #expect(model.trickplay == nil)
    }

    // MARK: - S10

    @Test("S10: A jump through the server does not report the title in again")
    func jumpWithoutSecondRegistration() async {
        let (model, host, source) = make(duration: 7200, delivery: .remux)
        source.itemToReturn = MediaItem(
            id: "film", kind: .movie, title: "Zirkel der Uhrmacher", runtime: 7200,
            source: MediaSource(container: .mkv, audioTracks: [], subtitleTracks: []))
        host.engine.status = .playing
        host.engine.position = 100
        await model.tick()
        #expect(source.begun == ["film"])

        model.restartGeneration += 1
        await model.restart(at: 3_000, generation: model.restartGeneration)
        await model.engineStartTask?.value
        #expect(model.target.startAt == 3_000, "the rebuild has run")
        host.engine.status = .playing
        host.engine.position = 3_000
        await model.tick()
        host.engine.position = 3_020
        await model.tick()

        #expect(source.begun == ["film"], "same session, no second registration")
        #expect(source.ended.isEmpty)
    }
}
