import Foundation

/// Which engine plays channels — the HLS path or the direct renderer.
///
/// **A switch for the on-device test, not a permanent state.** Both paths are
/// built (2026-09-03), and which one holds up on the TV is decided by no check
/// on the Mac: There runs no TV, no provider burst, no
/// frame-rate matching. The startup tally in the diagnostic report keeps both paths
/// apart — anyone who switches between them and opens the same channels
/// gets two rows that can be compared.
///
/// As soon as the TV has decided, the loser is dismantled. Two
/// engines in the long run are two collections of the same faults.
public enum LiveEngineChoice: String, CaseIterable, Sendable, Identifiable {

    /// Remux into fMP4 segments, playlist on `127.0.0.1`, system player.
    case hls
    /// Remux into packets, straight to the hardware — see
    /// ``PlaybackEngine/renderer``.
    case renderer

    public var id: String { rawValue }

    static let storageKey = "live.engine"

    /// **The default is the HLS path.** It is the proven one; the renderer is the
    /// measured one. The default changes when the TV says so — not
    /// before.
    public static let preset: LiveEngineChoice = .hls

    public static func load(from store: any KeyValueStore) -> LiveEngineChoice {
        guard let raw = try? store.value(for: storageKey), let choice = Self(rawValue: raw) else {
            return preset
        }
        return choice
    }

    /// The default is deleted instead of written — the same rule as with
    /// the bandwidth limit: "deliberately deferred" should be distinguishable from "never
    /// set anything".
    public func save(to store: any KeyValueStore) {
        if self == Self.preset {
            try? store.remove(Self.storageKey)
        } else {
            try? store.set(rawValue, for: Self.storageKey)
        }
    }
}

extension PlaybackDecision {

    /// The same decision, but with the direct renderer instead of the HLS path.
    ///
    /// **Only a remuxer target can be redirected.** What plays directly
    /// (a playlist from the provider) keeps playing directly — the
    /// renderer needs the raw stream, and there is none there. What goes to the
    /// server keeps going to the server. All other values — limit,
    /// width, throttling — travel along unchanged.
    public func asRenderer() -> PlaybackDecision {
        guard delivery == .remuxInApp else { return self }
        return PlaybackDecision(
            engine: .renderer, delivery: .renderInApp, reason: .renderedInApp,
            maxBitrate: maxBitrate, maxWidth: maxWidth, isBandwidthLimited: isBandwidthLimited,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
            displaySupportsHDR: displaySupportsHDR)
    }

    /// The way back: the same decision on the HLS path.
    ///
    /// For the **preview**, which always runs via segments and the system player —
    /// it has no renderer, and its session should be able to be
    /// handed off to playback if that runs the HLS path.
    public func asRepacker() -> PlaybackDecision {
        guard delivery == .renderInApp else { return self }
        return PlaybackDecision(
            engine: .native, delivery: .remuxInApp, reason: .remuxedInApp,
            maxBitrate: maxBitrate, maxWidth: maxWidth, isBandwidthLimited: isBandwidthLimited,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
            displaySupportsHDR: displaySupportsHDR)
    }

    /// Whether this path leads through the own remuxer — whatever stands behind it.
    /// The places that wait for the remuxer or dismantle it ask
    /// this here instead of naming both cases individually.
    public var runsOverRepacker: Bool {
        delivery == .remuxInApp || delivery == .renderInApp
    }
}
