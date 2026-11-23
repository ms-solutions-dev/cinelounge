import Foundation
import Testing

@testable import Playback

/// **Resuming without waiting — only for a file and only with a start seek**
/// (2026-09-30).
///
/// Diagnosis F-049: "Kumlu Fincan" via iptvhost.example, resumed at 21:30 min, needed 4.6 s
/// after the seek to the first frame — AVPlayer first estimated the connection.
/// Started from the beginning it was 13 ms. What is checked is the decision; the
/// playing itself is seen only by the device.
@MainActor
@Suite("Resuming without waiting")
struct ResumeWithoutWaitingTests {

    private func loaded(_ address: String, from location: TimeInterval) -> NativePlaybackEngine {
        let engine = NativePlaybackEngine()
        engine.load(URL(string: address)!, startingAt: location)
        return engine
    }

    @Test("A file resumed in the middle: without waiting")
    func fileWithJump() {
        let engine = loaded("http://iptvhost.example:2086/movie/u/p/343792.mp4", from: 1290.5)
        #expect(engine.immediatelyAfterStartJump)
        // The stall protection stays on — only the first wait is skipped.
        #expect(engine.player.automaticallyWaitsToMinimizeStalling)
    }

    @Test("From the start: as before")
    func fileFromStart() {
        #expect(
            !loaded("http://iptvhost.example:2086/movie/u/p/343792.mp4", from: 0).immediatelyAfterStartJump)
    }

    @Test("HLS and pass-through without an extension: as before")
    func noFile() {
        #expect(!loaded("http://host/live/u/p/1.m3u8", from: 600).immediatelyAfterStartJump)
        #expect(!loaded("http://cl/stream?address=x", from: 600).immediatelyAfterStartJump)
    }

    @Test("The extension decides, exactly as written")
    func extensions() {
        #expect(NativePlaybackEngine.isFile(URL(string: "http://h/a.MP4")!))
        #expect(NativePlaybackEngine.isFile(URL(string: "http://h/Videos/1/stream.mov?static=true")!))
        #expect(!NativePlaybackEngine.isFile(URL(string: "http://h/a.mkv")!))
    }
}
