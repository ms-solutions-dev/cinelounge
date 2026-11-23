import Foundation

/// How a library is sorted — **the rules that TV and phone share**
/// (AP58 R6, St7).
///
/// **What was the same and still stood twice:** the tap sequence (sort, reverse,
/// switch off) and the rule "series by year". **What was different and stays
/// different:** the TV sorts **on the server** (its lists arrive page by page, and
/// home videos can be ordered there by recording date), the phone **on the device**
/// (it holds the whole catalog of a library and jumps within it with the letter
/// bar). Both are a question of how the data is loaded and not of the rule. **What
/// was different and is now one:** the store (``SortStore``) including the
/// migration of both old formats.
public nonisolated enum SortRule {

    /// From how many shared words two titles count as one series.
    ///
    /// **Two**, and that is a compromise: one would be too few ("Der Fadono" and "Der
    /// Trailaut glintiorn Kimuskom" share "der"), three too many ("Griotru Cewuri: Episode IV" and "V"
    /// share two).
    public static let seriesWords = 2

    /// **Within a series, release counts, not the alphabet.** "Floupruk Saisjo kaingifre kriamaus
    /// Baifo" (2005) comes alphabetically before "der Poplubo plounfak Lumiok" (2001).
    ///
    /// The series keep their place; sorting happens within. **Without a year the order
    /// stays** as it was — a missing year treated as zero would yank the title to the
    /// front. Intended only for the default: whoever explicitly chooses "A–Z" gets the
    /// strict alphabet.
    public static func seriesByYear<Title>(
        _ list: [Title], title: (Title) -> String, year: (Title) -> Int?
    ) -> [Title] {
        var result: [Title] = []
        var location = 0
        while location < list.count {
            var last = location
            while last + 1 < list.count,
                sharedWords(title(list[last]), title(list[last + 1])) >= seriesWords
            {
                last += 1
            }
            if last > location {
                result += list[location...last].enumerated()
                    .sorted { links, right in
                        guard let a = year(links.element), let b = year(right.element), a != b
                        else { return links.offset < right.offset }
                        return a < b
                    }
                    .map(\.element)
            } else {
                result.append(list[location])
            }
            location = last + 1
        }
        return result
    }

    /// How many words two titles have in common at the start.
    public static func sharedWords(_ links: String, _ right: String) -> Int {
        let a = words(in: links)
        let b = words(in: right)
        var number = 0
        while number < a.count, number < b.count, a[number] == b[number] { number += 1 }
        return number
    }

    public static func words(in title: String) -> [String] {
        title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// For which **scope** a remembered sort order applies.
    ///
    /// A library is its own scope. **The movie and series categories of a provider
    /// share one scope per list** (`<XtreamList>|vod|<GenreCategory>` → `<XtreamList>|vod`,
    /// `<XtreamList>|series|<GenreCategory>` → `<XtreamList>|series`): otherwise fifty categories would
    /// mean setting the same thing fifty times by hand. The phone treats both as one
    /// catalog each anyway — both devices remember the same order there.
    ///
    /// **Series since the check of 2026-09-27** (D-S5). Until then they stayed per
    /// category on the TV; a series order from the phone arrived in no category there
    /// and vice versa. A choice that was stored per series category on the TV no
    /// longer applies since then — the category falls back to the default until a new
    /// choice is made.
    public static func area(forLibrary identifier: String) -> String {
        for kind in ["vod", "series"] {
            if let tag = identifier.range(of: "|\(kind)|") {
                return String(identifier[identifier.startIndex..<tag.lowerBound]) + "|\(kind)"
            }
        }
        return identifier
    }
}

/// What is sorted by — **the shared names**, and at the same time the values in
/// the store.
///
/// The raw values are those of the TV, because its store was the older and larger
/// one. The phone calls three of them differently (`title`, `fresh`, `rating`) and
/// maps them.
public nonisolated enum SortKind: String, Sendable, Hashable, Codable, CaseIterable {
    case title = "title"
    case added = "dateAdded"
    case rating = "rating"
    /// The recording date — only where the source can sort by it (home videos on the
    /// server).
    case recording = "recorded"
    /// The order of the source — the default of a portal level.
    case natural = "natural"

    /// The kind that stands in for this one on a device that does not offer it itself.
    ///
    /// **Recording and Added are the same question for home videos** (check
    /// 2026-09-27, D-S5): "newest first". The TV asks the server for the recording
    /// date, the phone orders on the device under "Newest". Without this bridge the
    /// choice of one arrived at the other as a default.
    public var equivalent: SortKind? {
        switch self {
        case .recording: .added
        case .added: .recording
        default: nil
        }
    }

    /// The direction one expects: for titles A–Z, for date and rating the newest and
    /// best first. `natural` means "as delivered".
    public var naturalAscending: Bool { self == .title || self == .natural }

    /// The order the server is asked for.
    public var serverOrder: ItemFilter.SortBy {
        switch self {
        case .title: .title
        case .added: .dateAdded
        case .rating: .rating
        case .recording: .dateCreated
        case .natural: .natural
        }
    }
}

/// A chosen order — **kind, direction and whether it was explicitly chosen.**
///
/// The third value carries more than it looks: without it there would be no
/// difference between "this is how the library arrives" and "I want the
/// alphabet". The default may sort more cleverly
/// (``SortRule/seriesByYear(_:title:year:)``); the choice must stay literal.
///
/// **Generalised over the kind**, because both apps keep their own names for it
/// (three on the phone, five on the TV); the rule is the same.
public nonisolated struct SortChoice<Kind: Hashable & Sendable>: Hashable, Sendable {
    public var kind: Kind
    public var ascending: Bool
    public var explicit: Bool

    public init(kind: Kind, ascending: Bool, explicit: Bool) {
        self.kind = kind
        self.ascending = ascending
        self.explicit = explicit
    }

    /// What a press on a sort button yields — **three states.**
    ///
    /// One press sorts, the second reverses, the third restores the default.
    /// **The first direction is the natural one** — whoever starts rigidly ascending
    /// shows the worst movies on the first press on "Rating". **The default itself has
    /// only two states**: for it, "switch off" and "restore" are the same.
    public func next(
        pressOn pressed: Kind, naturalAscending: (Kind) -> Bool, preset: SortChoice
    ) -> SortChoice {
        let natural = naturalAscending(pressed)
        guard pressed == kind, explicit else {
            return SortChoice(kind: pressed, ascending: natural, explicit: true)
        }
        if ascending == natural {
            return SortChoice(kind: pressed, ascending: !natural, explicit: true)
        }
        return preset
    }
}

/// Where chosen sort orders are kept — **one file for both apps** (AP58 R6, St7).
///
/// **Two formats before** (report A): the TV put one row per scope into the
/// Keychain (`library.sort.<Area>` = `title:to`), the phone a board in a file
/// (`library.sortByStock`, per catalog identifier). **And the old abbreviation
/// `from` meant the opposite on both sides**: on the TV *desc*ending, in the oldest
/// phone format (`UserDefaults`, until 2026-09-21) *asc*ending. Both migrations are
/// here, each with its own reading, and each is tested.
///
/// Only what was explicitly chosen is saved; the default is deleted and not
/// written — otherwise "never set" could not be told apart from "default chosen".
public nonisolated struct SortStore: Sendable {

    /// A remembered entry.
    public struct ContentEntryRecord: Codable, Sendable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case kind = "art"
            case ascending = "aufsteigend"
        }

        public var kind: SortKind
        public var ascending: Bool

        public init(kind: SortKind, ascending: Bool) {
            self.kind = kind
            self.ascending = ascending
        }
    }

    /// The file key of the shared board.
    public static let key = "library.sortierung"

    /// The prefix of the old TV rows in the Keychain (`library.sort.<Area>`).
    public static let tvPrefix = "library.sort."

    /// The phone's board until AP58 R6 (file, per catalog identifier).
    public static let phoneBoard = "library.sortByStock"

    private let store: any KeyValueStore
    private let keychain: (any KeyValueStore)?

    /// - Parameters:
    ///   - store: where the shared board lives — in the app the ``FileStore``.
    ///   - keychain: where the TV kept its rows until R6. If given,
    ///     ``read(area:)`` pulls over a row stored there, once.
    public init(store: any KeyValueStore, keychain: (any KeyValueStore)? = nil) {
        self.store = store
        self.keychain = keychain
    }

    private var board: [String: ContentEntryRecord] {
        RecordSheet.read([String: ContentEntryRecord].self, under: Self.key, from: store) ?? [:]
    }

    private func write(_ incoming: [String: ContentEntryRecord]) {
        if incoming.isEmpty {
            RecordSheet.cleanUp(Self.key, in: store)
        } else {
            RecordSheet.write(incoming, under: Self.key, in: store)
        }
    }

    /// The remembered order of this scope — or `nil`.
    public func read(area: String) -> ContentEntryRecord? {
        if let entry = board[area] { return entry }
        guard let keychain,
            let raw = try? keychain.value(for: Self.tvPrefix + area)
        else { return nil }
        let entry = Self.tvLine(raw)
        if let entry {
            var incoming = board
            incoming[area] = entry
            write(incoming)
            guard board[area] == entry else { return entry }
        }
        try? keychain.remove(Self.tvPrefix + area)
        return entry
    }

    /// The remembered order — **as this device can offer it.**
    ///
    /// Both apps read through this (check 2026-09-27, D-S5). If the kind is in
    /// `isOffered`, it applies; otherwise its ``SortKind/equivalent`` counterpart,
    /// if the device offers that; otherwise nothing at all, and the default stays.
    ///
    /// - Parameter isOffered: the kinds the device offers for this scope.
    public func read(area: String, isOffered: [SortKind]) -> ContentEntryRecord? {
        guard var entry = read(area: area) else { return nil }
        if isOffered.contains(entry.kind) { return entry }
        guard let substitute = entry.kind.equivalent, isOffered.contains(substitute) else {
            return nil
        }
        entry.kind = substitute
        return entry
    }

    /// Remembers an explicit choice — `nil` deletes (the default).
    public func memorize(_ entry: ContentEntryRecord?, area: String) {
        var incoming = board
        incoming[area] = entry
        write(incoming)
        try? keychain?.remove(Self.tvPrefix + area)
    }

    /// Reads an old TV row: `<kind>:to` or `<kind>:from`.
    ///
    /// **`from` means descending here** — unlike in the oldest phone format.
    static func tvLine(_ raw: String) -> ContentEntryRecord? {
        let split = raw.split(separator: ":")
        guard let first = split.first, let kind = SortKind(rawValue: String(first)) else {
            return nil
        }
        return ContentEntryRecord(kind: kind, ascending: split.last == "auf")
    }

    /// The kind for a phone name (`title`, `fresh`, `rating`).
    public static func phoneKind(_ name: String) -> SortKind? {
        switch name {
        case "titel": .title
        case "neu": .added
        case "bewertung": .rating
        default: nil
        }
    }

    /// Moves the phone board (`library.sortByStock`) into the shared one — **once.**
    ///
    /// Its entries carry a catalog identifier (`<origin>:<kind>:<raw>`) and a
    /// phone name with the direction **spelled out** (`ascending: Bool`) — there is
    /// no abbreviation to interpret here. What the shared board already holds stays.
    /// It is cleaned up only once what was written can be read back.
    ///
    /// - Returns: Whether something was migrated.
    @discardableResult
    public func adoptsPhoneBoard() -> Bool {
        struct Legacy: Decodable {
            /// Stored keys keep their original (German) names — renaming them would
            /// make data written by earlier versions unreadable (AP85 B4).
            private enum CodingKeys: String, CodingKey {
                case sorting = "sortierung"
                case ascending = "aufsteigend"
            }

            var sorting: String
            var ascending: Bool
        }
        guard let legacy = RecordSheet.read([String: Legacy].self, under: Self.phoneBoard, from: store)
        else { return false }
        var incoming = board
        for (catalog, entry) in legacy {
            guard let kind = Self.phoneKind(entry.sorting) else { continue }
            let area = SortRule.area(
                forLibrary: ShelfIdentifier.fromPhoneCatalog(catalog))
            if incoming[area] == nil {
                incoming[area] = ContentEntryRecord(kind: kind, ascending: entry.ascending)
            }
        }
        write(incoming)
        guard board == incoming else { return false }
        RecordSheet.cleanUp(Self.phoneBoard, in: store)
        return !legacy.isEmpty
    }
}
