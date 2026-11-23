import CloudSync
import Core
import Foundation
import ProfileKit
import Testing
import WordingKit

@testable import Flows

/// "Delete all my iCloud data" — on-device test build 1332, finding 10.
@Suite("Finding 10 · Delete all iCloud data")
@MainActor
struct CloudDataDeletionTests {

    let server = MockCloud()

    func cloud(store: InMemoryStore) -> ProfileCloud {
        ProfileCloud(
            hub: CloudHub(
                service: server.credential("alex"), file: nil,
                device: DeviceDescription(identifier: "t", name: "t", model: "Test rig")),
            store: store, moveBundle: InMemoryStore(), automatic: false)
    }

    @Test("Deletes the zones and clears the ledger — the state says how many")
    func deletes() async {
        let store = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(identifier: .init(rawValue: UUID().uuidString), name: "Test"))
        ledger.write(in: store)
        let cloud = cloud(store: store)
        await cloud.syncAll()
        #expect(server.zoneList().count == 1)

        let flow = CloudDataDeletion(cloud: { cloud })
        #expect(flow.available)
        await flow.delete()
        #expect(flow.state == .done(zones: 1))
        #expect(server.zoneList().isEmpty && ProfileBook.read(from: store).profile.isEmpty)
    }

    @Test("Without network or account: a sentence that says what to do")
    func fails() async {
        let cloud = cloud(store: InMemoryStore())
        server.reachable = false
        let flow = CloudDataDeletion(cloud: { cloud })
        await flow.delete()
        #expect(flow.state == .failed(message: "profiles.icloudDelete.offline"))

        let without = CloudDataDeletion(cloud: { nil })
        #expect(!without.available)
        await without.delete()
        #expect(without.state == .failed(message: "profiles.icloudDelete.noAccount"))
    }

    @Test("Every sentence of the confirmation prompt is in the shared catalog, in all three languages")
    func wordings() {
        let error: [CloudError] = [
            .noAccount, .unreachable, .zoneMissing, .deletedByUser, .rejected("x"),
            .other("y"),
        ]
        let key =
            error.map(CloudDataDeletion.message(forItem:))
            + ["", ".text", ".confirm", ".do", ".running", ".done"].map { "profiles.icloudDelete" + $0 }
        for entry in key {
            #expect(WordingKit.hasKey(entry), "\(entry)")
            for language in ["de", "en", "tr"] {
                let message = WordingKit.text(String.LocalizationValue(entry), language: language)
                #expect(message != entry, "\(entry) \(language)")
            }
        }
    }
}
