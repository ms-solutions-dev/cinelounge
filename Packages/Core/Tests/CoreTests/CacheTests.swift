import Foundation
import Testing

@testable import Core

/// **What the app has lying on the disk** (AP18, 2026-09-02).
///
/// On a TV with 32 gigabytes this is no side issue. Two
/// things decide here: that the inventory is **complete** — otherwise it
/// does not answer the question for which someone looks — and that the
/// cleanup **leaves** the diagnostic log **standing**.
@Suite("Cache: usage and clean-up")
struct CacheTests {

    /// A throwaway directory with predefined content.
    private func folder(_ files: [String: Int]) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (name, bytes) in files {
            let target = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: target)
        }
        return base
    }

    @Test("Every item appears with its size")
    func everyItemIsListed() throws {
        let base = try folder([
            "cinelounge-live.sqlite": 1000,
            "cinelounge-live.sqlite-wal": 500,
            "cinelounge-folgen-abc.json": 300,
            "cinelounge-spur.log": 200,
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let catalog = TransientCache.catalog(in: base)
        let after = Dictionary(uniqueKeysWithValues: catalog.map { ($0.nameKey, $0.bytes) })

        // The companion files of the database count as part of it — they are it.
        #expect(after["cache.channels"] == 1500)
        #expect(after["cache.episodes"] == 300)
        #expect(after["cache.diagnostics"] == 200)
        // The biggest item first: whoever looks wants to find the lump.
        #expect(catalog.first?.nameKey == "cache.channels")
    }

    /// **The inventory must not name less than the disk yields.**
    /// What fits no pattern appears as "Other" instead of disappearing.
    @Test("Unknown files do not vanish from the listing")
    func unknownFilesAreStillCounted() throws {
        let base = try folder(["irgendwas-fremdes.bin": 777])
        defer { try? FileManager.default.removeItem(at: base) }

        let catalog = TransientCache.catalog(in: base)
        #expect(catalog.count == 1)
        #expect(catalog[0].nameKey == "cache.other")
        #expect(catalog[0].bytes == 777)
    }

    /// The list digests lie as a directory — a measurement that only counts
    /// files would report zero there.
    @Test("A directory is measured with everything in it")
    func directoriesAreMeasuredRecursively() throws {
        let base = try folder([
            "CineLounge/Lists/abc/eins.json": 400,
            "CineLounge/Lists/abc/zwei.json": 600,
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let catalog = TransientCache.catalog(in: base)
        #expect(catalog.first { $0.nameKey == "cache.lists" }?.bytes == 1000)
    }

    // MARK: - Clean-up

    /// **The log stays.** It is the only thing here that cannot be
    /// restored — whoever is investigating an error right now would throw it away
    /// with the cleanup.
    @Test("Clean-up takes the extracts along and leaves both traces")
    func clearingKeepsBothTraces() throws {
        let base = try folder([
            "cinelounge-live.sqlite": 1000,
            "cinelounge-folgen-abc.json": 300,
            "cinelounge-spur.log": 200,
            "cinelounge-fehler.log": 100,
            "CineLounge/Lists/abc/eins.json": 400,
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let unrestricted = TransientCache.cleanUp(in: base)

        #expect(unrestricted == 1700)
        let remaining = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
        #expect(remaining == ["cinelounge-spur.log", "cinelounge-fehler.log"])
    }

    @Test("An empty directory yields nothing and frees nothing")
    func emptyDirectoryIsNoWork() throws {
        let base = try folder([:])
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(TransientCache.catalog(in: base).isEmpty)
        #expect(TransientCache.cleanUp(in: base) == 0)
    }

    /// Without a directory nothing is claimed — and nothing deleted.
    @Test("Without a directory nothing happens")
    func withoutDirectoryNothingHappens() {
        #expect(TransientCache.catalog(in: nil).isEmpty)
        #expect(TransientCache.cleanUp(in: nil) == 0)
    }
}
