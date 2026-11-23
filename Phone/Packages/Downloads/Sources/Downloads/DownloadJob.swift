import Core
import Foundation

/// A download job: what is fetched, from where, to what extent and under which rule.
///
/// **Until 2026-09-08 it was called `Job`, and that was one word too many.** "Auftrag" is
/// already taken in this project — `FeaturesPhone.Job` is a **state with exactly one
/// next step**, the counterpart to a plain notice ("Signed in expired ·
/// Sign in again"). Two things with one name are allowed in separate packages and are
/// still a mix-up in the reader's head; here it was made worse by the view package
/// knowing both, and the translator rightly refusing.
///
/// **The download job describes the route, not the address.** That is not a subtlety but
/// the condition for a portal being allowed into the downloads at all: a resolved video
/// address is valid for five minutes, a film takes longer to download. Whoever stored the
/// address would have a dead download job after five minutes; whoever stores the route
/// fetches a new address. Executed in ``PortalJob``.
///
/// **For Jellyfin and for the provider the route is trivial** — the ID is enough. The type
/// still does not distinguish three kinds of job: what differs is the resolving, and that
/// is in ``target``.
public struct DownloadJob: Sendable, Hashable, Identifiable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4). **One exception:**
    /// ``host`` is stored as `host`; ledgers written under an earlier name are rewritten by
    /// the build that wrote them before the ledger is read.
    private enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case beside = "neben"
        case source = "quelle"
        case extent = "umfang"
        case runtime = "laufzeit"
        case tier = "stufe"
        case host
        case version = "fassung"
        case rule = "regel"
        case estimatedSize = "groesseGeschaetzt"
        case sizeIsCertain = "groesseSicher"
    }

    public struct Identifier: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ value: String) { self.rawValue = value }
    }

    public let id: Identifier

    /// What the viewer sees — title and second line.
    public let title: String
    public var beside: String?

    public let source: SourceKind
    public let extent: Extent

    /// How long **one** episode or the film runs — **`nil` where the source does not say.**
    ///
    /// **New on 2026-09-09, from a reported finding:** nearly all portal items showed
    /// 720 MB. The size in the download sheet came from a hard-coded assumption of 48
    /// minutes, because there was no field in which a real runtime could be stored. Now there
    /// is one, and where it stays empty, no size is shown.
    ///
    /// **It belongs on the download job and not only on the view**, because it is needed
    /// twice: once before queuing for the size in the sheet and once afterwards for
    /// ``TimeEstimate`` — and a download job outlives the sheet it came from.
    ///
    /// **Measured on the bridge on 2026-09-09:** `/p/serieshub/list` returns
    /// `dauer_minuten: null` for every episode of "Bloufeit". For the portals `nil` is therefore
    /// the normal case and not an exception — Jellyfin, by contrast, carries `MediaItem.runtime`.
    public var runtime: TimeInterval?

    /// The chosen tier. **Set only for the media server**; the others deliver what they
    /// deliver, and a tier next to them would claim a choice that does not exist.
    public var tier: StreamQuality?

    /// For a portal: which host and which language version.
    ///
    /// **The version is the decision that cannot be made up later.** Resolution is an
    /// annoyance on a plane; a wrong audio track makes the title unusable, and choosing
    /// again is impossible without a network.
    public var host: String?
    public var version: String?

    public var rule: NetworkRule

    /// How large it is expected to become. **For a portal only certain after the first
    /// `Content-Length`** — until then "about" stands next to it, and that is not a
    /// courtesy but the difference between an estimate and a number.
    ///
    /// **`0` means "unknown", not "empty" (2026-09-09).** Without ``runtime`` there is no
    /// estimate, and zero is the only number that can be summed safely in ``Downloads/bytes`` and
    /// ``BulkSelection`` without claiming a size. Whoever **displays** a number here checks
    /// for `> 0` first — otherwise the screen says "0 bytes" where "unknown" was meant.
    public var estimatedSize: Int64
    public var sizeIsCertain: Bool

    public init(
        id: Identifier, title: String, beside: String? = nil,
        source: SourceKind, extent: Extent, runtime: TimeInterval? = nil,
        tier: StreamQuality? = nil, host: String? = nil, version: String? = nil,
        rule: NetworkRule = NetworkRule(),
        estimatedSize: Int64 = 0, sizeIsCertain: Bool = false
    ) {
        self.id = id
        self.title = title
        self.beside = beside
        self.source = source
        self.extent = extent
        self.runtime = runtime
        self.tier = tier
        self.host = host
        self.version = version
        self.rule = rule
        self.estimatedSize = estimatedSize
        self.sizeIsCertain = sizeIsCertain
    }

    /// Whether this download job is fully described.
    ///
    /// **The check differs per source, which is why it lives here and not on the view.** A
    /// portal job without a language version is not a half download job but one that will
    /// take the wrong audio track along — and the viewer notices that on the plane. A
    /// Jellyfin download job without a tier, by contrast, is not one at all: there are six,
    /// and none of them is the obvious one.
    public var complete: Bool {
        switch source {
        case .jellyfin: tier != nil
        case .provider: true
        case .portal: host != nil && version != nil
        }
    }
}
