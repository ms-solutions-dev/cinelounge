import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// **On-device test 2026-09-28:** Home and channel history did not travel along.
@Suite("Document preference: Home and channel history via the cloud")
@MainActor
struct DocumentPreferenceTests {

    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ server: MockCloud) -> (ProfileCloud, InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: UUID().uuidString, name: "x", model: "Test rig"))
        var ledger = ProfileBook.read(from: store)
        ledger.create(Profile(identifier: identifier, name: "Max"))
        ledger.write(in: store)
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    private func history(_ entries: [(String, TimeInterval)]) -> String {
        let list = entries.map {
            DocumentPreference.HistoryEntry(name: $0.0, timestamp: Date(timeIntervalSince1970: $0.1))
        }
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try! writer.encode(list), encoding: .utf8)!
    }

    @Test("Home and channel history arrive on the other device")
    func arrives() async throws {
        let server = MockCloud()
        let (tv, tvAblage) = device(server)
        var order = ShelfOrder()
        order.order = ["resume", "movies"]
        order.write(in: tvAblage, forItem: identifier.rawValue)
        try tvAblage.set(
            history([("TR: AYAZ", 2000)]),
            for: ProfileStore.bucket("live.recentChannels", forItem: identifier.rawValue))
        let profile = try #require(ProfileBook.read(from: tvAblage).profile.first)
        await tv.reconcile(profile)

        let (phone, telefonAblage) = device(server)
        await phone.reconcile(profile)
        #expect(
            ShelfOrder.read(from: telefonAblage, forItem: identifier.rawValue)
                == ShelfOrder.read(from: tvAblage, forItem: identifier.rawValue))
        let arrived = try telefonAblage.value(
            for: ProfileStore.bucket("live.recentChannels", forItem: identifier.rawValue))
        #expect(arrived.contains("TR: AYAZ"))
    }

    @Test("The channel history is merged: the latest time per channel")
    func merged() throws {
        let here = history([("A", 100), ("B", 300)])
        let top = history([("A", 200), ("C", 50)])
        let fresh = try #require(DocumentPreference.merge(here: here, top: top))
        let list = try JSONDecoder().decode([DocumentPreference.HistoryEntry].self, from: Data(fresh.utf8))
        #expect(list.map(\.name) == ["B", "A", "C"])
        #expect(list.first { $0.name == "A" }?.timestamp == Date(timeIntervalSince1970: 200))
    }

    /// TV and phone each write one channel — on conflict both stay.
    @Test("On conflict the channel history is merged, not replaced")
    func conflictMerged() throws {
        let field = PreferenceMapping.valueField
        let tv = CloudRecord(
            contentType: PreferenceMapping.contentType, name: DocumentPreference.channelHistory,
            fields: [field: .text(history([("TR: AYAZ", 100)]))], changed: Date(timeIntervalSince1970: 100))
        let phone = CloudRecord(
            contentType: PreferenceMapping.contentType, name: DocumentPreference.channelHistory,
            fields: [field: .text(history([("TELVE 1", 200)]))], changed: Date(timeIntervalSince1970: 200))
        let merged = DocumentPreference.rule.merge(tv, phone)
        let text = try #require(merged[field]?.text)
        #expect(text.contains("TR: AYAZ") && text.contains("TELVE 1"))

        // Other preferences: the younger change.
        let a = CloudRecord(
            contentType: PreferenceMapping.contentType, name: "x", fields: [field: .text("alt")],
            changed: Date(timeIntervalSince1970: 1))
        let b = CloudRecord(
            contentType: PreferenceMapping.contentType, name: "x", fields: [field: .text("neu")],
            changed: Date(timeIntervalSince1970: 2))
        #expect(DocumentPreference.rule.merge(a, b)[field]?.text == "neu")
    }

    @Test("A move takes the channel history along")
    func moveCarriesHistory() throws {
        let store = InMemoryStore()
        let leaving = Profile.Identifier(rawValue: "geht")
        let remains = Profile.Identifier(rawValue: "bleibt")
        try store.set(
            history([("A", 100)]), for: ProfileStore.bucket("live.recentChannels", forItem: leaving.rawValue))
        try store.set(
            history([("B", 200)]), for: ProfileStore.bucket("live.recentChannels", forItem: remains.rawValue))
        ProfileMove.migrate(from: leaving, after: remains, ledgerStore: store, keychain: nil, startStore: nil)
        let text = try store.value(for: ProfileStore.bucket("live.recentChannels", forItem: remains.rawValue))
        #expect(text.contains("\"A\"") && text.contains("\"B\""))
        #expect(
            (try? store.value(for: ProfileStore.bucket("live.recentChannels", forItem: leaving.rawValue)))
                == nil)
    }

    @Test("A fresh profile without files sends nothing")
    func fresh() {
        #expect(DocumentPreference.values(from: InMemoryStore(), forItem: identifier.rawValue).isEmpty)
    }

    @Test("The store keys match Core")
    func key() {
        #expect(DocumentPreference.slots[DocumentPreference.shelfOrder] == ShelfOrder.key)
    }

    // MARK: - Wer gewinnt (29.09.2026)

    private func order(_ row: [String]) -> ShelfOrder {
        var order = ShelfOrder()
        order.order = row
        return order
    }

    /// The phone carries an older order from the time before the sync and starts after
    /// the TV — the TV's choice stays.
    @Test("An old order on the other device does not displace the chosen one")
    func oldOrderLoses() async throws {
        let server = MockCloud()
        let (tv, tvAblage) = device(server)
        order(["resume", "cl-ordner"]).write(in: tvAblage, forItem: identifier.rawValue)
        let profile = try #require(ProfileBook.read(from: tvAblage).profile.first)
        await tv.reconcile(profile)

        let (phone, telefonAblage) = device(server)
        order(["resume", "collections"]).write(in: telefonAblage, forItem: identifier.rawValue)
        await phone.reconcile(profile)

        #expect(
            ShelfOrder.read(from: telefonAblage, forItem: identifier.rawValue).order
                == ["resume", "cl-ordner"])
        await tv.reconcile(profile)
        #expect(
            ShelfOrder.read(from: tvAblage, forItem: identifier.rawValue).order
                == ["resume", "cl-ordner"])
    }

    @Test("A change on the phone arrives on the TV")
    func changeArrives() async throws {
        let server = MockCloud()
        let (tv, tvAblage) = device(server)
        order(["resume", "cl-ordner"]).write(in: tvAblage, forItem: identifier.rawValue)
        let profile = try #require(ProfileBook.read(from: tvAblage).profile.first)
        await tv.reconcile(profile)
        let (phone, telefonAblage) = device(server)
        await phone.reconcile(profile)

        order(["cl-ordner", "resume"]).write(in: telefonAblage, forItem: identifier.rawValue)
        await phone.reconcile(profile)
        await tv.reconcile(profile)

        #expect(
            ShelfOrder.read(from: tvAblage, forItem: identifier.rawValue).order
                == ["cl-ordner", "resume"])
    }

    @Test("A device without its own Home does not delete the order upstairs")
    func noDeletionWithoutFile() async throws {
        let server = MockCloud()
        let (tv, tvAblage) = device(server)
        order(["resume", "cl-ordner"]).write(in: tvAblage, forItem: identifier.rawValue)
        let profile = try #require(ProfileBook.read(from: tvAblage).profile.first)
        await tv.reconcile(profile)

        let (phone, telefonAblage) = device(server)
        await phone.reconcile(profile)
        await phone.reconcile(profile)

        #expect(
            ShelfOrder.read(from: telefonAblage, forItem: identifier.rawValue).order
                == ["resume", "cl-ordner"])
        let (third, dritteAblage) = device(server)
        await third.reconcile(profile)
        #expect(
            ShelfOrder.read(from: dritteAblage, forItem: identifier.rawValue).order
                == ["resume", "cl-ordner"])
    }

    // MARK: - Der Stand entscheidet

    private func message(_ text: String, state: Date?, changed: Date) -> CloudRecord {
        var fields: [String: FieldValue] = [PreferenceMapping.valueField: .text(text)]
        if let state { fields[DocumentPreference.stateField] = .date(state) }
        return CloudRecord(
            contentType: PreferenceMapping.contentType, name: DocumentPreference.shelfOrder, fields: fields,
            changed: changed)
    }

    private func fileStore(order text: String, written: Date) throws -> FileStore {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "dokument-\(UUID().uuidString)")
        let store = FileStore(folder: folder)
        let bucket = ProfileStore.bucket(ShelfOrder.key, forItem: identifier.rawValue)
        try store.set(text, for: bucket)
        let path = folder.appending(path: bucket + ".json").path
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: path)
        return store
    }

    /// The race of 2026-09-29: The phone syncs later than the TV, but its
    /// order is older. On conflict the younger **choice** wins.
    @Test("On conflict the younger choice wins, not the later sync")
    func conflictByState() {
        let tv = message(
            "tv", state: Date(timeIntervalSince1970: 2000), changed: Date(timeIntervalSince1970: 2000))
        let phone = message(
            "telefon", state: Date(timeIntervalSince1970: 1000), changed: Date(timeIntervalSince1970: 9000))
        #expect(DocumentPreference.rule.merge(phone, tv)[PreferenceMapping.valueField]?.text == "tv")
    }

    @Test("An older file does not go up if a younger choice is up there")
    func olderFileStaysBelow() throws {
        let store = try fileStore(order: "telefon", written: Date(timeIntervalSince1970: 1000))
        let top = message("tv", state: Date(timeIntervalSince1970: 2000), changed: Date())
        let wordings = DocumentPreference.wordings(
            here: DocumentPreference.values(from: store, forItem: identifier.rawValue),
            top: { $0 == DocumentPreference.shelfOrder ? top : nil },
            store: store, forItem: identifier.rawValue, now: Date())
        #expect(
            wordings.first { $0.name == DocumentPreference.shelfOrder }?[PreferenceMapping.valueField]?.text
                == "tv")
        let download = DocumentPreference.fromTop(
            [top], store: store, forItem: identifier.rawValue, now: Date())
        #expect(download.map(\.text) == ["tv"])
    }

    @Test("A younger file goes up and is not overwritten")
    func newerFileWins() throws {
        let store = try fileStore(order: "telefon", written: Date(timeIntervalSince1970: 3000))
        let top = message("tv", state: Date(timeIntervalSince1970: 2000), changed: Date())
        let wordings = DocumentPreference.wordings(
            here: DocumentPreference.values(from: store, forItem: identifier.rawValue),
            top: { $0 == DocumentPreference.shelfOrder ? top : nil },
            store: store, forItem: identifier.rawValue, now: Date())
        let own = try #require(wordings.first { $0.name == DocumentPreference.shelfOrder })
        #expect(own[PreferenceMapping.valueField]?.text == "telefon")
        #expect(own[DocumentPreference.stateField]?.date == Date(timeIntervalSince1970: 3000))
        #expect(
            DocumentPreference.fromTop([top], store: store, forItem: identifier.rawValue, now: Date()).isEmpty
        )
    }

    @Test("A record from before without a stamp loses against a file with a timestamp")
    func oldRecordWithoutState() throws {
        let store = try fileStore(
            order: "tv-mit-ordnern", written: Date(timeIntervalSince1970: 1000))
        let top = message("telefon-alt", state: nil, changed: Date())
        #expect(
            DocumentPreference.fromTop([top], store: store, forItem: identifier.rawValue, now: Date()).isEmpty
        )
    }

    // MARK: - Grabstein im Senderverlauf

    @Test("A forgotten channel does not come back from the other device")
    func forgottenStays() throws {
        let writer = JSONEncoder()
        let here = String(
            data: try writer.encode([
                DocumentPreference.HistoryEntry(
                    name: "TELVE 1", timestamp: nil, forgotten: Date(timeIntervalSince1970: 500))
            ]), encoding: .utf8)
        let top = history([("TELVE 1", 300), ("KOPRU HABER", 400)])
        let fresh = try #require(DocumentPreference.merge(here: here, top: top))
        let list = try JSONDecoder().decode([DocumentPreference.HistoryEntry].self, from: Data(fresh.utf8))
        #expect(list.first { $0.name == "TELVE 1" }?.timestamp == nil)
        #expect(list.first { $0.name == "KOPRU HABER" }?.timestamp == Date(timeIntervalSince1970: 400))

        // Later watching brings it back.
        let later = history([("TELVE 1", 600)])
        let reconnectCount = try #require(DocumentPreference.merge(here: fresh, top: later))
        let following = try JSONDecoder().decode(
            [DocumentPreference.HistoryEntry].self, from: Data(reconnectCount.utf8))
        #expect(following.first { $0.name == "TELVE 1" }?.timestamp == Date(timeIntervalSince1970: 600))
    }
}
