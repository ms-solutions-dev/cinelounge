import Core
import Foundation

/// A coherent set of titles that a service carries as a unit of its own —
/// **the basic unit of this model.**
///
/// Six Jellyfin libraries are six catalogs, "Live", "Sport", "VOD films" and "VOD series"
/// of a channel list are four, nine portals are nine.
///
/// **Why not ``Tab``.** A tab is a place in a bar that has five at most. That is a
/// display budget and no statement about content; a model whose basic unit is a budget item
/// cannot carry anything that currently gets no place — and that is exactly where the
/// rejected tier ladder failed.
///
/// **Why not the source.** Behind *one* media server lie six catalogs; behind *one* Xtream
/// access lie channels, schedule, films and series. The source answers "where do the bytes
/// come from", not "what is there".
public struct Catalog: Sendable, Hashable, Identifiable {

    /// **Composed and never the provider's raw ID.**
    ///
    /// Xtream carries **separate number ranges** for films and series — the same number means
    /// a different section for the other kind (see `Core.VODMemory`). A raw ID as key would
    /// lead, when switching, into a section that does not exist there.
    public struct Identifier: Sendable, Hashable, Codable, RawRepresentable {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ origin: Origin, _ kind: Genre, _ raw: String) {
            self.rawValue = "\(origin.rawValue):\(kind.rawValue):\(raw)"
        }
    }

    /// Where a catalog comes from.
    ///
    /// **The downloads appear in the list even though they are no service.** They are the
    /// excerpt of the others that already lies on the device — and they must stay reachable
    /// even when the access they come from has been removed.
    public enum Origin: String, Sendable, Hashable, Codable, CaseIterable {
        case jellyfin = "medienserver"
        /// The channels of a provider — what runs in the Live tab.
        case channelList = "senderliste"
        /// The **catalog** of a provider: films and series on demand.
        ///
        /// **Its own origin and not `channelList`** (user finding 2026-09-05: In the register, "Provider
        /// · Films" stood under the heading **LIVE**). Both come from the same access, but they are
        /// not the same: Channels run by schedule and belong in the Live tab, a catalog is
        /// searched and belongs in the library. Merged, one would decide the tab bar of the other.
        case provider = "anbieter"
        case portals = "portale"
        case downloads = "vorrat"
    }

    public let id: Identifier
    public let origin: Origin
    public let label: CaptionLabel
    public let kind: Genre

    /// The identifier at the provider — what you query it with.
    public let sourceIdentifier: String

    /// The heading under which it stands in the register.
    ///
    /// **User finding of 2026-09-05: what is the IPTV provider called, and how would the system
    /// behave if several IPTV providers had been set up?** The answer was uncomfortable: Yes —
    /// and with two accesses the same wording would stand there twice, without any difference.
    /// A fixed heading per origin can only name as many services as there are origins.
    ///
    /// Hence the catalog carries its group itself: for the media server the key "Media
    /// server", for the provider **its name**. Two providers yield two sections, and you can
    /// see which is which. `nil` means "take the heading of the origin" — that is the normal
    /// case.
    public let group: CaptionLabel?

    /// How many titles. `nil` means **"not counted"**, not "zero".
    ///
    /// The difference decides the display: A missing number stays away, a zero says "nothing
    /// here" — and a catalog with zero titles does not appear at all, by the same rule as an
    /// empty shelf.
    public let extent: Int?

    public init(
        id: Identifier, origin: Origin, label: CaptionLabel, kind: Genre,
        sourceIdentifier: String, extent: Int? = nil, group: CaptionLabel? = nil
    ) {
        self.id = id
        self.origin = origin
        self.label = label
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.extent = extent
        self.group = group
    }

    /// Whether this catalog has anything to show.
    ///
    /// A library with zero titles — on the test server "Folders" is exactly that — is not
    /// information but a building site. The same rule as for the shelf without content, only
    /// one level higher.
    public var hasContent: Bool { extent != 0 }
}

extension Catalog.Origin {

    /// The readable origin (``Core/Origin``) as a concept of this app.
    ///
    /// **The three cases carry the same raw values** — channel list and downloads never come
    /// out of an identifier (the reasoning stands at ``PlaybackJob/origin(zu:)``).
    public init(_ origin: Core.Origin) {
        switch origin {
        case .jellyfin: self = .jellyfin
        case .provider: self = .provider
        case .portals: self = .portals
        }
    }
}
