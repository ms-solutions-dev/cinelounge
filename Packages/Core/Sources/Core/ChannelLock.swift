import Foundation

/// Hide adult channels — **two rules, because there are two kinds of list, and one place where
/// both take effect.**
///
/// **Xtream knows `is_adult`, an M3U list does not.** With the examined provider **294 of
/// 5,389** channels are marked that way; an M3U list has no field for it, and there only the
/// second rule helps: "hide unmarked".
///
/// **The second rule must be switchable off**, otherwise half the list disappears. It is no
/// statement about the channel but about the absence of an indication — and whoever keeps a
/// pure M3U list would end up with no channels at all.
///
/// **The marking comes from the provider and may be incomplete.** That stands in the draft
/// under the switch, and it belongs there: Whoever relies on it should know. An automatism that
/// acts as if it knew better would be more dishonest than a switch — the same reasoning as at
/// ``LivePreferences/showsAdultChannels``.
///
/// **Applied at the source, exactly once** (check before the on-device test, Live area,
/// finding 1, and Home area, S2/F4, 2026-09-27). Until then only the Live area applied the
/// second rule; TV search, live shelf, "Continue Watching", the player's group list, up/down,
/// the favorites and "Live Today" on the phone showed the hidden channel. All these paths get
/// their channels from `LiveLibrary`, and it sends every delivery through ``filter(_:)``. A
/// guard in PlaylistKit (`ChannelSourceFilterTests`) reports a path that leads past it.
///
/// **Until 2026-09-27 in `ParentalControls`**; moved to Core because `LiveLibrary` (PlaylistKit)
/// depends only on Core.
public nonisolated struct ChannelLock: Sendable, Equatable {

    /// Ob gekennzeichnete Erwachsenensender erscheinen. **Vorgabe: nein.**
    public var showsAdult: Bool

    /// Whether channels **without** marking are hidden.
    ///
    /// **Default: no**, and that is the reverse of the other default. The reason is the direction of
    /// surprise: A channel that slipped through is an annoyance, an empty channel list looks like a
    /// defect — and it occurs immediately with every M3U list.
    public var hidesUnlabeled: Bool

    public init(showsAdult: Bool = false, hidesUnlabeled: Bool = false) {
        self.showsAdult = showsAdult
        self.hidesUnlabeled = hidesUnlabeled
    }

    /// The lists that mark — **at least one channel with `is_adult`.**
    ///
    /// **Measured and not assumed:** An Xtream access without a single marked channel is as
    /// unreliable as an M3U list, and it is treated exactly that way.
    public static func labelingLists(_ channels: [Channel]) -> Set<String> {
        Set(channels.lazy.filter(\.isAdult).map(\.playlistID))
    }

    /// The catalog as the block lets it pass.
    ///
    /// **Measured per list, not on the whole catalog**: An M3U list next to a marking Xtream access
    /// still does not mark; measured on the whole catalog, the access let it through.
    ///
    /// **Apply only to the full catalog, and only once.** What is measured is whether a list marks —
    /// a subset without adult channels, or an already filtered catalog, would look like a list
    /// without marking and drop out entirely.
    public func filter(_ channels: [Channel]) -> [Channel] {
        let labeling = hidesUnlabeled ? Self.labelingLists(channels) : []
        return channels.filter { channel in
            if channel.isAdult { return showsAdult }
            return !hidesUnlabeled || labeling.contains(channel.playlistID)
        }
    }
}

// MARK: - The store — the same on both devices

extension ChannelLock {

    /// Where "Hide unmarked adult channels" is stored — **one key for both devices** (G3, finding
    /// C8).
    public static let unlabeledKey = "childLock.hideUnmarked"

    /// The stored block — **"Show adult channels" from the live preferences** (`live.showsAdult`, a
    /// second truth beside it would be a mistake), the second rule from
    /// ``unlabeledKey``.
    public static func stored(
        store: UserDefaults = .standard,
        keychain: any KeyValueStore = ProfileStore.playback
    ) -> ChannelLock {
        ChannelLock(
            showsAdult: LivePreferences.load(from: keychain).showsAdultChannels,
            hidesUnlabeled: hidesUnlabeled(in: store))
    }

    /// Only the second rule — **without the Keychain**, for a place that already knows the first
    /// from its own preferences.
    public static func hidesUnlabeled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: unlabeledKey)
    }

    /// Stores the second rule.
    public static func write(hidesUnlabeled fresh: Bool, in store: UserDefaults = .standard) {
        store.set(fresh, forKey: unlabeledKey)
    }
}
