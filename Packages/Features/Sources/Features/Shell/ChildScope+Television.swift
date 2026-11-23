import Core
import ParentalControls

/// **The mapping of the shared scope onto the TV** (AP58 R1, finding K1).
///
/// What a child can reach and what an origin may deliver is defined in
/// ``ParentalControls/ChildScope``. Here is only how the TV maps its destinations and
/// origins onto it — the sidebar destinations onto ``ParentalControls/ChildTarget``,
/// an identifier onto its ``Origin``.
extension AppSidebar.Destination {

    /// The neutral destination of this sidebar row.
    nonisolated var childDestination: ChildTarget {
        switch self {
        case .media, .jellyfin: .mediaLibrary
        case .search: .search
        case .favorites: .favorites
        case .accounts: .profileSwitch
        case .live, .liveGroup, .liveProvider, .liveProviderGroup: .live
        case .vod, .vodProvider: .provider
        case .sport: .sport
        case .portals, .portalProvider: .portals
        case .settings, .sync: .administration
        }
    }
}

extension ChildScope {

    /// Ob diese Herkunft Titel beisteuern darf.
    nonisolated func delivers(_ origin: Origin) -> Bool {
        delivers(Self.name(origin))
    }

    /// Whether this title may be opened or played — the origin is determined by the
    /// **identifier** (``Origin/forItem(identifier:)``), not by the source that the caller
    /// has in hand.
    nonisolated func opens(_ title: MediaItem) -> Bool {
        opens(title, origin: Self.name(Origin.forItem(identifier: title.id)))
    }

    /// Whether the picture-in-picture window may return to full screen.
    nonisolated func returnTarget(
        _ target: PlaybackTarget, title: MediaItem?, channels: [Channel], isVisible: LivePreferences
    ) -> Bool {
        returnTarget(
            target, title: title, origin: title.map { Self.name(Origin.forItem(identifier: $0.id)) },
            channels: channels, isVisible: isVisible)
    }

    /// Whether this sidebar destination is reachable.
    nonisolated func isAllowed(_ target: AppSidebar.Destination) -> Bool {
        isAllowed(target.childDestination)
    }

    /// The name under which ``ParentalControls/TabScope`` lists an origin.
    nonisolated static func name(_ origin: Origin) -> String {
        switch origin {
        case .jellyfin: "medienserver"
        case .provider: "anbieter"
        case .portals: "portale"
        }
    }
}
