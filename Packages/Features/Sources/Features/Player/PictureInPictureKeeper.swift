import Core
import Foundation
import Playback

/// Holds engine and model as long as the Picture-in-Picture window stands (AP8).
///
/// **The view owns the engine** — ``PlayerScreen`` holds ``EngineHost`` and
/// ``PlayerModel`` as `StateObject`, and whoever leaves the view takes both with them. With
/// Picture-in-Picture the viewer leaves the view **on purpose**, and the window should keep
/// playing: the keeper takes over the two, the view may go, and when the system wants to
/// return to full screen, the new view gets the same objects back (``claim(for:)``). If the
/// viewer starts something else instead, what is held is ended properly (``discard()``).
public final class PictureInPictureKeeper: ObservableObject {

    public static let shared = PictureInPictureKeeper()

    public struct Held {
        public let host: EngineHost
        public let model: PlayerModel
        public let target: PlaybackTarget
    }

    @Published public private(set) var held: Held?
    /// The system wants to return to full screen — ``MainView`` restores the view for this
    /// target.
    @Published public var restoreRequest: PlaybackTarget?
    /// Whether a return is currently in progress — then "window closed" does not mean "clean
    /// up" but "the view has taken over again".
    private var restoring = false

    private init() {}

    /// Whether this model currently belongs to the window — then the disappearing view must not
    /// end it.
    public func isHolding(_ model: PlayerModel) -> Bool {
        held?.model === model
    }

    public func take(host: EngineHost, model: PlayerModel, target: PlaybackTarget) {
        held = Held(host: host, model: model, target: target)
        restoring = false
    }

    /// The new view for the same target gets engine and model back.
    public func claim(for target: PlaybackTarget) -> Held? {
        guard let held, Self.matches(held.target, target) else { return nil }
        restoring = true
        held.model.resumesFromPictureInPicture = true
        return held
    }

    /// Whether a target is the same as the held one — by address, not by equality of the whole
    /// value: the rebuild carries different marks.
    nonisolated static func matches(_ held: PlaybackTarget, _ target: PlaybackTarget) -> Bool {
        held.url == target.url || held.sourceURL == target.sourceURL
    }

    /// The window is closed. After a return everything belongs to the view again; otherwise
    /// that was it, and what is held is ended.
    public func windowClosed() {
        guard let held else { return }
        if restoring {
            restoring = false
            self.held = nil
            return
        }
        self.held = nil
        held.model.finish()
        Diagnostics.playbackStep("Picture in Picture: window closed, playback ended", since: nil)
    }

    /// Something else should play: close the window, end what is held.
    public func discard() {
        guard let held else { return }
        self.held = nil
        restoring = false
        held.host.pictureInPicture.stop()
        held.model.finish()
        Diagnostics.playbackStep("Picture in Picture: ended by a new target", since: nil)
    }

    /// The return to full screen: request the view, confirm to the system.
    public func requestRestore(completion: @escaping (Bool) -> Void) {
        guard let held else {
            completion(false)
            return
        }
        restoring = true
        restoreRequest = held.target
        completion(true)
    }
}
