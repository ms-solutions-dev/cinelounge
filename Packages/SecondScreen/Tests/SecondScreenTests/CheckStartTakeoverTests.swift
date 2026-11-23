import Core
import Foundation
import PlaylistKit
import Testing

@testable import SecondScreen

/// Check agent `start`: the shelf order from the bundle has to land where Home reads — in
/// the order of the active profile.
@MainActor
struct CheckStartTakeoverTests {

    @Test("With an active profile the shelf order arrives in that profile's order")
    func orderIntoActiveProfile() {
        ProfilePointer.als("anna") {
            let name = "probe.\(UUID().uuidString)"
            let shelves = InMemoryStore()
            let takeover = Takeover(
                keychain: SecureStore(service: name),
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                trust: CertificateTrustStore(store: InMemoryStore()),
                store: UserDefaults(suiteName: name) ?? .standard,
                shelfStore: shelves, ledgerStore: InMemoryStore())

            let report = takeover.matches(
                code: SetupBundle(shelfOrder: ["live", "resume", "portale"]))

            #expect(report.shelves == 3)
            // This is how Home reads on the TV (HomeModel.load).
            #expect(
                ShelfPreferences.load(from: shelves, forItem: ProfilePointer.active).order
                    == ["live", "resume", "portale"])
        }
    }
}
