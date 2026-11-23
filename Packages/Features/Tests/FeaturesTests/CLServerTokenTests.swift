import ProfileKit
import Testing

@testable import Features

/// The ⊕ next to the CL-Server follows the profile (simulator 2026-09-28).
@Suite("CL-Server-Marke")
struct CLServerTokenTests {

    @Test("Set up means: login with a person")
    func isConfigured() {
        #expect(!SettingsView.withoutCLServer(Profile(name: "d", credentials: [.portals(person: "max")])))
        #expect(SettingsView.withoutCLServer(Profile(name: "d", credentials: [.portals(person: nil)])))
        #expect(SettingsView.withoutCLServer(Profile(name: "neu")))
        #expect(SettingsView.withoutCLServer(nil))
    }
}
