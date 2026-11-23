import Testing

@testable import Core

/// The CL-Server switch applies per profile (product decision, 2026-09-28).
@Suite("Portal switch per profile")
struct PortalSwitchTests {

    @Test("A profile switches off only itself")
    func perProfile() {
        let store = InMemoryStore()
        PortalSwitch.set(false, in: store, profile: "a")
        #expect(!PortalSwitch.on(in: store, profile: "a"))
        #expect(PortalSwitch.on(in: store, profile: "b"))
    }

    @Test("Without its own choice the device's earlier one applies")
    func deviceAsFallback() {
        let store = InMemoryStore()
        try? store.set("aus", for: PortalSwitch.key)
        #expect(!PortalSwitch.on(in: store, profile: "neu"))
        PortalSwitch.set(true, in: store, profile: "neu")
        #expect(PortalSwitch.on(in: store, profile: "neu"))
    }
}
