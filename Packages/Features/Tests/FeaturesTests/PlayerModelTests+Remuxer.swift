import Core
import Flows
import Foundation
import Testing

@testable import Features

/// **The fallback chain on the TV** (AP58 R4): if the repackager fails, the player goes through
/// the chain from ``Flows/RemuxStart`` — checked here that it is wired up.
extension PlayerModelTests {

    struct RemuxerBroken: Error {}

    private func failingModel(
        _ kind: PlaybackTarget.Kind, error: any Error = RemuxerBroken(), startAt: TimeInterval = 0
    ) async -> (PlayerModel, HostDouble) {
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: kind == .live ? nil : "film", title: "T",
                url: URL(string: "http://anbieter/datei.mkv")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                startAt: startAt, duration: 3_600, kind: kind),
            engine: host, source: SourceSpy(),
            remux: { @MainActor _ in throw error },
            rawStreamStore: InMemoryStore())
        await model.begin()
        await model.engineStartTask?.value
        return (model, host)
    }

    @Test("If the remuxer fails on a film, the server segments it")
    func remuxerFilmServer() async {
        let (model, host) = await failingModel(.recording)
        #expect(model.target.decision.delivery == .hls)
        #expect(model.target.url.absoluteString == "https://server/Videos/film/stream")
        #expect(host.started.last?.decision.delivery == .hls)
    }

    @Test("If the remuxer fails on a channel, the last attempt stays on the raw address")
    func remuxerChannelLastAttempt() async {
        let (model, _) = await failingModel(.live)
        #expect(model.target.decision.delivery == .directPlay)
        #expect(model.target.decision.engine == .native)
        #expect(model.target.decision.reason == .containerNotNativelySupported)
        #expect(model.target.url.absoluteString == "http://anbieter/datei.mkv")
    }

    @Test("A refusal gets no fallback through the server")
    func remuxerRefusal() async {
        let (model, _) = await failingModel(
            .live, error: LiveRemuxSession.SessionFailure.refused(status: 403))
        #expect(model.target.decision.delivery == .directPlay)
        #expect(model.target.decision.reason == .remuxedInApp, "the reason stays that of the target")
    }
}
