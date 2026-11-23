import Foundation
import Testing

@testable import Diagnose

@Suite("Error log")
struct ErrorLogTests {

    private func freshLocation() -> URL {
        URL.temporaryDirectory.appending(path: "error-log-\(UUID().uuidString).jsonl")
    }

    @Test("What is written in is in there")
    func writeAndRead() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let ledger = ErrorLog(location: location)
        await ledger.note(ContentEntryRecord(area: .network, severity: .error, message: "no network"))
        await ledger.note(ContentEntryRecord(area: .downloads, severity: .abort, message: "aborted"))

        let contained = await ledger.entries()
        #expect(contained.count == 2)
        #expect(contained.first?.message == "no network")
        #expect(contained.last?.area == .downloads)
    }

    /// The reason this package exists at all: the ring buffer in `Core`
    /// does not survive an app launch, and on a phone termination is the
    /// normal case.
    @Test("The log survives an app launch")
    func survivesRestart() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let previous = ErrorLog(location: location)
        await previous.note(ContentEntryRecord(area: .playback, severity: .error, message: "cut off"))

        // A second book on the same file is as much of a restart as can be tested.
        let after = ErrorLog(location: location)
        let contained = await after.entries()
        #expect(contained.count == 1)
        #expect(contained.first?.message == "cut off")
    }

    @Test("Ordinary steps appear only with verbose recording")
    func rule() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let ledger = ErrorLog(location: location)
        await ledger.note(ContentEntryRecord(area: .network, severity: .step, message: "Step"))
        await ledger.note(ContentEntryRecord(area: .network, severity: .error, message: "Error"))
        #expect(await ledger.entries().count == 1)

        await ledger.setVerbose(true)
        await ledger.note(ContentEntryRecord(area: .network, severity: .step, message: "Step"))
        #expect(await ledger.entries().count == 2)
    }

    /// Redaction happens on writing, not at the call site — a rule that every
    /// call site would have to apply itself gets forgotten at one of them.
    @Test("The sentence is already redacted in the log")
    func redactsWhenWriting() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let ledger = ErrorLog(location: location)
        await ledger.note(
            ContentEntryRecord(
                area: .network, severity: .error,
                message: "Abort at http://line.provider.tv/live/jdoe/secret123/1.ts"))

        let contained = await ledger.entries()
        #expect(contained.count == 1)
        #expect(!(contained.first?.message.contains("secret123") ?? true))
    }

    @Test("Cleanup throws away what should no longer stay")
    func cleansUp() async throws {
        let location = freshLocation()
        defer { try? FileManager.default.removeItem(at: location) }

        let ledger = ErrorLog(location: location)
        let old = Date().addingTimeInterval(-(Cleanup.maxAge + 100))
        await ledger.note(
            ContentEntryRecord(timestamp: old, area: .network, severity: .error, message: "old"))
        await ledger.note(ContentEntryRecord(area: .network, severity: .error, message: "new"))

        let route = await ledger.cleanUp()
        #expect(route == 1)
        let contained = await ledger.entries()
        #expect(contained.count == 1)
        #expect(contained.first?.message == "new")
    }
}
