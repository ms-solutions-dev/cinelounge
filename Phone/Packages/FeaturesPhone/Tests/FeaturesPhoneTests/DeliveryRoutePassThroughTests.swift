import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **The real decision for IPTV titles** (AP75, 2026-10-11): Until then "native,
/// direct" became the guessed `hls`, and a resumed movie first downloaded itself completely
/// via the start-mark rewrite.
@Suite("Passing the delivery route through (AP75)")
struct DeliveryRoutePassThroughTests {

    private func decision(_ delivery: Delivery) -> PlaybackDecision {
        PlaybackDecision(engine: .native, delivery: delivery, reason: .nativeContainer)
    }

    @Test("IPTV catalog: direct travels along, the repackager route stays at the estimate")
    func provider() {
        #expect(
            JellyfinPlayerSource.passedThrough(decision(.directPlay), origin: .provider)?.delivery
                == .directPlay)
        #expect(JellyfinPlayerSource.passedThrough(decision(.remuxInApp), origin: .provider) == nil)
        #expect(JellyfinPlayerSource.passedThrough(decision(.renderInApp), origin: .provider) == nil)
    }

    @Test("Jellyfin and downloads pass everything through, channels and CL-Server nothing")
    func other() {
        #expect(
            JellyfinPlayerSource.passedThrough(decision(.remuxInApp), origin: .jellyfin) != nil)
        #expect(JellyfinPlayerSource.passedThrough(decision(.directPlay), origin: .downloads) != nil)
        #expect(JellyfinPlayerSource.passedThrough(decision(.directPlay), origin: .channelList) == nil)
        #expect(JellyfinPlayerSource.passedThrough(decision(.directPlay), origin: .portals) == nil)
    }
}
