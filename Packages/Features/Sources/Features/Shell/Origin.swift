import Core
import Foundation
import JellyfinKit
import ParentalControls
import PlaylistKit
import PortalKit

/// Where a title comes from — **the TV part of an answer that has lived in `Core`
/// since AP58 R6.**
///
/// The form rules (``Core/Origin/forItem(identifier:)``, ``Core/Origin/forItem(library:)``)
/// have lived in `Core` since 2026-09-26, because the phone and the Top Shelf rule asked the same
/// question and it had been answered three times (report A, St8). What stays here is what only
/// the TV needs: the source for the origin, the way back into the sidebar, the
/// focus ladder and the heading in search and favorites.
nonisolated extension Origin {

    /// Where this **source** comes from — **by type and not by a field.**
    ///
    /// ``ContentSource`` carries no origin, and that stays so: The contract describes
    /// **what** a source can do, not **who** it is. The type is the answer here, and
    /// it is unambiguous — there are exactly three implementations. **A filtered source** (AP58
    /// R1) is not a fourth: It carries the origin of the source underneath.
    ///
    /// **Moved here on 2026-09-20** (AP39), out of ``MainView``: The outage interpretation
    /// now needs it in Library, search and detail page as well, and a fourth
    /// version of the same question would be exactly what this file was created to prevent.
    public static func forItem(source: any ContentSource) -> Origin {
        if let filtered = source as? FilteredSource { return forItem(source: filtered.source) }
        if source is JellyfinSource { return .jellyfin }
        if source is PortalSource { return .portals }
        return .provider
    }

    /// **Where the way back leads** — the sidebar row you land on.
    ///
    /// Until 2026-09-11 this mapping stood as `sidebarFocus = .vod` and
    /// `= .portals` at **four** call sites in ``MainView``, twice per area. Four
    /// copies of the same mapping are exactly the special case this package
    /// is meant to abolish: They drift apart as soon as an origin is added.
    var sidebarDestination: AppSidebar.Destination {
        switch self {
        case .jellyfin: .media
        case .provider: .vod
        case .portals: .portals
        }
    }

    /// Whether an origin carries **levels** — folders in folders.
    ///
    /// **The difference is real and not a tidying matter.** A provider category is a
    /// store: "Action" has no subfolders. A portal delivers menu items that again
    /// contain menu items — "Popular Series" at Serieshub is thirty genres.
    /// Two things hang on this: the focus ladder on leaving and the question of whether the
    /// menu button unwinds one level or leads straight to the sidebar.
    public var hasLevels: Bool { self == .portals }

    /// The steps the menu button takes out of a grid of this origin.
    ///
    /// Whoever carries levels gets one step more — see ``hasLevels``. Derived and
    /// not enumerated: A second case distinction over the same question would be the
    /// place where one is changed without the other.
    public var ladder: [FocusRules.ExitStep] {
        hasLevels ? FocusRules.portalLadder : FocusRules.vodLadder
    }

    /// The heading under which hits of this origin appear.
    public var headline: String {
        switch self {
        case .jellyfin: "search.media"
        case .provider: "favorites.vod"
        case .portals: "tab.portals"
        }
    }
}
