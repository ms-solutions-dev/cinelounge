import Core
import Foundation
import ParentalControls

/// **Channels in search — the same source on both devices** (decision 27, B4,
/// 2026-09-26).
///
/// **Until then only the phone searched the channels**, and the TV said
/// explicitly "Channels are not here". Whoever looks for a channel wants to find it: The
/// provider of this household carries 7,746 channels, and without search they can be reached only through the
/// Live area.
///
/// **Searching goes via ``LiveCatalog``** — the same visibility, the same search key
/// and the same minimum length as in the Live area. The catalog has already passed the ``ChannelLock``:
/// `LiveLibrary` filters every delivery (``Core/ChannelLock``).
/// Until 2026-09-27 only the phone passed it here, and the TV's search found
/// an unmarked channel that its Live area hid.
///
/// **Without network and without a fetch.** The channel list is in the store; searching it costs
/// one pass over an array in memory.
public nonisolated enum ChannelSearch {

    public struct Outcome: Sendable, Equatable {
        /// **One** entry per channel — a station's feeds, folded
        /// (``fold(_:)``), in the order of the catalog.
        public let match: [[Channel]]
        /// How many channels were searched — the information that answers, with zero hits,
        /// whether it was the word or the search.
        public let searched: Int
    }

    public static func search(
        _ word: String, in catalog: [Channel], preferences: LivePreferences, atMost: Int
    ) -> Outcome {
        let isVisible = LiveCatalog.isVisible(catalog, preferences: preferences)
        guard let key = LiveCatalog.searchKey(word) else {
            return Outcome(match: [], searched: isVisible.count)
        }
        let found = isVisible.filter { $0.searchKey.contains(key) }
        return Outcome(
            match: Array(fold(found).prefix(atMost)), searched: isVisible.count)
    }

    /// Folds a station's feeds — **same group, same name without
    /// quality mark** (``Core/ChannelDisplayName``).
    ///
    /// Otherwise "Zenit 1" would appear three times one below the other, once per version. **The group belongs
    /// to the key:** Two providers can carry the same name in different groups,
    /// and then those are two stations.
    public static func fold(_ channels: [Channel]) -> [[Channel]] {
        var bundles: [[Channel]] = []
        var slot: [String: Int] = [:]
        for one in channels {
            let key = (one.group ?? "") + "\u{1F}" + ChannelDisplayName(one.name).name
            if let found = slot[key] {
                bundles[found].append(one)
            } else {
                slot[key] = bundles.count
                bundles.append([one])
            }
        }
        return bundles
    }
}
