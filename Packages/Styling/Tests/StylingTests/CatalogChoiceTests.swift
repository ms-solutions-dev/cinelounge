import Core
import SwiftUI
import Testing

@testable import Styling

/// **`Text(app:)` looks up in the catalog that carries the key** (AP58 final step).
///
/// Shared wordings have been in the catalog `WordingKit` since then; the views still pass
/// `LocalizedStringKey` through. Which catalog applies is stated at the key — and
/// SwiftUI only hands that out via reflection. If this check fails, the devices show
/// their key for every shared sentence.
@Suite("The catalog choice")
struct CatalogChoiceTests {

    @Test("The key comes from the LocalizedStringKey, also with format specifiers")
    func key() {
        let count = 3
        let name = "Anna"
        #expect(LocalizedStringKey("a.b").catalogKey == "a.b")
        let withFormat: LocalizedStringKey = "a.c \(count) \(name)"
        #expect(withFormat.catalogKey == "a.c %lld %@")
    }

    @Test("A shared key finds the shared catalog, one of the app finds the app's")
    func catalog() {
        let shared: LocalizedStringKey = "player.subtitleForced"
        #expect(shared.catalog == AppLanguageSetting.catalog(forItem: "player.subtitleForced"))
        #expect(shared.catalog != .main)
        #expect(LocalizedStringKey("login.connect").catalog == .main)
    }
}
