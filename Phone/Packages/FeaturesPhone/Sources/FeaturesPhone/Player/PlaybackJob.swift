import Core
import Foundation
import PlaylistKit
import PortalKit

/// What you enter the player with — **a request and not a string.**
///
/// **Decided on 2026-09-06 as direction K6a.** The player was drawn; what was cut wrong was the
/// contract you enter it with. Until then a bare identifier traveled, and whoever got it
/// had to guess where it came from. The guessing went wrong on two of five tabs:
/// ``CompositePlayerSource`` knew two of four sources, every channel identifier fell
/// through to the Jellyfin server, and the failure was reported as "No response from the
/// Jellyfin server" over an Xtream broadcast.
///
/// **A channel cannot be recognized by its identifier — and that stays so.**
/// `XtreamPayload:136` justifies today's channel identifier by saying it survives a
/// reload and favorites are not lost; a prefix in it would be an intervention in a shared
/// package to solve a UI problem. So the origin travels along instead of being read from
/// the identifier.
public struct PlaybackJob: Sendable, Equatable {

    public let identifier: String
    public let origin: Catalog.Origin

    /// Where to begin. **It travels along**, because otherwise "From the beginning" and every
    /// chapter jump would get lost on the way: `playFrom` received the position from the
    /// detail page and threw it away because only a string was passed on.
    ///
    /// `nil` does **not** mean zero but "the server should say where" — the progress is kept
    /// on the user account and may come from the TV. Zero explicitly means from the
    /// beginning.
    public let startAt: TimeInterval?

    /// Which host to play from — **only for portals, and only when chosen.**
    ///
    /// `nil` means "take the first usable one", and that is the normal case: the bridge
    /// orders the hosts itself, moves the version in the chosen language to the front and
    /// works through them in turn. The identifier is set only by the source choice in the
    /// player — the one place where someone has seen what is on offer.
    public let source: String?

    /// Whether this startup should avoid the app's **own** repackager.
    ///
    /// **The second startup and never the first.** ``PlayerModel`` sets the flag after
    /// ``RepackagerRun/start(_:)`` has thrown: a Matroska without a seek table, a server
    /// without range requests, a certificate only the app trusts — then the app cannot read
    /// the file itself, and the Jellyfin server should segment it. What that costs and when
    /// it goes away is documented at ``JellyfinPlayerSource/isServable(_:withoutRepackager:)``.
    ///
    /// **It travels in the request and not in the model**, because ``CompositePlayerSource``
    /// sits between the two: the switch passes the request through, and a field on the model
    /// would never reach the source.
    public let withoutRepackager: Bool

    /// Which series this episode belongs to — `nil` for everything that is not an episode.
    ///
    /// **It travels along because nobody can compute it later** (finding of 2026-09-07): A portal
    /// assigns episode identifiers like `serieshub:1-mebik:` — the series cannot be
    /// derived from that, and the bridge keeps none for an episode. It is known exactly
    /// **once**: on the detail page from which playback starts. Whoever does not pass it on
    /// there has lost it forever.
    ///
    /// **What for:** The history records it, and the "Continue Watching" tile thereby leads
    /// to the **series** instead of the episode. Without it, the tile said "Bloufeit" and opened
    /// "1 - Mebik" — a page with a runtime and nothing else.
    public let series: String?

    /// What the series is **called** — `nil` for everything that is not an episode.
    ///
    /// **The finding of 2026-09-07, read off the simulator's history.** The one portal entry there
    /// carried `title` and `beside` twice: both "1 - Mebik". The history entry arises
    /// from what the **player** knows about the running file, and that is the episode; the
    /// series is known only to the page from which playback was started.
    ///
    /// **Without this name, label and target contradict each other.** Since the tile leads to
    /// the series (``series``), it would otherwise say "1 - Mebik" on a tile that opens
    /// "Bloufeit" — worse than before, when at least both were the episode. It cannot be fetched
    /// from the key: `serieshub|serieshub:1-mebik:|…` does carry a
    /// `TVShowTitle=Bloufeit` in its address, but that is the spelling of **one** portal —
    /// Animehub spells it differently, the ARD not at all. The same reasoning as at
    /// ``series``, and the same answer: it travels along.
    public let seriesTitle: String?

    /// Which past broadcast is played **as a recording** — `nil` means: the channel live
    /// (decision 27, A2, 2026-09-26).
    ///
    /// **It travels in the request because only the daily schedule knows it.**
    /// ``ChannelPlayerSource`` builds the address from the channel it finds via the filtered
    /// source — a channel that parental controls hide is therefore not found as a recording
    /// either.
    public let catchUp: CatchUpRequest?

    /// A past broadcast of an archive channel.
    public struct CatchUpRequest: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let title: String

        public init(start: Date, end: Date, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    public init(
        identifier: String, origin: Catalog.Origin, startAt: TimeInterval? = nil,
        source: String? = nil, withoutRepackager: Bool = false, series: String? = nil,
        seriesTitle: String? = nil, catchUp: CatchUpRequest? = nil
    ) {
        self.identifier = identifier
        self.origin = origin
        self.startAt = startAt
        self.source = source
        self.withoutRepackager = withoutRepackager
        self.series = series
        self.seriesTitle = seriesTitle
        self.catchUp = catchUp
    }

    /// The same request, this time without the app's own repackager.
    ///
    /// **From the position where it stalled.** The second startup is not a new title; whoever
    /// let it begin at zero would take Continue Watching away from the viewer because of a
    /// failure of the app.
    public func withoutOwnRepackager(from location: TimeInterval?) -> PlaybackJob {
        PlaybackJob(
            identifier: identifier, origin: origin, startAt: location ?? startAt, source: source,
            withoutRepackager: true, series: series, seriesTitle: seriesTitle, catchUp: catchUp)
    }

    /// The same request with a different host, from a different position.
    ///
    /// **The position goes along, and that is the point.** A host switch in the middle of a
    /// film is a restart; without the position it would begin at zero again, and the viewer
    /// would have paid twenty minutes for a better source.
    public func at(source incoming: String, from location: TimeInterval) -> PlaybackJob {
        // **`withoutRepackager` goes along.** A host switch is not a new attempt at the app's own
        // repackager: whoever has already fallen back to server segmentation would otherwise run
        // into the same failure at the next host and lose the half minute up to that point again.
        PlaybackJob(
            identifier: identifier, origin: origin, startAt: location, source: incoming,
            withoutRepackager: withoutRepackager, series: series, seriesTitle: seriesTitle,
            catchUp: catchUp)
    }

    /// The same request, only from a different position — **everything else travels along**:
    /// source, repackager flag, series, series name, look-back. For "Resolve again" (player
    /// review, finding S3); there, series and flag were dropped until then.
    public func from(_ location: TimeInterval) -> PlaybackJob {
        PlaybackJob(
            identifier: identifier, origin: origin, startAt: location, source: source,
            withoutRepackager: withoutRepackager, series: series, seriesTitle: seriesTitle,
            catchUp: catchUp)
    }

    /// A request whose origin is read from the identifier.
    ///
    /// **For the paths that bring no origin** — tiles from library, search, Home and the
    /// detail page. For the Live tab this path explicitly does not exist: see
    /// ``origin(zu:)``.
    public init(
        identifier: String, startAt: TimeInterval? = nil, series: String? = nil,
        seriesTitle: String? = nil
    ) {
        self.init(
            identifier: identifier, origin: Self.origin(zu: identifier), startAt: startAt,
            series: series, seriesTitle: seriesTitle)
    }

    /// Where an identifier comes from, **when nobody sent it along.**
    ///
    /// Portal and provider catalog read back what they generated themselves — the same rule
    /// as in ``AggregateDetailSource``, and for the same reason: asking in sequence would mean
    /// presenting every portal title to the Jellyfin server first and every Jellyfin title to
    /// the provider, whose account allows **one** connection.
    ///
    /// **A channel does not come out of this, and that is no oversight.** Its identifier
    /// carries no marker and should not get one. Whoever plays a channel sends
    /// ``Catalog/Origin/channelList`` along — the Live tab is the only place that does so,
    /// and it knows it for certain there.
    ///
    /// **Since AP58 R6 the rule lives in `Core`** (``Core/Origin/forItem(identifier:)``) — the same
    /// one the TV and the Top Shelf rule ask. Only the mapping onto this app's finer-grained
    /// notion remains here.
    public static func origin(zu identifier: String) -> Catalog.Origin {
        Catalog.Origin(Core.Origin.forItem(identifier: identifier))
    }
}
