import Foundation
import Testing

@testable import Downloads

/// Where the files are and what they are called.
///
/// **The checks here are short and their subject is expensive.** A path that breaks on a
/// space has already cost this project once, on 2026-09-07 — `/var/mobile/Vorrat/Kobe Runaways ...`
/// became two paths, and neither of them existed.
@Suite("Store")
struct StoreTests {

    /// **No title in the file name.** An identifier has no spaces, no
    /// colons, no slashes and no umlauts — and therefore never needs a
    /// quotation mark that someone forgets.
    @Test("An identifier becomes a harmless file name")
    func harmlessName() {
        let name = Store.fileName(forItem: .init("animehub/elvaran staffel-1:folge 12"))
        #expect(!name.contains(" "))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".mp4"))
    }

    /// **The partial state has its own name.** Whoever wrote into the final file
    /// would after an abort have one that looks playable and stops in the middle of the film —
    /// and you notice that on the plane.
    @Test("The partial state can be told apart from the finished file")
    func partialState() {
        let k = DownloadJob.Identifier("x1")
        #expect(Store.partialName(forItem: k) != Store.fileName(forItem: k))
        #expect(Store.partialName(forItem: k).hasPrefix(Store.fileName(forItem: k)))
    }

    @Test("Different identifiers get different names")
    func different() {
        #expect(Store.fileName(forItem: .init("a")) != Store.fileName(forItem: .init("b")))
    }

    /// **Without this flag fourteen gigabytes go into the iCloud backup**, and the
    /// viewer learns about it from Apple.
    @Test("The folder is excluded from the backup")
    func fromBackup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try Store.folder(under: root)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// Creating twice is no error — the app starts more than once.
    @Test("The folder can be obtained twice")
    func twice() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Store.folder(under: root) == (try Store.folder(under: root)))
    }
}
