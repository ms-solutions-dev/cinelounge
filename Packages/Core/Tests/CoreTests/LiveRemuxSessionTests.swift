import AVFoundation
import Foundation
import Testing

@testable import Core

/// **The whole bracket, from the network into the picture.**
///
/// What goes in is an address to a raw transport stream — the `.ts` ending
/// that a provider offers alongside the playlist. What comes out is an
/// address that an `AVURLAsset` accepts.
///
/// **The channel is simulated here, not called.** A test that needs a
/// real provider ends up testing its availability and not its
/// own code — and fails when someone works without a network.
@Suite("A channel from the network to the picture")
struct LiveRemuxSessionTests {

    /// A provider that hands out the test stream exactly once.
    private func provider() throws -> (server: LocalMediaServer, data: Data) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        let data = try Data(contentsOf: url)

        let server = try LocalMediaServer()
        server.provider = { name in
            name == "channel.ts" ? (data, "video/mp2t") : nil
        }
        return (server, data)
    }
}

/// The verdict on the delivery — the number for "Rendal 2 HQ hangs" (F-009).
/// **Measure first, then build** (AP73): The rule is computed and named in the
/// reserve line, but only applied after the on-device test.
@Suite("The early-start rule (AP73)")
struct EarlyStartTests {

    @Test("Buffered downloads and measured lead must both suffice")
    func bothConditions() {
        #expect(LiveRemuxSession.isEarlyStartPossible(downloads: 1.5, lead: 1.0))
        #expect(LiveRemuxSession.isEarlyStartPossible(downloads: 2.9, lead: 4.0))
        // Reserve present, but the line only just keeps pace: no early start.
        #expect(!LiveRemuxSession.isEarlyStartPossible(downloads: 2.9, lead: 0.3))
        // Vorsprung da, aber zu wenig Sendung im Vorrat.
        #expect(!LiveRemuxSession.isEarlyStartPossible(downloads: 1.0, lead: 3.0))
        // Without a measurement no rule.
        #expect(!LiveRemuxSession.isEarlyStartPossible(downloads: 5.0, lead: nil))
    }
}

@Suite("The delivery verdict")
struct SupplyVerdictTests {

    @Test("RENDAL 2 HQ: 18 s of broadcast in 31 s is too slow")
    func slowSupplyIsNamed() throws {
        let verdict = try #require(
            LiveRemuxSession.deliveryVerdict(broadcast: 18, duration: 31, bytes: 38_300_000))
        #expect(verdict.contains("18 s of broadcast in 31 s"))
        #expect(verdict.contains("17.0 Mbit/s"))
        #expect(verdict.contains("too slow"))
    }

    @Test("Keeping up earns no verdict")
    func keepingUpIsSilent() {
        #expect(LiveRemuxSession.deliveryVerdict(broadcast: 30, duration: 31, bytes: 20_000_000) == nil)
        #expect(LiveRemuxSession.deliveryVerdict(broadcast: 110, duration: 85, bytes: 81_000_000) == nil)
    }

    @Test("A short session is no proof")
    func shortSessionIsSilent() {
        #expect(LiveRemuxSession.deliveryVerdict(broadcast: 1, duration: 3, bytes: 1_000_000) == nil)
        #expect(LiveRemuxSession.deliveryVerdict(broadcast: 0, duration: 20, bytes: 0) == nil)
    }
}
