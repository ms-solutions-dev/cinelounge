import Foundation
import Testing

@testable import Core

/// **The structure survives the clearing of the cache** (2026-10-03): On the TV it
/// lives in Caches, and tvOS may empty Caches.
@Suite("Store backup")
struct StoreBackupTests {

    private func newStore() -> (FileStore, URL, UserDefaults) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "store-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "store-backup-\(UUID().uuidString)"
        let backup = UserDefaults(suiteName: suite)!
        return (FileStore(folder: folder, backup: backup), folder, backup)
    }

    @Test("A cleared folder comes back from the backup, with the old modification time")
    func clearedFolderComesBack() throws {
        let (store, folder, _) = newStore()
        try store.set("{\"regal\":[1,2,3]}", for: "regalordnung")
        let previous = try #require(store.changed("regalordnung"))

        try FileManager.default.removeItem(at: folder)  // the system clears

        #expect(try store.value(for: "regalordnung") == "{\"regal\":[1,2,3]}")
        let following = try #require(store.changed("regalordnung"))
        #expect(abs(following.timeIntervalSince(previous)) < 1, "restored does not count as freshly changed")
    }

    @Test("Deleted is deleted — also in the backup")
    func deletionHitsBoth() throws {
        let (store, folder, _) = newStore()
        try store.set("x", for: "pin")
        try store.remove("pin")
        try? FileManager.default.removeItem(at: folder)
        #expect(throws: SecureStore.Failure.notFound) { try store.value(for: "pin") }
    }

    @Test("Oversized stays only in the file, and an old state disappears from the backup")
    func oversizedIsDropped() throws {
        let (store, folder, _) = newStore()
        try store.set("klein", for: "bild")
        try store.set(String(repeating: "a", count: StoreBackup.entryLimit + 1), for: "bild")
        try FileManager.default.removeItem(at: folder)
        #expect(throws: SecureStore.Failure.notFound) { try store.value(for: "bild") }
    }

    /// **The still-frame ledger fits** (AP71, 2026-10-11): indented JSON just over the
    /// limit is saved compactly and comes back after the clearing as the same JSON.
    @Test("Indented JSON over the limit is backed up compactly")
    func backedUpCompactly() throws {
        let (store, folder, _) = newStore()
        let entries = (0..<2200).map { ["id": "titel-\($0)", "stelle": "\($0 * 7)"] }
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        let pretty = String(data: try writer.encode(["journal": entries]), encoding: .utf8)!
        #expect(pretty.utf8.count > StoreBackup.entryLimit, "\(pretty.utf8.count) Bytes")
        #expect(StoreBackup.compact(pretty).utf8.count <= StoreBackup.entryLimit)
        try store.set(pretty, for: "stand.p1")
        try FileManager.default.removeItem(at: folder)
        let back = try store.value(for: "stand.p1")
        let read = try JSONDecoder().decode([String: [[String: String]]].self, from: Data(back.utf8))
        #expect(read["journal"] == entries)
    }

    @Test("What is not JSON stays as it is")
    func noJSON() {
        #expect(StoreBackup.compact("a\tb") == "a\tb")
    }

    @Test("The budget holds")
    func budgetHolds() throws {
        let (store, folder, backup) = newStore()
        let storeName = folder.lastPathComponent
        let block = String(repeating: "b", count: StoreBackup.entryLimit)
        for i in 0..<20 { try store.set(block, for: "eintrag\(i)") }
        let backedUp = (0..<20).filter { backup.data(forKey: "ablage§\(storeName)§eintrag\($0)") != nil }
        #expect(!backedUp.isEmpty)
        #expect(backedUp.count * StoreBackup.entryLimit <= StoreBackup.budget)
    }
}
