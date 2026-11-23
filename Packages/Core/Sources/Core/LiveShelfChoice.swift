import Foundation

/// **Which channels go into the Live shelf of the Home screen — the same rule on all devices**
/// (AP58 R5, finding L3, 2026-09-26).
///
/// **Until then it stood twice** — on the TV in `LiveShelf`, on the phone in
/// `TodayLive` —, and it diverged in four places, although both sides read the same
/// choice (``ShelfOrder/liveChannel``), which travels via handoff and iCloud:
///
/// 1. **Favourites** came to the front on the TV after the last watched, on the phone
///    not at all. Now on both: A star is an explicit statement by the viewer.
/// 2. **One name, one channel** applied on the phone only for choice and history, on the TV not
///    at all. Now everywhere: The same channel stands at the provider in several groups and
///    versions, and "TR: KULE SPORT" twice next to each other is the same match with the same
///    bar (seen on the phone on 2026-09-07).
/// 3. **The guide window** was 200 against 400 channels. Now ``programmeFor``.
/// 4. **The upper limit of the choice** was missing on the TV, on the phone the oldest dropped out.
///    Now ``select(_:on:in:)`` on both.
///
/// **Chosen by name** (``Channel/channelName``, decision 21), not by
/// identifier: An Xtream identifier changes when the provider rebuilds its list, and
/// two devices on two providers know two different ones.
public enum LiveShelfChoice {

    /// So many channels go into the shelf — and so many can be chosen.
    ///
    /// **The running channel is the information, not the list.** A shelf with twenty
    /// channels would be the Live area done badly; six answer "is something running right now
    /// that interests me" and send you there for everything else.
    public static let atMost = 6

    /// For so many of the **ordered** channels the guide is fetched from the guide store.
    ///
    /// **Order first, then cut off** (finding of 2026-09-07 on the phone): If the cap stood
    /// before the ordering, a chosen channel at 2,064 visible ones lay slightly behind the
    /// limit and **never** got a guide. Two hundred and not four hundred, since the
    /// order lists a name only once — two hundred different channels suffice
    /// to find six with a running broadcast, and the grab into the guide store is the
    /// more expensive one on the TV.
    public static let programmeFor = 200

    /// The order in which channels move into the shelf — **a choice or a default, never
    /// both.**
    ///
    /// **If the viewer has chosen, only their choice applies**, in their order (requirement
    /// of 2026-09-07: if any entry is chosen there, the choice from settings
    /// takes precedence over the default). A choice whose channels are all
    /// missing displaces nothing — otherwise an empty shelf would stand there forever, without
    /// anyone saying that the choice is the cause.
    ///
    /// **Otherwise the default in three tiers:** the last watched, then the favourites,
    /// then the rest in the provider's order.
    ///
    /// **Separator rows drop out** — headings that a provider puts into the
    /// list as channels have neither picture nor guide.
    ///
    /// - Parameters:
    ///   - gewaehlt: The choice as channel names.
    ///   - zuletzt: The last watched as channel names, most recent first.
    public static func order(
        from channels: [Channel], chosen: [String], recent: [String]
    ) -> [Channel] {
        var perName: [String: Channel] = [:]
        var unique: [Channel] = []
        for channel in channels where !channel.isSectionMarker {
            let name = channel.channelName
            guard perName[name] == nil else { continue }
            perName[name] = channel
            unique.append(channel)
        }

        var result: [Channel] = []
        var seen = Set<String>()
        func take(_ names: [String]) {
            for name in names {
                guard let channel = perName[name], seen.insert(name).inserted else { continue }
                result.append(channel)
            }
        }

        take(chosen)
        guard result.isEmpty else { return result }

        take(recent)
        take(unique.filter(\.isFavorite).map(\.channelName))
        take(unique.map(\.channelName))
        return result
    }

    /// Which of the ordered channels get a tile, with what is running right now.
    ///
    /// **For the default the guide requirement applies**: A suggestion without "running now"
    /// does not answer the question of the shelf.
    ///
    /// **An explicitly chosen channel stands even without a guide** (finding of 2026-09-07
    /// on the phone and of 2026-09-12 on the TV): Whether the provider keeps a guide for a group
    /// is up to the provider and not the viewer, and without this exception
    /// the shelf they have just set up would vanish.
    ///
    /// - Parameter laeuft: The running broadcast of a channel, if known.
    public static func selection(
        _ ordered: [Channel], chosen: [String], atMost limit: Int = atMost,
        isRunning: (Channel) -> Programme?
    ) -> [(channels: Channel, isRunning: Programme?)] {
        let choice = Set(chosen)
        var found: [(channels: Channel, isRunning: Programme?)] = []
        for channel in ordered {
            guard found.count < limit else { break }
            let broadcast = isRunning(channel)
            guard broadcast != nil || choice.contains(channel.channelName) else { continue }
            found.append((channel, broadcast))
        }
        return found
    }

    /// Choose or deselect a channel — **at most ``atMost``, the oldest yields.**
    ///
    /// **A choice that allows more than the shelf shows is a promise it does not
    /// keep**: The seventh channel would stand nowhere, and nobody would say why. On the
    /// TV no limit applied until 2026-09-26. ("a second limit would drift apart from that of the
    /// shelf") — this one is the same number as the shelf's and can no longer do
    /// that. An older, longer choice remains untouched when reading.
    public static func select(_ name: String, on: Bool, in list: [String]) -> [String] {
        var fresh = list.filter { $0 != name }
        guard on else { return fresh }
        fresh.append(name)
        if fresh.count > atMost { fresh.removeFirst(fresh.count - atMost) }
        return fresh
    }
}
