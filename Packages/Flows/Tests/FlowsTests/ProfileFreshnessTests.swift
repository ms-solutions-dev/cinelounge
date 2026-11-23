import Core
import Foundation
import ProfileKit
import Testing

@testable import Flows

/// A created profile inherits no settings of the device (owner requirement, 2026-09-28).
@MainActor
@Suite("A new profile starts empty")
struct ProfileFreshnessTests {

    @Test("Creating marks the profile as fresh")
    func creationIsNoted() throws {
        let keychain = SecureStore(service: "probe.\(UUID().uuidString)")
        var deviceValue = LivePreferences()
        deviceValue.setPreviewsChannels(false)
        deviceValue.save(to: keychain)
        let administration = ProfileManagement(
            keychain: keychain, store: InMemoryStore(), cloud: { nil },
            startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!, deviceLists: { nil })
        let identifier = try #require(
            administration.create(name: "neu", color: .amber, kind: .adult, avatar: nil))
        #expect(ProfileStore.isFresh(identifier.rawValue, in: keychain))
        #expect(
            LivePreferences.load(from: ProfileStore(keychain, forItem: identifier.rawValue))
                == LivePreferences())
    }
}
