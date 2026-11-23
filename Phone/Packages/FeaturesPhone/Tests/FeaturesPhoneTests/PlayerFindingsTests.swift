import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// **The findings of the "Player" check** (2026-09-27) on the phone — S1 to S4, S6, S8, S9.
///
/// The check's reproductions were red; here they stand as guards. S1 and S2 run
/// **through the real clock** (``PlayerModel/startClock(cadence:tap:)``) and not via a
/// direct call of ``PlayerModel/tick(controller:pulse:)``: The trap was in the clock —
/// the existing test `continueAtEnd` called the tick directly and therefore never saw it.
@MainActor
@Suite("Player on the phone: findings of the review")
struct PlayerFindingsTests {

    struct Declined: Error {}
    nonisolated static let address = URL(string: "http://a" + ".beispiel/f2.mp4")!

    /// Remembers every request and whether it came in a cancelled task — the way
    /// `URLSession` answers it: with `CancellationError`.
    final class NetworkSource: PlayerSource, @unchecked Sendable {
        var asked: [PlaybackJob] = []
        var wasCancelled: [Bool] = []
        var unregistrations: [Bool] = []
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            asked.append(job)
            wasCancelled.append(Task.isCancelled)
            try Task.checkCancellation()
            throw Declined()
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
        func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {
            unregistrations.append(Task.isCancelled)
            try Task.checkCancellation()
        }
    }

    /// A model in the middle of episode 1, with episode 2 known — the way ``PlayerModel/start()``
    /// sets it up after a successful start.
    private func episodeOne(_ source: any PlayerSource) -> PlayerModel {
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source)
        model.core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        model.next = PlaybackRequest(
            identifier: "episode-2", title: "Folge 2", address: Self.address)
        model.core.setNext(available: true, location: 0, duration: 1_400)
        return model
    }

    /// Waits until a condition holds — two seconds at most.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - S1: Der Folgenwechsel aus der Uhr bricht sich nicht mehr selbst ab

    @Test("S1: At the end the clock resolves the next episode in a live task")
    func episodeSwitchFromWatch() async throws {
        let source = NetworkSource()
        let model = episodeOne(source)
        let engine = EngineDouble()
        engine.duration = 1_400
        engine.position = 1_398
        engine.status = .ended
        model.startClock(cadence: .milliseconds(5)) { (engine, nil) }

        try await wait { !source.asked.isEmpty }
        await model.switchObserver?.value

        #expect(source.asked.map(\.identifier) == ["episode-2"])
        #expect(
            source.wasCancelled == [false],
            "otherwise the next episode ends in the disruption screen")
        await model.finish()
    }

    @Test("S1: After the counter, the unregistration of the old episode really goes out")
    func unregistrationFromWatch() async throws {
        let source = NetworkSource()
        let model = episodeOne(source)
        let engine = EngineDouble()
        engine.duration = 1_400
        engine.position = 1_340
        engine.status = .playing
        // Every tick one second further — the counter of the next episode runs from that point.
        model.startClock(cadence: .milliseconds(2)) {
            engine.position += 1
            return (engine, nil)
        }

        try await wait { !source.asked.isEmpty }
        await model.switchObserver?.value

        #expect(source.asked.map(\.identifier) == ["episode-2"])
        #expect(source.unregistrations == [false], "exactly one unregistration, not cancelled")
        #expect(source.wasCancelled == [false])
        await model.finish()
    }

    // MARK: - S2: "Try again" — the old clock does not overwrite the loading screen

    /// Holds the resolving until the check releases it.
    final class WaitingSource: PlayerSource, @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var asked = 0
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            asked += 1
            await withCheckedContinuation { continuation = $0 }
            throw Declined()
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
    }

    @Test("S2: During the renewed startup the loading screen stays up")
    func loadingScreenStays() async throws {
        let source = WaitingSource()
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .portals), source: source)
        let engine = EngineDouble()
        engine.status = .failed
        model.startClock(cadence: .milliseconds(5)) { (engine, nil) }
        try await wait { model.state != .isLoading }
        guard case .disrupted = model.state else {
            Issue.record("The failed engine shows no disruption screen")
            return
        }

        let run = Task { @MainActor in await model.start() }
        try await wait { source.continuation != nil }
        // Give ten ticks of the old clock time to overwrite the loading screen.
        try await Task.sleep(for: .milliseconds(50))
        let whileLoading = model.state
        source.continuation?.resume()
        await run.value

        #expect(whileLoading == .isLoading, "the old clock puts the disruption screen on top")
        #expect(source.asked == 1, "no second startup")
    }

    // MARK: - S3: "Resolve again" keeps the job

    @Test("S3: Resolving again keeps series, series name and repackager flag and unregisters first")
    func resolveAgain() async {
        let source = NetworkSource()
        let model = PlayerModel(
            job: PlaybackJob(
                identifier: "serieshub:1-wendetag:", origin: .portals, startAt: 1_200,
                source: "hosta", withoutRepackager: true, series: "serieshub:morrowfeld",
                seriesTitle: "Morrowfeld"),
            source: source)
        model.core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        let engine = EngineDouble()
        engine.status = .playing
        engine.position = 1_300
        await model.tick(controller: engine, pulse: nil)

        await model.resolveAgain()

        let job = source.asked.last
        #expect(job?.source == "hosta")
        #expect(job?.startAt == 1_300)
        #expect(job?.series == "serieshub:morrowfeld", "the history needs the series")
        #expect(job?.seriesTitle == "Morrowfeld")
        #expect(job?.withoutRepackager == true)
        #expect(source.unregistrations == [false], "the old session closes first")
    }

    // MARK: - S4: Die Tonwahl je Titel landet unter der Serie

    @Test("S4: The series is looked up even when there is a next episode")
    func seriesForAudioChoice() async {
        let catalog = CatalogDouble()
        var episode = MediaItem(id: "episode-1", kind: .episode, title: "Folge 1")
        episode.seriesID = "serie-9"
        catalog.title = episode
        let source = PlayerEquivalenceTests.ProbeSource()
        source.catalog = catalog
        let store = InMemoryStore()
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source,
            audioStore: store)
        let job = PlayerEquivalenceTests.recording(audioTracks: [
            PlaybackTrack(id: 1, language: "deu"), PlaybackTrack(id: 2, language: "jpn"),
        ])
        model.job = job
        model.next = PlaybackRequest(
            identifier: "episode-2", title: "Folge 2", address: Self.address)
        await model.loadExtra(zu: job, from: source)
        model.select(audioTrack: 2)
        let remembered = AudioMemory.load(from: store)
        #expect(remembered.language(forItem: "serie-9") == "jpn", "it is read under the series")
        #expect(model.similarItem == nil, "with a next episode there is no similar movie")
    }

    // MARK: - S6: Das Tempo gilt auch nach einem Neuaufbau desselben Titels

    @Test("S6: When the engine starts playing it gets the chosen speed — once")
    func speedAfterRebuild() async {
        let model = PlayerEquivalenceTests.model()
        model.job = PlayerEquivalenceTests.recording()
        model.rate = 1.5
        let engine = EngineDouble()
        engine.supportsSpeed = true
        engine.status = .opening
        await model.tick(controller: engine, pulse: nil)
        #expect(engine.rates.isEmpty, "not before the first frame — the rate is the start switch")
        engine.status = .playing
        await model.tick(controller: engine, pulse: nil)
        await model.tick(controller: engine, pulse: nil)
        #expect(engine.rates == [1.5])
    }

    @Test("S6: Without a chosen speed and on a channel, the tick sets nothing")
    func speedWithoutChoice() async {
        let model = PlayerEquivalenceTests.model()
        model.job = PlayerEquivalenceTests.recording()
        let engine = EngineDouble()
        engine.supportsSpeed = true
        engine.status = .playing
        await model.tick(controller: engine, pulse: nil)
        model.job = PlayerEquivalenceTests.recording(kind: .live)
        model.rate = 1.5
        engine.status = .paused
        await model.tick(controller: engine, pulse: nil)
        engine.status = .playing
        await model.tick(controller: engine, pulse: nil)
        #expect(engine.rates.isEmpty)
    }

    // MARK: - S8: A superseded startup no longer sets anything

    /// Resolves every ID — those from `hold` only once the check releases them; what is in
    /// `fails` throws.
    final class SeasonSource: PlayerSource, @unchecked Sendable {
        var hold: Set<String> = []
        var fails: Set<String> = []
        var holdNext = false
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        var nextIsWaiting: CheckedContinuation<Void, Never>?
        var asked: [String] = []

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            asked.append(job.identifier)
            if hold.contains(job.identifier) {
                await withCheckedContinuation { waiting[job.identifier] = $0 }
            }
            if fails.contains(job.identifier) { throw Declined() }
            return PlaybackRequest(
                identifier: job.identifier, title: job.identifier, address: PlayerFindingsTests.address,
                duration: 1_400)
        }
        func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? {
            if holdNext { await withCheckedContinuation { nextIsWaiting = $0 } }
            return PlaybackRequest(
                identifier: "nach-\(job.identifier)", title: "Nachfolgerin",
                address: PlayerFindingsTests.address)
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
    }

    @Test("S8: The late target of a superseded startup does not take over the player")
    func lateTarget() async throws {
        let source = SeasonSource()
        source.hold = ["episode-1"]
        source.fails = ["sender-2"]
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source)
        let stale = Task { @MainActor in await model.start() }
        try await wait { source.waiting["episode-1"] != nil }

        await model.switchTo(toChannel: "sender-2")
        source.waiting["episode-1"]?.resume()
        await stale.value

        #expect(model.identifier == "sender-2")
        #expect(model.job == nil, "the old title does not play over the new request")
        #expect(!model.isRunning)
        guard case .disrupted = model.state else {
            Issue.record("The disruption screen of the new request is gone")
            return
        }
        await model.finish()
    }

    @Test("S8: The late next episode of the previous title does not land on the new one")
    func lateNextEpisode() async throws {
        let source = SeasonSource()
        source.holdNext = true
        source.fails = ["sender-2"]
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source)
        let stale = Task { @MainActor in await model.start() }
        try await wait { source.nextIsWaiting != nil }
        #expect(model.job?.identifier == "episode-1")

        await model.switchTo(toChannel: "sender-2")
        source.holdNext = false
        source.nextIsWaiting?.resume()
        await stale.value

        #expect(model.next == nil, "the successor of the old episode does not belong here")
        await model.finish()
    }

    @Test("S8: After closing nothing starts anymore")
    func afterClosing() async {
        let source = SeasonSource()
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source)
        await model.finish()
        await model.start()
        #expect(source.asked.isEmpty)
    }

    // MARK: - S9: The file hint belongs to the file

    @Test("S9: A start without repackager clears the hint of the previous file")
    func fileHintWorks() async {
        let source = SeasonSource()
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-2", origin: .jellyfin), source: source)
        model.fileHint = "Datei endet bei 41:10"
        await model.start()
        #expect(model.job?.identifier == "episode-2", "the start succeeded")
        #expect(model.fileHint == nil)
        await model.finish()
    }
}
