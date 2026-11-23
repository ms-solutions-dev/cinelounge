import Foundation
import Testing

@testable import SourceProbe

/// **The board is correct** — otherwise every check pointing at it would read into the void.
///
/// This is the one place that turns red after a move, and it names the location by
/// name. Without it the same move would break a dozen checks with
/// "file not found" in a dozen places.
@Suite("Source probe")
struct SourceLocationTests {

    @Test("Every location on the board exists", arguments: CodeLocation.allCases)
    func locationExists(_ location: CodeLocation) {
        #expect(
            FileManager.default.fileExists(atPath: location.url.path),
            "\(location) points to \(location.rawValue), and there is nothing there")
    }

    @Test("A file is found by its name, whatever subfolder it is in")
    func findsByName() throws {
        let url = try SourceText.file("SourceText.swift", in: .packets)
        #expect(url.path.hasSuffix("SourceProbe/Sources/SourceProbe/SourceText.swift"))
    }

    /// **Never silently the first.** A check that reads the wrong one of two files with the
    /// same name stays green while the right one breaks.
    @Test("An ambiguous name is an error and not a choice")
    func ambiguousThrows() {
        #expect(throws: SourceText.TestError.self) {
            try SourceText.file("Package.swift", in: .packets)
        }
    }

    @Test("A missing name is an error")
    func missingThrows() {
        #expect(throws: SourceText.TestError.self) {
            try SourceText.file("DoesNotExist.swift", in: .core)
        }
    }

    @Test("The files of a location carry name, path from the location and path from the root")
    func filesCarryPaths() throws {
        let files = try SourceText.files(in: .packets, subfolder: "SourceProbe")
        let thisFile = try #require(files.first { $0.name == "SourceText.swift" })
        #expect(thisFile.relative == "SourceProbe/Sources/SourceProbe/SourceText.swift")
        #expect(thisFile.path == "Packages/SourceProbe/Sources/SourceProbe/SourceText.swift")
        #expect(thisFile.content.contains("enum SourceText"))
    }

    @Test("Pure comment lines drop out, code with a trailing comment stays")
    func commentLines() {
        let text = "a()\n    // gone\nb() // stays\n/// gone"
        #expect(SourceText.strippingCommentLines(text) == "a()\nb() // stays")
    }
}
