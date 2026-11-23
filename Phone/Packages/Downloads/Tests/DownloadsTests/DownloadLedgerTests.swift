import Core
import Foundation
import Testing

@testable import Downloads

/// What the downloads keep across a restart.
///
/// **Without the ledger not even the list survives.** Until 2026-09-08 the manager held the jobs
/// only in memory; whoever quit the app afterwards had fourteen gigabytes on the
/// disk and no row that knows about them — exactly the files that
/// ``Cleanup/orphaned(files:known:)`` later finds and nobody can assign any more.
@Suite("Download ledger")
struct DownloadLedgerTests {

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func job(_ name: String) -> DownloadJob {
        DownloadJob(
            id: .init(name), title: name, beside: "Jellyfin",
            source: .jellyfin, extent: .season(number: 2, episodes: 8),
            tier: .low, estimatedSize: 4_900_000_000)
    }

    @Test("What was written comes back")
    func thereAndBack() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DownloadLedger(folder: folder)

        ledger.write([Self.job("a"), Self.job("b")])
        #expect(ledger.read().count == 2)
        #expect(ledger.read().first?.extent == .season(number: 2, episodes: 8))
    }

    /// **The host is stored under `host`.** A changed key would let every stored portal job lose
    /// its source silently — `host` is optional and decodes to `nil`.
    @Test("The host of a portal job is stored under host")
    func hostKey() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DownloadLedger(folder: folder)
        ledger.write([
            DownloadJob(
                id: .init("beispiel|x|/film/1"), title: "Invented Film", source: .portal,
                extent: .film, host: "Examplehost", version: "English")
        ])

        let raw = try Data(contentsOf: folder.appendingPathComponent(DownloadLedger.fileName))
        let rows = try #require(try JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        #expect(rows.first?["host"] as? String == "Examplehost")
        #expect(ledger.read().first?.host == "Examplehost")
    }

    /// **The first start has no ledger, and that is no error.**
    @Test("Without a file an empty list comes")
    func withoutFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DownloadLedger(folder: folder).read().isEmpty)
    }

    /// **An unreadable ledger is no reason not to start the app.** It is a reason
    /// to begin empty and write it down — the files are still there, and
    /// "Reconcile" finds them. Whoever threw here would turn a broken row into a
    /// screen that no longer opens at all.
    @Test("A broken ledger does not throw, it starts empty")
    func brokenLedger() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ das ist kein JSON".utf8)
            .write(to: folder.appendingPathComponent(DownloadLedger.fileName))

        #expect(DownloadLedger(folder: folder).read().isEmpty)
    }

    /// **Next to it first, then rename.** A write that the system ends midway
    /// would otherwise leave a half file — unreadable at the next start, so the whole
    /// list gone. What is checked is what remains of it: **no leftovers.**
    @Test("After writing no half file lies beside it")
    func noLeftovers() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DownloadLedger(folder: folder).write([Self.job("a")])

        let contained = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(contained == [DownloadLedger.fileName])
    }

    /// **Writing twice replaces and does not accumulate.**
    @Test("The second write replaces the first")
    func replaces() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DownloadLedger(folder: folder)

        ledger.write([Self.job("a"), Self.job("b")])
        ledger.write([Self.job("c")])
        #expect(ledger.read().map(\.title) == ["c"])
    }

    /// **The information against which it is checked after the restart must come along.** Without it
    /// it could no longer be determined whether the same file lies at the other end — and
    /// ``BackgroundSession`` would start every job from scratch.
    @Test("A portal job keeps host and version")
    func portalKeepsEverything() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DownloadLedger(folder: folder)

        var job = Self.job("p")
        job.host = "HOSTA"
        job.version = "(DE)"
        ledger.write([job])

        let back = try #require(ledger.read().first)
        #expect(back.host == "HOSTA")
        #expect(back.version == "(DE)")
    }
}
