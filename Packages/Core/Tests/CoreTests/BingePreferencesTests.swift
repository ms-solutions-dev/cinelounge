import Foundation
import Testing

@testable import Core

/// **The binge switches per profile** (AP85, 2026-11-09).
@Suite("Binge preferences")
struct BingePreferencesTests {

    private final class Memory: KeyValueStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func value(for key: String) throws -> String {
            guard let value = values[key] else { throw SecureStore.Failure.notFound }
            return value
        }
        func set(_ value: String, for key: String) throws { values[key] = value }
        func remove(_ key: String) throws { values[key] = nil }
    }

    @Test("Nothing stored: all off, ask after three episodes")
    func defaults() {
        let read = BingePreferences.load(from: Memory())
        #expect(!read.skipsIntro)
        #expect(!read.hidesSpoilers)
        #expect(read.stillWatchingAfter == 3)
        #expect(read.autoSkipKinds.isEmpty)
    }

    @Test("Each switch writes only its own key and reads back")
    func roundTrip() {
        let store = Memory()
        BingePreferences.writeSkipsIntro(true, in: store)
        #expect(store.values.keys.sorted() == ["binge.skipIntro"])
        BingePreferences.writeHidesSpoilers(true, in: store)
        BingePreferences.writeStillWatchingAfter(0, in: store)
        let read = BingePreferences.load(from: store)
        #expect(read.skipsIntro && read.hidesSpoilers)
        #expect(read.stillWatchingAfter == 0)
        #expect(read.autoSkipKinds == [.intro, .recap])
    }
}
