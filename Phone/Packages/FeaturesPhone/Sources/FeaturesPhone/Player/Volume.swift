import Diagnose
import Foundation
import SwiftUI

#if canImport(UIKit)
    import AVFAudio
    import MediaPlayer
#endif

/// The volume — the right swipe zone.
///
/// **Until 2026-09-07 it explicitly stayed with the device buttons**, on the grounds that a
/// rebuilt slider does not know the buttons and would soon show a different value than the
/// device. The first TestFlight round reversed that: volume control was reported missing.
/// The concern of back then is justified and answered — **not with a slider of our own but
/// with the system's:** `MPVolumeView` is the only way iOS offers to set the volume, and
/// its slider is the system volume itself. Whoever presses the buttons moves the same
/// value; it is read from `AVAudioSession`, where the buttons write it.
///
/// **Absolute from the total travel**, like ``Brightness`` — the same calculation, the same
/// anchor, for the same reason.
@MainActor
enum Volume {
    static let span = 0.6
    private static var anchor: Double?

    #if canImport(UIKit)
        /// The hidden system slider — it stands in the player's view, see ``VolumeSlider``.
        /// Weak, because the view owns it.
        static weak var slider: UISlider?
    #endif

    /// Whether a finger is at work right now.
    ///
    /// **The distinction without which the level would appear twice:** The guard reports
    /// **every** change, including the ones this file has just written itself. During a
    /// gesture the level already shows what applies.
    static var isDragging: Bool { anchor != nil }

    /// Where a change from outside is reported — set by ``VolumeSlider``.
    ///
    /// **Here and not in the observer**, because the callback from `AVAudioSession` arrives on
    /// a foreign thread: If it took the observer across, it would carry an object over a
    /// thread boundary that it is not built for — and that is exactly what the concurrency
    /// check objected to on 2026-09-10. This way only a number travels, and it is picked up on the
    /// main thread.
    static var fromOutside: ((Double) -> Void)?

    /// - Returns: The new volume, 0 to 1 — for the display next to the finger.
    @discardableResult
    static func update(um portion: Double) -> Double? {
        #if canImport(UIKit)
            let start = anchor ?? Double(AVAudioSession.sharedInstance().outputVolume)
            anchor = start
            let fresh = min(1, max(0, start + portion * span))
            slider?.value = Float(fresh)
            return fresh
        #else
            return nil
        #endif
    }

    static func release() {
        anchor = nil
    }

    /// One step louder (`+1`) or quieter (`-1`) — see ``Brightness/step(_:)``, the same
    /// reasoning for the release at the end.
    static func step(_ direction: Double) {
        update(um: direction * Brightness.stepSize / span)
        release()
    }
}

#if canImport(UIKit)
    /// The system slider, invisible in the view — **it must be in the hierarchy**, otherwise
    /// its slider sets nothing. One point in size and transparent; the zone above it belongs
    /// to the ``SwipeZones``.
    ///
    /// **And at the same time it suppresses the system's display** (E66). As long as an
    /// `MPVolumeView` is visibly in the hierarchy, iOS does not show its own volume display —
    /// otherwise two bars would appear on top of each other with every movement, one of them
    /// across the film. That is why `alpha` just above zero and not `isHidden`: What is hidden
    /// does not count as visible, and the suppression would be lost with it.
    ///
    /// **What that costs if you leave it at that:** The device buttons would then have no
    /// feedback at all — the system's is gone, and our own hangs on the swipe gesture. That is
    /// exactly what ``changed`` reports every change from outside for; the player's level
    /// then appears for the buttons as for the finger.
    struct VolumeSlider: UIViewRepresentable {

        /// The new volume, when it did **not** come from a gesture.
        var changed: (Double) -> Void = { _ in }

        func makeUIView(context: Context) -> MPVolumeView {
            let slider = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            slider.alpha = 0.001
            slider.isUserInteractionEnabled = false
            Volume.slider = slider.subviews.compactMap { $0 as? UISlider }.first
            Volume.fromOutside = changed
            context.coordinator.startListening()
            return slider
        }

        func updateUIView(_ slider: MPVolumeView, context: Context) {
            if Volume.slider == nil {
                Volume.slider = slider.subviews.compactMap { $0 as? UISlider }.first
            }
            Volume.fromOutside = changed
        }

        /// **Cleaning up is part of it.** The reporter is static; if it stayed in place, it would
        /// write into a view that no longer exists after the film ends.
        static func dismantleUIView(_ slider: MPVolumeView, coordinator: ButtonWatcher) {
            Volume.fromOutside = nil
        }

        func makeCoordinator() -> ButtonWatcher { ButtonWatcher() }

        /// Listens to the system volume — **the device buttons have no other trace.**
        ///
        /// `AVAudioSession.outputVolume` is the place where the buttons write their value; an
        /// observer on it is the only permitted way to find out. The old system notification found
        /// in examples for this is not public — and an app that uses it is rejected in review
        /// (AP9 · A2).
        ///
        /// **Only the observer, no state.** It lives as long as the view — it has nothing more to
        /// do; where to report is known to ``Volume/fromOutside``.
        final class ButtonWatcher {
            private var observers: NSKeyValueObservation?

            func startListening() {
                observers = AVAudioSession.sharedInstance().observe(
                    \.outputVolume, options: [.new]
                ) { _, change in
                    guard let fresh = change.newValue else { return }
                    // **Only the number travels.** Anything else would remain an object carried across a
                    // thread boundary.
                    let level = Double(fresh)
                    Task { @MainActor in
                        // What the finger wrote itself, the level already shows.
                        guard !Volume.isDragging else { return }
                        // **One trace per report** (2026-10-19): The bar appeared during live TV without a button
                        // press. If this line is in the report, iOS really changed the value and not the view.
                        Diagnose.step(
                            .playback, "System volume changed from outside: \(Int(level * 100)) %")
                        Volume.fromOutside?(level)
                    }
                }
            }
        }
    }
#endif
