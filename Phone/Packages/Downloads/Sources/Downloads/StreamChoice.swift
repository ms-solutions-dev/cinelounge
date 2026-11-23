import Core

/// Which tier of an HLS master playlist is fetched.
///
/// **Connected and not placed beside** — that is the whole purpose of this file.
/// ``Selection`` has known the case ``Selection/slots(_:)`` since 2026-09-08 and says there
/// verbatim what it is waiting for: *"What fills it again is a source that lists **finished**
/// tiers, not one that first produces them."* An HLS master playlist is exactly that —
/// five pre-produced renditions, each downloadable on its own. That is the same fact that
/// the roadmap noted on 2026-09-08 as the Aloha answer: *"Aloha chooses between variants
/// that exist."*
///
/// **A second selection next to ``SelectionRule`` would be the place where the two
/// diverge** — and one would only notice when a download entry looks different from
/// the same title in the player. The same reasoning has stood since 2026-09-08 at
/// ``SelectionRule/slots`` for ``Core/StreamQuality``, and it applies one level higher
/// in the same way.
public enum StreamChoice {

    /// What this master playlist offers to choose from — **as an ``Selection`` and not as a list of its own.**
    ///
    /// With this the case ``Selection/slots(_:)`` is filled from a real source for the first
    /// time. The order is that of the display: best first.
    public static func selection(_ slots: [StreamPlaylist.Tier]) -> Selection {
        let sortedEntries = ordered(slots).map(quality)
        guard !sortedEntries.isEmpty else { return .asDelivered }
        // Duplicates are dropped: two renditions can fall into the same tier (ARD
        // delivers 480x270 and 640x360, both "minimal"), and a list that shows the same
        // word twice is not a choice.
        var seen: Set<StreamQuality> = []
        return .slots(sortedEntries.filter { seen.insert($0).inserted })
    }

    /// Which tier is fetched.
    ///
    /// - Parameter hoechstens: The upper limit from the download job (``DownloadJob/tier``).
    ///   **`nil` means "no limit" and therefore the best** — that is what the brief of
    ///   2026-09-09 says: *"Without a value: the highest resolution the job allows."* In
    ///   practice a limit almost always arrives, because ``SelectionRule/suggestion`` is set to
    ///   720p; the reasoning for that (12.4 GB versus nine hours of cellular, and on
    ///   six inches not distinguishable) applies here unchanged.
    ///
    /// **If none fits, the smallest is taken and there is no rejection.** That is the same
    /// decision that ``Core/StreamQuality/minimal`` carries: *"Looks bad and
    /// plays — that is the point."* A rejection would be especially bad here, because it
    /// would declare a title undownloadable that the same viewer can
    /// play a second later.
    public static func take(
        _ slots: [StreamPlaylist.Tier], atMost: StreamQuality? = nil
    ) -> StreamPlaylist.Tier? {
        let ordered = self.ordered(slots)
        guard let smallest = ordered.last else { return nil }
        guard let atMost else { return ordered.first }
        return ordered.first { matches($0, in: atMost) } ?? smallest
    }

    /// Best first.
    ///
    /// **Ordered by picture height and only then by bandwidth.** The other way round,
    /// a 720p rendition with a high rate would beat a 1080p with a frugal one — and what the
    /// viewer chooses in the download sheet is a resolution and not an amount of data. The rate
    /// decides only where two renditions have the same height; then it is
    /// indeed the difference.
    static func ordered(_ slots: [StreamPlaylist.Tier]) -> [StreamPlaylist.Tier] {
        slots.sorted {
            if ($0.height ?? 0) != ($1.height ?? 0) { return ($0.height ?? 0) > ($1.height ?? 0) }
            return ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0)
        }
    }

    /// Whether this rendition stays under the upper limit — **by picture width and not by
    /// rate.**
    ///
    /// **The first draft checked both, and the check refuted it.** The measured
    /// ARD master playlist lists its 720p rendition with `BANDWIDTH=4008160`; the upper limit
    /// ``SelectionRule/suggestion`` is 720p and carries `bitrate` = 2 000 000. Comparing both,
    /// the 720p rendition failed, and 480x270 was chosen — for a
    /// viewer who tapped "720p".
    ///
    /// **The two numbers do not measure the same thing.** `StreamQuality.bitrate` is a
    /// **target for a transcoder** ("make me 720p at 2 Mbit at most"); `BANDWIDTH`
    /// in an HLS playlist is the **peak rate of a finished rendition**, and for
    /// 720p50 that regularly lies around four. Whoever compares them rejects exactly the
    /// version that was meant.
    ///
    /// **The rate decides only where there is no width.** It is missing in the standard not
    /// rarely, and then it is the only information about the size.
    static func matches(_ tier: StreamPlaylist.Tier, in limit: StreamQuality) -> Bool {
        if let has = tier.width {
            guard let width = limit.maxWidth else { return true }
            return has <= width
        }
        guard let rate = limit.bitrate, let has = tier.bandwidth else { return true }
        return has <= rate
    }

    /// Which tier of the project this rendition is — **for display, not for selection.**
    ///
    /// **By picture height and not by rate.** The rate of a rendition is what
    /// its encoder needed; the height is what the viewer sees. In the measured
    /// ARD example (2026-09-09) the 1080p rendition carries 6.0 Mbit/s — by rate it would be
    /// "high" (8 Mbit) and thus the same word as a 1080p with 4 Mbit. By height
    /// it is right.
    static func quality(_ tier: StreamPlaylist.Tier) -> StreamQuality {
        switch tier.height ?? 0 {
        case 1400...: .veryHigh
        case 1000..<1400: .high
        case 700..<1000: .low
        case 1..<700: .minimal
        // **Without `RESOLUTION` only the rate remains.** It is missing in the standard not rarely;
        // a rendition with neither cannot be classified and is then called "Original" —
        // more honest than an invented tier.
        default: tier.bandwidth.map { StreamQuality.fitting($0) } ?? .unlimited
        }
    }
}
