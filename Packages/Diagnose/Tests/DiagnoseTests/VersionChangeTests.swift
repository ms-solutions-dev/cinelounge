import Foundation
import Testing

@testable import Diagnose

@Suite("Version change")
struct VersionChangeTests {

    /// A separate store per test — the standard store belongs to the computer on which
    /// the tests run, and a test that writes into it changes its diagnostics.
    private func freshStore() -> (UserDefaults, String) {
        let name = "diagnose-check-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func freshLocation() -> URL {
        URL.temporaryDirectory.appending(path: "error-log-\(UUID().uuidString).jsonl")
    }

    /// The first run has no book yet — then the beginning too is a change.
    @Test("Without a remembered version a new log is started")
    func firstRun() {
        let (store, name) = freshStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(VersionChange.state(in: store) == nil)
        #expect(VersionChange.changes(to: "1.0 (57)", in: store))
    }

    /// The core of it all: **the same version keeps its book.** A reset on
    /// every launch would lose the log precisely when the app has crashed and
    /// restarted.
    @Test("The same version does not change, another one does")
    func remembersTheVersion() {
        let (store, name) = freshStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let started = Date(timeIntervalSince1970: 1_757_000_000)
        VersionChange.memorize(LogVersion(version: "1.0 (57)", started: started), in: store)

        #expect(!VersionChange.changes(to: "1.0 (57)", in: store))
        #expect(VersionChange.changes(to: "1.0 (58)", in: store))
        #expect(VersionChange.changes(to: "1.1 (57)", in: store))

        let state = VersionChange.state(in: store)
        #expect(state?.version == "1.0 (57)")
        #expect(state?.started == started)
    }

    /// Without this line a shared report would be undated — and the number in it worth
    /// nothing.
    @Test("The opening line names version and time")
    func openingNamesBoth() {
        let state = LogVersion(version: "1.0 (57)", started: .now)
        #expect(state.opening.contains("1.0 (57)"))
        #expect(state.label.contains("1.0 (57)"))
    }

    @Test("Started by hand, only the opening line remains")
    func restartsManually() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let ledger = ErrorLog(location: location)
        await ledger.note(
            ContentEntryRecord(area: .network, severity: .error, message: "from the day before yesterday"))
        #expect(await ledger.entries().count == 1)

        let state = await ledger.restart()
        let contained = await ledger.entries()
        #expect(contained.count == 1)
        #expect(contained.first?.message == state.opening)
        #expect(contained.first?.severity == .hint)
    }
}
