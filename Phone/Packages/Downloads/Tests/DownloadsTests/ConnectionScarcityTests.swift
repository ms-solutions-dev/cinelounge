import Foundation
import Testing

@testable import Downloads

/// The consideration for the single-connection account — **the rule that was missing on 2026-09-09.**
///
/// **The product owner's finding:** *"xstream vod content can't be
/// downloaded either."* Measured on the device it was neither a format error nor a broken address:
/// the download path ran into the account's one connection, which its **own**
/// format probe had occupied 220 ms earlier, and got `509`.
///
/// **It is checked without a clock and without a line.** ``ConnectionScarcity/verdict(claim:occupiedSince:now:)``
/// receives both points in time — built the same way as ``TimeEstimate`` and for
/// the same reason: a check that waits for a real second tests the patience of the
/// checker and not the rule.
@Suite("Connection scarcity")
struct ConnectionScarcityTests {

    private static let now = Date(timeIntervalSince1970: 1_757_000_000)

    // MARK: - Whoever is watching wins

    /// **Watching always wins** — the same statement as ``ConnectionScarcity/mayLoad(_:)``,
    /// only with the reason attached.
    @Test("Whoever is watching holds the loading path — here as on the second device")
    func viewerWins() {
        for claim in [
            ConnectionScarcity.Claim.playbackHere, .playbackOnSecondDevice,
        ] {
            #expect(
                ConnectionScarcity.verdict(claim: claim, now: Self.now)
                    == .waiting(.viewer))
        }
    }

    /// **The downloads themselves are no obstacle.** They are the one asking; whoever listed themselves as
    /// the claimant would never get started.
    @Test("Free and the downloads themselves run")
    func freeRuns() {
        #expect(ConnectionScarcity.verdict(claim: .unrestricted, now: Self.now) == .isRunning)
        #expect(ConnectionScarcity.verdict(claim: .downloads, now: Self.now) == .isRunning)
    }

    // MARK: - What the provider said itself

    /// **The core of the finding.** The provider has just reported "busy"; the next
    /// grab at the same connection gets the same answer.
    ///
    /// The 0.22 s is the gap measured on the device between probe and first block.
    @Test("Shortly after a reported busy, it waits")
    func busyPauses() {
        let justNow = Self.now.addingTimeInterval(-0.22)
        #expect(
            ConnectionScarcity.verdict(claim: .unrestricted, occupiedSince: justNow, now: Self.now)
                == .waiting(.busyReported))
    }

    /// **And it goes away by itself** — that is the whole difference from an error.
    @Test("After the trailing period it runs again")
    func trailingTimeExpires() {
        let previous = Self.now.addingTimeInterval(-ConnectionScarcity.trailing)
        #expect(
            ConnectionScarcity.verdict(claim: .unrestricted, occupiedSince: previous, now: Self.now)
                == .isRunning)
    }

    /// **"Never" is not "just now".** Reading a `nil` as "wait to be safe"
    /// would mean that nothing started without a single provider contact — even for the
    /// media server, which the limit does not concern at all.
    @Test("Without a reported busy it does not wait")
    func noWaitWithoutReport() {
        #expect(
            ConnectionScarcity.verdict(claim: .unrestricted, occupiedSince: nil, now: Self.now)
                == .isRunning)
    }

    /// **The order of the questions is the statement** — the same rule as at
    /// ``NetworkRule/verdict(forItem:)``. Whoever is watching is the reason, even if the provider has
    /// additionally just reported "busy": the aftermath passes, the viewer
    /// does not.
    @Test("The viewer goes before the trailing period")
    func viewerBeforeTrailingTime() {
        #expect(
            ConnectionScarcity.verdict(
                claim: .playbackHere, occupiedSince: Self.now, now: Self.now)
                == .waiting(.viewer))
    }

    // MARK: - The status it hinges on

    /// **The measured `509` is in the list** — together with the three other numbers
    /// with which panels express the same thing. Without this check the list would be
    /// a claim; on 2026-09-09 the number came from the device.
    @Test("509 counts as a busy connection")
    func busyStatusContainsMeasured() {
        #expect(DeliveryKind.busyStatuses.contains(509))
        #expect(DeliveryKind.from(Probe(status: 509, contentType: "video/mp4")) == .accessBusy)
        #expect(DeliveryKind.from(Probe(status: 509)).rejection == .accessBusy)
    }
}
