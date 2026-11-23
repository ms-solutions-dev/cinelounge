import Core
import Flows
import Foundation
import PortalKit

/// Where the portals come from — **and what distinguishes them from a catalog.**
///
/// A portal's catalog is a library like any other: `PortalSource` fulfils
/// `Core.ContentSource`, and so the same ``CatalogSource``, the same
/// detail page and the same player carry it as they carry the media server. **That is the reason
/// this package is small** — only what a portal has *more* than a catalog is built:
/// a state, a choice between several, and language versions.
public protocol PortalContentSource: Sendable {

    /// Which portals exist, with their state.
    ///
    /// **Including those that are not ready.** Taking a portal that demands a sign-in out of
    /// the list would mean: the viewer does not see that it is there and cannot
    /// sign in. That is exactly what turns a property into an error message.
    func portals() async throws -> [PortalInfo]

    /// "Continue Watching" of this person at the CL-Server — as on the TV (2026-09-28).
    func continueWatching(atMost: Int) async -> [TileContent]

    /// The identifier of a portal's **root level.**
    ///
    /// **The root is a level like any other** — the same identifier form as everything
    /// below it, so that the path needs no special case. Until 2026-09-06 it was one here:
    /// a chip row of "entry points" above a grid, and the way back from a
    /// folder led nowhere because there was no stack.
    func root(zu portal: String) -> String

    /// A level — **with the notice why nothing came, and the question it asks.**
    ///
    /// An empty level is not an error: a performer without videos, a page beyond
    /// the last. If a notice is there, it is the information; if none is, the level
    /// is simply empty. And if a **question** is there, an input field belongs here — the
    /// entry point "Search" answers with `braucht_eingabe` and until 2026-09-06 landed in the
    /// empty state "Nothing here".
    /// - Parameter weiter: The marker from ``PortalLayer/next``, when a **follow-up page**
    ///   is meant. `nil` means: the level from the start.
    func level(zu identifier: String, title: String, next: String?) async throws -> PortalLayer

    /// The same level, **sorted by the CL-Server across all its pages** (AP60, 2026-09-30).
    ///
    /// Requirement: sorted by rating, no 6 may stand on page 1 before
    /// an 8 from page 3. As long as the server is still collecting the level, `progress`
    /// reports how many entries it has.
    func level(
        zu identifier: String, title: String, next: String?, sorting: PortalSorting?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PortalLayer

    /// The language versions of a title — empty where the portal has none.
    func languages(zu identifier: String) async throws -> [String]

    /// Set the chosen version.
    func select(language: String, forItem identifier: String) async throws

    /// The remembered version of a series — empty means: no preference (AP58 G1, A9).
    func language(zu identifier: String) async throws -> String

    /// What a title yields in hosts, tiers and versions.
    ///
    /// **Empty is a valid answer.** A portal that keeps only one source per title
    /// has nothing to choose here — and the choice is then dropped, instead of showing a button
    /// that offers one row.
    func host(zu identifier: String) async throws -> [PortalHost]

    /// Take one page out of "Recently Used" — the long press on its row (2026-10-12).
    func forgetRecent(_ identifier: String) async throws

    /// What is remembered at the portals — **across all portals in one go.**
    ///
    /// **The bridge keeps the state and not the app**: Behind a portal
    /// there is often nobody who remembers what someone likes, and so the bridge does.
    /// It answers `favorites()` across its whole catalog; whoever wants the favorites of **one**
    /// portal filters — the same split as in ``CatalogFavorites``.
    ///
    /// **What it is here for:** the own area of a portal (``PortalPreferences``).
    /// A portal that does not count in the shared shelves keeps its favorites
    /// under its own root — and the Favorites tab then does not ask it at all.
    func favorites(width: Int) async throws -> [TileContent]
}

extension PortalContentSource {

    /// Without an answer of its own there is no preference.
    public func language(zu identifier: String) async throws -> String { "" }

    /// Without an answer of its own there are no favorites — for test sources that only
    /// imitate levels.
    public func favorites(width: Int) async throws -> [TileContent] { [] }

    /// Without an answer of its own the level comes unsorted — for test sources that only
    /// imitate levels.
    public func level(
        zu identifier: String, title: String, next: String?, sorting: PortalSorting?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PortalLayer {
        try await level(zu: identifier, title: title, next: next)
    }

    /// The level from the start — the normal case, and therefore available without a marker.
    public func level(zu identifier: String, title: String) async throws -> PortalLayer {
        try await level(zu: identifier, title: title, next: nil)
    }
}

/// A portal, as the bridge reports it.
public struct PortalInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let state: PortalState
    /// What the portal can do — **raw, because both vocabularies come through.**
    ///
    /// The bridge writes them in German (`seasons`), the server in English (`seasons`).
    /// They are therefore checked with ``PortalKit/PortalCapability/settled(in:)`` and **never** with
    /// a hard-written word — see the properties below.
    public let capabilities: Set<String>
    /// What the portal is, in one sentence. Empty with the old bridge.
    public let description: String
    /// What the portal **cannot** do, e.g. `drm_partial`.
    public let limits: [String]
    /// Whether the portal carries adult content — **a label, not a lock.**
    public let adult: Bool

    public init(
        id: String, name: String, state: PortalState, capabilities: Set<String>,
        description: String = "", limits: [String] = [], adult: Bool = false
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.capabilities = capabilities
        self.description = description
        self.limits = limits
        self.adult = adult
    }

    /// **The difference that matters while waiting.**
    ///
    /// A portal with `resolver` looks for the video source only when you press — that
    /// takes time. One without plays immediately. The design puts this in the portal choice, because
    /// it influences the choice: whoever wants to watch something quickly while out and about takes the other.
    public var playsImmediately: Bool { !PortalCapability.resolver.settled(in: capabilities) }

    public var requiresSignIn: Bool { PortalCapability.login.settled(in: capabilities) }
    public var offersLanguages: Bool { PortalCapability.languages.settled(in: capabilities) }
    public var canSearch: Bool { PortalCapability.search.settled(in: capabilities) }
    public var supportsSeasons: Bool { PortalCapability.seasons.settled(in: capabilities) }
    public var offersSubtitles: Bool { PortalCapability.subtitles.settled(in: capabilities) }

    /// The abbreviation for the badge — **from the name, not from a table.**
    ///
    /// A hand-kept table would have to be updated with every new portal of the bridge,
    /// and whoever forgets it gets an empty badge. What is taken is the
    /// initial letters of the words, at most three.
    public var abbreviation: String {
        let words = name.split(separator: " ")
        if words.count > 1 {
            return String(words.prefix(3).compactMap(\.first)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

/// An entry point into a portal's catalog.
public struct EntryPoint: Sendable, Equatable, Identifiable {
    public let id: String
    public let portal: String
    public let name: String
    /// How many titles lie behind it — the bridge rarely says.
    public let count: Int?

    public init(id: String, portal: String, name: String, count: Int?) {
        self.id = id
        self.portal = portal
        self.name = name
        self.count = count
    }
}

extension PortalContentSource {
    /// A source without a state of its own contributes nothing.
    public func continueWatching(atMost: Int) async -> [TileContent] { [] }

    /// A source without a state of its own remembers no pages.
    public func forgetRecent(_ identifier: String) async throws {}
}
