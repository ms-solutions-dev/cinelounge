import Core

/// Which library a tab shows when the server has several of its kind (AP89, variant A).
///
/// **The finding of 2026-11-16:** the tab took `libraries.first(where:)`, and a second home
/// video folder, a "Kids movies" next to "Movies" or a second series library was reachable
/// only through its shelf on Home. The phone answers the same question with its title
/// choice (`TitleChoice` + `CatalogPickerSheet`); the TV now does the same at the title of
/// the tab, with the list restricted to one kind, because the pill already separates kinds.
///
/// **The normal case stays as it was, pixel for pixel.** With exactly one library of a kind
/// there is nothing to choose: no chevron, no extra focus stop, no list. A list with a single
/// row would look empty and cost a press on the way up.
nonisolated enum LibraryChoice {

    /// The libraries a tab of this kind may show — in the order the server reports them.
    ///
    /// **Server order and no sorting of our own**, as in the phone's register: it is the
    /// order the person arranged in Jellyfin, and the first one stays the default.
    static func candidates(
        _ libraries: [Core.Library], kind: Core.Library.Kind
    ) -> [Core.Library] {
        libraries.filter { $0.kind == kind }
    }

    /// Whether the title becomes a choice — **only from two libraries on.**
    static func offersChoice(_ libraries: [Core.Library], kind: Core.Library.Kind) -> Bool {
        candidates(libraries, kind: kind).count > 1
    }

    /// The library the tab opens with.
    ///
    /// **A remembered library that has disappeared falls back silently to the first one** —
    /// the behavior before AP89. A folder renamed or removed on the server, or a library this
    /// account may no longer see, must not leave an empty tab behind.
    static func resolve(
        _ libraries: [Core.Library], kind: Core.Library.Kind, remembered: String?
    ) -> Core.Library? {
        let options = candidates(libraries, kind: kind)
        if let remembered, let match = options.first(where: { $0.id == remembered }) {
            return match
        }
        return options.first
    }
}

/// The remembered library per tab kind **and per profile** (AP89).
///
/// **Per profile**, because two people on the same TV mean two different folders: the parents
/// open "Home videos" in "Holiday 2025", the child in its own. The key carries the profile
/// identifier at the end, the same pattern as ``Core/ProfileStore/bucket(_:forItem:)``.
///
/// **In the structure store and not in the Keychain** — it is an assignment, not a secret
/// (see ``Core/FileStore``). A plain library identifier and nothing else: an old state that
/// never wrote this key simply reads as "nothing remembered", and the tab opens on the first
/// library as before.
nonisolated struct LibraryChoiceMemory: Sendable {

    let store: any KeyValueStore
    let profile: String?

    /// The basis of the key — completed per kind and profile in ``key(for:)``.
    ///
    /// **Without a dot on purpose:** `scripts/strings.py` reads every dotted string literal as a
    /// language key.
    static let basis = "libraryChoice"

    /// The key of one tab kind in this profile's compartment.
    func key(for kind: Core.Library.Kind) -> String {
        ProfileStore.bucket(Self.basis + "." + kind.rawValue, forItem: profile)
    }

    /// The remembered library identifier, or `nil` if this profile never chose here.
    func remembered(_ kind: Core.Library.Kind) -> String? {
        guard let value = try? store.value(for: key(for: kind)), !value.isEmpty else { return nil }
        return value
    }

    /// Remembers a choice. **Only an explicit choice is written** — the fallback to the first
    /// library is not a choice, and storing it would pin a stand-in.
    func remember(_ libraryID: String, for kind: Core.Library.Kind) {
        try? store.set(libraryID, for: key(for: kind))
    }
}

/// What a media tab hands its library view when there is something to choose (AP89).
///
/// **Built by the shell, drawn by the library.** The shell knows the libraries, the memory and
/// the counts; the library view only knows its own model. Hence a value with a callback rather
/// than a model of its own.
struct TabLibraryChoice {
    /// The language key of the tab — the head of the list says which kind it lists.
    let titleKey: String
    /// The libraries of this kind, in server order.
    let libraries: [Core.Library]
    /// The identifier of the library that is shown.
    let chosen: String
    /// Titles per library, as far as counted — a missing number stays hidden, see
    /// ``ParentalControls/FilteredSource/itemCount(in:filter:)``.
    let counts: [String: Int]
    /// Whether the new view should put the focus on the title — after a choice in the list.
    let landsOnTitle: Bool
    /// Switches the tab to another library.
    let select: (Core.Library) -> Void
}
