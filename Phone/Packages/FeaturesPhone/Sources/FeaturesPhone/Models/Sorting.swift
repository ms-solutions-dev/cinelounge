import Core
import Foundation

/// What a title list is ordered by.
///
/// **Three orders, each with three states** — the cycle logic of the TV, caught up on 2026-09-05
/// on request.
///
/// I had first left them out and justified it by saying a choice from a sheet always has
/// exactly one value. The reasoning fell with the sheet: The choice has become chips, and a
/// chip **must** be switchable off — otherwise there is no way back to the order with which
/// the catalog opened. That is exactly the third state, and it is the way back that such
/// bars otherwise never have.
///
/// **Sorting happens in memory, never at the server.** If the order went out as an
/// `ItemFilter`, every switch would cost a new round trip — with a provider account with
/// **one** permitted connection exactly the error that the scope row has already avoided
/// ("Four seconds later it said 'Takes longer than usual'").
public enum Sorting: String, Sendable, Equatable, CaseIterable, Identifiable {

    /// A–Z, without leading article and language-aware — see ``JumpMarks``.
    case title = "titel"
    /// What was added last, first.
    case fresh = "neu"
    /// The best rating first.
    case rating = "bewertung"

    public var id: String { rawValue }

    /// **The first direction is not always ascending.**
    ///
    /// For titles you expect A–Z, for date and rating the newest and best first. Whoever starts
    /// stubbornly ascending here shows the worst films on the first press on "Rating".
    public var naturalAscending: Bool { self == .title }

    /// Which orders a catalog of this genre offers at all.
    ///
    /// **For home videos the rating is pointless** — they have none. Conversely the title says
    /// nothing for "Video_017", which is why the date comes first there. The same rule as on
    /// the TV; **gone instead of greyed out**, as with the tabs and the scopes.
    public static func possible(forItem kind: Genre) -> [Sorting] {
        kind == .homeVideos ? [.fresh, .title] : [.title, .fresh, .rating]
    }

    /// The label of the button — **it carries the state.**
    ///
    /// An active filter must be permanently visible, otherwise an empty list is inexplicable. A
    /// sort order always has a value, and it fits into the label; that way no state hangs on a
    /// colour that stands at 1,02 : 1 with deuteranopia.
    public var titleKey: String {
        switch self {
        case .title: "sort.alphabetical"
        case .fresh: "sort.newest"
        case .rating: "sort.rating"
        }
    }

    /// The order with which a catalog **opens** — before anyone chooses anything.
    ///
    /// **Taken over from the TV and first forgotten here** (`SortRules.standard`): Sorting home
    /// videos alphabetically is pointless — they are called "Video_010" and
    /// "vlc-record-2024-07-01". What you want to know about them is **when**, and exactly that
    /// is what the server carries as the recording date.
    ///
    /// **The portal level is still missing here** (there the provider's order applies, because
    /// a list called "Most watched right now" would otherwise lose its meaning). It comes with
    /// AP18; until then there are no portal catalogs, and a case for something that does not
    /// exist would be a claim.
    public static func preset(forItem kind: Genre) -> Sorting {
        kind == .homeVideos ? .fresh : .title
    }

    /// Orders the titles and calculates the jump markers with them.
    ///
    /// **Both in one go, because both need the same key.** Calculated separately, it was the
    /// error of 2026-09-05: The list came sorted by the raw title, the markers arose without the
    /// leading article — "T" jumped to "Das Staseit spupleispus Skofainbrand Boujaum" and thus **before** the
    /// D block.
    /// - Parameter ausdruecklich: whether the viewer **chose** this order.
    ///
    ///   **The value carries more than it looks like** — also taken over from the TV. Without
    ///   it there would be no difference between "this is how the catalog opens" and "I want
    ///   the alphabet", and exactly that is needed: The default may sort more cleverly than the
    ///   alphabet, the explicit choice must stay literal.
    /// - Parameter aufsteigend: the direction. `nil` means the natural one of this order.
    public func arrange(
        _ title: [TileContent], ascending: Bool? = nil, explicit: Bool = true
    ) -> Order {
        let direction = ascending ?? naturalAscending
        var sortedEntries: [TileContent]
        switch self {
        case .title:
            let alphabetical = JumpMarks.sortedEntries(title, after: \.title)
            sortedEntries = explicit ? alphabetical : Self.seriesByYear(alphabetical)
        case .fresh:
            // Without a date to the end: An unknown age is not a young one.
            sortedEntries = title.sorted {
                ($0.added ?? .distantPast) > ($1.added ?? .distantPast)
            }
        case .rating:
            sortedEntries = title.sorted {
                ($0.rating?.portion ?? -1) > ($1.rating?.portion ?? -1)
            }
        }
        // **Reversed, not re-sorted.** The calculations above each set their own rule for missing
        // values ("without a date to the end"); whoever sorted a second time for the opposite
        // direction would have to mirror it there — and the one spot you forget doing so is the
        // one with the missing values.
        if direction != naturalAscending { sortedEntries.reverse() }

        var marks: [String] = []
        var targets: [String: String] = [:]
        for entry in sortedEntries {
            let tag = self.tag(forItem: entry)
            if targets[tag] == nil {
                targets[tag] = entry.id
                marks.append(tag)
            }
        }
        return Order(entries: sortedEntries, marks: marks, targets: targets)
    }

    /// Under which marker a title stands in **this** order.
    ///
    /// **For date and rating the bar is coarser, not pointless.** "Jump to the sevens" is, in a
    /// list of 4.211 titles, a jump over three thousand. Hiding it for that reason would also
    /// shift the tile width at every switch — and with it the requested image size.
    func tag(forItem tile: TileContent) -> String {
        switch self {
        case .title:
            return JumpMarks.tag(forItem: tile.title)
        case .fresh:
            guard let datum = tile.added else { return JumpMarks.collectiveSymbol }
            return Calendar.current.component(.year, from: datum).formatted(.number.grouping(.never))
        case .rating:
            guard let note = tile.rating else { return JumpMarks.collectiveSymbol }
            return Int(note.portion * 10).formatted(.number)
        }
    }
}

extension Sorting {

    /// **Within a series, appearance counts, not the alphabet.**
    ///
    /// "Floupruk Saisjo piki beflund Haiflizait stounskeije Caizai" is from 2005, "… and the Leglaut'm Cosler"
    /// from 2001 — alphabetically the fourth part stands before the first. This was verified
    /// against the catalog: With Floupruk Saisjo and with The Skeitbuwol cofrel klonjaska Skeigria the series is
    /// otherwise jumbled.
    ///
    /// **Only with the default.** Whoever explicitly chooses "A–Z" gets the strict alphabet —
    /// the default is the cleverer one, the choice the literal one.
    ///
    /// **The series stay in their place:** Sorting happens **within** the group, its position
    /// in the list is still determined by its first title. Otherwise a film series would jump
    /// through half the library on re-sorting.
    ///
    /// **The rule has stood in ``Core/SortRule/seriesByYear(_:title:year:)`` since AP58
    /// R6** — the same as on the TV; here the year comes from the secondary text of the tile.
    static func seriesByYear(_ title: [TileContent]) -> [TileContent] {
        SortRule.seriesByYear(title, title: \.title, year: year)
    }

    static let seriesWords = SortRule.seriesWords

    /// The year from the second line — where it stands for a film.
    static func year(_ tile: TileContent) -> Int? {
        tile.beside.flatMap(Int.init)
    }

    static func sharedWords(_ links: String, _ right: String) -> Int {
        SortRule.sharedWords(links, right)
    }

    static func words(in title: String) -> [String] {
        SortRule.words(in: title)
    }
}

/// An ordered title list together with its jump markers.
///
/// **Calculated once, not per swipe.** The finding of 2026-09-05: Markers and jump targets were
/// computed properties **in the view**, and the bar accesses them at every letter change.
/// One swipe across the whole bar thus rebuilt a dictionary over 4.211 entries
/// twenty-six times.
public struct Order: Sendable, Equatable {

    public let entries: [TileContent]

    /// The occupied markers in the order in which they appear in the list.
    ///
    /// **Read off the list and not sorted.** With "Newest first" the years run backwards; an
    /// ascending sorted bar would point in the wrong direction there.
    public let marks: [String]

    /// Where a marker jumps — the identifier of the first title below it.
    public let targets: [String: String]

    public static let empty = Order(entries: [], marks: [], targets: [:])
}
