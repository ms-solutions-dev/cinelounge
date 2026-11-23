import Core
import Flows
import Foundation
import ParentalControls
import PlaylistKit

/// Which source plays a title — decided **by its origin.**
///
/// **Four arms, not two, since 2026-09-06** Until then this switch knew only
/// `jellyfin` and `provider`; portals and channels fell through to the Jellyfin
/// server. That was the app's most expensive single bug: **two of five tabs had no
/// playback path at all**, and the failure was reported on top of that as a Jellyfin
/// outage — "No response from the Jellyfin server" over an Xtream broadcast.
///
/// **The decision rests on the origin and no longer on the string.** The
/// ``PlaybackJob`` carries it along; where nobody supplies it, ``PlaybackJob`` reads it
/// from the identifier. This is the same cut as in ``AggregateDetailSource``, only one
/// level earlier: asking in sequence would mean bothering the Jellyfin server first for
/// every provider title — and, the other way round, the provider for every Jellyfin
/// title, whose account allows **one** connection and throttles on request bursts.
///
/// **Exactly one place.** Whoever rebuilds the switch in a second place reopens the gap
/// that was just closed here.
///
/// **And above it, since 2026-09-09, sits a precedence.** What is downloaded here plays
/// from here — whether it came from Jellyfin, from the provider or from a portal. That is
/// not a fifth origin but the right of way over all three: that is exactly what a download
/// is for, and exactly why it works without a network. It stands in **one** place — in
/// ``responsibleSource(_:)`` — and not at each of the eight forwards below it.
public struct CompositePlayerSource: PlayerSource {

    /// The precedence: **the local disk.**
    private let downloads: (any DownloadsSource)?

    private let jellyfin: (any PlayerSource)?
    private let provider: (any PlayerSource)?
    private let channels: (any PlayerSource)?
    private let portals: (any PlayerSource)?

    /// Origins that **do not play at all** — not even from disk.
    ///
    /// **The child profile on the phone** (tvOS roadmap AP45, 2026-09-25): channels, portals
    /// and the provider catalog carry no ratings and drop out in child mode
    /// (``ParentalControls/TabScope/withoutApprovals``). The tabs and shelves were closed,
    /// but a **downloaded** portal title kept playing: the disk precedence only asked whether
    /// the file is there. Here the question comes before the precedence.
    private let locked: Set<Catalog.Origin>

    /// Parental controls **for what plays from disk** (strand G, 2026-09-25).
    ///
    /// ``locked`` asks only about the origin. A **Jellyfin server** title does still
    /// deliver in child mode — just not every one: tabs, shelves and search filter it by
    /// the age limit (``ParentalControls/ProtectionRule/shows(approval:)``). The disk
    /// precedence did not, and a child played a downloaded 18-rated film.
    private let rule: ProtectionRule

    public init(
        downloads: (any DownloadsSource)? = nil,
        jellyfin: (any PlayerSource)? = nil,
        provider: (any PlayerSource)? = nil,
        channels: (any PlayerSource)? = nil,
        portals: (any PlayerSource)? = nil,
        locked: Set<Catalog.Origin> = [],
        rule: ProtectionRule = .pending
    ) {
        self.locked = locked
        self.rule = rule
        self.downloads = downloads
        self.jellyfin = jellyfin
        self.provider = provider
        self.channels = channels
        self.portals = portals
    }

    /// Who answers this request — **first the disk, then the origin.**
    ///
    /// **The finding of 2026-09-09:** A portal title was fully downloaded at 466 MB, and
    /// there was no way to watch it. `.downloads` answered this switch with `nil`, and via the
    /// real origin the title would have gone back to the network — exactly where the download
    /// means it no longer has to go.
    ///
    /// **The question costs one look at the file system and no request.**
    /// ``DownloadsSource/isHere(_:)`` is explicitly not `async`: it may stand in front of
    /// every forward without bothering an account that allows **one** connection.
    ///
    /// **The precedence applies to everything this switch passes through**, and that is
    /// deliberate. A title that plays locally should also answer locally what comes after it
    /// and what gets reported — otherwise half the playback would go over a network that is
    /// not there on a plane. What that means per question is documented at
    /// ``DownloadsPlayerSource``.
    private func responsibleSource(_ job: PlaybackJob) -> (any PlayerSource)? {
        // **Also asked at the identifier:** ``Catalog/Origin/downloads`` travels along from the
        // downloads screen, and a portal title would get past the filter that way.
        guard !locked.contains(job.origin),
            !locked.contains(PlaybackJob.origin(zu: job.identifier))
        else { return nil }
        if let downloads, downloads.isHere(job.identifier) {
            // **And the rating, before the disk plays.** No fallback to the network if it does not
            // fit: the same title via the Jellyfin server would be the same film.
            guard rule.shows(downloads: downloads.description(job.identifier)) else { return nil }
            return downloads
        }
        return byOrigin(job.origin)
    }

    /// The four arms — **as a `switch` and not as a chain of `if`.**
    ///
    /// A `switch` over a closed enumeration reports itself at compile time as soon as an
    /// origin is added. An `if` chain with a trailing `else` does not: it swallows the new
    /// case and sends it to the Jellyfin server — and that is exactly how this bug came about.
    private func byOrigin(_ origin: Catalog.Origin) -> (any PlayerSource)? {
        switch origin {
        case .jellyfin: jellyfin
        case .provider: provider
        case .channelList: channels
        case .portals: portals
        // **Here the downloads are already behind us.** Whoever arrives here with this origin
        // has no finished file on disk — ``responsibleSource(_:)`` would have intercepted them
        // otherwise. "Listed in downloads but not fully downloaded" is nothing to play, and an
        // arm to the Jellyfin server would be exactly the bug from above.
        case .downloads: nil
        }
    }

    public func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
        guard let source = responsibleSource(job) else { throw Missing.source }
        return try await source.target(zu: job)
    }

    /// **The download address also goes through the switch** — and that is no formality.
    ///
    /// **The finding of 2026-09-08:** Without these four lines, the default from the protocol
    /// extension applied to **every** origin, i.e. the playback address; Jellyfin's own
    /// version was never called, and the download run kept failing at the first block. A
    /// switch that does not pass a question through answers it itself — silently and
    /// wrongly. The same kind of bug as the short-circuit line that E24 removed here.
    public func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest {
        guard let source = responsibleSource(job) else { throw Missing.source }
        return try await source.loadTarget(zu: job)
    }

    public func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
    ) async throws {
        try await responsibleSource(job)?.notify(
            location: location, duration: duration, zu: job, isPaused: isPaused)
    }

    /// The next episode — **from the responsible, filtered source**, with its origin checked
    /// once more against the blocked ones before it is offered.
    public func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? {
        guard let episode = try await responsibleSource(job)?.nextEpisode(after: job),
            !locked.contains(PlaybackJob.origin(zu: episode.identifier))
        else { return nil }
        return episode
    }

    public func segments(zu job: PlaybackJob) async throws -> [MediaSegment] {
        try await responsibleSource(job)?.segments(zu: job) ?? []
    }

    public func begin(_ job: PlaybackJob) async throws {
        try await responsibleSource(job)?.begin(job)
    }

    public func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {
        try await responsibleSource(job)?.finish(job, at: location)
    }

    public func host(zu job: PlaybackJob) async throws -> [PortalHost] {
        try await responsibleSource(job)?.host(zu: job) ?? []
    }

    /// **A dedicated error and no silent null case.** "Nothing is set up for this origin" is
    /// something different from "the network does not respond", and the screen says the two
    /// differently — see ``PlayerModel``.
    public func contents(zu job: PlaybackJob) -> (any ContentSource)? {
        responsibleSource(job)?.contents(zu: job)
    }

    /// **Two questions, in the same order as on the TV**
    /// (``ParentalControls/ChildScope/opens(_:origin:)``): Does the origin deliver at
    /// all in child mode, and does the rule let the title through? The responsible source
    /// answers them — without one, the default says no.
    public func mayPlay(_ title: MediaItem, zu job: PlaybackJob) -> Bool {
        guard !locked.contains(job.origin),
            rule.scope.opens(title, origin: job.origin.rawValue),
            let source = responsibleSource(job)
        else { return false }
        return source.mayPlay(title, zu: job)
    }

    enum Missing: Error { case source }
}

/// **The error knows which state belongs to it** — the shared interpretation asks that
/// first (``DisruptionInterpretation``): nothing is set up for this origin, and that is not a
/// network question.
extension CompositePlayerSource.Missing: CarriesState {
    nonisolated var state: PlaybackPhase { .notSetUpYet }
}
