import Testing

@testable import Core

/// A new profile starts empty (product decision, 2026-09-28: "a new profile is new").
@Suite("Profile store: fresh profiles")
struct ProfileStoreFreshTests {

    @Test("An old profile keeps the device value, a fresh one does not")
    func fallbackOnlyForOld() throws {
        let device = InMemoryStore()
        try device.set("aus", for: LivePreferences.previewKey)
        ProfileStore.markFresh("neu", in: device)
        #expect((try? ProfileStore(device, forItem: "alt").value(for: LivePreferences.previewKey)) == "aus")
        #expect((try? ProfileStore(device, forItem: "neu").value(for: LivePreferences.previewKey)) == nil)
    }

    @Test("An own choice also applies in a fresh profile")
    func ownChoice() throws {
        let device = InMemoryStore()
        ProfileStore.markFresh("neu", in: device)
        let store = ProfileStore(device, forItem: "neu")
        try store.set("an", for: TrailerPreferences.autostartKey)
        #expect((try? store.value(for: TrailerPreferences.autostartKey)) == "an")
    }

    @Test("Live preferences of a fresh profile are the defaults")
    func defaultSettings() {
        let device = InMemoryStore()
        var legacy = LivePreferences()
        legacy.setShowsAdultChannels(true)
        legacy.save(to: device)
        ProfileStore.markFresh("neu", in: device)
        #expect(LivePreferences.load(from: ProfileStore(device, forItem: "neu")) == LivePreferences())
        #expect(LivePreferences.load(from: ProfileStore(device, forItem: "alt")).showsAdultChannels)
    }
}
