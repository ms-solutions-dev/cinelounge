import Core
import Playback
import SwiftUI

/// The trailer as the detail page's background — in place of the still frame, behind
/// the same gradient (AP82, 2026-10-12, requirement: "the way Netflix does it … after
/// playing, the normal background comes back into view, clean transitions").
///
/// **Muted and once.** The audio belongs to the full screen via the trailer button; here
/// the picture runs alongside it, not against it. When it ends the surface reports ``onEnd`` and
/// the page fades back to the still frame — no loop, because a trailer with
/// an intro is obtrusive in the third round (product decision, 2026-10-12).
///
/// **Visible only with the first frame.** Until the engine reports `.playing`, the
/// surface stays transparent and the still frame stays up; a black hole during the one to
/// two seconds of resolving would look like an error. The state is polled, not
/// observed: ``EngineHost/status`` is deliberately not `@Published` (the startup measurement
/// needs a value without feedback), and three polls per second cost nothing.
struct TrailerBackdrop: View {

    let target: PlaybackTarget
    /// Called once when the trailer has ended or fails.
    let onEnd: @MainActor () -> Void

    @State private var host = EngineHost()
    @State private var isVisible = false

    /// Duration of the cross-fade — slower than the 0.4 s of the column, because here the whole
    /// screen changes and a fast cut twitches in the corner of the eye.
    static let fade: Duration = .milliseconds(600)

    var body: some View {
        VideoSurface(host: host)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: isVisible)
            .allowsHitTesting(false)
            .onAppear {
                host.start(target)
                host.isMuted = true
            }
            .onDisappear { host.stop() }
            .task(id: target.id) {
                var reported = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    switch host.status {
                    case .playing:
                        // After the start the player is a new one; muted stays muted.
                        host.isMuted = true
                        if !isVisible { isVisible = true }
                    case .ended, .failed:
                        if !reported {
                            reported = true
                            onEnd()
                        }
                        return
                    default:
                        break
                    }
                }
            }
    }
}
