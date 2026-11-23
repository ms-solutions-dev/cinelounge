import Foundation
import Testing

@testable import Core

/// The seek table — the piece without which a film would not be playable,
/// only listenable.
@Suite("Seek table and piece division")
struct MatroskaIndexTests {

    /// A complete file made of real material — see ``TestMatroskaFile``.
    static func completeFile(
        _ name: String = "mkv-hevc-aac"
    ) throws -> (
        data: Data, header: Matroska.Header
    ) {
        let reader = MatroskaReader()
        let blocks = reader.read(try MatroskaTests.fixture(name))
        return (TestMatroskaFile.make(header: reader.header, blocks: blocks), reader.header)
    }
}
