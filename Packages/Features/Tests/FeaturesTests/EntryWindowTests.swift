import Foundation
import Testing

@testable import Features

/// The entry window of the sidebar — AP4 · K9.
///
/// **The finding:** The wait ran in a `.task` of the sidebar, and that runs again at every
/// rebuild of its view identity — after every return from the search the sidebar was dead
/// for a quarter of a second, with no reason for it.
@Suite("The entry window")
@MainActor
struct EntryWindowTests {

    /// It runs out once and then stays open — even if the sidebar rebuilds itself ten times.
    @Test("It expires exactly once")
    func runsOnlyOnce() async {
        let window = EntryWindow()
        #expect(!window.over)

        await window.open()
        #expect(window.over)

        // The second build does not wait again — measurable by it returning immediately and the
        // state being in place.
        let previous = Date()
        await window.open()
        #expect(Date().timeIntervalSince(previous) < 0.05)
        #expect(window.over)
    }

    /// **The duration stays where it was.** The point was not the length but how often it
    /// applies — a shorter wait would have let the initial focus wander back into the sidebar.
    @Test("A quarter second, unchanged")
    func durationUnchanged() {
        #expect(EntryWindow.duration == .milliseconds(250))
    }
}
