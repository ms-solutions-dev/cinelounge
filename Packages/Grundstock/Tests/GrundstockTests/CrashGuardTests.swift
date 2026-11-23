import Foundation
import Testing

@testable import Grundstock

/// The crash guard — checked without a crash: the catcher writes on
/// demand, and the next "start" reads what it left behind.
@Suite("The crash guard", .serialized)
struct CrashGuardTests {

    private func freshFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A clean run leaves nothing behind")
    func cleanRunLeavesNothing() throws {
        let folder = try freshFolder()
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
        // A second start without a crash in between: still nothing.
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
    }

    @Test("What the catcher writes, the next launch reads")
    func writtenReportIsReadOnNextLaunch() throws {
        let folder = try freshFolder()
        CrashGuard.install(directory: folder, catching: false)
        CrashGuard.note(activity: "Playback “TR: TELVE 2 UHD” — engine renderer")
        CrashGuard.write(signal: SIGSEGV)

        CrashGuard.install(directory: folder, catching: false)
        let report = try #require(CrashGuard.takePreviousReport())
        #expect(report.contains("Signal 11"))
        #expect(report.contains("during: Playback “TR: TELVE 2 UHD”"))
        #expect(report.contains("Image loaded at 0x"))
        // The call chain: at least one frame with an address.
        #expect(report.contains("0x"))

        let (header, chain) = CrashGuard.lines(from: report)
        #expect(header.contains("Signal 11"))
        #expect(header.contains("during:"))
        #expect(!header.contains("Version:"), "the header does not repeat the diagnosis")
        #expect(!chain.isEmpty)
        #expect(!chain.contains("  "), "the chain is condensed")

        // Picked up is picked up.
        #expect(CrashGuard.takePreviousReport() == nil)
        // And the new run starts with an empty file.
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
    }

    @Test("The chain is cut down to what is readable")
    func framesAreLimited() {
        var text = "Signal 6 (SIGABRT)\nduring: Probe\n"
        for i in 0..<50 { text += "\(i)   CineLounge    0x00000001000\(i)   CineLounge + \(i)\n" }
        let (_, chain) = CrashGuard.lines(from: text, frameLimit: 5)
        #expect(chain.split(separator: "|").count == 5)
    }
}

/// The memory guard — the footprint must be a number, not zero.
@Suite("The memory watch")
struct MemoryWatchTests {
    @Test("The footprint is measurable")
    func footprintIsMeasurable() {
        #expect(MemoryWatch.footprintBytes > 1_000_000)
        #expect(MemoryWatch.footprintText.hasSuffix(" MB"))
    }
}
