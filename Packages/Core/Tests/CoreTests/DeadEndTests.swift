import Foundation
import Testing

@testable import Core

/// **The silent dead end** — AP32, 2026-09-11.
///
/// A foreign picture codec without a media server went **unchanged** to Apple's
/// engine until then: it opened the file, showed nothing and reported nothing.
/// Without a server nobody can transcode, remuxing does not help — so all that was
/// left to build was the honest message. **The choice knew all along** and delivered
/// anyway.
struct DeadEndTests {

    /// A camcorder MP4: container fine, picture is MPEG-4 Part 2.
    private func camcorder() -> MediaSource {
        MediaSource(
            container: .mp4, videoCodec: "mpeg4",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")])
    }

    /// **The name of the reason now says what is meant.**
    ///
    /// This used to say `containerNotNativelySupported` — and the container is MP4, so
    /// perfectly fine. Whoever followed the diagnosis looked at the container.
    @Test("An unplayable codec without a server means dead end")
    func foreignCodecWithoutServer() {
        let choice = PlaybackEngineSelector.decide(for: camcorder())
        #expect(choice.isDeadEnd)
        #expect(choice.reason == .notPlayable)
    }

    /// **With a media server it is not a dead end** — it transcodes.
    ///
    /// The distinction is the whole point: the same title, the same codec, and the
    /// answer is a different one because there is someone who can help.
    @Test("With a Jellyfin server the chunked route remains")
    func foreignCodecWithServer() {
        let choice = PlaybackEngineSelector.decide(for: camcorder(), hasMediaServer: true)
        #expect(!choice.isDeadEnd)
        #expect(choice.delivery == .hls)
    }

    /// **What Apple's engine can do is not a dead end.**
    @Test("A native title stays untouched")
    func nativeTitle() {
        let native = MediaSource(
            container: .mp4, videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")])
        let choice = PlaybackEngineSelector.decide(for: native)
        #expect(!choice.isDeadEnd)
        #expect(choice.reason == .nativeContainer)
    }

    /// **And what our own remuxer takes over is not either.**
    ///
    /// A Matroska with H.264 and AAC: container foreign, picture and sound the hardware
    /// can handle — the app swaps the wrapper itself. Exactly this boundary separates
    /// "does not work" from "works, just differently".
    @Test("What can be remuxed is not a dead end")
    func repackable() {
        let mkv = MediaSource(
            container: .mkv, videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")])
        let choice = PlaybackEngineSelector.decide(for: mkv)
        #expect(!choice.isDeadEnd)
        #expect(choice.delivery == .remuxInApp)
    }
}
