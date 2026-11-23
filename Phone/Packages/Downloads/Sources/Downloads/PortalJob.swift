import Foundation

/// A download job from a portal — **it remembers the route, not the address.**
///
/// That is the one idea on which all portal downloading hangs. `Strom.gueltig_bis`
/// carries 300 seconds, a film takes longer to download — until 2026-09-08 this was taken to
/// mean "does not work". What actually follows is only: **a stored address does not work.**
///
/// **Why this is so simple at all:** behind the resolved address lies an ordinary file
/// over HTTP and not an HLS playlist — `PortalModelle` writes it down from what was
/// measured: *"Serieshub and Animehub consistently answer with `video/mp4`"*,
/// `supportsDirectPlay: true`. A portal download therefore needs **less** than a
/// Jellyfin download: no repackaging, no collecting of pieces, one range request.
///
/// **What is not here is the fetching itself.** This type computes and decides; whoever
/// moves the bytes is ``BackgroundSession``. The separation is the reason the hard part
/// can be tested here without a network next to it.
public struct PortalJob: Sendable, Hashable, Codable {
    /// Stored keys keep their original (German) names (AP85 B4), except ``host``. A portal
    /// job is only held in memory — no ledger carries it, so the key could change freely.
    private enum CodingKeys: String, CodingKey {
        case portal
        case key = "schluessel"
        case host
        case version = "fassung"
        case reached = "erreicht"
        case segments = "segmente"
        case length = "laenge"
        case tag = "marke"
        case changed = "geaendert"
        case validUntil = "gueltigBis"
    }

    /// The route the bridge can walk again.
    ///
    /// **A note and not a line** (2026-09-09). The session resolves through the
    /// ``AddressProvider`` and not through these four fields — they are what is **in the ledger**
    /// and in the diagnostics (``shortForm``): which portal, which episode, which host, which
    /// version. That is exactly the information missing when searching for the cause of a
    /// failed download job.
    ///
    /// **Until 2026-09-09 the string `"portals"` stood here** — the origin and not the portal
    /// ID. The error went unnoticed because the field was read nowhere; the two together are
    /// the kind of construction this comment stands against.
    public let portal: String
    public let key: String
    public let host: String
    public let version: String

    /// How far it has got.
    public var reached: Int64

    /// How many **segments** are on disk — `nil` as long as it is not a playlist.
    ///
    /// **Added additively on 2026-09-09, for HLS delivery.** For a file, ``reached`` is the
    /// partial state, and the next range is computed from it. For a playlist nothing can be
    /// computed from it: the segments differ in size, and from 412 337 129 bytes one cannot
    /// tell whether that is 143 or 144. There the partial state means "this many segments are
    /// on disk" — the same role, a different unit.
    ///
    /// **And `Int?` and not `Int`, so that the difference stays visible.** `0` would mean
    /// "a playlist of which nothing is on disk yet"; `nil` means "no playlist at all". Whoever
    /// merged the two would have a file that suddenly has segments. Incidentally, an
    /// optional field from an older ledger resolves to `nil` instead of refusing to read.
    public var segments: Int?

    /// What identified the file the first time — for ``Resumability/sameFile``.
    public var length: Int64?
    public var tag: String?
    public var changed: String?

    /// When the resolved address expires. `nil` as long as none has been fetched.
    public var validUntil: Date?

    public init(
        portal: String, key: String, host: String, version: String,
        reached: Int64 = 0, segments: Int? = nil, length: Int64? = nil, tag: String? = nil,
        changed: String? = nil, validUntil: Date? = nil
    ) {
        self.portal = portal
        self.key = key
        self.host = host
        self.version = version
        self.reached = reached
        self.segments = segments
        self.length = length
        self.tag = tag
        self.changed = changed
        self.validUntil = validUntil
    }

    /// What appears in a diagnostics line about this job.
    ///
    /// **"ard · doku/s1/f3 · HD 1080p (DE)" and not just the key.** When a download job
    /// fails, the first question is **which** host did not hold up — Animehub offers four
    /// to choose from. Empty fields are dropped so that for the media server the line does
    /// not consist of separators.
    public var shortForm: String {
        var split = [portal, key].filter { !$0.isEmpty }
        let source = [host, version].filter { !$0.isEmpty }.joined(separator: " ")
        if !source.isEmpty { split.append(source) }
        return split.joined(separator: " · ")
    }

    /// The portal ID from a portal title ID — `nil` where none is contained.
    ///
    /// **The form is `portal|key|address`** (`PortalKit.PortalItemID`), and it is
    /// reproduced here instead of imported: according to ROADMAP A1, `PortalKit` must stay
    /// switchable off at build time (the store build gets by without portals), and this
    /// package depends on no source. An import for **one** separator would be the
    /// beginning of the dependency that is explicitly not meant to arise there.
    public static func portal(from identifier: String) -> String? {
        let split = identifier.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard split.count == 3, !split[0].isEmpty else { return nil }
        return String(split[0])
    }

    /// How much lead time an address must have for a block to still be worthwhile.
    ///
    /// **Thirty seconds of safety margin.** A block is sized at three and a half minutes
    /// (``Resumability/span``); starting it with four minutes of validity left would
    /// sometimes lose it — and a lost block costs more than one additional resolve.
    public static let leadTime: TimeInterval = Resumability.span + 30

    /// Whether the address is still good enough for the next block.
    ///
    /// **Without an address the answer is "no" and not "don't know".** The caller is then
    /// to resolve, and that is exactly what `true` says here.
    public func needsNewAddress(now: Date) -> Bool {
        guard let validUntil else { return true }
        return validUntil.timeIntervalSince(now) < Self.leadTime
    }

    /// The next range, or `nil` when nothing is missing any more.
    ///
    /// **Computed half-open and clamped at the end.** A range reaching past the end of the
    /// file is answered by some hosts with `416` and by some with the whole file; either
    /// would be an error nobody would look for here.
    public func nextBlock(mbit: Double?) -> ClosedRange<Int64>? {
        guard let length, length > 0 else {
            // Without a known length the first block is fetched anyway — it is the one that
            // brings the length along.
            let block = Resumability.blockSize(mbit: mbit)
            return reached...(reached + block - 1)
        }
        guard reached < length else { return nil }
        let block = Resumability.blockSize(mbit: mbit)
        return reached...min(reached + block - 1, length - 1)
    }

    public var done: Bool {
        guard let length, length > 0 else { return false }
        return reached >= length
    }

    /// Whether writing may continue after re-resolving.
    ///
    /// **The error this prevents only shows up on the plane:** a host may deliver a
    /// different encode on the second resolve — same episode, different bytes. Whoever then
    /// continues writing at byte 400,000,000 gets a file that looks complete and falls
    /// apart in the middle.
    public func mayResume(
        length fresh: Int64?, tag newTag: String?, changed newModified: String?
    )
        -> Bool
    {
        // Before the first byte there is nothing to protect.
        guard reached > 0 else { return true }
        return Resumability.sameFile(
            length: length, tag: tag, changed: changed,
            likeLength: fresh, likeTag: newTag, likeModified: newModified)
    }
}
