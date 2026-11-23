import AVFoundation

#if os(tvOS)
    import AVKit
    import UIKit
#endif

/// What the connected screen can play — asked at runtime,
/// not configured.
///
/// Lives with playback and not in `Core`: The answer comes from
/// AVFoundation, and `Core` deliberately stays free of system frameworks so that
/// its rules can be tested without a device. The callers pass the value on as a
/// plain truth value into the engine choice — see
/// `PlaybackDecision.displaySupportsHDR`.
public enum DisplaySupport {

    /// Whether the chain of device and TV can display HDR.
    ///
    /// On the simulator this is off, on the Apple TV 4K it depends on the connected
    /// TV and its settings. The answer decides whether Dolby Vision capability is declared to the
    /// server — wrongly declared, an SDR viewer would see washed-out colours, wrongly
    /// withheld, a profile 5 title flickers (the documented finding from the on-device test).
    @MainActor
    public static var hdr: Bool {
        AVPlayer.eligibleForHDRPlayback
    }

    #if os(tvOS)
        /// The display manager of the main window — for the frame-rate registration.
        ///
        /// **Here and not in an engine**, since there are two (2026-09-03): Both
        /// register frame rates, and the guard underneath belongs written
        /// only once.
        @MainActor
        static var displayManager: AVDisplayManager? {
            guard
                let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: { $0.isKeyWindow })
            else { return nil }
            // The guard for the crash of 2026-08-16: `avDisplayManager` is an
            // AVKit CATEGORY on UIWindow — if the framework is not
            // loaded, the call throws "unrecognized selector" and tears
            // the app down (crash reports 12:25–12:31). Linking is forced by
            // Package.swift; this guard holds in case that ever
            // shifts again: Then the adjustment is missing, instead of everything dying.
            guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
                return nil
            }
            return window.avDisplayManager
        }
    #endif
}
