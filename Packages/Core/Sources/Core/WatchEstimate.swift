import Foundation

/// How long a series lasts in total and how much of it is still outstanding.
///
/// **Estimated, not measured** — and for one reason: The field the server keeps
/// for the total runtime of a series is unusable. For one series it is missing
/// entirely, for another it contains the runtime of a *single* episode: 0.4 hours
/// for 41 episodes. Anyone who relies on it displays nonsense.
///
/// The calculation therefore goes by the episode count. That is imprecise where
/// episodes differ in length — for a series with double episodes or a deviating
/// opener. For the question "can I still finish this tonight?" it is precise
/// enough, though, and that is what matters here.
///
/// The imprecision has to be **visible**: The display rounds to half hours and puts
/// an "about" in front. A figure like "14 h 23 min" would claim an accuracy that is
/// not there.
public struct WatchEstimate: Sendable, Equatable {

    /// Gesamtdauer aller Folgen in Sekunden.
    public let total: TimeInterval
    /// What of it is still outstanding.
    public let remaining: TimeInterval
    /// Anteil des Gesehenen, 0 bis 1.
    public let watchedFraction: Double

    public init(total: TimeInterval, remaining: TimeInterval, watchedFraction: Double) {
        self.total = total
        self.remaining = remaining
        self.watchedFraction = watchedFraction
    }

    /// Derives the estimate from what the server supplies per title.
    ///
    /// Returns `nil` if the basis is missing — no episode count or no runtime. Then
    /// nothing is displayed, instead of claiming a zero.
    public static func forSeries(_ item: MediaItem) -> WatchEstimate? {
        guard let episodes = item.episodeCount, episodes > 0 else { return nil }

        // For a series the runtime stands for one episode — exactly what is needed. If
        // it is missing, nothing can be calculated.
        guard let perEpisode = item.runtime, perEpisode > 0 else { return nil }

        let total = perEpisode * Double(episodes)

        // Without a value the default is: nothing watched. That is the cautious
        // assumption — it shows too much remaining time rather than too little.
        let unplayed = item.unplayedCount ?? episodes
        let remaining = perEpisode * Double(min(max(unplayed, 0), episodes))

        let watched = Double(episodes - min(max(unplayed, 0), episodes)) / Double(episodes)
        return WatchEstimate(total: total, remaining: remaining, watchedFraction: watched)
    }

    /// For a single film or a video: There the runtime is the truth.
    public static func forSingle(_ item: MediaItem) -> WatchEstimate? {
        guard let runtime = item.runtime, runtime > 0 else { return nil }

        let watched = item.progress?.fraction ?? 0
        return WatchEstimate(
            total: runtime,
            remaining: runtime * (1 - min(max(watched, 0), 1)),
            watchedFraction: watched
        )
    }

    public static func of(_ item: MediaItem) -> WatchEstimate? {
        item.kind == .series ? forSeries(item) : forSingle(item)
    }

    /// Whether anything is still outstanding at all — under one minute counts as done.
    public var hasRemaining: Bool { remaining >= 60 }

    /// A duration as text — `2 h 30 min`, `45 min`, `3 h`. For series rounded to half
    /// hours (``roundedToHalfHours(_:)``): The number is estimated, and that should
    /// be apparent from it.
    ///
    /// **Shared since decision 27 (C7)** — the TV shows the watch time next to the
    /// grid, the phone on the detail page; both with the same notation.
    public static func durationText(_ seconds: TimeInterval, roundedValue: Bool) -> String {
        let value = roundedValue ? roundedToHalfHours(seconds) : seconds
        let hours = Int(value) / 3600
        let minutes = (Int(value) % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) h" }
        return "\(hours) h \(minutes) min"
    }

    /// Rounded to half hours, in seconds.
    ///
    /// The rounding belongs in the calculation and not in the label: That way every
    /// display uses the same one, and one place does not show "14 h" and another
    /// "13.8 h".
    ///
    /// **Under half an hour rounded up to five minutes** (review 2026-09-27, D6). Half
    /// hours turned ten open minutes of a children's series into "About 0 min left" —
    /// above a line that only appears because something is still outstanding. Rounded
    /// up and not rounded, so that a remaining time above zero never becomes zero.
    public static func roundedToHalfHours(_ seconds: TimeInterval) -> TimeInterval {
        let halfHour: TimeInterval = 1800
        let fiveMinutes: TimeInterval = 300
        guard seconds > 0 else { return 0 }
        if seconds < halfHour { return (seconds / fiveMinutes).rounded(.up) * fiveMinutes }
        return (seconds / halfHour).rounded() * halfHour
    }
}
