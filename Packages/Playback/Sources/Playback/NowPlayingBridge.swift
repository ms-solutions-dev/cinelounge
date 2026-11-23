import Core
import Foundation

#if canImport(MediaPlayer)
    import MediaPlayer
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// The bridge to the system controls: what is playing appears in Control Center,
/// and play/pause via Siri and the TV app reach the engine (AP8).
///
/// **Until now the app did not fill `MPNowPlayingInfoCenter`** — so title and channel
/// were missing from the system display, and a "pause" from Siri went nowhere. The
/// bridge is a holder: ``begin(title:subtitle:isLive:commands:)`` at the start of a
/// target, ``update(position:duration:isPlaying:)`` on the tick, ``end()`` on
/// leaving. The commands go in as closures, so that the bridge does not have to know
/// the model.
@MainActor
public final class NowPlayingBridge {

    public static let shared = NowPlayingBridge()

    /// What the system controls may trigger.
    public struct Commands {
        public var play: () -> Void
        public var pause: () -> Void
        public var toggle: () -> Void
        /// Seek by seconds — `nil` for a channel that cannot do it.
        public var skip: ((TimeInterval) -> Void)?

        public init(
            play: @escaping () -> Void, pause: @escaping () -> Void,
            toggle: @escaping () -> Void, skip: ((TimeInterval) -> Void)? = nil
        ) {
            self.play = play
            self.pause = pause
            self.toggle = toggle
            self.skip = skip
        }
    }

    private var commands: Commands?
    private var title: String?
    private var subtitle: String?
    private var isLive = false
    private var lastWritten: (position: Int, duration: Int, playing: Bool)?
    #if canImport(MediaPlayer)
        private var targets: [(MPRemoteCommand, Any)] = []
    #endif

    private init() {}

    #if canImport(MediaPlayer)
        private var artwork: MPMediaItemArtwork?
    #endif
    private var artworkTask: Task<Void, Never>?

    #if canImport(MediaPlayer) && canImport(UIKit)
        /// Builds the poster outside any actor binding — the provider may be called from any
        /// thread.
        nonisolated private static func artwork(for image: UIImage) -> MPMediaItemArtwork {
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    #endif

    /// Registers a new target — and hooks in the commands.
    ///
    /// - Parameter artworkURL: The poster, if the source has one — it is loaded later
    ///   and then set into the display.
    public func begin(
        title: String, subtitle: String?, isLive: Bool, artworkURL: URL? = nil, commands: Commands
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isLive = isLive
        self.commands = commands
        lastWritten = nil
        artworkTask?.cancel()
        #if canImport(MediaPlayer) && canImport(UIKit)
            artwork = nil
            if let artworkURL {
                artworkTask = Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                        let image = UIImage(data: data), !Task.isCancelled
                    else { return }
                    // **The provider runs on a foreign thread** (F-041, 2026-09-04: SIGTRAP on every
                    // Jellyfin start with a poster). MediaPlayer calls it from its own queue, and a
                    // closure created here on the main actor carries its binding — the call from outside
                    // is then a trap. It is therefore built in an unbound function.
                    let mediaArtwork = Self.artwork(for: image)
                    await MainActor.run { [weak self] in
                        guard let self, self.title == title else { return }
                        self.artwork = mediaArtwork
                        self.lastWritten = nil
                    }
                }
            }
        #endif
        #if canImport(MediaPlayer)
            unhook()
            let center = MPRemoteCommandCenter.shared()
            hook(center.playCommand) { [weak self] in self?.commands?.play() }
            hook(center.pauseCommand) { [weak self] in self?.commands?.pause() }
            hook(center.togglePlayPauseCommand) { [weak self] in self?.commands?.toggle() }
            let canSkip = commands.skip != nil
            center.skipForwardCommand.isEnabled = canSkip
            center.skipBackwardCommand.isEnabled = canSkip
            if canSkip {
                center.skipForwardCommand.preferredIntervals = [30]
                center.skipBackwardCommand.preferredIntervals = [10]
                hook(center.skipForwardCommand) { [weak self] in self?.commands?.skip?(30) }
                hook(center.skipBackwardCommand) { [weak self] in self?.commands?.skip?(-10) }
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.info(
                title: title, subtitle: subtitle, isLive: isLive, position: 0, duration: 0,
                isPlaying: false)
        #endif
    }

    /// Keeps state and condition up to date — only when something visible happened.
    public func update(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let title else { return }
        let state = (Int(position), Int(duration), isPlaying)
        if let last = lastWritten, last == state { return }
        lastWritten = state
        #if canImport(MediaPlayer)
            var info = Self.info(
                title: title, subtitle: subtitle, isLive: isLive, position: position,
                duration: duration, isPlaying: isPlaying)
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// Clears the display — nothing is playing any more.
    public func end() {
        title = nil
        commands = nil
        lastWritten = nil
        artworkTask?.cancel()
        artworkTask = nil
        #if canImport(MediaPlayer)
            unhook()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// The entry for the system display — pure computation, checkable.
    nonisolated static func info(
        title: String, subtitle: String?, isLive: Bool,
        position: TimeInterval, duration: TimeInterval, isPlaying: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        #if canImport(MediaPlayer)
            info[MPMediaItemPropertyTitle] = title
            if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
            info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            if !isLive, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        #endif
        return info
    }

    #if canImport(MediaPlayer)
        private func hook(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            targets.append((command, target))
        }

        private func unhook() {
            for (command, target) in targets { command.removeTarget(target) }
            targets.removeAll()
        }
    #endif
}
