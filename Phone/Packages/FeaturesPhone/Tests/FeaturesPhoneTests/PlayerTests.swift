import Core
import Flows
import Foundation
import JellyfinKit
import NetworkStatus
import PlaylistKit
import PortalKit
import Testing

@testable import FeaturesPhone

/// The way into the player: **one request travels, not a string.**
///
/// Direction K6a of 2026-09-06. The most expensive single error of the app lay here — two of five
/// tabs had no playback path at all, and the failure was reported as a
/// Jellyfin outage.
@Suite("Playback request")
struct PlayerRequestTests {

    private static let address = URL(string: "http://a" + ".example/x.m3u8")!

    /// A source that only says that it was asked.
    private struct ProbeSource: PlayerSource {
        let tag: String

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: tag, address: PlayerRequestTests.address,
                startAt: job.startAt ?? 0, origin: job.origin)
        }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob,
            isPaused: Bool
        ) async throws {}
    }

    // MARK: - Where an identifier comes from

    /// **A channel does not come out here, and that is no oversight.** Its ID
    /// carries no attribute and is meant to get none — `XtreamPayload:136` justifies it
    /// by the fact that it survives a reload and favorites are not lost.
    /// That is why the Live tab must send the origin along; this check records
    /// **why** it must.
    @Test("A channel identifier looks like a Jellyfin title")
    func channelIsNotRecognizable() {
        #expect(PlaybackJob.origin(zu: "xtream#live#4711") == .jellyfin)
        #expect(PlaybackJob(identifier: "xtream#live#4711").origin == .jellyfin)

        // Sent along, it carries.
        let live = PlaybackJob(identifier: "xtream#live#4711", origin: .channelList)
        #expect(live.origin == .channelList)
    }

    // MARK: - The four arms

    /// **Four and not two.** Until 2026-09-06 portals and channels fell through to the
    /// media server — which does not carry them.
    @Test("Every origin reaches its own source")
    func fourArms() async throws {
        let switchPoint = CompositePlayerSource(
            jellyfin: ProbeSource(tag: "server"),
            provider: ProbeSource(tag: "catalog"),
            channels: ProbeSource(tag: "channel"),
            portals: ProbeSource(tag: "portal"))

        for (origin, tag) in [
            (Catalog.Origin.jellyfin, "server"), (.provider, "catalog"),
            (.channelList, "channel"), (.portals, "portal"),
        ] {
            let target = try await switchPoint.target(zu: PlaybackJob(identifier: "x", origin: origin))
            #expect(target.title == tag, "\(origin.rawValue) went to the wrong source")
        }
    }

    /// **A missing arm throws and does not guess.** The downloads get their source with the
    /// package **Downloads and storage**;
    /// a downloaded title that lands at the media server would be the same error all over again.
    @Test("Without an arm there is an error and no fallback")
    func missingArm() async {
        let switchPoint = CompositePlayerSource(jellyfin: ProbeSource(tag: "server"))
        await #expect(throws: CompositePlayerSource.Missing.self) {
            try await switchPoint.target(zu: PlaybackJob(identifier: "x", origin: .downloads))
        }
    }

    /// The start position travels along — "From the start" and every chapter jump hang on it.
    @Test("The start position that travels along arrives")
    func startPositionTravels() async throws {
        let switchPoint = CompositePlayerSource(jellyfin: ProbeSource(tag: "server"))
        let target = try await switchPoint.target(
            zu: PlaybackJob(identifier: "x", origin: .jellyfin, startAt: 0))
        #expect(target.startAt == 0, "From the beginning is a zero and not an ask-the-server")
    }

    // MARK: - What kind of thing is playing

    /// **A channel is not seekable and writes no progress.** Both hang on the
    /// shared `PlaybackTarget`, and both hung until 2026-09-06 on the default value
    /// `.recording`: A channel counted as a recording with a length and an end.
    @Test("A channel plays as a channel, not as a recording")
    func channelIsNoRecording() {
        let channel = PlaybackRequest(
            identifier: "ahorn", title: "Das Nordlicht", address: Self.address,
            origin: .channelList, kind: .live)

        #expect(channel.target.kind == .live)
        #expect(!channel.target.isSeekable)
        #expect(!channel.target.tracksProgress)
        #expect(channel.target.itemID == nil, "there is nothing to remember")
        #expect(!channel.belongsInHistory)

        let film = PlaybackRequest(
            identifier: "42", title: "Selvin", address: Self.address, duration: 3600)
        #expect(film.target.isSeekable)
        #expect(film.target.tracksProgress)
        #expect(film.belongsInHistory)
    }

    // MARK: - Expired is not broken

    /// **The difference without which every playback error was resolved anew.**
    ///
    /// A host address is valid for five minutes (`Strom.gueltig_bis` in the bridge); five
    /// minutes is shorter than any interruption. **`nil` means "unknown" and not
    /// "forever"** — but whoever treats an unknown deadline like an expired one fetches
    /// anew on every error, and that is exactly what the roadmap warns against.
    @Test("Without a deadline an address does not count as expired")
    func expiryNeedsDeadline() {
        let without = PlaybackRequest(
            identifier: "x", title: "t", address: Self.address, origin: .portals)
        #expect(!without.isExpired(), "unknown is not expired")

        let now = Date()
        let expired = PlaybackRequest(
            identifier: "x", title: "t", address: Self.address, origin: .portals,
            validUntil: now.addingTimeInterval(-1))
        #expect(expired.isExpired(um: now))

        let valid = PlaybackRequest(
            identifier: "x", title: "t", address: Self.address, origin: .portals,
            validUntil: now.addingTimeInterval(60))
        #expect(!valid.isExpired(um: now))

        // The media server never names one — there a drop is always a drop.
        let film = PlaybackRequest(identifier: "42", title: "Selvin", address: Self.address)
        #expect(film.validUntil == nil)
        #expect(!film.isExpired())
    }

    // MARK: - The screen names the right source

    /// **The finding of 2026-09-06:** Above an Xtream broadcast it said "No answer from the
    /// media server". A message that sends the viewer to the wrong place is
    /// worse than one that says nothing: they check a server that has nothing
    /// to do with the matter.
    @Test("Every origin gets its own disruption screen")
    func errorPerOrigin() {
        struct Anything: Error {}
        func interpret(_ error: any Error, _ origin: Catalog.Origin) -> PlaybackPhase {
            DisruptionInterpretation.state(forItem: error, origin: origin)
        }

        #expect(interpret(Anything(), .jellyfin) == .networkJellyfin)
        #expect(interpret(Anything(), .provider) == .networkXtream)
        #expect(interpret(Anything(), .portals) == .networkPortals)
        #expect(interpret(Anything(), .channelList) == .networkXtream)

        // A channel the account no longer carries is not a network error.
        #expect(interpret(ChannelPlayerSource.Missing.channels, .channelList) == .xtreamDeliversNothing)

        // **And "no source" is not a network error but a missing setup.**
        #expect(interpret(CompositePlayerSource.Missing.source, .portals) == .notSetUpYet)
    }

    /// **No network takes precedence over everything.** Which source does not answer is then an answer
    /// to a question nobody asked — the app did not even try.
    @Test("Without a network no source shows its own failure")
    func withoutNetworkNobodyShowsItsFailure() {
        struct Anything: Error {}
        for origin in Catalog.Origin.allCases {
            let state = DisruptionInterpretation.state(
                forItem: Anything(), origin: origin, network: NetworkPath.none)
            #expect(state == .networkAirplaneMode, "\(origin.rawValue) reports itself anyway")
        }

        // With a network the source applies again.
        #expect(
            DisruptionInterpretation.state(
                forItem: Anything(), origin: .portals, network: NetworkPath(kind: .wifi))
                == .networkPortals)
    }

    /// **A drop in the engine is the only information there is for two sources.**
    ///
    /// The provider rejects an occupied connection without a word — ``PlaybackPhase/xtreamBusy``
    /// itself spells out that there is no dedicated error ID for it. And a
    /// portal address is valid for five minutes, shorter than any interruption.
    @Test("A dropout in the engine means something different per source")
    func breakdownPerSource() {
        let breakdown = PlayerModel.Dropout.motor
        #expect(DisruptionInterpretation.state(forItem: breakdown, origin: .provider) == .xtreamBusy)
        #expect(DisruptionInterpretation.state(forItem: breakdown, origin: .channelList) == .xtreamBusy)
        #expect(
            DisruptionInterpretation.state(forItem: breakdown, origin: .portals)
                == .portalAddressExpired)
        // **On the media server it said "no answer" until 2026-09-07 — that was wrong.**
        // A drop in the engine comes from the player and not from the source; the server
        // did answer. Measured on the simulator: library there in 50 ms, movie
        // fails with `-11828`. The old sentence sent the viewer to the tunnel, as
        // with the ninth finding of the TestFlight evening.
        #expect(
            DisruptionInterpretation.state(forItem: breakdown, origin: .jellyfin)
                == .jellyfinWontPlay)
        // A network error from the same source stays the network case — the distinction
        // hangs on the error and not on the origin.
        #expect(
            DisruptionInterpretation.state(
                forItem: URLError(.notConnectedToInternet), origin: .jellyfin)
                == .networkJellyfin)
    }

    /// **The error type names the source whose sign-in has expired** (AP58, finding S5).
    /// Until 2026-09-26 an Xtream 401 led to a sign-in at the media server.
    @Test("An expired login leads to the source that reports it")
    func loginExpired() {
        #expect(
            DisruptionInterpretation.state(
                forItem: JellyfinSource.SourceFailure.unauthorized, origin: .jellyfin)
                == .loginExpired)
        #expect(
            DisruptionInterpretation.state(
                forItem: XtreamClient.Failure.unauthorized, origin: .provider)
                == .xtreamAccessExpired)
        #expect(
            DisruptionInterpretation.state(
                forItem: XtreamClient.Failure.unauthorized, origin: .channelList)
                == .xtreamAccessExpired)
    }

    /// **The bridge answered and refused** — that is not a network failure,
    /// and it states the reason verbatim.
    @Test("A rejected portal source is not a network error")
    func portalRejected() {
        let rejected = PortalBridge.TestError.rejected(
            status: 404, reason: "Für diese Folge steht kein Host bereit.")
        #expect(
            DisruptionInterpretation.state(forItem: rejected, origin: .portals)
                == .portalUnresolvable)
        #expect(
            DisruptionInterpretation.state(
                forItem: PortalBridge.TestError.unreadable, origin: .portals) == .networkPortals)
    }

    /// **The server declines with a code, not with a sentence** — and must therefore
    /// arrive here the same way.
    ///
    /// Without this case the app would interpret every refusal from the CineLounge server as a
    /// network failure: "Connection lost" for a portal that answered and gave a
    /// reason — exactly the error of 2026-09-06 that this interpretation was built
    /// against.
    @Test("A refusal from the server is not a network error either")
    func portalDeclined() {
        let cancelled = PortalBridge.TestError.cancelled(
            status: 502, code: "stream.no_host", values: [:])
        #expect(
            DisruptionInterpretation.state(forItem: cancelled, origin: .portals)
                == .portalUnresolvable)
    }
}
