import Foundation
import Testing

@testable import Core

/// What is stored is what is excluded — not what is allowed. This
/// decision has consequences, and they are recorded here.
@Suite("Libraries in the hero area")
struct HeroPreferencesTests {

    @Test("Without a setting everything is allowed")
    func defaultAllowsEverything() {
        // The default must be the friendly one: Whoever sets nothing
        // should see their libraries.
        let preferences = HeroPreferences()

        #expect(preferences.allows("filme"))
        #expect(preferences.allows("serien"))
        #expect(preferences.excluded.isEmpty)
    }

    @Test("A newly added library is included without any action")
    func newLibrariesAreIncluded() {
        // The actual reason for the exclusion list. With an
        // allow list, a library created tomorrow would be silently
        // invisible, and people would look for the bug in the app instead of in a
        // setting they no longer know about.
        var preferences = HeroPreferences()
        preferences.setAllowed(false, for: "privat")

        #expect(!preferences.allows("privat"))
        #expect(preferences.allows("morgen-angelegt"), "an unknown identifier counts as allowed")
    }

    @Test("Deselecting and reselecting returns to the initial state")
    func toggleRoundTrip() {
        var preferences = HeroPreferences()

        preferences.setAllowed(false, for: "filme")
        #expect(!preferences.allows("filme"))

        preferences.setAllowed(true, for: "filme")
        #expect(preferences.allows("filme"))
        #expect(preferences.excluded.isEmpty, "no remainder is left behind")
    }

    @Test("The selection survives saving and loading")
    func survivesStorage() {
        let store = InMemoryStore()

        var saved = HeroPreferences()
        saved.setAllowed(false, for: "privat")
        saved.setAllowed(false, for: "sonstiges")
        saved.save(to: store)

        let loaded = HeroPreferences.load(from: store)

        #expect(loaded.excluded == ["privat", "sonstiges"])
        #expect(!loaded.allows("privat"))
        #expect(loaded.allows("filme"))
    }

    @Test("Reselecting everything clears the entry")
    func emptyRemovesEntry() {
        // An empty entry would not be a bug, but ballast — and when reading,
        // a string that splits into no element.
        let store = InMemoryStore()

        var preferences = HeroPreferences()
        preferences.setAllowed(false, for: "privat")
        preferences.save(to: store)
        #expect((try? store.value(for: HeroPreferences.storageKey)) != nil)

        preferences.setAllowed(true, for: "privat")
        preferences.save(to: store)

        #expect((try? store.value(for: HeroPreferences.storageKey)) == nil)
        #expect(HeroPreferences.load(from: store).excluded.isEmpty)
    }

    @Test("The same selection always yields the same stored line")
    func stableSerialisation() {
        // Without a fixed order a comparison would see changes where there are none —
        // and a backup would grow on every open.
        let a = InMemoryStore()
        let b = InMemoryStore()

        var first = HeroPreferences()
        first.setAllowed(false, for: "zebra")
        first.setAllowed(false, for: "alpha")
        first.save(to: a)

        var second = HeroPreferences()
        second.setAllowed(false, for: "alpha")
        second.setAllowed(false, for: "zebra")
        second.save(to: b)

        #expect(
            (try? a.value(for: HeroPreferences.storageKey))
                == (try? b.value(for: HeroPreferences.storageKey))
        )
    }

    @Test("An empty stored line yields no ghost identifier")
    func emptyStoredValue() {
        // Otherwise an exclusion for the identifier "" would arise — it would never match,
        // but the setting would look occupied.
        let store = InMemoryStore()
        try? store.set("", for: HeroPreferences.storageKey)

        #expect(HeroPreferences.load(from: store).excluded.isEmpty)
    }
}
