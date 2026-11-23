import Core
import Foundation

/// Which order was chosen last — per catalog.
///
/// **The client's remark of 2026-09-06:** If a sort order has already been set up there,
/// can it be carried over to Home here?
/// The answer was no twice: The choice lived as `[Catalog.Identifier: OrderChoice]` in the
/// working memory of the library model and was gone at the next launch — and
/// Home could not have read it anyway, because the model does not belong to it.
///
/// **The counterpart has long existed.** ``CategoryMemory`` remembers the last open
/// category per catalog, and Home reads it along. This is the same construction for the
/// second question you ask of a catalog.
///
/// **The default is not remembered.** It is not a state but the absence
/// of a state — storing it would mean saving "I chose nothing" and reading it as a
/// choice at the next opening. That is why ``memorize(_:zu:)`` deletes the entry as soon as
/// the choice is no longer ``OrderChoice/explicit``.
///
/// **On disk and not in the Keychain** — since 2026-09-21 in
/// ``Core/FileStore`` (AP40). That is structure, and the rule in `ARCHITEKTUR.md` says
/// where structure belongs. **That also removes the separator:** Here stood
/// `fresh:from` — sorting and direction in one word, "because `UserDefaults` does not handle
/// nested dictionaries well". That was correctly observed and the wrong
/// answer: In a file, a choice has two fields because it has two.
///
/// **Since AP58 R6 in the shared board of both programs** (``Core/SortStore``):
/// The scope is the identifier under which the source keeps the catalog
/// (``Core/SortRule/area(forLibrary:)``) — the same one under which the TV
/// stores its choice. The phone board `library.sortByStock` migrates over at launch.
public struct SortMemory: Sendable {

    private let store: any KeyValueStore
    /// The phone board until AP58 R6 — and before that the key in `UserDefaults`.
    static let key = SortStore.phoneBoard

    public init(store: (any KeyValueStore)? = nil) {
        self.store = store ?? FileStore()
    }

    /// The kind from a catalog identifier (`<origin>:<kind>:<raw>`).
    static func kind(_ catalog: Catalog.Identifier) -> Genre? {
        let split = catalog.rawValue.split(separator: ":", maxSplits: 2)
        guard split.count > 1 else { return nil }
        return Genre(rawValue: String(split[1]))
    }

    /// The scope for a catalog.
    static func area(_ catalog: Catalog.Identifier) -> String {
        SortRule.area(forLibrary: ShelfIdentifier.fromPhoneCatalog(catalog.rawValue))
    }

    /// The order chosen last — `nil` if none was chosen or it names nothing
    /// here (a kind the phone does not offer).
    ///
    /// **Read as on the TV** (review 2026-09-27, D-S5): via
    /// ``Core/SortStore/read(area:isOffered:)`` with the kinds the phone offers for
    /// this type — "Recording" from the TV becomes "Newest" for home videos.
    public func last(zu catalog: Catalog.Identifier) -> OrderChoice? {
        let isOffered = Sorting.possible(forItem: Self.kind(catalog) ?? .movies).map(\.kind)
        guard
            let entry = SortStore(store: store).read(
                area: Self.area(catalog), isOffered: isOffered),
            let sorting = Sorting(entry.kind)
        else { return nil }
        return OrderChoice(
            sorting: sorting, ascending: entry.ascending, explicit: true)
    }

    public func memorize(_ choice: OrderChoice, zu catalog: Catalog.Identifier) {
        SortStore(store: store).memorize(
            choice.explicit
                ? SortStore.ContentEntryRecord(kind: choice.sorting.kind, ascending: choice.ascending)
                : nil,
            area: Self.area(catalog))
    }

    /// Brings the old stores over — **both stages, in this sequence.**
    ///
    /// 1. `UserDefaults` (until 2026-09-21): per catalog `fresh:from` in one word — **`from` meant
    ///    ascending there**, the opposite of the TV abbreviation. Becomes the phone board.
    /// 2. The phone board becomes the shared one (``Core/SortStore/adoptsPhoneBoard()``).
    ///
    /// Each stage runs once and overwrites nothing that is already there.
    ///
    /// - Returns: Whether anything was taken over.
    @discardableResult
    public static func adopt(from old: UserDefaults, in store: any KeyValueStore) -> Bool {
        let fromDefaults = adoptDefaults(from: old, in: store)
        let fromBoard = SortStore(store: store).adoptsPhoneBoard()
        return fromDefaults || fromBoard
    }

    struct ContentEntryRecord: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case sorting = "sortierung"
            case ascending = "aufsteigend"
        }

        var sorting: String
        var ascending: Bool
    }

    private static func adoptDefaults(
        from old: UserDefaults, in store: any KeyValueStore
    )
        -> Bool
    {
        guard (try? store.value(for: key)) == nil,
            let oldBoard = old.dictionary(forKey: key) as? [String: String],
            !oldBoard.isEmpty
        else { return false }

        var incoming: [String: ContentEntryRecord] = [:]
        for (catalog, raw) in oldBoard {
            let split = raw.components(separatedBy: ":")
            guard split.count == 2 else { continue }
            incoming[catalog] = ContentEntryRecord(sorting: split[0], ascending: split[1] == "ab")
        }
        guard !incoming.isEmpty else { return false }

        RecordSheet.write(incoming, under: key, in: store)
        guard RecordSheet.read([String: ContentEntryRecord].self, under: key, from: store) == incoming
        else { return false }
        old.removeObject(forKey: key)
        return true
    }
}

extension Sorting {

    /// The shared name (``Core/SortKind``).
    var kind: SortKind {
        switch self {
        case .title: .title
        case .fresh: .added
        case .rating: .rating
        }
    }

    /// The phone sort order for a shared name — `nil` for kinds the phone
    /// cannot sort on the device (recording date, order of the source).
    init?(_ kind: SortKind) {
        switch kind {
        case .title: self = .title
        case .added: self = .fresh
        case .rating: self = .rating
        case .recording, .natural: return nil
        }
    }
}
