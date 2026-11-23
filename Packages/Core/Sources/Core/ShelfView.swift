import Foundation

/// Which shelves appear, how an order is carried forward when a shelf is moved, and who
/// fills the header area — **one rule for both apps** (check round 2026-09-27,
/// findings A-S6, A-S7, A-S8).
///
/// **Previously each of these rules existed twice.** The TV checked only the shelf's own
/// identifier in ``ShelfPreferences/isVisible(_:)``, whereas the phone let a hidden
/// "From the Portals" shelf also hide all portal-folder shelves, and a hidden tab shelf
/// hide all of its categories. The same `shelves.json` thus produced two Home screens.
/// The phone's version is the decided one (decision 25: same feel everywhere): whoever
/// turns off "From the Portals" has said so about **the portals**.
public nonisolated enum ShelfView {

    // MARK: - Sichtbarkeit

    /// The collective shelf whose switch this shelf inherits — or `nil`.
    ///
    /// A portal-folder shelf inherits from ``ShelfIdentifier/portals``, a category of the
    /// provider catalog (`list|vod|4711`) from its tab shelf (`list|vod`).
    public static func proxy(_ identifier: String) -> String? {
        if ShelfIdentifier.isPortalFolder(identifier) { return ShelfIdentifier.portals }
        return ShelfIdentifier.registerShelf(zu: identifier)
    }

    /// Whether this shelf appears. **Its own identifier wins; the collective statement is the
    /// fallback.**
    public static func shows(_ identifier: String, hidden: Set<String>) -> Bool {
        if hidden.contains(identifier) { return false }
        if let representative = proxy(identifier), hidden.contains(representative) {
            return false
        }
        return true
    }

    /// Show or hide a shelf — **including the resolution of a collective statement.**
    ///
    /// If the collective shelf is hidden, turning a shelf on would otherwise have no effect:
    /// ``shows(_:hidden:)`` lets the collective statement win. So the statement is first
    /// resolved into individual statements for all known shelves of the same collection; the
    /// state stays the same, and the tap takes effect.
    ///
    /// - Parameter alle: All shelf identifiers known today.
    public static func setEnabled(
        _ identifier: String, on: Bool, hidden: Set<String>, all: [String]
    ) -> Set<String> {
        var fresh = hidden
        if let representative = proxy(identifier), fresh.contains(representative) {
            fresh.remove(representative)
            fresh.formUnion(all.filter { proxy($0) == representative })
            fresh.insert(identifier)
        }
        if on { fresh.remove(identifier) } else { fresh.insert(identifier) }
        return fresh
    }

    // MARK: - Reihenfolge

    /// Carries an order forward — **the positions of currently absent shelves stay in place.**
    ///
    /// A portal folder that is silent today is missing from the list the viewer moves around.
    /// Until 2026-09-27 both apps wrote back only the identifiers that are currently present,
    /// and the silent shelf lost its position.
    ///
    /// - Parameters:
    ///   - reihenfolge: the stored order.
    ///   - neu: the present shelves in their new sequence.
    /// - Returns: The positions of the order that held a present shelf are filled with `fresh`
    ///   in sequence; absent ones stay where they were; whatever the order did not yet know
    ///   goes to the end. **Without duplicates.**
    public static func merge(order orderValue: [String], using fresh: [String]) -> [String] {
        var seen = Set<String>()
        let available = fresh.filter { seen.insert($0).inserted }
        let members = Set(available)
        var sortOrder = available.makeIterator()
        var old = Set<String>()
        var isSet = Set<String>()
        var result: [String] = []
        for identifier in orderValue where old.insert(identifier).inserted {
            let entry = members.contains(identifier) ? sortOrder.next() : identifier
            guard let entry, isSet.insert(entry).inserted else { continue }
            result.append(entry)
        }
        while let rest = sortOrder.next() {
            if isSet.insert(rest).inserted { result.append(rest) }
        }
        return result
    }

    // MARK: - Kopfbereich

    /// Whether this shelf may fill the header area. **Empty means: all.**
    public static func fillsHeroes(_ identifier: String, heroShelves: Set<String>) -> Bool {
        heroShelves.isEmpty || heroShelves.contains(identifier)
    }

    /// Select or deselect a shelf for the header area.
    ///
    /// **The last one cannot be deselected.** An empty set means "all" — whoever deselected
    /// the last one would suddenly get all of them again.
    ///
    /// - Parameter start: What a still-empty selection starts with — the shelves that
    ///   filled the header until then.
    public static func fill(
        _ identifier: String, on: Bool, heroShelves: Set<String>, start: [String]
    ) -> Set<String> {
        var fresh = heroShelves.isEmpty ? Set(start) : heroShelves
        if on {
            fresh.insert(identifier)
        } else if fresh.count > 1 || !fresh.contains(identifier) {
            fresh.remove(identifier)
        }
        return fresh
    }
}
