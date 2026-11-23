import Core
import Foundation
import Testing

@testable import Features

/// The TV reads and writes the colour scheme **through the one store** (AP58 R7, E5).
@Suite("Theme swatches on the TV")
@MainActor
struct ThemeStoreStoreTests {

    @Test("The old choice from the Keychain applies, and every new one lands in the store")
    func store() throws {
        let name = "probe.\(UUID().uuidString)"
        let device = try #require(UserDefaults(suiteName: name))
        defer { device.removePersistentDomain(forName: name) }
        let sharedStore = InMemoryStore()
        try sharedStore.set(Theme.contrast.id, for: ColorPattern.key)
        let store = InMemoryStore()

        let themes = ThemeStore(store: store, keychain: sharedStore, device: device)
        #expect(themes.current == .contrast)

        themes.choose(.midnight)
        #expect(ColorPattern.chosen(in: store) == Theme.midnight.id)
        #expect(ThemeStore(store: store, keychain: sharedStore, device: device).current == .midnight)
        Theme.current = .cinema
    }
}
