import Core
import Foundation
import Testing

@testable import JellyfinKit

/// Check "Setup" of 2026-09-27, E10: **Quick Connect and the throughput measurement trust the
/// same certificate as sign-in.** Until then both built a session without
/// ``TrustingSessionDelegate`` — with a confirmed, self-issued certificate the code button was
/// missing, and the measurement silently delivered nothing.
@Suite("Setup check – certificate trust")
struct CheckSetupTrustTests {

    @Test("Quick Connect asks through the trust delegate")
    func quickConnectTrusts() {
        #expect(QuickConnect().session.delegate is TrustingSessionDelegate)
        #expect(
            QuickConnect(protocols: [URLProtocol.self]).session.delegate is TrustingSessionDelegate,
            "also with the check log")
    }

    @Test("The throughput measurement asks through the trust delegate")
    func measurementTrusts() {
        let session = ConnectionProbe.measuringSession(
            trustStore: CertificateTrustStore(store: InMemoryStore()))
        defer { session.invalidateAndCancel() }
        #expect(session.delegate is TrustingSessionDelegate)
    }
}
