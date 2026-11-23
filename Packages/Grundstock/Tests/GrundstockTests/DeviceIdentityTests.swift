import Foundation
import Testing

@testable import Grundstock

/// The device identifier is the bracket around everything the server
/// keeps about this device: sign-in, sessions, running encodings. Two identifiers side by side
/// are therefore not a cosmetic flaw — the server then cleans up encodings that
/// belong to "another device", and playback runs into a 404.
@Suite("Device identifier")
struct DeviceIdentityTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "device-identity-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("The first query creates an identifier and stores it")
    func firstAskPersists() {
        // This is exactly what was missing at app start: it rolled an identifier without
        // storing it — the next run got the next one, and the server kept
        // the TV multiple times.
        let defaults = freshDefaults()

        let first = DeviceIdentity.id(in: defaults)

        #expect(!first.isEmpty)
        #expect(defaults.string(forKey: DeviceIdentity.storageKey) == first)
    }

    @Test("Every further query returns the same identifier")
    func laterAsksAgree() {
        // Sign-in and app start both ask. If they got different values, the
        // playback session would hang on a device the sign-in has never seen.
        let defaults = freshDefaults()

        let first = DeviceIdentity.id(in: defaults)
        let second = DeviceIdentity.id(in: defaults)

        #expect(first == second)
    }

    @Test("An already stored identifier stays untouched")
    func storedIdentitySurvives() {
        let defaults = freshDefaults()
        defaults.set("existing", forKey: DeviceIdentity.storageKey)

        #expect(DeviceIdentity.id(in: defaults) == "existing")
    }
}
