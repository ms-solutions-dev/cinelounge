import Foundation
import Testing

@testable import FeaturesPhone

/// The items of the storage screen.
///
/// **The finding of 2026-09-12, visible in the requester's screenshot:** In the
/// cleanup row "Image cache" it said `246 kB`, in the legend above it "Image cache
/// 80 MB" — and `246 kB` was the value of the **downloads**. Two places accessed an ordered
/// list with `.first`, and the first item is the downloads.
///
/// The second place was the worse one: Cleanup measured before and after on the downloads,
/// which it does not touch — the message "this much was freed" was therefore always zero.
@Suite("The storage items")
struct SavedStateTests {

    /// **Every item must be findable by its ID.** A position is not an
    /// ID: The order is a matter of display, and whoever changes it should not
    /// shift two numbers in other places.
    @Test("Without knowledge of the downloads they stay a single number")
    func identifiersWithoutKnowledge() {
        let items = StorageUsage.items()
        let identifiers = items.map(\.id)
        #expect(identifiers.count == 4)
        for expected in ["storage.stock", "storage.images", "storage.log", "storage.other"] {
            #expect(identifiers.contains(expected), "Item \(expected) is missing")
        }
        // No two items with the same ID — otherwise looking up would be as shaky
        // as counting.
        #expect(Set(identifiers).count == identifiers.count)
    }

    /// **With knowledge the downloads split into three parts** — finding of 2026-09-12: "in
    /// storage, contents should be separated by type".
    @Test("With knowledge the downloads split into videos, details and leftovers")
    func identifiersWithKnowledge() {
        let items = StorageUsage.items(
            downloads: .init(videos: ["abc"], details: ["angabe"]))
        let identifiers = items.map(\.id)
        #expect(identifiers.contains("storage.videos"))
        #expect(identifiers.contains("storage.details"))
        #expect(identifiers.contains("storage.orphans"))
        // And then not once more as a whole — that would be counted twice.
        #expect(identifiers.contains("storage.stock") == false)
        #expect(Set(identifiers).count == identifiers.count)
    }

    /// **No knowledge is not the same as "nothing there".** Without a set-up download store
    /// every file would be "orphaned" — a claim nobody has substantiated.
    @Test("Empty knowledge carries no knowledge")
    func emptyKnowledge() {
        let items = StorageUsage.items(downloads: .unknown)
        #expect(items.map(\.id).contains("storage.stock"))
        #expect(items.map(\.id).contains("storage.orphans") == false)
    }

    /// The assignment itself, without a disk: What the downloads know is not a remainder.
    @Test("Every file lands in exactly one bucket")
    func assignment() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "storage-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func create(_ name: String, _ bytes: Int) throws {
            try Data(repeating: 7, count: bytes).write(to: folder.appending(path: name))
        }
        try create("film", 4096)
        try create("plakat", 2048)
        try create("nieGehoert", 1024)

        let after = StorageUsage.splitSizes(
            in: folder, .init(videos: ["film"], details: ["plakat"]))
        // Occupied sizes are block sizes — the assignment is checked, not the number.
        #expect(after.videos > 0)
        #expect(after.details > 0)
        #expect(after.orphaned > 0)
        #expect(after.videos >= after.details)
    }

    /// **The downloads stay, everything else is cache.** Exactly this
    /// promise is on the screen, and it hangs on a flag.
    @Test("Only the downloads remain")
    func onlyDownloadsRemain() throws {
        let items = StorageUsage.items()
        let downloads = try #require(items.first { $0.id == "storage.stock" })
        #expect(downloads.remains)
        for other in items where other.id != "storage.stock" {
            #expect(other.remains == false, "\(other.id) claims to remain")
        }
    }

    /// **The downloads come first, and nothing relies on that any more.** The check holds
    /// the order so that a change gets noticed — but since 2026-09-12 the display
    /// looks up by ID, not by position.
    @Test("The first item is the downloads and not the image cache")
    func order() {
        #expect(StorageUsage.items().first?.id == "storage.stock")
        #expect(StorageUsage.items().first?.id != "storage.images")
    }
}
