import Core

/// What no longer holds after a playback.
///
/// **The finding (test report 2026-08-11):** "After leaving an episode the button still
/// shows the old state — neither watched nor the new position." Media library,
/// favorites, movies and home videos are affected alike, and that is exactly the
/// information: it is not down to one view, but to what is not fetched again on
/// returning.
///
/// **The player knows first and tells nobody.** It reports the position to the server
/// when closing — in a detached task that nobody waits for. Anyone who comes back in
/// the same second sees the state from before. The views themselves cannot change
/// that: they do not know that something just played.
///
/// **That is why the refresh sits at the one place every playback goes through** — the
/// binding the player hangs from (``MainView``). It is the same reasoning as with the
/// home-video popup: one branching point, not five patch-ups.
///
/// Only the calculation for it lives here, as a pure function over values — what holds
/// for a view cannot be checked anywhere else.
enum PlaybackRefresh {

    /// Which identifiers count as stale after this playback.
    ///
    /// **The episode and its series**, because both change: the episode in its watched
    /// mark, the series in the number of unwatched episodes and thereby in what its play
    /// button offers.
    ///
    /// **Empty for a channel**, and that is not a special case but the normal case of this
    /// section: live targets carry no media-library identifier. If something were reported
    /// here anyway, every channel switch would trigger a refetch of the whole library —
    /// over a thin line that is exactly the sort of wait the cache was built against.
    static func staleIDs(after target: PlaybackTarget) -> [String] {
        guard target.kind != .live else { return [] }
        return [target.itemID, target.seriesID].compactMap { $0 }
    }
}
