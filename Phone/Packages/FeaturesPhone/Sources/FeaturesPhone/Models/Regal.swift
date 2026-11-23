import Core
import Foundation

/// A shelf of the Home screen — **a value, not an enumeration case.**
///
/// **Why `Regalart` fell.** It carried six fixed names; on the test server there are six
/// libraries, of which **four did not occur in it** — home videos, music, collections,
/// folders. Adding a shelf for them would have cost a retranslation each, and for a foreign
/// fourteenth library there would be no way.
///
/// The TV programme has had it right for a long time: four fixed rows plus **one per
/// library**, generated on loading instead of written down.
public struct Shelf: Sendable, Hashable, Identifiable {

    /// **Stable across program runs**, because the stored order remembers it.
    public struct Identifier: Sendable, Hashable, Codable, RawRepresentable {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A fixed shelf that exists independently of individual catalogs.
        ///
        /// **The names have been the TV's since 2026-09-20** (AP40): `resume`, `live`, `portals`
        /// instead of `weiterSchauen`, `heuteLive`, `ausDenPortalen`. They stand over there as API
        /// (``Core/ShelfPreferences/resumeID``), lie in the stores of both programs and travel in
        /// the handoff bundle — a shelf order that migrated from here to the TV was until then a
        /// list of unknown words there and was silently discarded.
        ///
        /// `zuletztHinzugefuegt` has always been called that; the TV has carried the shelf under
        /// the same name since 2026-09-13. The names are collected in ``Core/ShelfIdentifier``.
        public static func fixed(_ name: String) -> Identifier { Identifier(rawValue: name) }

        /// Reads a stored identifier — **in the form that both programs share.**
        ///
        /// The translation has stood in `Core` since AP58 R6 (``Core/ShelfIdentifier/read(_:)``):
        /// the old names of the fixed shelves until 2026-09-20 (`weiterSchauen`, `heuteLive`,
        /// `ausDenPortalen`) and the catalog shelves with prefix (`fresh:<origin>:…`).
        public init(stored raw: String) {
            self.init(rawValue: ShelfIdentifier.read(raw))
        }

        /// A shelf that belongs to exactly one catalog — **named as the TV names it** (AP58 R6,
        /// St1).
        ///
        /// Until then `fresh:` stood before the catalog identifier, and the same library was called
        /// `fresh:jellyfin:movies:a1b2…` on the phone and `a1b2…` on the TV in the shared
        /// `shelves.json`. An order that arose on one device named nothing on the other. Now it is
        /// the identifier under which the source carries the catalog (``Core/ShelfIdentifier``).
        public static func zu(_ catalog: Catalog.Identifier) -> Identifier {
            Identifier(rawValue: ShelfIdentifier.fromPhoneCatalog(catalog.rawValue))
        }
    }

    public let id: Identifier
    public let label: CaptionLabel

    /// Which catalogs fill this shelf.
    ///
    /// **The same question as for the tabs, asked against the same state** — the reason why
    /// the Home screen and the bar are not two truths.
    public let sources: Set<Catalog.Origin>

    /// The catalog that the shelf header opens. `nil` for the fixed shelves that span several
    /// catalogs.
    public let target: Catalog.Identifier?

    public let form: TileShape

    public init(
        id: Identifier, label: CaptionLabel, sources: Set<Catalog.Origin>,
        target: Catalog.Identifier? = nil, form: TileShape = .poster
    ) {
        self.id = id
        self.label = label
        self.sources = sources
        self.target = target
        self.form = form
    }
}

/// Which tile shape a shelf carries.
///
/// **Posters, with one exception.** A row of alternating 2 : 3 and 16 : 9 would no longer be
/// a shelf but a pile — that is why "Continue Watching" and "Recently added" carry posters,
/// although episodes and films stand mixed in them.
///
/// **The exception is the home video**, and it is no carelessness: A home video has no
/// poster but a still frame from the recording. Put into a 2 : 3 frame, that is the crop of
/// a crop. The TV programme decides it at the same place and with the same reason.
public enum TileShape: Sendable, Hashable {
    case poster
    case wide

    /// A logo on a plate — **fitted and not filled.**
    ///
    /// **Seen on the screen on 2026-09-06** "Live today" first got `poster` and stood there as a
    /// channel logo cropped to portrait; with `wide` it became wide and still cropped. The
    /// error was not the aspect ratio but the verb: A poster and an episode image **fill** their
    /// tile, because they are images and every crop remains an image. A logo is a drawing with
    /// a margin — whoever fills it cuts half of it off.
    case tag

    /// A **vertical** channel row across the full width.
    ///
    /// **The draft was right, and the build outvoted it** (contradiction W2, decided on
    /// 2026-09-06). The draft says literally here: "Live today: **VERTICAL**. A channel row is as
    /// wide as the screen — side by side, 'now/next' would be unreadable." What was built was a
    /// 200 × 112 wide plate with a logo in it, on which **nothing** of "now/next" stood — so
    /// exactly the information was missing that this shelf exists for.
    ///
    /// **The Home screen thus has two grammars, and that is the price.** It is justifiable
    /// here, because a channel is not a title: For a film the poster answers the question "what
    /// is this", for a channel it answers only the running programme with its remaining time —
    /// and that does not fit into 200 points.
    case channelRow
}
