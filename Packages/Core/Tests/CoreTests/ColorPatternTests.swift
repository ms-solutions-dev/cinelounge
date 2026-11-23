import Foundation
import Testing

@testable import Core

/// The colour swatch in **one** store (AP58 R7, finding E5) — and the one-time migration
/// from the two previous places.
@Suite("Color pattern")
struct ColorPatternTests {

    private func device() -> (UserDefaults, String) {
        let name = "probe.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("The TV's choice comes from the Keychain and is cleared there")
    func tv() throws {
        let (legacy, name) = device()
        defer { legacy.removePersistentDomain(forName: name) }
        let keychain = InMemoryStore()
        try keychain.set("midnight", for: ColorPattern.key)
        let fresh = InMemoryStore()

        #expect(ColorPattern.adoptLegacyCatalog(device: legacy, keychain: keychain, in: fresh))
        #expect(ColorPattern.chosen(in: fresh) == "midnight")
        #expect((try? keychain.value(for: ColorPattern.key)) == nil)
        #expect(!ColorPattern.adoptLegacyCatalog(device: legacy, keychain: keychain, in: fresh), "only once")
    }

    @Test("The phone's choice comes from UserDefaults, also under the very old name")
    func phone() {
        let (legacy, name) = device()
        defer { legacy.removePersistentDomain(forName: name) }
        legacy.set("kontrast", forKey: ColorPattern.oldKey)
        let fresh = InMemoryStore()

        ColorPattern.adoptLegacyCatalog(device: legacy, keychain: InMemoryStore(), in: fresh)

        #expect(ColorPattern.chosen(in: fresh) == "contrast")
        #expect(legacy.string(forKey: ColorPattern.oldKey) == nil)
    }

    @Test("A choice already made wins, clearing happens anyway")
    func newOneWins() {
        let (legacy, name) = device()
        defer { legacy.removePersistentDomain(forName: name) }
        legacy.set("contrast", forKey: ColorPattern.key)
        let fresh = InMemoryStore()
        ColorPattern.select("midnight", in: fresh)

        #expect(!ColorPattern.adoptLegacyCatalog(device: legacy, keychain: InMemoryStore(), in: fresh))
        #expect(ColorPattern.chosen(in: fresh) == "midnight")
        #expect(legacy.string(forKey: ColorPattern.key) == nil)
    }
}
