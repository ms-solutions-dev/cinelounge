import Core
import Foundation

/// Which tabs the viewer has **deselected.**
///
/// **The third reason a tab can be missing.** A tab appears if it **exists**
/// (``CatalogState``), if it is **allowed** (``TabScope`` in child mode) and if it is
/// **wanted** — that is what is stored here. Merging the three would be convenient and would
/// lose the information: "Live is missing because there is no list" and "Live is missing
/// because you switched it off" lead to different next steps.
///
/// **Deselected and not allowed.** What is stored is what should be **gone**, not what may
/// stay — the same direction as with groups and sports. If a tab is added, it is there
/// without any action; with an allow list it would be silently invisible, and one would look
/// for the error in the app.
///
/// **On disk and not in the Keychain.** Which tabs someone wants to see is no secret.
/// **Since 2026-09-21 in ``Core/FileStore``** and no longer in the default settings — this
/// is structure, and the rule in `ARCHITEKTUR.md` says where structure belongs.
public struct TabSelection: Equatable {

    /// **Not a language key but a store key.**
    static let key = "tabs.hidden"

    public private(set) var deselected: Set<String>

    private let store: any KeyValueStore

    public init(store: (any KeyValueStore)? = nil) {
        let bucket = store ?? FileStore()
        self.store = bucket
        self.deselected = Self.stored(store: bucket)
    }

    /// **What is compared is the choice and not the store.** Two choices are the same if the
    /// same tabs are missing; where they were read from is not the question.
    public static func == (links: TabSelection, right: TabSelection) -> Bool {
        links.deselected == right.deselected
    }

    public func shows(_ tabs: String) -> Bool { !deselected.contains(tabs) }

    public mutating func set(_ tabs: String, isVisible: Bool) {
        if isVisible {
            deselected.remove(tabs)
        } else {
            deselected.insert(tabs)
        }
        if deselected.isEmpty {
            RecordSheet.cleanUp(Self.key, in: store)
        } else {
            // Sortiert, damit dieselbe Auswahl immer dieselbe Ablage ergibt.
            RecordSheet.write(deselected.sorted(), under: Self.key, in: store)
        }
    }

    /// The deselected tabs, **without building the structure.**
    ///
    /// For the shell: it asks on every rebuild of the bar and has nothing to do with changing.
    public static func stored(store: (any KeyValueStore)? = nil) -> Set<String> {
        Set(RecordSheet.read([String].self, under: key, from: store ?? FileStore()) ?? [])
    }

    /// Brings over a choice stored in the default settings — **once.**
    ///
    /// First write, then read back, then clean up — the rule from
    /// ``Core/ShelfPreferences/adopt(from:in:)``, and for the same reason.
    @discardableResult
    public static func adopt(from previous: UserDefaults, in store: any KeyValueStore) -> Bool {
        guard (try? store.value(for: key)) == nil,
            let old = previous.stringArray(forKey: key), !old.isEmpty
        else { return false }
        RecordSheet.write(old.sorted(), under: key, in: store)
        guard stored(store: store) == Set(old) else { return false }
        previous.removeObject(forKey: key)
        return true
    }
}
