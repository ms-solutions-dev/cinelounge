import DesignSystemPhone

/// The five tabs of the shell.
///
/// **Five is the limit** from which labels break. It applies to those **visible at the same
/// time** — the enumeration carries six, because ``favorites`` appears only when a place
/// remains free. ``CatalogState/tabs`` never shows more than five.
///
/// The active tab carries the **filled** icon and a semibold label, never colour alone: With
/// deuteranopia `rotHell` and `textQuiet` stand at 1,02 : 1, and that is the same tone.
public enum Tab: String, CaseIterable, Sendable, Identifiable {
    case start
    case library = "bibliothek"
    case live
    case portals = "portale"
    case favorites = "favoriten"
    case search = "suche"

    public var id: String { rawValue }

    /// At most this many stand at the bottom at the same time.
    public static let atMost = 5

    /// The key in the string catalog.
    ///
    /// Named in English like all keys — the design documents are German, the keys are not.
    public var titleKey: String {
        switch self {
        case .start: "tab.home"
        case .library: "tab.library"
        case .live: "tab.live"
        case .portals: "tab.portals"
        case .favorites: "tab.favorites"
        case .search: "tab.search"
        }
    }

    /// The view with which this tab begins.
    public var root: ViewID {
        switch self {
        case .start: .start
        case .library: .library
        case .live: .live
        case .portals: .portals
        case .favorites: .favorites
        case .search: .search
        }
    }

    public var icon: Glyph.Pair {
        switch self {
        case .start: Glyph.Tab.start
        case .library: Glyph.Tab.library
        case .live: Glyph.Tab.live
        case .portals: Glyph.Tab.portals
        case .favorites: Glyph.favorite.pair
        case .search: Glyph.Tab.search
        }
    }
}
