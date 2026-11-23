import Foundation

/// **Every channel in two presses, without a keyboard** (AP32, from E80, 2026-09-24).
///
/// The viewer's request at E80 was that for channels it should also be structured and have a
/// search, as on iOS. The search has existed since 2026-09-12; **what is missing is the way
/// without typing.** On the remote, typing is the most expensive operation this app knows, and
/// the right column of the channel selection shows **thirty** entries — whoever looks for a
/// channel further down has no way there without an index.
///
/// **It is computed via ``ChannelName/searchKey(_:)`` and not via the display name**, and that
/// is the difference between an index and a dummy: The display name carries the provider's
/// prefix, and in the examined catalog **1313 channels begin with "DE"** because of it. An
/// index over that would have one letter.
///
/// **Articles are not stripped — unlike in the library.** There "Der Fadono" stands under P,
/// because the article belongs to the title and not to the name. A channel, by contrast, is
/// called what it is called: Nobody looks for "Das Nordlicht" under N. The same move here would be
/// the wrong transfer of a right rule.
public enum ChannelIndex {

    /// The character under which everything stands that does not begin with a letter.
    ///
    /// **And it stands at the end.** Channels like "13th Street" or "3sat" exist in every list; an
    /// index that starts with them starts with the special case.
    public static let other = "#"

    /// The letter under which this channel stands.
    public static func letter(_ rawName: String) -> String {
        let key = ChannelName.searchKey(rawName)
        guard let first = key.first else { return other }
        let large = String(first).uppercased()
        return large.rangeOfCharacter(from: .letters) != nil ? large : other
    }

    /// The letters under which there **actually** are channels.
    ///
    /// **A jump into nothing would be worse than no jump** — the same rule as in the library grid
    /// (``LibraryModel/initials(for:)``): An index with twenty-six marks, eleven of which show
    /// nothing, is eleven futile presses on a remote.
    ///
    /// **Group headings do not count.** Providers put them in the middle of the list; they have
    /// identifier and address like any channel and deliver nothing
    /// (``ChannelName/isSectionMarker(_:)``). A letter occupied only by a heading leads to an
    /// entry that cannot be played.
    public static func letters(_ rawNames: [String]) -> [String] {
        let taken = Set(
            rawNames
                .filter { !ChannelName.isSectionMarker($0) }
                .map(letter))
        return taken.sorted { links, right in
            if links == other { return false }
            if right == other { return true }
            return links.localizedStandardCompare(right) == .orderedAscending
        }
    }

    /// Whether this channel stands under the chosen letter.
    ///
    /// **A question of its own and not `searchTerm = letter`.** The search checks whether the name
    /// **contains** the word — with "R" as the search term "Sport R" would come along too, and an
    /// index that shows more than its letter is none.
    public static func matches(_ rawName: String, zu selected: String) -> Bool {
        letter(rawName) == selected
    }
}

/// **Two ways to the same channel, of which only one applies at a time.**
///
/// Search and index answer the same question in two ways: Whoever knows the name types it;
/// whoever knows it roughly jumps. **Both at once give a "nothing found" with no recognisable
/// reason** — one does not see the search field and the chosen mark as the cause at the same
/// time, and with the letter "R" and the search term "Sport" the list is empty although each
/// alone would have hits.
///
/// **The rule lives here and not in the view**, because otherwise it lies in two places (once
/// when typing, once when pressing a mark) and diverges at the next area. Here it is a
/// computation and can be checked.
public struct ChannelFilter: Equatable, Sendable {

    public private(set) var searchTerm: String = ""
    public private(set) var letter: String?

    public init() {}

    /// A search term applies — **and cancels the letter.**
    ///
    /// **Only a non-empty one.** Whoever empties the field wants to see the whole list and not
    /// additionally lose an index they may have just set.
    public mutating func search(_ word: String) {
        searchTerm = word
        if !word.isEmpty { letter = nil }
    }

    /// A letter applies — **and cancels the search term.**
    ///
    /// **The same letter twice cancels.** Without a way back, the only way to the whole list would
    /// be emptying a field in which nothing stands.
    public mutating func select(_ character: String) {
        letter = letter == character ? nil : character
        if letter != nil { searchTerm = "" }
    }

    /// Whether this channel passes both filters.
    ///
    /// - Parameters:
    ///   - rohname: The name as the provider delivers it.
    ///   - schluessel: Its ``ChannelSource/searchKey`` — passed in because it is already computed
    ///     on the channel and this question is asked once per keypress in a list of 7,746 entries.
    public func letsPass(rawName: String, key: String) -> Bool {
        if let letter { return ChannelIndex.matches(rawName, zu: letter) }
        let word = ChannelName.searchKey(searchTerm.trimmingCharacters(in: .whitespaces))
        return word.isEmpty || key.contains(word)
    }
}
