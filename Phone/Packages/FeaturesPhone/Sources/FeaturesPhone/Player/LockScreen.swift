import Core
import Foundation
import Playback

/// Title, picture and buttons outside the app.
///
/// **Nothing is built here — what is already finished gets called.** `NowPlayingBridge`
/// lives in the shared package, is written to work on iOS and was called **not once** by
/// the phone project. It fills `MPNowPlayingInfoCenter`, hooks in the commands of the
/// `MPRemoteCommandCenter` and even reloads the poster. A second version of it would be
/// the same work with a second bug.
///
/// **Without it, more than a display is missing.** The lock screen then shows nothing,
/// Control Center nothing, and a "pause" via Siri, the headphone button or the car goes
/// nowhere. For a film that should keep playing when the screen goes off, that is half
/// the controls.
///
/// **The order matters:** ``AudioSession`` first. Without category `.playback`, iOS treats
/// the playback as an accessory and does not show it at all.
///
/// **A channel gets no skip buttons.** `PlaybackTarget.isSeekable` says the same, and it
/// is repeated here: a button that jumps back ten seconds is a button without effect on a
/// running broadcast — and nobody can read on the lock screen why.
@MainActor
public enum LockScreen {

    /// Registers a target — **once per playback, after the start.**
    public static func notify(
        _ job: PlaybackRequest, commands: NowPlayingBridge.Commands
    ) {
        NowPlayingBridge.shared.begin(
            title: job.title,
            subtitle: job.beside,
            isLive: job.kind == .live,
            // **The poster and not the background image.** The lock screen shows a square-cropped
            // image; a 16 : 9 background loses its edges in the process, a poster survives it.
            artworkURL: job.image ?? job.backdrop,
            commands: commands)
    }

    /// Keeps position and state up to date — in the beat of the player's clock.
    ///
    /// The bridge writes only when something visible has changed; one call per second
    /// therefore costs nothing.
    public static func advance(location: TimeInterval, duration: TimeInterval, isRunning: Bool) {
        NowPlayingBridge.shared.update(position: location, duration: duration, isPlaying: isRunning)
    }

    /// Withdraws the registration.
    ///
    /// **Without it the title stays up** after the player is closed — and a "play" from
    /// outside would go to an engine that no longer exists.
    public static func finish() {
        NowPlayingBridge.shared.end()
    }
}
