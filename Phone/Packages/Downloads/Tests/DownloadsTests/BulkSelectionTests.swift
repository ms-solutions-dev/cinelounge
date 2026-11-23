import Foundation
import Testing

@testable import Downloads

/// Several at once — **and the one rule on which a bulk delete fails.**
@Suite("Bulk selection")
struct BulkSelectionTests {

    private func job(_ name: String, gb: Double = 1) -> DownloadJob {
        DownloadJob(
            id: .init(name), title: name, source: .jellyfin, extent: .film,
            estimatedSize: Int64(gb * 1_000_000_000))
    }

    private var three: [DownloadJob] { [job("a"), job("b", gb: 3.1), job("c")] }

    /// **"All" means: all visible.** The downloads have five filters and a search field; whoever
    /// related "All" to the catalog would at the next press take along titles for which no
    /// row is on the screen.
    @Test("Select all picks only what was passed")
    func allIsVisible() {
        var selection = BulkSelection()
        selection.select(Array(three.prefix(2)))
        #expect(selection.count == 2)
        #expect(!selection.contains(.init("c")))
    }

    /// **A filter change must not let a selection survive** that is no longer visible.
    @Test("What is no longer there drops out of the selection")
    func restriction() {
        var selection = BulkSelection()
        selection.select(three)
        selection.restrictTo([job("b", gb: 3.1)])
        #expect(selection.chosen == [.init("b")])
    }

    /// **Closing clears.** A selection that lives on in hiding shows at the next
    /// expansion a number nobody set.
    @Test("Closing takes the selection along")
    func closingClears() {
        var selection = BulkSelection()
        selection.open()
        selection.select(three)
        selection.close()
        #expect(!selection.pending)
        #expect(selection.count == 0)
    }

    @Test("Toggling puts down and takes away again")
    func toggling() {
        var selection = BulkSelection()
        selection.toggle(.init("a"))
        #expect(selection.contains(.init("a")))
        selection.toggle(.init("a"))
        #expect(!selection.contains(.init("a")))
    }

    /// **The quantity is always shown** — the rule from ``Cleanup``.
    @Test("The release counts only the chosen rows")
    func approval() {
        var selection = BulkSelection()
        selection.toggle(.init("b"))
        #expect(selection.approval(from: three) == 3_100_000_000)
    }

    /// **An identifier without a row does not count.** It can only come from a state
    /// that no longer exists; counting it would promise room that does not get freed.
    @Test("An identifier without a row brings nothing")
    func releaseWithoutRow() {
        var selection = BulkSelection()
        selection.toggle(.init("weg"))
        #expect(selection.approval(from: three) == 0)
    }

    @Test("Watched are the watched among the visible")
    func watchedJobs() {
        let match = BulkSelection.watchedJobs(
            from: three, watchedIDs: [.init("a"), .init("c"), .init("gibtEsNicht")])
        #expect(match.map(\.id.rawValue) == ["a", "c"])
    }

    /// **What is still loading is never included.** Whoever has watched an episode to the end via the server
    /// and then queues it for the flight would otherwise lose it with one press — in the middle of
    /// loading. "Watched" describes the viewer, not the file.
    @Test("What is still loading is not taken along by \"Remove watched\"")
    func runningStays() {
        let match = BulkSelection.watchedJobs(
            from: three, watchedIDs: [.init("a"), .init("c")],
            isRunning: [Transfer(id: .init("a"), state: .isLoading)])
        #expect(match.map(\.id.rawValue) == ["c"])
    }

    /// A **finished** transfer is not a running one — it is only still in the list
    /// because the row shows its last state.
    @Test("A finished transfer holds nothing back")
    func finishedDoesNotCount() {
        let match = BulkSelection.watchedJobs(
            from: three, watchedIDs: [.init("a")],
            isRunning: [Transfer(id: .init("a"), state: .done)])
        #expect(match.map(\.id.rawValue) == ["a"])
    }
}
