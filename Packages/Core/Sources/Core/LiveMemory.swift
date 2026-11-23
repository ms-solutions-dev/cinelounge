import Foundation

/// Remembers which channel was watched last — per list **and per person.**
///
/// **That removes the intermediate screen.** Anyone who selects "Live" or a channel list wants to
/// watch TV and not browse a list: Since the channels, the groups and the guide are
/// reachable in the player itself, the overview area in front is a step without a purpose.
/// One press therefore opens directly the channel where one left off.
///
/// **Per list and not just once**, because a list is a selection: Anyone switching between a
/// Turkish and a German provider wants to continue in both where they
/// were — a shared memory would lead to the wrong one at every switch.
///
/// **Since AP42 (2026-09-21) a reader of the ``StillLedger``.** Before, this held its own rows
/// in the Keychain (`live.lastChannel*`), which belonged to the **device**: Whoever watched TV after
/// another person landed on that person's channel, and that person the next day on the former's. The
/// scope of this type stays unchanged — only where it looks has changed.
public enum LiveMemory {

    /// The key in the Standbuch. **The empty text means "last overall"**, see
    /// ``StateRecording/lastChannel``.
    private static func bucket(_ playlistID: String?) -> String {
        guard let playlistID, !playlistID.isEmpty else { return "" }
        return playlistID
    }

    public static func remember(
        _ channelID: String, of playlistID: String?, ledger store: any KeyValueStore
    ) {
        // The "last overall" is written along by ``StateRecording/apply(_:on:)`` — the same
        // rule as before here, now in one place instead of two.
        var ledger = StillLedger.read(from: store, forItem: ProfilePointer.active)
        ledger.record(.senderGewaehlt(list: bucket(playlistID), channels: channelID))
        ledger.write(in: store, forItem: ProfilePointer.active)
    }

    public static func lastChannel(
        of playlistID: String?, ledger store: any KeyValueStore
    ) -> String? {
        let state = StillLedger.read(from: store, forItem: ProfilePointer.active).state
        if let own = state.lastChannel[bucket(playlistID)], !own.isEmpty {
            return own
        }
        guard playlistID != nil else { return nil }
        // For a list in which nothing has ever played, the general state applies — better
        // yesterday's channel than the first of the list.
        return state.lastChannel[""].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Remembers the channel whose stream is **running right now**.
    ///
    /// **The finding of 2026-09-02** (after opening a different channel and leaving and
    /// re-entering, the app did not recognise that a different channel had been opened —
    /// it always landed on the last sports channel). The memory was
    /// written in four places, and all four lay **before** the player: the channel list, the favourites,
    /// the schedule, the arrow keys. Anyone who opened the overlay in the player and chose a
    /// channel there got past none of them — and the app kept remembering the one
    /// the player was opened with.
    ///
    /// **Via the address and not via an identifier**, for the same reason as in
    /// ``PlayerScreen``: A playback target for a channel deliberately carries no identifier —
    /// there is nothing to remember —, and the running address deviates from the registered one on fallback to the
    /// raw stream. ``Channel/plays(_:)`` knows that, an
    /// equality test does not.
    ///
    /// - Returns: The recognised channel, or `nil` if the address does not belong to any in the catalog.
    ///   Then nothing is remembered either: A memory of a channel that is not in the
    ///   catalog led nowhere at the next open.
    @discardableResult
    public static func remember(
        playing url: URL, in channels: [Channel], ledger store: any KeyValueStore
    ) -> Channel? {
        guard let channel = channels.first(where: { $0.plays(url) }) else { return nil }
        remember(channel.id, of: channel.playlistID, ledger: store)
        return channel
    }

    /// The channel to open with.
    ///
    /// **Without a memory the first of the catalog** and not "nothing": The very first time
    /// there is nothing to remember, and an empty screen would be the worst of all
    /// answers to a press on "Live".
    ///
    /// If the remembered channel has disappeared — list changed, group hidden —, the
    /// same applies: It no longer exists, so there is nothing to continue.
    public static func opening(_ channels: [Channel], remembered: String?) -> Channel? {
        guard let remembered, let found = channels.first(where: { $0.id == remembered })
        else { return channels.first }
        return found
    }
}
