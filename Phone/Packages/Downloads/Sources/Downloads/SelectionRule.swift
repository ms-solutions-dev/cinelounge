import Core

/// What a source offers to choose before loading.
///
/// Three sources, three different questions — and none of them is "which resolution would
/// you like":
///
/// * **Jellyfin** offers **one** — the file that is there. Until 2026-09-08 there were six
///   tiers here, "because the server converts". It converts; only the result is not a
///   download but a stream (see below).
/// * **The provider** offers **one**: It holds exactly one stream per title, and nobody
///   converts — not the app, not the provider. That is stated as a sentence and not as a
///   list with one entry.
/// * **A portal** offers **host and language version**, and at the ARD real tiers.
///
/// **Until 2026-09-08 this said the opposite:** "Portals none at all, because nothing is
/// downloaded there." Both halves of the sentence are measured to be wrong. Measured on
/// 2026-09-06 at the bridge, `/sources` for Animehub returns **twelve rows for one episode** —
/// four hosts times three language versions —, for the ARD **ten rows that are not hosts
/// at all but resolution tiers**. There is more to choose there than at the provider, not
/// less. And from now on it is loaded there; the reasoning is at ``PortalJob``.
///
/// ## Why the media server lost its six tiers
///
/// **The question came from the product owner (2026-09-08):** *"With Aloha Browser you can
/// select the resolution beforehand — how does that work there?"* Answer: Aloha chooses
/// between variants **that exist** — finished files or pre-produced HLS renditions, all
/// static, all individually loadable.
///
/// **Jellyfin has one file.** Every other resolution comes into being only when
/// requested, and measured on 2026-09-08 against this household's server:
///
/// | Request | Response |
/// |---|---|
/// | `stream?static=true` (the file) | **206**, `Accept-Ranges: bytes` |
/// | `stream.mp4?VideoBitrate=…` (converted) | **200**, `Accept-Ranges: none` |
/// | HLS segment 500 | **byte-identical to segment 0** |
/// | HLS with `StartTimeTicks` | **HTTP 400** |
///
/// A running encoding job is not an archive: The segment number is ignored, and every new
/// request starts at zero. Over HLS one could only load sequentially from the front — if
/// the cell drops at minute 40, the whole movie starts over. That is exactly what
/// `stock.resumableWhy` has warned about since E16, only there about portal hosts.
///
/// **And the choice would be empty anyway:** Of sixty movies in this library, **sixty**
/// carry exactly one version. There is nothing to pick — only something to recompute.
///
/// **Where the choice is real, it stays:** at the portals (host and language version), and
/// where a title really has two versions, that is the selection — the sources sheet has
/// shown it since E16.
public enum Selection: Sendable, Equatable {

    /// The server converts. The order is that of the display: best first.
    ///
    /// **Nobody chooses it any more today** — the case stays because the display is built for
    /// it and there are sources with real variants. What fills it again is a source that holds
    /// **finished** tiers, not one that first produces them.
    case slots([StreamQuality])

    /// There is exactly one version. **Not an error case, a catalog.**
    ///
    /// At the provider because it holds one stream per title — measured on 2026-09-08: `206` with
    /// `Content-Range`, even in the middle of a 2.3 GB file. At the media server because **one
    /// file** lies there and everything else would first be computed.
    case asDelivered

    /// Host and language version. Which exist, only the bridge knows.
    case sourcesAndVersion
}

public enum SelectionRule {

    /// **The six tiers are `StreamQuality` and not a ladder of their own.** They are in
    /// `Core`, the player uses them, and so does the provider catalog. A second enumeration of
    /// the same thing here would be the place where the two drift apart — and one notices only
    /// when a download item looks different from the same title in the player.
    ///
    /// **The design draws four of them** (Original · 1080p converted · 720p · 540p). That is
    /// not a deviation but a display decision: `unlimited` is "Original", and `veryHigh`
    /// appears only where 4K exists at all.
    public static let slots: [StreamQuality] = [
        .unlimited, .veryHigh, .high, .medium, .low, .minimal,
    ]

    /// What is chosen without any action.
    ///
    /// **720p and not "as good as possible".** The same season in 4K would be 12.4 GB and
    /// about nine hours through a mobile cell; on six inches it cannot be told apart from
    /// 1080p. The higher tier stays visible anyway — otherwise somebody makes the decision by
    /// accident, by doing nothing.
    public static let suggestion: StreamQuality = .low

    /// The same suggestion, **measured against the network** (AP6).
    ///
    /// **Why downward and not upward.** The reason for 720p is the screen size and not the
    /// line — "on six inches it cannot be told apart from 1080p" —, and that holds on Wi-Fi
    /// just the same. A rule that suggested a higher tier at home would override a decision
    /// that has nothing to do with the network.
    ///
    /// **Downward very much so, and there are numbers.** Measured on 2026-09-06. (M1/M6), the same
    /// cellular cell lay between **0.28 and 7.34 Mbit/s** — twenty-six to one, and the
    /// difference was a change of place. 720p through the lower end is not a movie but a
    /// waiting time; the smallest tier gets through.
    ///
    /// **A suggestion and not a limit.** Whoever wants the higher tier chooses it — the list
    /// still shows it. What this rule prevents is the tier somebody gets **without** choosing
    /// it.
    ///
    /// - Parameter grosseMengenVertretbar: from ``NetworkStatus/NetworkPath/largeVolumesAcceptable``
    ///   — carries, not expensive, not low-data. A hotspot is Wi-Fi and still expensive.
    public static func suggestion(largeVolumesAcceptable: Bool) -> StreamQuality {
        largeVolumesAcceptable ? suggestion : .minimal
    }

    public static func forItem(_ kind: SourceKind) -> Selection {
        switch kind {
        case .jellyfin: .asDelivered
        case .provider: .asDelivered
        case .portal: .sourcesAndVersion
        }
    }

    /// Whether this source has anything to decide at all.
    ///
    /// **Needed for "gone instead of greyed out":** Where there is nothing to choose, the
    /// sheet shows a sentence and not a list with one entry.
    public static func choiceIsWorthwhile(_ kind: SourceKind) -> Bool {
        forItem(kind) != .asDelivered
    }
}
