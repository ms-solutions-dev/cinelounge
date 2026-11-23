import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// The address loaded from — **and the switch that has to pass it through.**
@Suite("Download target")
struct DownloadTargetTests {

    /// A source that answers both questions distinguishably.
    private struct TwoWaySource: PlayerSource {
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "play",
                address: URL(string: "https://example.invalid/stream")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .transcode, reason: .bandwidthTooLow))
        }

        func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "load",
                address: URL(string: "https://example.invalid/file")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .directPlay, reason: .nativeContainer))
        }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
        func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? { nil }
        func begin(_ job: PlaybackJob) async throws {}
        func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {}
        func host(zu job: PlaybackJob) async throws -> [PortalHost] { [] }
    }

    /// A source without its own answer — it is to deliver the playback URL.
    private struct OneWaySource: PlayerSource {
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "both",
                address: URL(string: "https://example.invalid/one")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .directPlay, reason: .nativeContainer))
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
        func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? { nil }
        func begin(_ job: PlaybackJob) async throws {}
        func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {}
        func host(zu job: PlaybackJob) async throws -> [PortalHost] { [] }
    }

    /// **A portal and a channel have only one address** — the resolved host file
    /// is the same one that plays. Without this default every source would have to carry a second
    /// body along.
    @Test("Without its own answer the download address is the playback address")
    func preset() async throws {
        let target = try await OneWaySource().loadTarget(zu: PlaybackJob(identifier: "a"))
        #expect(target.address.path == "/one")
    }

    /// **The bug of 2026-09-08, and it cost the whole download path.** If the
    /// switch does not pass the question through, the default applies for **every** origin — that is, the
    /// playback URL. With the media server that is a transcoded stream, and it
    /// does not answer a range request: The download run failed at the first block with
    /// "Range not answered (200)", and the screen showed "Downloading · 0 KB".
    @Test("The composite source passes the download address through")
    func softPassesThrough() async throws {
        let aggregate = CompositePlayerSource(jellyfin: TwoWaySource())
        let target = try await aggregate.loadTarget(
            zu: PlaybackJob(identifier: "a", origin: .jellyfin))
        #expect(target.address.path == "/file")
        #expect(target.decision?.delivery == .directPlay)

        // The counter-check: Playback still gets the other address.
        let play = try await aggregate.target(zu: PlaybackJob(identifier: "a", origin: .jellyfin))
        #expect(play.address.path == "/stream")
    }
}
