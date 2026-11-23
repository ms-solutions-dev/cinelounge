import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// **Continue Watching plays on tap** (user request 2026-10-01, as on the TV): The detail
/// page is then under "Details" in the long press.
@Suite("Continue Watching: tap plays")
struct ContinueWatchingPlaysTests {

    @Test("Started items play, unwatched ones and channels do not")
    func decision() {
        let started = TileContent(id: "f", title: "Film", duration: 6000, progress: 0.25)
        let fresh = TileContent(id: "s", title: "Serie")
        #expect(started.playsInHistory(origin: nil))
        #expect(started.playsInHistory(origin: .portals))
        #expect(!started.playsInHistory(origin: .channelList))
        #expect(!fresh.playsInHistory(origin: nil))
    }

    @Test("The position comes from the fraction and the duration")
    func location() {
        #expect(TileContent(id: "f", title: "F", duration: 6000, progress: 0.25).resumePosition == 1500)
        #expect(TileContent(id: "f", title: "F", progress: 0.25).resumePosition == 0)
    }
}
