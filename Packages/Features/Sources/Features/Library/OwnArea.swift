import Core
import ParentalControls
import PortalKit

/// Continue Watching and favorites of **one** CL-Server provider — above its folder list,
/// when it is set to "Own Continue Watching and favorites" (AP60 point 5, 2026-09-30).
///
/// **The finding:** the TV removed such a provider from Home, Top Shelf and
/// favorites but showed its titles nowhere separately. Whoever switched on the TV found
/// their started titles gone afterwards. The phone has shown them at the top of the
/// provider since AP59 (`PortalsModel.ownHistory`); the same two rows now appear here.
///
/// **What must never arrive here** (requirement, 2026-09-30: this must definitely not
/// happen): titles of a **switched-off** provider. Three layers prevent this,
/// and none relies on the other:
/// 1. The CL-Server delivers `/resume` and `/favorites` only from portals the person
///    sees — the same rule as `/portals`.
/// 2. ``PortalSource/resumable(limit:)`` and ``PortalSource/favorites()`` filter once more
///    against the server's portal list.
/// 3. Here only what belongs to **exactly this** provider remains, and a provider that
///    is switched off does not even appear in the sidebar.
///
/// Plus the ``ProtectionRule``: the layer gets the raw source, not the filtered one —
/// without this line a child profile would see what Home withholds from it.
struct OwnArea: Equatable, Sendable {

    var continueWatching: [MediaItem]
    var favorites: [MediaItem]

    var isEmpty: Bool { continueWatching.isEmpty && favorites.isEmpty }

    /// What of it belongs to this provider — `nil` if it has no area of its own
    /// or both rows are empty (then it looks as before).
    static func forItem(
        portal: String, preferences: PortalPreferences, rule: ProtectionRule,
        continueWatching: [MediaItem], favorites: [MediaItem]
    ) -> OwnArea? {
        guard !preferences.countsTogether(portal) else { return nil }
        func own(_ title: [MediaItem]) -> [MediaItem] {
            rule.filter(title.filter { PortalPreferences.portal(zu: $0.id) == portal })
        }
        let area = OwnArea(
            continueWatching: own(continueWatching), favorites: own(favorites))
        return area.isEmpty ? nil : area
    }

    /// Fetches both rows — **only** for the top level of a provider with its own
    /// area; otherwise without a single request.
    ///
    /// An error omits the rows and not the level: the folder list is usable even
    /// without them.
    static func load(
        forItem library: Library.ID, source: PortalSource, preferences: PortalPreferences,
        rule: ProtectionRule
    ) async -> OwnArea? {
        guard let identifier = PortalLibraryID(library), identifier.entry.isEmpty,
            !preferences.countsTogether(identifier.portal)
        else { return nil }
        async let next = try? source.resumable(limit: 50)
        async let favorites = try? source.favorites()
        return forItem(
            portal: identifier.portal, preferences: preferences, rule: rule,
            continueWatching: await next ?? [], favorites: await favorites ?? [])
    }
}
