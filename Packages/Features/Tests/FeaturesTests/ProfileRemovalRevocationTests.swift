import Core
import Foundation
import ProfileKit
import Testing

@testable import Features

/// **Whoever removes a profile clears its open revocation** (counter-check strand D, 2.2).
///
/// The revocation itself has been tested since AP58 R2 in the `Household` package
/// (`TokenRevocationTests`); what remains here is what hangs on the TV's ``ProfileModel``.
@Suite("Revoke mark — removal on the TV")
@MainActor
struct ProfileRemovalRevocationTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()
    let childProfile = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Selin", color: .lilac,
        credentials: [.portals(person: "selin")])
    let max = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Max", color: .lilac,
        credentials: [.portals(person: "max")])
    let childRequest = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Emre", color: .lilac,
        credentials: [.portals(person: "emre")])

    func ledger(_ profileEntry: [Profile], active: Profile) {
        var ledger = ProfileBook()
        for profileName in profileEntry { ledger.create(profileName) }
        ledger.switchTo(zu: active.identifier)
        ledger.write(in: ledgers)
    }

    @Test("2.2: Whoever removes a profile clears its open revocation")
    func removalCleansUp() throws {
        ProfilePointer.als(nil) {
            let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
            defer { JoinNote(secureStore).forgetRevocation(childProfile.identifier) }
            ledger([childProfile, max], active: max)
            let model = ProfileModel(keychain: secureStore, store: ledgers)
            JoinNote(secureStore).rememberRevocation(childProfile.identifier)
            JoinNote(secureStore).rememberRevocation(max.identifier)
            model.remove(childProfile.identifier)
            #expect(JoinNote(secureStore).openRevocations == [max.identifier])
            JoinNote(secureStore).forgetRevocation(max.identifier)
        }
    }
}
