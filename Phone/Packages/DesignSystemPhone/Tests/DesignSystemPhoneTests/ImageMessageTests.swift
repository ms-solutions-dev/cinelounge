import Foundation
import Synchronization
import Testing

@testable import DesignSystemPhone

/// **The image layer reports without knowing the error log** (AP58, finding A16).
///
/// The message must arrive at the receiver exactly as `Diagnose` built it itself before —
/// otherwise the log would read differently after the refactor than before.
@Suite("Image message")
struct ImageMessageTests {

    private struct SampleError: LocalizedError {
        var errorDescription: String? { "Timeout" }
    }

    @Test("An error arrives as a finished sentence with its description")
    func sentenceWithDescription() {
        let arrived = Mutex<[ImageMessage.UserNotice]>([])
        ImageMessage.derive { report in arrived.withLock { $0.append(report) } }

        ImageMessage.notify(.error, .network, "Image not loaded", SampleError())
        ImageMessage.notify(.step, .downloads, "Image store cleaned up: 3 files")

        let read = arrived.withLock { $0 }
        #expect(
            read.contains(
                .init(kind: .error, area: .network, message: "Image not loaded: Timeout")))
        #expect(
            read.contains(.init(kind: .step, area: .downloads, message: "Image store cleaned up: 3 files")))
    }
}
