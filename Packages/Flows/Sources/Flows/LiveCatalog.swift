import Core
import Foundation
import ParentalControls
import PlaylistKit

/// **What of the channel catalog is visible, how it is searched and how a favourite is recognised —
/// one rule for TV and phone** (AP58 R5, finding L1, 2026-09-26).
///
/// **Until then both Live models kept their own version**, and they diverged in three
/// places:
///
/// - **Search:** The TV required two characters and showed at most 200 hits from
///   the whole catalog; the phone searched from one character, without limit and **only in the
///   selected group.** The TV's rule now applies — rationale at
///   ``search(_:in:)``.
/// - **Favourites:** The TV compared via ``PlaylistStore/favoriteKey(for:)``
///   (spelling, accents, punctuation), the phone the folded name raw. With
///   "Das Nordlicht HD" versus "DAS NORDLICHT | HD" the phone did not match and showed on one of the
///   two no star, until the next load. Now ``isSameFavorite(_:_:)``.
/// - **Visibility:** Separator rows were dropped only on the TV. Now
///   ``isVisible(_:preferences:)``. The ``ChannelLock`` has lived at the source since 2026-09-27
///   (`LiveLibrary`, ``Core/ChannelLock``) and no longer here.
///
/// **Computations and no state.** The models of the two interfaces are built too differently
/// — a focus grid with sidebar, a list of bundles with a chip row — for
/// a shared state to take more off them than these rules. What they must share
/// so that the same question gets the same answer is here; the TV's focus dwell and the
/// phone's bundling stay with them.
public nonisolated enum LiveCatalog {

    // MARK: - Visibility

    /// What of a catalog comes into question at all.
    ///
    /// Two reasons why an entry is dropped, and both are documented in the catalog:
    ///
    /// - **It is not a channel at all.** 113 of 5389 entries are headings of the form
    ///   `##### SOLA HEVC #####`; whoever selects them sees a black picture.
    /// - **The viewer does not want to see it** — ``LivePreferences/allows(group:isAdult:)``,
    ///   called here and not rebuilt.
    ///
    /// **The second rule of the channel lock is not here**, but at the source
    /// (``Core/ChannelLock``): Applied here, it applied only on the paths that call this
    /// computation — search, Live shelf and player do not call it (Live check, finding 1).
    public static func isVisible(_ channels: [Channel], preferences: LivePreferences) -> [Channel] {
        channels.filter {
            !$0.isSectionMarker && preferences.allows(group: $0.group, isAdult: $0.isAdult)
        }
    }

    // MARK: - Search

    /// From how many characters on a search happens.
    ///
    /// **Two and not one**: A single letter matches almost everything among 5389 channels
    /// and says nothing — on the phone the same list then appeared once more, only without its
    /// sections.
    public static let minimumLength = 2

    /// More hits are not a result but a second list to page through. The
    /// count is still reported in full (``Match/count``).
    public static let maxMatches = 200

    /// The entered text as a search key — `nil` if it is too short.
    ///
    /// **Via the same key as the channels** (``ChannelName/searchKey(_:)``): 1313
    /// channels begin with a prefix like `DE:`, 2176 carry superscript characters that
    /// no keyboard enters.
    public static func searchKey(_ input: String) -> String? {
        let key = ChannelName.searchKey(input)
        return key.count >= minimumLength ? key : nil
    }

    /// What a search found.
    public struct Match: Sendable, Equatable {
        /// The first ``LiveCatalog/maxMatches`` in the order of the catalog.
        public let channels: [Channel]
        /// How many there would be in total — so that the number tells the truth even if the
        /// list is capped.
        public let count: Int
    }

    /// Searches in the **whole** catalog passed in — `nil` if no search is happening.
    ///
    /// **Not only in the selected group**, as the phone did until 2026-09-26: Whoever
    /// looks for a channel usually does not know in which of the 79 groups the provider
    /// put it — that is the reason to search at all. Whoever stood in a group and typed
    /// "Sola" got "nothing found" there, although Sola was three groups further on.
    public static func search(_ input: String, in channels: [Channel]) -> Match? {
        guard let key = searchKey(input) else { return nil }
        let found = channels.filter { $0.searchKey.contains(key) }
        return Match(channels: Array(found.prefix(maxMatches)), count: found.count)
    }

    // MARK: - Favorites

    /// Whether two entries are **the same favourite** — via the list store's ID.
    ///
    /// The store remembers a favourite under ``PlaylistStore/favoriteKey(for:)``:
    /// without case, without accents and punctuation, **with** quality mark.
    /// Whoever compares differently when toggling than the store shows no star on a same-named
    /// entry, although the store has long listed it as a favourite.
    public static func isSameFavorite(_ links: Channel, _ right: Channel) -> Bool {
        PlaylistStore.favoriteKey(for: links) == PlaylistStore.favoriteKey(for: right)
    }

    /// Toggles the star on all entries that are the same favourite as `channels`.
    ///
    /// **In place and without reloading**: A fetch for a star would be a connection storm on an
    /// account with **one** permitted connection.
    public static func setFavorite(_ on: Bool, for channels: Channel, in catalog: inout [Channel]) {
        let key = PlaylistStore.favoriteKey(for: channels)
        for slot in catalog.indices
        where PlaylistStore.favoriteKey(for: catalog[slot]) == key {
            catalog[slot].isFavorite = on
        }
    }

    // MARK: - What is on now

    /// The remaining time of the running programme in minutes — **rounded up**, `nil` if none
    /// is running.
    ///
    /// Rounded down, the last minute would read "0 min left", a number that looks as if
    /// the programme were over. Was in three places until 2026-09-26.
    public static func remainingMinutes(_ broadcast: Programme?, um time: Date) -> Int? {
        guard let broadcast, broadcast.isRunning(at: time) else { return nil }
        return max(1, Int(ceil(broadcast.end.timeIntervalSince(time) / 60)))
    }

    /// How far the running programme has progressed — 0 to 1.
    public static func progress(_ broadcast: Programme?, um time: Date) -> Double? {
        guard let broadcast, broadcast.isRunning(at: time) else { return nil }
        let total = broadcast.end.timeIntervalSince(broadcast.start)
        guard total > 0 else { return nil }
        return min(1, max(0, time.timeIntervalSince(broadcast.start) / total))
    }
}
