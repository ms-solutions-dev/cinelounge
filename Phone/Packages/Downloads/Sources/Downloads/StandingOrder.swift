import Core
import Foundation

/// A standing order: **always keep the next episodes of this series ready.**
///
/// **It hangs on the series and not on an episode**, and that is why it is a type of its
/// own next to ``DownloadJob``. The episode on which the switch was flipped is watched and
/// removed after three days; a field on its job would disappear with it.
///
/// **It carries along the choice under which it was created.** Whoever chose 720p means
/// that for the topped-up episodes too — a delivery in a different tier would be a decision
/// that nobody made, and it would be noticed only on the plane.
public struct StandingOrder: Sendable, Hashable, Codable, Identifiable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case series = "serie"
        case source = "quelle"
        case tier = "stufe"
        case rule = "regel"
    }

    public let series: String
    public let source: SourceKind

    /// The tier in which episodes are topped up — **set only for the media server**, as at
    /// ``DownloadJob/tier``.
    public var tier: StreamQuality?

    public var rule: NetworkRule

    public var id: String { series }

    public init(
        series: String, source: SourceKind, tier: StreamQuality? = nil,
        rule: NetworkRule = NetworkRule()
    ) {
        self.series = series
        self.source = source
        self.tier = tier
        self.rule = rule
    }

    /// The job for a topped-up episode.
    ///
    /// **The size is estimated and says so** (``DownloadJob/sizeIsCertain``): It arises from
    /// runtime and tier, not from a `Content-Length`. A number without this caveat would sit in
    /// the storage budget next to measured ones and look just the same.
    public func job(
        identifier: String, title: String, beside: String?, extent: Extent, bytes: Int64
    ) -> DownloadJob {
        DownloadJob(
            id: .init(identifier), title: title, beside: beside, source: source, extent: extent,
            tier: source == .jellyfin ? tier : nil, rule: rule,
            estimatedSize: bytes, sizeIsCertain: false)
    }
}
