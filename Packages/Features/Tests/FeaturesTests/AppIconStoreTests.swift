import Foundation
import Testing

@testable import Features

/// The choice of the app icon.
///
/// What is tested here is only what the app decides — not whether tvOS really swaps the
/// icon. That was measured on the simulator on 2026-08-29 and is in the roadmap; a rule
/// cannot verify it, because the swap lies behind a system dialog.
///
/// The one rule that really prevents harm is the last: Whoever dismisses the prompt
/// must **not** see the new tile as chosen. Exactly this case occurred during the
/// trial — without confirmation the base icon was back after a restart.
@MainActor
@Suite("Choosing the app icon")
struct AppIconStoreTests {

    /// A system that records instead of swapping.
    final class FakeIcons: AppIconSwitching {

        var supportsAlternateIcons: Bool
        var currentIconName: String?
        /// What was requested in sequence — including the `nil` for the base icon.
        var requested: [String?] = []
        var error: Error?

        init(supports: Bool = true, current: String? = nil) {
            supportsAlternateIcons = supports
            currentIconName = current
        }

        func setIcon(_ name: String?) async throws {
            requested.append(name)
            if let error { throw error }
            currentIconName = name
        }
    }

    private func icon(_ id: String) -> AppIcon {
        try! #require(AppIconStore.all.first { $0.id == id })
    }

    @Test("Without an alternate icon the default icon applies")
    func baseSymbol() {
        let downloads = AppIconStore(system: FakeIcons())

        #expect(downloads.current.id == "original")
        #expect(downloads.current.alternateName == nil)
        #expect(downloads.isSupported)
    }

    @Test("An alternate icon that is already set is recognized")
    func existingRecognized() {
        let downloads = AppIconStore(system: FakeIcons(current: "SymbolBogen"))

        #expect(downloads.current.id == "SymbolBogen")
    }

    @Test("The choice passes the name of the image stack through")
    func choiceIsPassedThrough() async {
        let system = FakeIcons()
        let downloads = AppIconStore(system: system)

        await downloads.choose(icon("SymbolSessel"))

        #expect(system.requested == ["SymbolSessel"])
        #expect(downloads.current.id == "SymbolSessel")
    }

    /// The base icon has no image stack of its own — the way back is `nil`.
    @Test("Back to original sends nil")
    func backToOriginal() async {
        let system = FakeIcons(current: "SymbolNegativ")
        let downloads = AppIconStore(system: system)

        await downloads.choose(icon("original"))

        #expect(system.requested == [nil])
        #expect(downloads.current.id == "original")
    }

    @Test("The same icon again triggers nothing")
    func sameSymbol() async {
        let system = FakeIcons(current: "SymbolBogen")
        let downloads = AppIconStore(system: system)

        await downloads.choose(icon("SymbolBogen"))

        #expect(system.requested.isEmpty)
    }

    /// The case this test mainly exists for.
    @Test("A declined confirmation leaves the state as it was")
    func rejected() async {
        let system = FakeIcons(current: "SymbolSessel")
        system.error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let downloads = AppIconStore(system: system)

        await downloads.choose(icon("SymbolNegativ"))

        #expect(system.requested == ["SymbolNegativ"])
        #expect(downloads.current.id == "SymbolSessel", "the tile must not jump ahead")
    }

    @Test("Without support the selection stays off")
    func withoutSupport() {
        let downloads = AppIconStore(system: FakeIcons(supports: false))

        #expect(!downloads.isSupported)
    }

    @Test("Every icon has a preview image and a name of its own")
    func complete() {
        let names = Set(AppIconStore.all.map(\.id))
        let previews = Set(AppIconStore.all.map(\.preview))

        #expect(names.count == AppIconStore.all.count)
        #expect(previews.count == AppIconStore.all.count)
        #expect(AppIconStore.all.filter { $0.alternateName == nil }.count == 1)
    }
}
