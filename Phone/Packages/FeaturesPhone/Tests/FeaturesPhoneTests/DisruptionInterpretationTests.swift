import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// **A certificate that only the app trusts is not a network error** (2026-09-07, TestFlight):
/// Above a responding server it said "No answer from the media server", and the
/// viewer checked the tunnel. The state now names the true reason.
@Suite("Disruption interpretation")
struct DisruptionInterpretationTests {

    private struct Anything: Error {}

    @Test("App-only trust becomes a certificate state, not a network error")
    func certificate() {
        let using = DisruptionInterpretation.state(
            forItem: Anything(), origin: .jellyfin, certificateTrustedByAppOnly: true)
        let without = DisruptionInterpretation.state(forItem: Anything(), origin: .jellyfin)
        #expect(using == .certificateSystemPlayer)
        #expect(without == .networkJellyfin)
    }

    @Test("For the provider the media server certificate does not matter")
    func onlyMediaServer() {
        let state = DisruptionInterpretation.state(
            forItem: Anything(), origin: .provider, certificateTrustedByAppOnly: true)
        #expect(state != .certificateSystemPlayer)
    }

    @Test("Only https with a remembered digest counts as app-trusted")
    func flag() {
        #expect(!PlayerModel.trustedByAppOnly(URL(string: "http://192.168.1.14:8096/x")!))
        #expect(!PlayerModel.trustedByAppOnly(nil))
    }
}
