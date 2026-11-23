import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The stream dried up without a word** — stall level 1, 2026-09-24.
///
/// If the writer build failed after a section change, the reason stayed lying in the
/// `try?`, ``TransportRemuxer/writerFailure`` stayed empty, and the property that was
/// meant to report exactly this case could never do so: it asked the writer that did
/// not exist.
@Suite("The writer failure")
struct WriterFailureTests {

    struct Declined: Error, Equatable {}

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    /// **Once per remuxer.** The build is attempted again at every small piece; without a
    /// gate a permanently failing build would write dozens of identical lines per second.
    @Test("The failure is reported once and not per attempt")
    func reportedOnce() {
        var gate = WriterOutage()
        #expect(gate.notify(Declined()) != nil)
        #expect(gate.notify(Declined()) == nil)
        #expect(gate.notify(Declined()) == nil)
    }
}

/// **The file path** — stall level 5, 2026-09-25.
///
/// The same gap as with the channel, just one door further: ``MatroskaRemuxer`` built
/// its writer with `try?`, ``MatroskaRemuxer/failure`` asked the writer that then did
/// not exist, and nobody read the property.
@Suite("The writer failure on the file path")
struct FileWriterFailureTests {

    struct Declined: Error {}

    @Test("Once per file, not per piece")
    func oncePerFile() {
        var gate = MatroskaFileSession.FileReportGate()
        let first = MatroskaFileSession.writerMessage(Declined(), piece: 3) { gate.claim($0) }
        let second = MatroskaFileSession.writerMessage(Declined(), piece: 4) { gate.claim($0) }
        let without = MatroskaFileSession.writerMessage(nil, piece: 5) { gate.claim($0) }
        #expect(first?.hasPrefix("Piece 3: the writer failed") == true)
        #expect(second == nil)
        #expect(without == nil)
    }
}
