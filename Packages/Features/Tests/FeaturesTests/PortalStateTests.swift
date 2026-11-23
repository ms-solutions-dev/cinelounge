import PortalKit
import Testing

@testable import Features

/// The "Portal service" row says what the cause is (on-device test 2026-09-27).
///
/// A server that answers 401 "person missing" showed up as "not reachable".
@Suite("Portal state")
struct PortalStateTests {

    @Test("If the server answers and only the login is missing, it does not say \"unreachable\"")
    func loginMissing() {
        for state: SignInState in [.setupRequired, .notSignedIn([]), .profileRequired([])] {
            #expect(PortalSettings.state(reachable: false, state: state) == "settings.portals.signInMissing")
        }
    }

    @Test("Without an answer it stays \"unreachable\", with a list \"reachable\"")
    func edgeCases() {
        #expect(
            PortalSettings.state(reachable: false, state: .unreachable) == "settings.portals.unreachable")
        #expect(PortalSettings.state(reachable: false, state: nil) == "settings.portals.unreachable")
        #expect(
            PortalSettings.state(reachable: true, state: .profileRequired([])) == "settings.portals.reachable"
        )
    }
}
