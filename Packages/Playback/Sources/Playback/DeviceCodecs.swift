import AVFoundation
import Core
import VideoToolbox

/// What **this** device can decode — asked at runtime, not assumed.
///
/// **Why ask and not know** (roadmap P11, after the format research):
/// A hard-wired list ages badly. AV1, for example, the Apple TV 4K
/// of the third generation (A15) can **not** do in hardware — only from A17 Pro/M3;
/// a future model can. Whoever assumes that in the source either delivers
/// something today that stutters or stays black, or gives away the
/// hardware tomorrow.
///
/// VideoToolbox answers exactly this question. The answer does not change
/// within one program run, so it is asked once and
/// kept — it feeds into the engine choice and thus comes before every playback.
public enum DeviceCodecs {

    /// Whether HEVC is decoded in hardware. On every Apple TV 4K: yes.
    public static let hasHEVC: Bool = supports(kCMVideoCodecType_HEVC)

    /// Whether AV1 is decoded in hardware.
    ///
    /// **On the Apple TV 4K (3rd gen.) the answer is no**, and
    /// software decoding is not reachable on tvOS: Apple's own
    /// software decoder cannot be addressed via VideoToolbox. An
    /// AV1 title therefore belongs on the server — or it stays black.
    public static let hasAV1: Bool = supports(kCMVideoCodecType_AV1)

    /// The picture codecs that this device may report to the media server as "can do" —
    /// in the spelling that Jellyfin expects.
    public static var nativeVideoCodecList: String {
        var codecs = ["h264"]
        if hasHEVC { codecs.append("hevc") }
        if hasAV1 { codecs.append("av1") }
        return codecs.joined(separator: ",")
    }

    private static func supports(_ codec: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codec)
    }
}

extension PlaybackPlan.Device {

    /// What **this** device can do — the default for ``Core/PlaybackPlan``.
    ///
    /// Here and not in `Core`, because the answers live here: `DisplaySupport` asks the
    /// screen, ``DeviceCodecs`` the hardware. Both programs read the same place.
    @MainActor
    public static var thisDevice: PlaybackPlan.Device {
        PlaybackPlan.Device(hdr: DisplaySupport.hdr, hevc: DeviceCodecs.hasHEVC)
    }
}
