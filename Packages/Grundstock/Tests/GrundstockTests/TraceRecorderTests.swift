import Foundation
import Testing

@testable import Grundstock

/// The on-disk trace has to stay short by itself — nobody maintains a log file
/// on the TV. The two limits are checked, and that the newest stays when trimming:
/// a trace that sacrifices the newest would be worse than
/// none.
@Suite("Diagnostics trace on disk")
struct TraceRecorderTests {

    private func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "trace-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Appended text comes back with a timestamp")
    func roundTrip() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        await recorder.append("Sign-in  https://server  ✓", at: noon)
        await recorder.append("Bibliothek  https://server/Items  ✗ Timeout", at: noon)

        let text = await recorder.contents()
        #expect(text.contains("2026-08-07T12:00:00Z\tSign-in"))
        #expect(text.contains("✗ Timeout"))
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("Anything older than three days drops out on the next run")
    func trimsByAge() async throws {
        let directory = try freshDirectory()
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        let first = TraceRecorder(directory: directory)
        await first.append("old", at: noon.addingTimeInterval(-4 * 24 * 3600))
        await first.append("fresh", at: noon.addingTimeInterval(-3600))

        // A new run — trimming takes effect at the first write, as at
        // app start.
        let second = TraceRecorder(directory: directory)
        await second.append("new", at: noon)

        let text = await second.contents()
        #expect(!text.contains("old"))
        #expect(text.contains("fresh"))
        #expect(text.contains("new"))
    }

    @Test("Above the size cap it is cut at the front, not the back")
    func trimsBySize() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        // Lines of ~1000 characters each, until the cap has been broken twice —
        // each time the trimming has to sacrifice the oldest.
        let filler = String(repeating: "x", count: 1000)
        for index in 0..<2300 {
            await recorder.append("Line \(index) \(filler)", at: noon)
        }

        let text = await recorder.contents()
        #expect(text.utf8.count <= TraceRecorder.maxBytes)
        #expect(!text.contains("Line 0 "))
        #expect(text.contains("Line 2299 "))
    }

    @Test("Line breaks inside an entry do not tear the trace apart")
    func flattensNewlines() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        // Measurements are multi-line — stored as one line, the
        // timestamp per line stays true, and age-based trimming never throws away
        // half a measurement.
        await recorder.append("Measurement  line one\nline two", at: noon)

        let lines = await recorder.contents().split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("line one line two"))
    }
}
