import Foundation
import Testing

@testable import Core

/// The state of the two switches. The rules themselves have been checked since
/// 2026-09-27 by `ChannelBlockTests` — they take effect at the source (check Live,
/// finding 1).
@Suite("Channel block: store")
struct ChannelBlockStoreTests {

    /// **One store for both devices** (G3, finding C8) — since then the TV reads the switch
    /// via the same key as the phone.
    @Test("The \"unmarked\" switch lives in one place and comes back")
    func store() {
        let store = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!
        let sharedStore = InMemoryStore()
        #expect(!ChannelLock.stored(store: store, keychain: sharedStore).hidesUnlabeled)
        ChannelLock.write(hidesUnlabeled: true, in: store)
        #expect(ChannelLock.stored(store: store, keychain: sharedStore).hidesUnlabeled)
        #expect(store.bool(forKey: "childLock.hideUnmarked"), "the same key as on the phone up to G3")
        var preferences = LivePreferences()
        preferences.setShowsAdultChannels(true)
        preferences.save(to: sharedStore)
        #expect(ChannelLock.stored(store: store, keychain: sharedStore).showsAdult)
    }
}
