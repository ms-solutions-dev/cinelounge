import Diagnose
import Downloads
import Foundation
import ParentalControls
import PlaylistKit
import PortalKit

/// Which source carries a title — decided **by its identifier**.
///
/// **The finding of 2026-09-05, on screen:** A title from the provider catalog opened
/// "No answer from the media server". The detail page was hard-wired to the media server;
/// a provider identifier (`list#movie#123#mkv`) sent to Jellyfin yields no
/// match, and the failure looks like a network outage. It was not one — the question
/// went to the wrong place.
///
/// **It is decided by the identifier, not by trial and error.** Asking in sequence
/// would mean bothering the media server first for every provider title — and
/// the other way round the provider for every media server title, whose account **allows one**
/// connection and throttles on request bursts. `XtreamVOD.Reference` reads back the identifier
/// it generated itself; it cannot get more exact than that.
public struct AggregateDetailSource: DetailSource {

    private let jellyfin: (any DetailSource)?
    private let provider: (any DetailSource)?
    private let portals: (any DetailSource)?

    /// The downloads — **a source like the others, with two special rights.**
    ///
    /// **It is the only one that answers without a network**, and that is why it appears here
    /// twice: once as the one responsible for its own identifier (``DownloadsDetailSource``,
    /// the reasoning is there) and once as a safety net behind every other. Not
    /// **before** them — what is downloaded is an excerpt, and the library
    /// keeps showing the whole.
    private let downloads: DownloadsDetailSource?

    /// - Parameter vorrat: **No default** (check 2026-09-27, D1). Here it said
    ///   `.standard` — a downloads store without a rule that answered every stored identifier. Whoever
    ///   builds a combined source passes the downloads in with the profile's rule
    ///   (``DownloadsDetailSource/standard(rule:)``).
    public init(
        jellyfin: (any DetailSource)?, provider: (any DetailSource)?,
        portals: (any DetailSource)? = nil,
        downloads: DownloadsDetailSource?
    ) {
        self.jellyfin = jellyfin
        self.provider = provider
        self.portals = portals
        self.downloads = downloads
    }

    /// Whether this identifier comes from the provider.
    ///
    /// **As its own function and not as an `if` in every branch**, because there are four paths
    /// (details, two brands, preview) and a condition copied four times
    /// becomes wrong in three places at the first format change.
    static func fromProvider(_ identifier: String) -> Bool {
        XtreamVOD.Reference(itemID: identifier) != nil
    }

    /// Whether this identifier comes from a portal.
    ///
    /// `PortalItemID` reads back what it generated itself — the same rule as for the
    /// provider, and for the same reason: trial and error would mean presenting every portal title
    /// to the media server first.
    static func fromPortal(_ identifier: String) -> Bool {
        PortalItemID(identifier) != nil
    }

    /// Where an identifier comes from — **one rule, two call sites.**
    ///
    /// **Since 2026-09-08 the download button asks here too.** It has to know whether the sheet shows
    /// steps (media server), a set (provider) or host and language version
    /// (portal). Writing the condition a second time would be exactly what the
    /// comment at ``fromProvider(_:)`` was written against — only that
    /// this time it would not be four paths but two packages.
    public static func origin(_ identifier: String) -> Catalog.Origin {
        if DownloadsDetailSource.key(from: identifier) != nil { return .downloads }
        if fromPortal(identifier) { return .portals }
        return fromProvider(identifier) ? .provider : .jellyfin
    }

    private func responsibleSource(_ identifier: String) -> (any DetailSource)? {
        switch Self.origin(identifier) {
        case .downloads: downloads
        case .portals: portals
        case .provider: provider
        default: jellyfin
        }
    }

    /// **And if the responsible source does not answer, the downloads answer.**
    ///
    /// **This case is not the exception but the one downloads exist for.** Whoever
    /// opens a title from the library on a plane that sits on the disk got
    /// "No answer from the media server" until 2026-09-09 — about a film that can be played
    /// a finger's width away. What was stored is then the only
    /// information there is.
    ///
    /// **First the source, then the downloads.** The order is the whole difference from
    /// a precedence: with a network the complete page appears, without one the stored page — and
    /// nobody has to know beforehand whether there is a network.
    ///
    /// **A block is not a dead zone** (check 2026-09-27, D1). If the source throws
    /// ``ParentalControls/ChildProtectionError/locked``, it stays that way — the downloads would
    /// otherwise have shown exactly the title the filter just rejected. And the downloads
    /// themselves answer only with the profile's rule (``DownloadsDetailSource``); that also
    /// covers the path without a responsible source, on which a child ends up with a remembered
    /// provider identifier.
    public func detailInfo(zu identifier: String) async throws -> DetailContent {
        guard let source = responsibleSource(identifier) else {
            guard let downloads, downloads.knows(identifier) else { throw Missing.source }
            return try await downloads.detailInfo(zu: identifier)
        }
        do {
            return try await source.detailInfo(zu: identifier)
        } catch ChildProtectionError.locked {
            throw ChildProtectionError.locked
        } catch {
            guard let downloads, downloads.knows(identifier) else { throw error }
            Diagnose.step(
                .downloads, "Detail page: source silent, answer from the downloads — \(error)")
            return try await downloads.detailInfo(zu: identifier)
        }
    }

    public func set(seen: Bool, forItem identifier: String) async throws {
        try await responsibleSource(identifier)?.set(seen: seen, forItem: identifier)
    }

    public func set(favorite: Bool, forItem identifier: String) async throws {
        try await responsibleSource(identifier)?.set(favorite: favorite, forItem: identifier)
    }

    public func removeFromContinueWatching(_ identifier: String) async throws {
        try await responsibleSource(identifier)?.removeFromContinueWatching(identifier)
    }

    public func seriesReference(zu tile: TileContent) async -> String? {
        await responsibleSource(tile.id)?.seriesReference(zu: tile)
    }

    public func previewURL(zu identifier: String) async throws -> URL? {
        try await responsibleSource(identifier)?.previewURL(zu: identifier)
    }

    /// **Its own error and not a `nil`.** The detail page distinguishes "no source
    /// set up" from "source does not answer" — a silent null case would end up in the
    /// wrong one of the two.
    enum Missing: Error { case source }
}
