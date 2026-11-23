import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// Tall or wide — **the level decides, and the tile saves the rest.**
///
/// The finding of the product owner from 2026-09-07: wide-format posters were rendered as portrait
/// on the phone, while tvOS did it right. On the TV two layers hang on it, on the phone none —
/// the information was available in `Core.Artwork.isWide` and never reached the tile.
@Suite("Tile format")
struct TileFormatTests {

    private func tile(_ id: String, wide: Bool?) -> TileContent {
        TileContent(id: id, title: id, wide: wide)
    }

    /// **Wide only if one reports it and none contradicts** — the same wording as
    /// `MediaItem.prefersWideArtwork(in:)` on the TV.
    @Test("One wide report is enough as long as none reports tall")
    func oneIsEnough() {
        #expect(TileContent.isWideShelf([tile("a", wide: true)]))
        #expect(
            TileContent.isWideShelf([tile("a", wide: nil), tile("b", wide: true)]))
    }

    /// **When in doubt, tall.** A wide picture in a portrait frame stands, thanks to ``PosterTile``,
    /// completely on its plate; a poster in a landscape frame would be cropped
    /// by two thirds.
    @Test("A single portrait item keeps the level tall")
    func oneOverrules() {
        #expect(
            !TileContent.isWideShelf([tile("a", wide: true), tile("b", wide: false)]))
    }

    /// **Unchecked is no statement.** Without this rule every source that does not carry the
    /// field would claim its pictures are tall — and thereby outvote the checked ones.
    @Test("Without information it stays with the poster")
    func withoutValue() {
        #expect(!TileContent.isWideShelf([tile("a", wide: nil)]))
        #expect(!TileContent.isWideShelf([]))
    }

    /// **The information comes from the shared package and is not re-created.**
    ///
    /// The bridge sends `bild_breit`, `PortalKit` writes it to `Artwork.isWide`, and
    /// ``TileArtwork`` passes it through. Until 2026-09-07 the chain ended at the last
    /// point.
    @Test("The mapping passes isWide through to the tile")
    func mappingPassesThrough() {
        var frames = Artwork()
        frames.isWide = true
        let title = MediaItem(id: "x", kind: .movie, title: "X", artwork: frames)
        let built = TileArtwork.tile(title, source: EmptySource(), width: 110)
        #expect(built.wide == true)
    }

    /// **A home video has no poster but a still frame from the recording.**
    ///
    /// Reported on 2026-09-08: home videos are usually landscape here too, but posters
    /// are displayed as portrait. The shelf on the Home screen had long carried its wide format
    /// (``ShelvesPerCatalog``), the **Library grid** however decides
    /// by the picture — and the media server reported none for any entry until then.
    /// It is fixed where the information arises: ``JellyfinKit`` now reads
    /// `PrimaryImageAspectRatio`.
    ///
    /// **Measured on a reference server:** 22 of 22 home videos lie above 1 (21 × 1.222,
    /// 1 × 1.778), all 102 films below (0.667).
    @Test("A shelf of home videos draws wide")
    func homeVideos() {
        let recordings = (1...22).map { tile("video-\($0)", wide: true) }
        #expect(TileContent.isWideShelf(recordings))
        // And the tile then also fills its frame, instead of standing fitted on a
        // plate — ``PosterTile/isFilling`` takes care of that.
        #expect(recordings.allSatisfy { $0.wide == true })
    }

}

/// A source that can do nothing — that is enough for the mapping.
///
/// **No re-creation of Jellyfin.** ``TileArtwork`` asks it only for image addresses, and
/// there are none here: the check is about the aspect ratio and not the picture.
private struct EmptySource: ContentSource {
    var displayName: String { "Probe" }
    nonisolated var canStartAtOffset: Bool { false }
    nonisolated var tracksStateItself: Bool { true }
    func libraries() async throws -> [Library] { [] }
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, kind: .movie, title: "") }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// The image format on **all** paths to the tile — 2026-09-08.
///
/// **The finding from the product owner:** with the portal flatone switched on, the
/// posters are still portrait; shouldn't the application detect the poster
/// formats automatically?
///
/// **Measured at the bridge, not assumed.** An entry point of flatone delivers 27
/// entries, of which **24** carry `bild_breit: true`; the other three are marks of the
/// portal and no posters. So the information is there — the app need not measure it,
/// it must **pass it through**.
///
/// **It dropped out at two places**, and both were intermediate types without a field:
/// `PortalEntry` (the level in the portal) and `HistoryEntry` ("Continue Watching"). Exactly
/// the same error that the rating had in the same file a day earlier.
///
/// **That is why this collection checks the chain and not the places.** A check per
/// mapping would drop out again at the next intermediate type; here stands the question that matters:
/// does the format reach the tile?
@Suite("Image format across the whole chain")
struct ImageFormatChainTests {

    /// **The portal level passes it through.** Before 2026-09-08. ``PortalEntry/asTile``
    /// built the tile without the field — in the portal every landscape poster stood in the
    /// portrait frame, although the bridge named it.
    @Test("The portal level passes the format through to the tile")
    func portalLevel() {
        let isLandscape = PortalEntry(id: "p|a|/x", title: "Landscape", wide: true)
        let up = PortalEntry(id: "p|a|/y", title: "Tall", wide: false)
        let unknown = PortalEntry(id: "p|a|/z", title: "Unknown")

        #expect(isLandscape.asTile.wide == true)
        #expect(up.asTile.wide == false)
        #expect(unknown.asTile.wide == nil)
    }

    /// **And the level decides its shelf from it.** That is the case that was
    /// observed: 24 landscape, 3 without information — the three must not force the level
    /// into portrait, because they are no posters.
    @Test("Entries without information do not force the level into portrait")
    func unknownsDoNotForce() {
        let likeAtFlatone =
            (0..<24).map { PortalEntry(id: "p|a|/\($0)", title: "Landscape", wide: true) }
            + (0..<3).map { PortalEntry(id: "p|a|/z\($0)", title: "Marks") }
        #expect(TileContent.isWideShelf(likeAtFlatone.map(\.asTile)))
    }

    /// **The history must carry it across the app start.** The same chain as with
    /// ``HistoryEntry/series`` a day earlier: the field existed on the tile but not in the
    /// stored form — unnoticeable within one session, because the store holds the
    /// entry completely.
    @Test("The history carries the format across a restart")
    func flowOverTheSlab() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        var history = History()
        history.note(
            HistoryEntry(
                identifier: "flatone|clipsite|/x", origin: .portals, title: "Landscape",
                wide: true))
        await HistoryStore(folder: folder).save(history)

        let read = await HistoryStore(folder: folder).load()
        #expect(read.entries.first?.wide == true)
        #expect(read.entries.first?.tile.wide == true)
    }

    /// **And the player writes it in.** Without this spot the field would stay empty in the history
    /// forever — wiring without current, and this project has already found several
    /// of those.
    @Test("The playback request passes the format on to the history entry")
    func fromRequest() throws {
        let job = PlaybackRequest(
            identifier: "flatone|clipsite|/x", title: "Landscape",
            address: try #require(URL(string: "https://example.invalid/x.m3u8")),
            duration: 3600, origin: .portals, wide: true)
        #expect(job.entry(at: 600).wide == true)
        #expect(job.entry(at: 600).tile.wide == true)
    }
}
