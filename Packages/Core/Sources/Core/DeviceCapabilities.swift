import Foundation

/// What the device can do — entered once at startup, readable everywhere.
///
/// **Why here and not in playback:** the answer comes from
/// VideoToolbox and thus belongs to ``Playback``; but it is also needed
/// by ``JellyfinKit`` when it sends the device profile to the server — and
/// there is deliberately no dependency between the two. `Core` sits below
/// both, so the answer lives here.
///
/// The default is the state of the Apple TV 4K: HEVC yes, AV1 no. Whoever enters nothing
/// therefore gets the right information for the device the app runs on
/// today — and a newer model reports itself (roadmap P11).
public enum DeviceCapabilities {

    /// Whether HEVC is decoded in hardware.
    public nonisolated(unsafe) static var hasHEVC = true

    /// Whether AV1 is decoded in hardware. Apple TV 4K (3rd gen.): no.
    public nonisolated(unsafe) static var hasAV1 = false

    /// Enters the capabilities determined at runtime. Once, at startup.
    public static func adopt(hasHEVC: Bool, hasAV1: Bool) {
        Self.hasHEVC = hasHEVC
        Self.hasAV1 = hasAV1
    }

    /// The video codecs for the device profile, in the server's notation.
    public static var videoCodecList: String {
        var codecs = ["h264"]
        if hasHEVC { codecs.append("hevc") }
        if hasAV1 { codecs.append("av1") }
        return codecs.joined(separator: ",")
    }
}
