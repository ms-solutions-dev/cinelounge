import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Checks the playback UI without an engine, without a server and without a TV.
///
/// That is the reason why ``PlayerModel`` gets its engine and its source from
/// outside: a model that creates both itself could be checked only with a running
/// Jellyfin and a connected Apple TV — and would therefore never be checked.
/// Exactly here lie the bugs that are expensive on the TV: a trailer under
/// "Continue Watching", a session that stays on the server as playing, a
/// button that does not go away any more.
@Suite("Playback")
@MainActor
struct PlayerModelTests {

    // MARK: - Setup

    func target(
        kind: PlaybackTarget.Kind = .recording,
        itemID: String? = "film",
        duration: TimeInterval? = 3600,
        delivery: Delivery = .directPlay
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: itemID,
            title: "Zirkel der Uhrmacher",
            subtitle: "1985",
            url: URL(string: "https://server/Videos/film/stream")!,
            decision: PlaybackDecision(engine: .native, delivery: delivery, reason: .nativeContainer),
            duration: duration,
            seriesID: "serie",
            kind: kind
        )
    }

    /// A repackager without a network — it acts as if the local
    /// playlist were up, and remembers for which address it was asked.
    ///
    /// **That is what makes the path checkable at all.** The real one needs a server, file
    /// and partial fetches; as long as it was hard-wired into the model, no test could see
    /// that ``PlayerModel/adopt(_:)`` bypassed it.
    final class RemuxSpy: @unchecked Sendable {
        private(set) var asked: [URL] = []
        /// The handle the player holds on to — with counters when the check wants to have a
        /// stall interpreted (``PulseDouble``), otherwise a bare object.
        var pulse: PulseDouble?
        var builder: PlayerModel.RemuxBuilder {
            { @MainActor [self] target in
                asked.append(target.url)
                return PlayerModel.StartedRemux(
                    url: URL(string: "http://127.0.0.1:60000/media.m3u8")!,
                    handle: pulse ?? NSObject(),
                    stop: {}
                )
            }
        }
    }

    func make(
        kind: PlaybackTarget.Kind = .recording,
        itemID: String? = "film",
        duration: TimeInterval? = 3600,
        delivery: Delivery = .directPlay,
        remux: RemuxSpy = RemuxSpy(),
        audioStore: any KeyValueStore = InMemoryStore()
    ) -> (model: PlayerModel, host: HostDouble, source: SourceSpy) {
        let host = HostDouble()
        let source = SourceSpy()
        let model = PlayerModel(
            target: target(kind: kind, itemID: itemID, duration: duration, delivery: delivery),
            engine: host,
            source: source,
            remux: remux.builder,
            audioStore: audioStore
        )
        return (model, host, source)
    }

    /// Reproduces running playback — in steps of half a second, as
    /// ``PlayerModel/tickInterval`` prescribes.
    ///
    /// **Needed since the next-episode counter carries a reference point of its own.**
    /// A single position in the middle of the counter window has since then not meant "the ten
    /// seconds are up" — exactly this equation was the finding: a jump
    /// there switched without a counter and without a chance to cancel. Whoever wants to check the
    /// expiry has had to let it run down ever since, instead of asserting it.
    func play(
        _ model: PlayerModel,
        _ host: HostDouble,
        from start: TimeInterval,
        seconds: TimeInterval
    ) async {
        host.engine.status = .playing
        var elapsed: TimeInterval = 0
        while elapsed <= seconds {
            host.engine.position = start + elapsed
            await model.tick()
            // Half seconds are exact in binary; after twenty steps it really stands at
            // ten and not 9.999. Otherwise the expiry of the counter would depend on
            // a rounding remainder.
            elapsed += 0.5
        }
    }

    // MARK: - The readiness mark comes from the event

    /// **The host outlives the target.** ``HostDouble`` holds the same engine
    /// across all targets — exactly the design in which a timestamp of the
    /// previous channel would fall into the new measurement. Accepted, it would give a
    /// negative startup time; rejected, it gives a dash with a reason.
    /// **Back must not bring the bar up** (finding 2026-11-09): it closes the bar first and
    /// the player on the next press — with the bar shown by its own press, it never left.
    @Test("Counting a press for Still watching does not show the bar on Back")
    func backDoesNotShowTheBar() {
        let (model, _, _) = make()
        model.hideBar()
        model.noteViewer(showsBar: false)
        #expect(!model.isBarVisible)
        model.noteViewer()
        #expect(model.isBarVisible)
    }

    @Test("A readiness timestamp from the previous target is not accepted")
    func staleReadinessIsRefused() async throws {
        let (model, host, _) = make()
        host.engine.readyToPlayAt = Date().addingTimeInterval(-5)

        await model.begin()
        await model.engineStartTask?.value

        host.engine.firstFrameVisible = true
        _ = model.sampleStartup(now: Date())

        let timing = try #require(model.startupTiming)
        #expect(timing.readyAt == nil)
        #expect(timing.timeToReady == nil)
        #expect(timing.line.contains("readiness never reported on its own"))
    }

    /// The proof that the 156 of 156 zeros can no longer arise by
    /// construction: readiness carries the timestamp of the event, the picture
    /// that of the sample — two sources, so a measurable gap.
    @Test("Readiness and first frame come from two separate sources")
    func readinessAndFirstFrameComeFromDifferentSources() async throws {
        let (model, host, _) = make()
        await model.begin()
        await model.engineStartTask?.value

        let start = try #require(model.startupTiming).startedAt
        host.engine.readyToPlayAt = start.addingTimeInterval(0.4)
        host.engine.firstFrameVisible = true
        _ = model.sampleStartup(now: start.addingTimeInterval(1.9))

        let timing = try #require(model.startupTiming)
        let toReady = try #require(timing.timeToReady)
        let toFirstFrame = try #require(timing.timeToFirstFrame)
        #expect(abs(toReady - 0.4) < 0.001)
        #expect(abs(toFirstFrame - 1.5) < 0.001)
        #expect(!timing.line.contains("nicht trennbar"))
        #expect(!timing.line.contains("first frame: 0 ms"))
    }

    /// The rule without an engine and without a clock — that is why it stands as a function of its own.
    @Test("The rule for the readiness mark, branch by branch")
    func readyMarkRules() {
        let start = Date()

        #expect(PlayerModel.readyMark(reported: nil, startedAt: start) == nil)
        #expect(PlayerModel.readyMark(reported: start.addingTimeInterval(-1), startedAt: start) == nil)
        // A tie is accepted: an engine may be ready at the same instant
        // it was started — that is fast, not wrong.
        #expect(PlayerModel.readyMark(reported: start, startedAt: start) == start)
        let later = start.addingTimeInterval(0.25)
        #expect(PlayerModel.readyMark(reported: later, startedAt: start) == later)
    }

    /// Ensures that the default `nil` from the contract does not pass as zero:
    /// an engine without a report gets a dash with a reason, no record time.
    @Test("An engine without readiness information keeps the measurement honestly open")
    func silentEngineLeavesTheSectionOpen() async throws {
        let (model, host, _) = make()
        await model.begin()
        await model.engineStartTask?.value

        host.engine.firstFrameVisible = true
        _ = model.sampleStartup(now: Date())

        let timing = try #require(model.startupTiming)
        #expect(timing.isComplete)
        #expect(timing.timeToReady == nil)
        #expect(timing.line.contains("readiness never reported on its own"))
    }
}
