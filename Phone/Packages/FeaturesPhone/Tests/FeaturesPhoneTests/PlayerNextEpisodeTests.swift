import Core
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **"Next episode" plays the episode** (AP58, finding S1): Until 2026-09-26 the
/// button called `back()` and only closed the player.
///
/// The source throws on every request so that the engine never starts; what is counted is **what**
/// was asked for.
@MainActor
@Suite("Next episode on the phone")
struct PlayerNextEpisodeTests {

    struct Declined: Error {}

    /// Remembers every ID for which a target was requested.
    actor Transcript {
        var asked: [PlaybackJob] = []
        func note(_ job: PlaybackJob) { asked.append(job) }
    }

    struct WitnessSource: PlayerSource {
        let transcript: Transcript

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            await transcript.note(job)
            throw Declined()
        }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob,
            isPaused: Bool
        ) async throws {}
    }

    private static let address = URL(string: "http://a" + ".beispiel/f2.mp4")!

    @Test("The button resolves the next episode instead of closing the player")
    func playsTheEpisode() async {
        let transcript = Transcript()
        let model = PlayerModel(
            job: PlaybackJob(
                identifier: "episode-1", origin: .jellyfin, startAt: 1200, source: "host-a",
                series: "series-9", seriesTitle: "Morrowfeld"),
            source: WitnessSource(transcript: transcript))
        model.next = PlaybackRequest(
            identifier: "episode-2", title: "Episode 2", address: Self.address, startAt: 300)

        await model.playNext()

        let asked = await transcript.asked
        #expect(asked.map(\.identifier) == ["episode-2"])
        #expect(asked.first?.startAt == nil, "the server names the position")
        #expect(asked.first?.source == nil, "the host choice belongs to the previous episode")
        #expect(asked.first?.series == "series-9")
        #expect(asked.first?.seriesTitle == "Morrowfeld")
        #expect(model.identifier == "episode-2")
        #expect(model.next == nil)
    }

    @Test("Without a next episode nothing happens")
    func noEpisodeNothing() async {
        let transcript = Transcript()
        let model = PlayerModel(
            job: PlaybackJob(identifier: "film", origin: .jellyfin),
            source: WitnessSource(transcript: transcript))

        await model.playNext()

        #expect(await transcript.asked.isEmpty)
        #expect(model.identifier == "film")
    }

    @Test("The view wires the button to playNext and not to back")
    func buttonIsWired() throws {
        let view = try SourceText.read("SpielerView.swift", in: .featuresPhone)
        guard let start = view.range(of: "NextEpisode(\n") ?? view.range(of: "NaechsteFolge(titel:")
        else {
            Issue.record("Button not found")
            return
        }
        let call = view[start.lowerBound...].prefix(260)
        #expect(call.contains("model.playNext()"))
        #expect(!call.contains("back()"))
    }

    // MARK: - Der Kern am Telefon (AP58 R4)

    /// A model whose core holds a recording with a next episode — the way ``PlayerModel/start()``
    /// sets it up after a successful start.
    private func recording(_ source: any PlayerSource, next: Bool = true) -> PlayerModel {
        let model = PlayerModel(
            job: PlaybackJob(identifier: "episode-1", origin: .jellyfin), source: source)
        model.core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        if next {
            model.next = PlaybackRequest(
                identifier: "episode-2", title: "Episode 2", address: Self.address)
            model.core.setNext(available: true, location: 0, duration: 1_400)
        }
        return model
    }

    /// **Until R4 the phone did not count and never advanced on its own.**
    @Test("At the end the next episode plays by itself")
    func continueAtEnd() async {
        let transcript = Transcript()
        let model = recording(WitnessSource(transcript: transcript))
        let motor = EngineDouble()
        motor.duration = 1_400
        motor.position = 1_390
        motor.status = .ended
        await model.tick(controller: motor, pulse: nil)
        // **The switch runs in its own task** (check Player, finding S1).
        await model.switchObserver?.value
        #expect(await transcript.asked.map(\.identifier) == ["episode-2"])
    }

    @Test("Whoever stays sees the credits")
    func stayingRejects() async {
        let transcript = Transcript()
        let model = recording(WitnessSource(transcript: transcript))
        let motor = EngineDouble()
        motor.duration = 1_400
        motor.status = .playing
        motor.position = 1_365
        await model.tick(controller: motor, pulse: nil)
        #expect(model.nextOffer?.secondsLeft == 10, "forty seconds before the end")
        model.stay()
        #expect(model.nextOffer == nil)
        motor.status = .ended
        await model.tick(controller: motor, pulse: nil)
        #expect(await transcript.asked.isEmpty)
    }

    /// Remembers sign-in, state and sign-out.
    struct ReportingSource: PlayerSource {
        let transcript: Transcript

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest { throw Declined() }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob,
            isPaused: Bool
        ) async throws {
            await transcript.note(PlaybackJob(identifier: "report", origin: .jellyfin))
        }

        func begin(_ job: PlaybackJob) async throws {
            await transcript.note(PlaybackJob(identifier: "begin", origin: .jellyfin))
        }

        func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {
            await transcript.note(PlaybackJob(identifier: "finish", origin: .jellyfin))
        }
    }

    /// **Signed in with the first frame, signed out at `.ended`** — until R4 the
    /// phone signed in before the first frame and signed out after the end only on closing.
    @Test("The session begins with the picture and ends with the title")
    func session() async {
        let transcript = Transcript()
        let model = recording(ReportingSource(transcript: transcript), next: false)
        let motor = EngineDouble()
        motor.duration = 1_400
        motor.status = .opening
        await model.tick(controller: motor, pulse: nil)
        #expect(await transcript.asked.isEmpty, "no registration before the first frame")
        motor.status = .playing
        await model.tick(controller: motor, pulse: nil)
        motor.status = .ended
        motor.position = 1_398
        await model.tick(controller: motor, pulse: nil)
        await model.finish()
        #expect(await transcript.asked.map(\.identifier) == ["begin", "report", "finish"])
    }

    @Test("The intro can be skipped")
    func preamble() async {
        let model = recording(WitnessSource(transcript: Transcript()), next: false)
        model.core.setSegments([MediaSegment(id: "v", kind: .intro, start: 30, end: 90)])
        let motor = EngineDouble()
        motor.duration = 1_400
        motor.status = .playing
        motor.position = 40
        await model.tick(controller: motor, pulse: nil)
        #expect(model.skipOffer?.id == "v")
        model.skip()
        #expect(model.location == 90)
        #expect(model.skipOffer == nil)
    }
}
