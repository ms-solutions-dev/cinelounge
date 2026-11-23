import Core
import Flows
import Foundation

/// A channel and its feeds — **one entry, several qualities.**
///
/// **What folding really brings was counted on 2026-09-06**, and the number differs from the
/// expected one: **7.746** channels become **7.188** entries, not 1.500 to 2.500. 468
/// bundles with more than one feed arise — 462 of them with all different tags, six with
/// duplicates. 2.161 names carry a tag at the end at all, but most stand alone: The
/// provider carries very few channels in several variants.
///
/// **So folding is not the lever against the length of the list** — that comes from 96
/// groups, the largest of which carries 644 channels. It is still right, for two reasons:
/// Three rows that are all called "Zenit 1" are an error for the viewer and not a choice.
/// And the tags are the **fallback route**: With an account that has exactly one permitted
/// connection, "take the other feed" is the natural detour when one does not work.
///
/// **Folding happens per group.** Across the groups you would get 7.178 instead of 7.188 —
/// ten names appear in more than one group. Ten entries are not worth tearing a channel
/// out of the group the provider put it in.
public struct ChannelBundle: Sendable, Equatable, Identifiable {

    /// The feeds, **in the provider's order.**
    ///
    /// **Not sorted by quality, and that is measured and not convenient:** The provider
    /// already lists them from top to bottom — "Zenit 1 FHD, HD, SD", "SOL 1 FHD, SD". Our own
    /// ranking over `SD/HD/FHD/UHD/4K/RAW/HEVC` would be a second rule over foreign words that
    /// are allowed to change; it would drift apart at the first new abbreviation, and it
    /// would overwrite an order the provider set on purpose.
    public let feeds: [Channel]

    /// The name without the tag — "Zenit 1".
    public let name: String

    public init(name: String, feeds: [Channel]) {
        self.name = name
        self.feeds = feeds
    }

    /// The channel that plays when the row is pressed: the provider's first.
    public var leader: Channel { feeds[0] }

    /// **The ID of the leader and none of its own.** It goes into the player, the history and
    /// the favorites; an invented bundle ID would have to be resolved again everywhere there.
    public var id: String { leader.id }

    public var group: String? { leader.group }

    /// The tags to choose from — empty where there is nothing to choose.
    ///
    /// **For 93 percent of the entries this is empty**, and then nothing appears in the row
    /// either: A switch with one position is not a switch. A feed without a tag carries the
    /// dash — it is the variant the provider did not name, and leaving it out would take it
    /// out of the choice.
    public var marks: [Brand] {
        guard feeds.count > 1 else { return [] }
        return feeds.map { Brand(channels: $0) }
    }

    /// A feed as it appears in the row.
    public struct Brand: Sendable, Equatable, Identifiable {
        public let channels: Channel
        public var id: String { channels.id }

        /// "FHD", "HD" — or the dash for the unnamed variant.
        public var wording: String { ChannelDisplayName(channels.name).tag ?? Self.noBrand }

        static let noBrand = "—"
    }

    // MARK: - Falten

    /// Merge channels into bundles — **in the order in which they came.**
    ///
    /// **Nothing is reordered.** A bundle stands where its **first** feed stood; the others
    /// disappear from the list and sit inside it. Anyone who reordered would destroy the
    /// provider's order, which this model treats as information elsewhere.
    ///
    /// **The key is `ChannelDisplayName` and not `Channel.searchKey`.** Both fold the same
    /// decorations; `searchKey` additionally throws away the provider's prefix ("DE:",
    /// "PERLE:") and all punctuation. Measured on the catalog this would give 7.165 instead
    /// of 7.188 entries — 23 bundles more, and among them cases like "SPORTFELD HD" with
    /// "SPORTFELD+HD" that are **not** the same channel. For twenty rows that is too high a price.
    ///
    /// **The rule has stood in ``Flows/ChannelSearch/fold(_:)`` since 2026-09-26** (B4): The
    /// TV's channel search folds its hits by the same key.
    public static func fold(_ channels: [Channel]) -> [ChannelBundle] {
        ChannelSearch.fold(channels).map { feeds in
            ChannelBundle(name: ChannelDisplayName(feeds[0].name).name, feeds: feeds)
        }
    }
}
