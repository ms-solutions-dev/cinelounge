import Foundation
import Testing

@testable import Core

/// The third store — **for structure**, AP40, 2026-09-20.
///
/// It closes the gap in the rule from `README.md`: For "secrets" there was the
/// Keychain, for "transient data" the cache — and for lists, orderings
/// and mappings there was nothing. Because both somehow work, every screen took
/// something different, and that is exactly how the sixteen cases of the feature comparison
/// came about.
@Suite("The file store")
struct FileStoreTests {

    private func freshFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "filestore-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("Write, read, delete")
    func roundTrip() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileStore(folder: folder)

        try store.set("[\"a\",\"b\"]", for: "shelves.order")
        #expect(try store.value(for: "shelves.order") == "[\"a\",\"b\"]")

        try store.remove("shelves.order")
        #expect(throws: SecureStore.Failure.notFound) { try store.value(for: "shelves.order") }
    }

    @Test("The folder does not exist beforehand — and that is not an error")
    func createsTheFolder() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // The first launch after a fresh install: Application Support has no
        // folder for this program yet. A failure here would mean that the first
        // setting is lost — and silently at that.
        try FileStore(folder: folder).set("x", for: "first.setting")
        #expect(try FileStore(folder: folder).value(for: "first.setting") == "x")
    }

    @Test("Writing replaces completely and does not append")
    func replacesCompletely() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileStore(folder: folder)

        try store.set("[\"a\",\"b\",\"c\"]", for: "list")
        try store.set("[\"a\"]", for: "list")

        // A half-overwritten list would be worse than a missing one: It looks
        // valid.
        #expect(try store.value(for: "list") == "[\"a\"]")
    }

    @Test("Deleting what does not exist is not an error")
    func deletingIsLenient() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Otherwise every caller needs a `try?` — and that also swallows the
        // real failures.
        try FileStore(folder: folder).remove("doesNotExist")
    }

    @Test("A slash in the key does not create a subfolder")
    func keyWithSlash() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileStore(folder: folder)

        try store.set("value", for: "portal/level")

        #expect(try store.value(for: "portal/level") == "value")
        // Exactly one file, no directory level below it.
        let content = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(content == ["portal_level.json"])
    }

    @Test("Two stores in the same folder see the same thing")
    func twoStoresOneFolder() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // The normal case in operation: Two components independently create a
        // store. It is a pointer to a folder and holds no state.
        try FileStore(folder: folder).set("yes", for: "marker")
        #expect(try FileStore(folder: folder).value(for: "marker") == "yes")
    }
}
