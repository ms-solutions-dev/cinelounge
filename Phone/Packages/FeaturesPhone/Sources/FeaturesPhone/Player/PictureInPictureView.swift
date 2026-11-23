import DesignSystemPhone
import Diagnose
import Playback
import SwiftUI

/// Continue watching while doing something else.
///
/// **Meaningless on tvOS, on iOS the place where the competition fails
/// one after another.** From the market research: Picture in Picture, lock screen, subtitle switching
/// and resume position break repeatedly through updates in Swiftfin and cost it
/// stars there. It is also the reason for the decision against a playback
/// engine of our own: a decoder of our own costs exactly that — Picture in Picture, AirPlay,
/// lock screen — and battery.
///
/// **Nothing is built here either.** `PictureInPicture` lives in the shared package, has
/// always been `canImport(UIKit)` instead of `os(tvOS)`, and `VideoSurface` already attaches the
/// image layer (`pictureInPicture.attach(layer)`). What was missing was a button.
///
/// **The button is the second way, not the first** (on-device test build 1332, 2026-09-27).
/// On the iPhone one expects the window when leaving the app while the film
/// is playing — and iOS never did that, because the controller did not support automatic start.
/// That is now in the shared package (`PictureInPicture.adopt`, `os(iOS)` only).
///
/// **Here "grayed out" applies and not "gone" — the exception to the rule of the
/// ``CommandButtons``, and it is justified.** `isPossible` is false for a brief second
/// when the player opens and permanently true afterwards. A button that appears after that
/// second pushes four neighbors aside under the thumb — and exactly
/// when the viewer is reaching for one of them. A button that is pale for a
/// second does not do that.
///
/// **Two conditions, and both are in the system's state**, not in an
/// assumption: `PictureInPicture.isSupported` says whether the device can do it, `isPossible` whether
/// it works **now** — with the system player only once a picture stands. A button that checks neither
/// is, at the wrong second, a button without effect.
///
/// **And without ``AudioSession`` the offer does not exist at all.** Without the category `.playback`
/// iOS does not offer Picture in Picture — that is why the session is in the roadmap before this
/// item and not next to it.
struct PictureInPictureView: View {

    let host: EngineHost
    /// What happens when the viewer returns from the small window.
    ///
    /// **The view must then stand there again.** iOS gives a callback with a
    /// receipt for this; whoever does not answer it gets a window that can no longer be
    /// closed.
    let back: () -> Void

    /// Where a rejected start is reported — see ``PlayerView/briefHint``.
    var rejected: (String) -> Void = { _ in }

    var body: some View {
        if PictureInPicture.isSupported {
            Button {
                // **`start()` says itself whether it worked** — and until 2026-09-10 nobody
                // listened. Here it said that a `false` leaves the screen "as it
                // is"; that was true and was the gap: the viewer pressed a
                // button that looked operable, and nothing happened. A button that
                // silently does nothing is worse than one that is missing (E38).
                guard host.pictureInPicture.start() else {
                    rejected("player.pipNotNow")
                    let reason = host.pictureInPicture.rejection?.message ?? "no reason"
                    Diagnose.hint(.playback, "Picture in Picture rejected: \(reason)")
                    return
                }
                Diagnose.step(.playback, "Picture in Picture started via the button")
            } label: {
                Image(systemName: Glyph.pictureInPicture.name)
            }
            .buttonStyle(.rounded)
            .disabled(!host.pictureInPicture.isPossible)
            .accessibilityLabel(Text(app: "player.pip"))
            .onAppear {
                host.pictureInPicture.onRestore = { done in
                    back()
                    done(true)
                }
            }
        }
    }
}
