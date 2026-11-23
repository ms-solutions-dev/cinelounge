import Foundation
import Testing

@testable import Core

/// H.264 in ten bit — the codec name lies (on-device finding 2026-08-15).
///
/// Kobe Runaways, episode 1: The server reports `h264`, the codec list says
/// "the hardware can do it" — but the profile is High 10, and no Apple device
/// decodes H.264 in ten bit. The remuxer built a stream from it that
/// AVFoundation accepts and never decodes: a stall without a single
/// error message, again with every audio track switch. These tests nail down
/// the boundary in both places: in the engine choice (server metadata)
/// and in the remuxer itself (avcC profile byte) — the second applies when the
/// first has no data.
@Suite("H.264 in ten bit")
struct Hi10PTests {

    private func hi10p(container: MediaSource.Container = .mkv) -> MediaSource {
        MediaSource(
            container: container,
            videoCodec: "h264",
            audioTracks: [MediaTrack(id: "1", kind: .audio, title: "Deutsch", codec: "aac")],
            videoBitDepth: 10
        )
    }

    // MARK: - Die Motorwahl

    @Test("Ten-bit H.264 counts as a software case")
    func tenBitH264NeedsSoftware() {
        #expect(hi10p().videoNeedsSoftwareDecoding)
        #expect(!hi10p().isNativelyPlayable)
        #expect(!hi10p().isProvenNativelyPlayable)
    }

    @Test("HEVC in ten bit stays a hardware matter — every HDR video is encoded that way")
    func tenBitHEVCStaysNative() {
        let source = MediaSource(container: .mp4, videoCodec: "hevc", videoBitDepth: 10)
        #expect(!source.videoNeedsSoftwareDecoding)
        #expect(source.isNativelyPlayable)
    }

    @Test("Eight bit and unknown depth stay untouched")
    func eightBitAndUnknownAreUntouched() {
        // Unknown does not count as an exclusion — the same rule as with
        // interlacing: Otherwise every channel without a statement would take the expensive path.
        #expect(
            !MediaSource(container: .mkv, videoCodec: "h264", videoBitDepth: 8)
                .videoNeedsSoftwareDecoding)
        #expect(
            !MediaSource(container: .mkv, videoCodec: "h264")
                .videoNeedsSoftwareDecoding)
    }

    @Test("The remuxer refuses ten bit")
    func remuxRefusesTenBit() {
        #expect(!PlaybackEngineSelector.canRemuxInApp(hi10p()))
    }

    @Test("With a Jellyfin server ten bit goes to the server in pieces — natively")
    func withServerTenBitGoesToTheServer() {
        // Product rule 2026-08-15: move away from the second engines. The server converts
        // the picture (the eight-bit condition in the device profile forces that),
        // and Apple's engine plays the segmentation — including clean audio track selection,
        // on which the German version failed with VLC.
        let decision = PlaybackEngineSelector.decide(for: hi10p(), hasMediaServer: true)
        #expect(decision.delivery == .hls)
        #expect(decision.reason == .videoNeedsSoftwareDecoder)
    }

    @Test("Without a Jellyfin server ten bit is a dead end")
    func withoutServerTenBitIsADeadEnd() {
        // **The name lied, and the test tested nothing** (AP8, added
        // 2026-09-02): "only the second engine remains" — it no longer exists, and
        // `engine == .native` has been always true since the VLC removal.
        //
        // What really happens is stated here: Without a server nobody converts, the
        // hardware cannot do ten bit, and there is no path.
        //
        // **Until 2026-09-11 this place held the margin left over from the VLC
        // removal** — verbatim: "The viewer sees nothing of this except a picture that
        // does not come." The choice delivered unchanged and named the container
        // as the reason, although that one fit. **Now it says that it does not work** (AP32),
        // and the player can pass that on instead of showing a black picture.
        let decision = PlaybackEngineSelector.decide(for: hi10p())

        #expect(decision.isDeadEnd)
        #expect(decision.reason == .notPlayable)
    }

    // MARK: - Der Rückhalt im Umpacker

    /// An avcC header with the desired profile byte — the test needs nothing more.
    private func avcc(profile: UInt8) -> Data {
        Data([1, profile, 0x00, 40, 0xFF, 0xE1])
    }

    private func videoTrack(codecPrivate: Data?) -> Matroska.Track {
        Matroska.Track(
            number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC", codecPrivate: codecPrivate,
            language: "und", name: nil, isDefault: true, isForced: false,
            width: 1920, height: 1080, sampleRate: nil, channels: nil,
            defaultDuration: nil, isEncoded: false
        )
    }

    @Test("High 10 in the avcC header: the hardware cannot do it")
    func high10ProfileIsRefused() {
        // 110 = High 10, 122 = High 4:2:2, 244 = High 4:4:4 — all three carry
        // the same codec name as what the hardware can do.
        for profile: UInt8 in [110, 122, 244] {
            #expect(!videoTrack(codecPrivate: avcc(profile: profile)).isVideoHardwareDecodable)
        }
    }

    @Test("The four hardware profiles pass")
    func hardwareProfilesPass() {
        for profile: UInt8 in [66, 77, 88, 100] {
            #expect(videoTrack(codecPrivate: avcc(profile: profile)).isVideoHardwareDecodable)
        }
    }

    @Test("Without an avcC header the codec verdict stands")
    func missingHeaderKeepsTheCodecVerdict() {
        // The parameter sets then sit in the picture stream (as with a channel) — there
        // Hi10P is practically unknown, and a blanket no would throw files at
        // VLC that the hardware can very well handle.
        #expect(videoTrack(codecPrivate: nil).isVideoHardwareDecodable)
        #expect(videoTrack(codecPrivate: Data([1])).isVideoHardwareDecodable)
    }

    @Test("HEVC checks no profile byte — Main10 is a hardware matter")
    func hevcSkipsTheProfileCheck() {
        var track = videoTrack(codecPrivate: avcc(profile: 110))
        track.codecID = "V_MPEGH/ISO/HEVC"
        #expect(track.isVideoHardwareDecodable)
    }
}
