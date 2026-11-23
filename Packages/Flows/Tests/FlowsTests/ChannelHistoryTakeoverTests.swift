import Core
import Foundation
import Testing

@testable import Flows

/// **The old device list goes only after a successful takeover** (decision 2; Live
/// check, finding 3, 2026-09-27).
@Suite("Channel history: takeover of the device list")
struct ChannelHistoryTakeoverTests {

    struct FailingStore: KeyValueStore {
        struct TestError: Error {}
        func set(_ value: String, for key: String) throws { throw TestError() }
        func value(for key: String) throws -> String { throw TestError() }
        func remove(_ key: String) throws {}
    }

    @Test("If the store does not write, the old list stays")
    func takeoverWithoutReadBack() throws {
        let legacy = try #require(UserDefaults(suiteName: "pruefung.live.\(UUID().uuidString)"))
        legacy.set(["Das Nordlicht", "ZINNE"], forKey: "live.recentChannels")
        let history = ChannelHistory(store: FailingStore(), profile: { "p" }, legacy: legacy)
        #expect(history.names == ["Das Nordlicht", "ZINNE"])
        #expect(legacy.stringArray(forKey: "live.recentChannels") != nil)
        #expect(history.names == ["Das Nordlicht", "ZINNE"])
    }

    @Test("If the takeover succeeds, the list is in the profile and the old one is gone")
    func takeoverSucceeds() throws {
        let legacy = try #require(UserDefaults(suiteName: "pruefung.live.\(UUID().uuidString)"))
        legacy.set(["Das Nordlicht", "ZINNE"], forKey: "live.recentChannels")
        let store = InMemoryStore()
        #expect(
            ChannelHistory(store: store, profile: { "p" }, legacy: legacy).names == [
                "Das Nordlicht", "ZINNE",
            ])
        #expect(legacy.stringArray(forKey: "live.recentChannels") == nil)
        #expect(
            ChannelHistory(store: store, profile: { "p" }, legacy: nil).names == ["Das Nordlicht", "ZINNE"])
    }
}
