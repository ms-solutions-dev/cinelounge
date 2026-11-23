import Foundation
import Testing

@testable import FeaturesPhone

/// Order and jump marks — **one calculation, not two.**
@Suite("Sorting")
struct SortingTests {

    private func tile(
        _ title: String, year: Int? = nil, note: Double? = nil, days: Int? = nil
    ) -> TileContent {
        TileContent(
            id: title, title: title,
            rating: note.flatMap { Rating.fromTen($0, .imdb) },
            added: days.map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) })
    }

    /// **The finding of 2026-09-05:** The list was sorted by the **raw** title, the
    /// tags were made **without** the leading article. "Der Fennbruch" thus stood in the
    /// D block and carried the tag F — and "T" jumped to "Das Tauwerk der Ilse Brann",
    /// that is **before** the D block. The bar jumped backwards, and the real E-to-Z blocks
    /// could not be reached through it at all.
    @Test("Mark and order come from the same key")
    func markAndOrderMatch() {
        let order = Sorting.title.arrange([
            tile("Der Fennbruch"), tile("Das Tauwerk der Ilse Brann"),
            tile("Before Ninefold"), tile("Der Dammwärter"), tile("Zirbel"),
        ])

        // Sorted by the trimmed name: Before, Dammwärter, Fennbruch,
        // Tauwerk, Zirbel.
        #expect(
            order.entries.map(\.title) == [
                "Before Ninefold", "Der Dammwärter", "Der Fennbruch",
                "Das Tauwerk der Ilse Brann", "Zirbel",
            ])
        #expect(order.marks == ["B", "D", "F", "T", "Z"])

        // **And every tag points forward.** That is the check that holds the finding
        // in place: Before, "T" pointed to a title that stood further up.
        for (location, tag) in order.marks.enumerated() {
            let target = order.targets[tag]
            let positionInText = order.entries.firstIndex { $0.id == target }
            #expect(positionInText == location)
        }
    }

    /// Without a date to the end: an unknown age is not a young one.
    @Test("New first — and unknown last")
    func newestFirst() {
        let order = Sorting.fresh.arrange([
            tile("Alt", days: 100), tile("Ohne"), tile("Neu", days: 20_000),
        ])
        #expect(order.entries.map(\.title) == ["Neu", "Alt", "Ohne"])
        // The tags are years and run backwards — **read off the list**, not
        // sorted. An ascending bar would point in the wrong direction here.
        #expect(order.marks.last == JumpMarks.collectiveSymbol)
    }

    /// Without a rating to the end — same rule as for the date.
    @Test("Rating — the best first")
    func byRating() {
        let order = Sorting.rating.arrange([
            tile("Mittel", note: 6.4), tile("Ohne"), tile("Gut", note: 8.8),
        ])
        #expect(order.entries.map(\.title) == ["Gut", "Mittel", "Ohne"])
        #expect(order.marks == ["8", "6", JumpMarks.collectiveSymbol])
    }

    /// Every order needs a word — otherwise the bare key would show on the device.
    @Test("Every order has a word of its own", arguments: Sorting.allCases)
    func words(order: Sorting) {
        #expect(order.titleKey.hasPrefix("sort."))
        #expect(
            Sorting.allCases.filter { $0.titleKey == order.titleKey }.count
                == 1)
    }

    /// Three orders, and each knows its natural direction.
    @Test("Three orders with one natural direction each")
    func threeOrders() {
        #expect(Sorting.allCases.count == 3)
        #expect(Sorting.title.naturalAscending)
        #expect(!Sorting.fresh.naturalAscending)
        #expect(!Sorting.rating.naturalAscending)
    }
}

/// The three-state cycle — added on request on 2026-09-05.
@Suite("Order choice")
struct OrderChoiceTests {

    private func choice(_ s: Sorting, _ to: Bool, _ descending: Bool) -> OrderChoice {
        OrderChoice(sorting: s, ascending: to, explicit: descending)
    }

    /// **One tap sorts, the second reverses, the third switches off.** The third
    /// state is the way back that such bars otherwise never have.
    @Test("Three presses on the same chip go in a circle")
    func threeStates() {
        var now = OrderChoice.preset(forItem: .movies)
        #expect(now.sorting == .title && !now.explicit)

        now = OrderChoice.next(after: now, pressOn: .rating, kind: .movies)
        // **The first direction is not always ascending.** Anyone who starts rigidly ascending here
        // shows the worst movies on the first tap on "Rating".
        #expect(now == choice(.rating, false, true))

        now = OrderChoice.next(after: now, pressOn: .rating, kind: .movies)
        #expect(now == choice(.rating, true, true))

        now = OrderChoice.next(after: now, pressOn: .rating, kind: .movies)
        #expect(now == OrderChoice.preset(forItem: .movies))
    }

    /// A different order applies immediately — in **its** natural direction.
    @Test("The change always starts naturally")
    func switchObserver() {
        let reversed = choice(.title, false, true)
        let fresh = OrderChoice.next(after: reversed, pressOn: .fresh, kind: .movies)
        #expect(fresh == choice(.fresh, false, true))

        let back = OrderChoice.next(after: fresh, pressOn: .title, kind: .movies)
        #expect(back == choice(.title, true, true))
    }

    /// **The default has only two visible states.** The first tap on it
    /// does not change the direction — it only makes it explicit, and with that the
    /// smarter order (movie series by year) is dropped.
    @Test("The first press on the default makes it literal")
    func presetIsTakenLiterally() {
        let preset = OrderChoice.preset(forItem: .movies)
        let firstPress = OrderChoice.next(
            after: preset, pressOn: .title, kind: .movies)
        #expect(firstPress.sorting == preset.sorting)
        #expect(firstPress.ascending == preset.ascending)
        #expect(firstPress.explicit)
    }

    /// **For home videos the rating is meaningless** — they have none. And the title says
    /// nothing for "Video_017", which is why the date comes first there.
    @Test("Home videos offer no rating")
    func possiblePerGenre() {
        #expect(Sorting.possible(forItem: .homeVideos) == [.fresh, .title])
        #expect(Sorting.possible(forItem: .movies) == [.title, .fresh, .rating])
        #expect(OrderChoice.preset(forItem: .homeVideos).sorting == .fresh)
    }

    /// The finished list is reversed, not sorted a second time — otherwise
    /// every rule for missing values would have to be mirrored.
    @Test("The opposite direction reverses the list")
    func oppositeDirection() {
        let title = [
            TileContent(id: "a", title: "Alpha"), TileContent(id: "b", title: "Beta"),
        ]
        let to = Sorting.title.arrange(title, ascending: true)
        let from = Sorting.title.arrange(title, ascending: false)
        #expect(to.entries.map(\.id) == ["a", "b"])
        #expect(from.entries.map(\.id) == ["b", "a"])
    }
}

/// What the TV carries in sorting logic — and what of it applies here.
@Suite("Sorting · default")
struct SortPresetTests {

    private func tile(_ title: String, year: Int? = nil) -> TileContent {
        TileContent(id: title, title: title, beside: year.map(String.init))
    }

    /// **Sorting home videos alphabetically is pointless** — they are called "Video_010" and
    /// "vlc-record-2024-07-01". What one wants to know about them is **when**.
    @Test("Home videos go by date, everything else by title")
    func preset() {
        #expect(Sorting.preset(forItem: .homeVideos) == .fresh)
        #expect(Sorting.preset(forItem: .movies) == .title)
        #expect(Sorting.preset(forItem: .allSeries) == .title)
        #expect(Sorting.preset(forItem: .isCollection) == .title)
    }

    /// **Within a series, release counts, not the alphabet.** "Lenno Varsk
    /// und der Moosturm" is from 2003, "… und der Spiegel von Orbel" from 1996 —
    /// alphabetically the fourth part stands before the first.
    @Test("The default sorts film series by year")
    func seriesByYear() {
        let row = [
            tile("Lenno Varsk und der Moosturm", year: 2003),
            tile("Lenno Varsk und der Spiegel von Orbel", year: 1996),
            tile("Zorn", year: 1990),
        ]
        let preset = Sorting.title.arrange(row, explicit: false)
        #expect(
            preset.entries.map(\.title).prefix(2) == [
                "Lenno Varsk und der Spiegel von Orbel",
                "Lenno Varsk und der Moosturm",
            ])

        // **Only for the default.** Anyone who explicitly chooses "A–Z" gets the
        // strict alphabet — the default is the smarter one, the choice the literal one.
        let chosen = Sorting.title.arrange(row, explicit: true)
        #expect(
            chosen.entries.map(\.title).prefix(2) == [
                "Lenno Varsk und der Moosturm",
                "Lenno Varsk und der Spiegel von Orbel",
            ])
    }

    /// **Two shared words, and that is a compromise.** One would be too few: "Der
    /// Pakuro" and "Der Hüter der Mühlen" share "der" and are not a series.
    @Test("A shared article does not make a series")
    func noWrongRow() {
        let order = Sorting.title.arrange(
            [tile("Der Pakuro", year: 1974), tile("Der Hüter der Mühlen", year: 1999)],
            explicit: false)
        // Trimmed alphabetically: Hüter, Pakuro — and no re-sorting by year.
        #expect(order.entries.map(\.title) == ["Der Hüter der Mühlen", "Der Pakuro"])
    }

    /// Without a year the order stays as it was — reading a missing year as zero would
    /// tear the title to the start of the series.
    @Test("Without a year nothing is re-sorted")
    func withoutYear() {
        let order = Sorting.title.arrange(
            [
                tile("Nova Tides Episode IV"), tile("Nova Tides Episode V", year: 1981),
            ], explicit: false)
        #expect(order.entries.map(\.title) == ["Nova Tides Episode IV", "Nova Tides Episode V"])
    }
}
