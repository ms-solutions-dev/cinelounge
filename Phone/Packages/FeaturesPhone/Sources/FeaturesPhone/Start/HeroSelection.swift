import Core
import Flows

/// Who appears large at the top.
///
/// The same rules as on the TV, and each has a reason:
///
/// * **Mixed through the libraries.** A header area that always shows the same thing is a
///   picture and not an invitation.
/// * **Nothing already started.** Until 2026-09-06 the most recently started item was in first
///   place — but it was then also the first tile in the "Continue Watching" shelf directly
///   below, and the same question appeared twice on one screen. Since direction B to K4
///   the box asks "what is new"; what has been started answers a different question in
///   its own place.
/// * **Only titles with a background image.** The box is ninety percent image; without
///   one an empty area would remain, and when paging it would look like a loading error.
/// * **No home videos.** The automation recognises the kind of a library, not the intent —
///   anyone who sets up family recordings as a movie library does not want them large on
///   Home.
/// * **A series counts once.** Two started episodes of the same series are one title here,
///   otherwise the box pages between two nearly identical pictures.
enum HeroSelection {

    /// This many are up for selection.
    static let atMost = HomeLayout.maxHeroes

    /// **The rules have been in
    /// ``Flows/HomeLayout/heroes(libraries:shuffle:atMost:)`` since AP58 R6** — the
    /// same as on the TV, which since decision 25 also leaves out what has been started.
    static func select(
        libraries: [[MediaItem]], shuffle: Bool = true, atMost: Int = atMost
    ) -> [MediaItem] {
        HomeLayout.heroes(libraries: libraries, shuffle: shuffle, atMost: atMost)
    }

    /// The same choice from **one** list.
    static func select(
        library: [MediaItem], shuffle: Bool = true, atMost: Int = atMost
    ) -> [MediaItem] {
        select(libraries: [library], shuffle: shuffle, atMost: atMost)
    }
}
