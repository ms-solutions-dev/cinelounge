import Foundation

/// How far a title has been watched.
public struct PlaybackProgress: Sendable, Equatable, Hashable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case position
        case duration
        case isWatched
        case runsOnServer = "laufServer"
    }

    public var position: TimeInterval
    public var duration: TimeInterval
    public var isWatched: Bool
    /// **The server has decided that watching continues here** — for Jellyfin: a
    /// position above zero and not watched. `nil` for states without a server (IPTV, channels).
    ///
    /// **The finding (on-device test 2026-09-28):** "The Habauple Joubrespait Roudiok" watched for 110 s
    /// on the phone, 1.1 %. Jellyfin lists it as resumable (threshold 1 %), the Top Shelf
    /// showed it — the app demanded 2 %, left it out of "Continue Watching" and offered
    /// "Play". Two rules for the same question; now the server's applies.
    public var runsOnServer: Bool?

    public init(
        position: TimeInterval, duration: TimeInterval, isWatched: Bool = false, runsOnServer: Bool? = nil
    ) {
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.runsOnServer = runsOnServer
    }

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    public var remaining: TimeInterval {
        max(0, duration - position)
    }

    /// Whether the title belongs under "Continue Watching".
    ///
    /// The thresholds are set deliberately: whoever only looked in briefly
    /// does not want an entry in the list, and whoever is almost through does not either —
    /// the next episode should already be there.
    ///
    /// **Jellyfin's thresholds also for states without a server** (1 % and 90 %, the defaults in
    /// `MinResumePct`/`MaxResumePct`) — so that an IPTV movie sits in the row by the same
    /// rules as a movie from the media server.
    public var isResumable: Bool {
        guard !isWatched, duration > 0 else { return false }
        if let runsOnServer { return runsOnServer }
        return fraction > 0.01 && fraction < 0.90
    }

    /// Where a playback begins — **the one rule for TV and phone** (AP58 R0).
    ///
    /// **A saved state** resumes only what ``isResumable`` counts as started,
    /// measured against the length of the title. Near the end (from 95 %) it means "from the start":
    /// there "Continue Watching" already shows the next episode, and whoever opens the title
    /// anyway wants to watch it and not the credits. A state **beyond** the end falls
    /// under the same rule — the fraction is capped at 1 and is thus no longer
    /// resumable.
    ///
    /// **A fixed position** (chapter, remote, rebuild in the middle of the film) means
    /// exactly this position, even in the last five percent — whoever picks the chapter "Credits"
    /// wants the credits. Only **at or beyond the end** does it mean "from the start".
    ///
    /// **Why this check lives here and not in the engine.** Until 2026-09-25 it sat
    /// in the VLC engine (`resumesSomething`) and measured against the length the engine itself saw.
    /// The native engine jumps immediately on loading, before it knows a length, and caps
    /// an overly large jump only at the end — the movie then ended as soon as it was opened. The
    /// engine's length would also be the wrong yardstick for this: on the remuxer route the
    /// playlist is still growing, and half a list would have discarded every real resume point.
    /// The length of the title, in contrast, is already known before loading.
    ///
    /// - Parameters:
    ///   - fest: An explicitly chosen position — it takes precedence over the state.
    ///   - stand: The saved progress, or `nil` for "from the start".
    ///   - laenge: The runtime of the title; without it the length in the state applies.
    public static func startPoint(
        fixed: TimeInterval? = nil, state: PlaybackProgress?, length: TimeInterval?
    ) -> TimeInterval {
        let known = length.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let fixed {
            guard let end = known ?? state?.duration, end > 0 else { return max(0, fixed) }
            return fixed < end - 1 ? max(0, fixed) : 0
        }
        guard let state else { return 0 }
        let measured = PlaybackProgress(
            position: state.position, duration: known ?? state.duration,
            isWatched: state.isWatched, runsOnServer: state.runsOnServer)
        return measured.isResumable ? state.position : 0
    }
}
