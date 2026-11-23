import Core
import Foundation
import PortalKit

/// An entry of a portal level — **a door or a title, never both.**
public struct PortalEntry: Sendable, Equatable, Identifiable {

    public let id: String
    public let title: String
    public let image: URL?

    /// The level behind it. `nil` means: this is a title and leads to its detail page.
    ///
    /// **This is decided in the shared package** (`PortalSource.levelID(forItem:)`), which
    /// calls itself "the one place where 'leads deeper' is decided" — and which
    /// on the phone had **zero** callers until 2026-09-06. Two versions of the same
    /// decision would be one too many: the one would stay when the other
    /// changes.
    public let leadsDeeper: String?

    /// A subheading ("--- Geheimtipps ---") — not an entry one presses.
    public let isSeparator: Bool

    /// The rating the portal maintains — `nil` for doors and for titles without a rating.
    ///
    /// **It was there and never arrived** (requirement, 2026-09-07: portals maintain
    /// ratings too… can we show those on the poster as well). The bridge
    /// delivers it as `rating`, `PortalKit` maps it to `MediaItem.ratings.community`
    /// — and exactly here it dropped out, because this type had no field for it. In the
    /// "From the Portals" shelf, therefore, alone among all, no badge stood on the
    /// poster, while the same rating does stand on the detail page.
    public let rating: Rating?

    /// Whether the image of this entry is **landscape**. `nil` means: the bridge says nothing.
    ///
    /// **The same bug as with ``rating`` one paragraph above, found on 2026-09-08:**
    /// with portal flatone switched on, the posters are still
    /// portrait.
    ///
    /// **Measured at the bridge, not assumed:** of 27 entries of a
    /// flatone entry point, **24** carry `bild_breit: true`; the other three are
    /// marks of the portal and not posters. So the information is there, `PortalKit`
    /// writes it to `Artwork.isWide` — and **this type had no field for it.** It
    /// dropped out exactly here, one line above the place where the rating had
    /// fared the same the day before.
    ///
    /// **That is why it is in the type and not in the mapping.** Whoever builds the entry has
    /// the `MediaItem` in hand; a missing field here is a translation error,
    /// a forgotten line in a mapping is a silent loss.
    public let wide: Bool?

    public init(
        id: String, title: String, image: URL? = nil, leadsDeeper: String? = nil,
        isSeparator: Bool = false, rating: Rating? = nil, wide: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.leadsDeeper = leadsDeeper
        self.isSeparator = isSeparator
        self.rating = rating
        self.wide = wide
    }

    public var asTile: TileContent {
        TileContent(id: id, title: title, image: image, rating: rating, wide: wide)
    }
}

/// A level of a portal.
///
/// **A catalog is flat and gets sorted, a portal is a tree and gets
/// walked through.** That is the withdrawal of 2026-09-06. (direction K3a): `PortalsView`
/// had hard-coded until then that portal page and library are "the same build with a different
/// catalog … no back arrow". Measured at the bridge, **four of eight**
/// Serieshub entry points deliver pure folder lists — 30, 24, 18 and 27 entries, not a single
/// image. As a poster grid those would be empty frames with text below.
public struct PortalLayer: Sendable, Equatable {

    /// The identifier of this level — `Core.Library.ID`, formed by `PortalKit`.
    public let identifier: String
    public let title: String
    public let entries: [PortalEntry]

    /// Why nothing came — the bridge's sentence, verbatim.
    public let hint: String?

    /// What the portal asked for. If it is set, an input field belongs here.
    public let query: String?

    /// What may already stand in this input field — **the suggestion for the ``query``.**
    ///
    /// **Finding of 2026-09-09:** search in flatone in the individual areas
    /// does not work. Measured at the bridge, the five rows under
    /// `flatone › Clips › Search` — "New Search", "Edit Search History",
    /// "Clear Search History" and the remembered terms — came as perfectly ordinary folders,
    /// all five with `braucht_eingabe: null`. So there was no search field, ``answer``
    /// was never reached, and "New Search" silently delivered the hits of the **last**
    /// search from the reader's history: it stood as the default in its keyboard, and
    /// a prefilled keyboard counted as answered for the bridge.
    ///
    /// **The suggestion is not an answer.** It stands in the field so that the same gesture
    /// has the same effect as in the portal itself — it is submitted only when somebody
    /// submits it.
    ///
    /// `nil` for every bridge that does not know the field yet.
    public let suggestion: String?

    /// What the portal wants **confirmed** — a question, not information.
    ///
    /// **Finding of 2026-09-09:** "Clear Search History" delivers `items: []` with the sentence
    /// "Confirm: Are you sure you want to clear the search history?". The view showed
    /// that as "Nothing here" with the sentence below — an unanswered question as
    /// information about an empty level.
    ///
    /// **It cannot be answered yet.** The way back is missing: a parameter
    /// that reaches from here all the way into the bridge's `Portal.list` like `input`. Until then
    /// the bridge says "no" — and the view at least says what was asked, instead of claiming an
    /// empty level.
    public let followUpQuestion: String?

    /// How many entries the portal names in total — `nil` where it is silent.
    ///
    /// **Only for labeling, never for calculating.** Measured on 2026-09-06, Animehub and
    /// Serieshub name it for "All series" (2,463 and 10,869), the ARD Mediathek for
    /// none of its nine entry points. Turning the absence into a zero would mean writing "0 titles"
    /// over fifteen visible ones.
    public let total: Int?

    /// The marker of the next page. `nil` means: **that was everything.**
    ///
    /// It belongs to the portal and is returned unchanged — at the ARD it is a
    /// page number that jumps (page 1 names 3, page 3 names 6). Whoever computed "next =
    /// current + 1" themselves would skip entries.
    public let next: String?

    /// Whether the server cut the level off at its cap (1 500 entries) — until AP77
    /// read and never shown.
    public let truncated: Bool

    public init(
        identifier: String, title: String, entries: [PortalEntry],
        hint: String? = nil, query: String? = nil, total: Int? = nil,
        next: String? = nil, suggestion: String? = nil, followUpQuestion: String? = nil,
        truncated: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.entries = entries
        self.hint = hint
        self.query = query
        self.total = total
        self.next = next
        self.suggestion = suggestion
        self.followUpQuestion = followUpQuestion
        self.truncated = truncated
    }

    /// Whether there is another page behind this level.
    public var hasMore: Bool { next != nil }

    /// This level with an appended follow-up page.
    ///
    /// **Duplicates drop out in the process, and that is not a cosmetic service.** The entries
    /// are `Identifiable`, and two equal identifiers in a `ForEach` are in SwiftUI
    /// not a cosmetic flaw but a drawing error: the list jumps, and the
    /// screen reader loses its place. A reader that repeats an entry from page 1 on page 2
    /// because something was added in between is the normal case
    /// and not an error.
    ///
    /// **Title and identifier stay those of the first page** — the path keeps pointing to
    /// where one entered. Only ``next`` and ``total`` are taken over: the
    /// marker is the new one, and the total is the one named last.
    public func using(page: PortalLayer) -> PortalLayer {
        var seen = Set(entries.map(\.id))
        let fresh = page.entries.filter { seen.insert($0.id).inserted }
        return PortalLayer(
            identifier: identifier, title: title, entries: entries + fresh,
            hint: hint, query: query, total: page.total ?? total,
            next: page.next, suggestion: suggestion, followUpQuestion: followUpQuestion,
            truncated: truncated || page.truncated)
    }

    /// Whether this level is drawn as **rows** instead of posters.
    ///
    /// **The level decides the form, not the tile** — the same rule as in the
    /// TV version (`PortalLevel.areFolders`), and it stands there in this direction
    /// because the other one was wrong once before: A grid is shown **as soon as there is anything
    /// to show**. Rows remain only where a level consists **exclusively** of folders
    /// and subheadings.
    ///
    /// **That also decides the mixed level** ("Discover" = four separators and
    /// twenty series with images): it becomes a grid, and the separators drop out of it.
    /// The structure is lost in the process — it is in the TV version too, and
    /// is no backlog of the phone but a limit of the template.
    ///
    /// A folder **in** the grid is not a special case: it becomes a tile, and a press
    /// leads one level deeper as everywhere.
    ///
    /// **Since AP58 R7 the rule is in ``PortalKit/PortalShape``**, the same as on the TV;
    /// ``PortalEntry/leadsDeeper`` comes from ``PortalKit/PortalSource/levelID(forItem:)``.
    public var areFolders: Bool {
        PortalShape.areFolders(entries) { $0.leadsDeeper != nil || $0.isSeparator }
    }

    /// What stands in the grid — **without the subheadings.**
    ///
    /// In a poster grid "--- Geheimtipps ---" would stand as a tile without an image.
    public var tiles: [TileContent] {
        entries.filter { !$0.isSeparator }.map(\.asTile)
    }
}
