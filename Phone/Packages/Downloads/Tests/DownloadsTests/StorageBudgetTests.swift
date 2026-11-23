import Foundation
import Testing

@testable import Downloads

/// Six items, one truth.
///
/// **The finding from which this type arose:** Two authors had independently each
/// built a storage screen — 1.4 GB versus 17.9 GB for the same phone. Whoever
/// found the first read "CineLounge uses 1.4 GB", cleaned up elsewhere, and next to it lay
/// 14.8 GB of films.
@Suite("Storage budget")
struct StorageBudgetTests {

    private static let gb: Int64 = 1024 * 1024 * 1024

    private static func household(unrestricted: Int64) -> StorageBudget {
        StorageBudget(
            items: [
                LineItem(kind: .downloads, bytes: 14 * gb),
                LineItem(kind: .frames, bytes: 2 * gb),
                LineItem(kind: .channelsAndGuide, bytes: 412 * 1024 * 1024),
                LineItem(kind: .diagnosticTraces, bytes: 14 * 1024 * 1024),
            ], unrestricted: unrestricted)
    }

    /// **Only the downloads stay.** Everything else comes back — that is not a judgment
    /// but the information that is missing before the cleanup.
    @Test("Only the downloads remain standing")
    func onlyDownloadsRemain() {
        #expect(LineItem(kind: .downloads, bytes: 1).remains)
        for kind in LineItem.Kind.allCases where kind != .downloads {
            #expect(!LineItem(kind: kind, bytes: 1).remains, "\(kind) must not stay")
        }
    }

    /// **A cleanup that takes films along is a deletion** — and deleting asks first.
    @Test("Cleaning up does not touch the downloads")
    func cleanupKeepsDownloads() {
        let h = Self.household(unrestricted: 40 * Self.gb)
        #expect(h.reclaimable == h.taken - h.downloads)
        #expect(Cleanup.approval(h.items) == h.reclaimable)
    }

    /// **Asked beforehand and not at ninety percent.** Whoever is packing for a flight should
    /// learn it while packing and not at the gate.
    @Test("What does not fit does not fit beforehand")
    func doesNotFit() {
        let h = Self.household(unrestricted: 5 * Self.gb)
        #expect(h.matches(2 * Self.gb))
        #expect(!h.matches(4 * Self.gb))
    }

    /// **The reserve is not arbitrary.** iOS tidies up itself when space is tight, and
    /// what it takes first looks like cache. Downloads that fill the device down to
    /// the last remainder endanger themselves.
    @Test("Reserve is left over")
    func reserve() {
        let h = Self.household(unrestricted: 3 * Self.gb)
        #expect(!h.matches(2 * Self.gb))
        #expect(StorageBudget.reserve == 2 * Self.gb)
    }

    /// **"Reconcile" finds files that nobody knows about any more.** The case does not arise
    /// through negligence but through aborts.
    @Test("Orphaned files are found")
    func orphaned() {
        // Without a dot in the name: `scripts/strings.py` would take `a.mp4` for a
        // catalog key, and the checker would be right — you cannot tell from a string
        // what it is for.
        let onDisk: Set<String> = ["datei-a", "datei-b", "datei-c"]
        let known: Set<String> = ["datei-a", "datei-c"]
        #expect(Cleanup.orphaned(files: onDisk, known: known) == ["datei-b"])
    }

    @Test("Without orphans nothing is left over")
    func noOrphans() {
        #expect(Cleanup.orphaned(files: ["a"], known: ["a", "b"]).isEmpty)
    }
}
