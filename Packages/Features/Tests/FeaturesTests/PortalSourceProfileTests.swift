import Foundation
import PortalKit
import Testing

@testable import Features

/// **Test Apple TV, 2026-09-28:** After the profile switch, the standing source kept asking with
/// the attribute of the previous profile.
@Suite("The CL-Server source follows the profile")
struct PortalSourceProfileTests {

    private func source(trait: String?, header: String? = nil) -> PortalSource {
        PortalSource(
            bridge: PortalBridge(
                basis: URL(string: "http://cl.example:8100/")!, trait: trait, profile: header))
    }

    @Test("A different trait rebuilds, even without a head")
    func differentAttribute() {
        #expect(PortalHeaderGuard.isStale(source(trait: "max"), expectedValue: source(trait: "aliye")))
        #expect(!PortalHeaderGuard.isStale(source(trait: "max"), expectedValue: source(trait: "max")))
    }

    @Test("A profile without a CL-Server removes the source, one with it builds it up")
    func presentOrNot() {
        #expect(PortalHeaderGuard.isStale(source(trait: "max"), expectedValue: nil))
        #expect(PortalHeaderGuard.isStale(nil, expectedValue: source(trait: "aliye")))
        #expect(!PortalHeaderGuard.isStale(nil, expectedValue: nil))
    }

    @Test("A different head keeps rebuilding")
    func differentHead() {
        #expect(
            PortalHeaderGuard.isStale(
                source(trait: "g", header: "a"), expectedValue: source(trait: "g", header: "b")))
    }
}
