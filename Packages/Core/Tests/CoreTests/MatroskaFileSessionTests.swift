import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The other half of P19: a file instead of a channel.**
///
/// Testing is done on a complete file made of real material — see
/// ``TestMatroskaFile``. The test files in the directory are beginnings; for everything
/// to do with seeking, they lack the end where the seek table
/// sits.
@Suite("Playback: an MKV file with seek marks")
struct MatroskaFileSessionTests {

    static func session(
        _ name: String = "mkv-hevc-aac"
    ) throws -> (
        MatroskaFileSession, Data
    ) {
        let (data, _) = try MatroskaIndexTests.completeFile(name)
        return (try MatroskaFileSession(source: DataByteRangeSource(data)), data)
    }

    private func outcome(of item: AVPlayerItem, seconds: Double = 15) async -> AVPlayerItem.Status {
        let deadline = Date().addingTimeInterval(seconds)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return item.status
    }

    /// F-022 (2026-09-04): The reserve of six threw the player's next piece out
    /// as soon as the read-ahead built eight ahead — piece 481
    /// fetched seven times. What gets evicted is what lies behind the player.
    @Test("The buffer evicts what lies behind the player — never the next segment")
    func downloadsEvictsFromBack() {
        var downloads: [(index: Int, data: Data)] = (480...496).map { ($0, Data(count: 10)) }
        MatroskaFileSession.evict(&downloads, um: 484, atMost: 16, bytes: 1 << 20)
        #expect(downloads.map(\.index) == Array(481...496))
        // Further back nothing is left: It stays at 483 and 484, the farthest ahead goes.
        MatroskaFileSession.evict(&downloads, um: 484, atMost: 12, bytes: 1 << 20)
        #expect(downloads.map(\.index) == Array(483...494))
    }

    @Test("The buffer keeps the byte limit and sacrifices the farthest segment ahead for it")
    func downloadsByteLimit() {
        var downloads: [(index: Int, data: Data)] = (0..<5).map { ($0, Data(count: 100)) }
        MatroskaFileSession.evict(&downloads, um: 0, atMost: 16, bytes: 250)
        #expect(downloads.map(\.index) == [0, 1])
    }
}
