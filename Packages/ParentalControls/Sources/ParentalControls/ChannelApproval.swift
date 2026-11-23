import Core
import Diagnose
import Foundation

/// **The channel groups a child may see** (AP52, product decision 14 of
/// 2026-09-25, replaces decision 8).
///
/// **An allow list and not a block list — deliberately against the direction of
/// ``Core/LivePreferences/hiddenGroups``.** There what is stored is what is hidden,
/// so that a new group from the provider appears without any action: For an adult an
/// invisible group is the more annoying mistake. For a child it is the other way round. Channels
/// carry no age ratings (``TabScope``), and a group that the provider
/// slips in overnight has been looked at by nobody. **Only what is explicitly on
/// the list is allowed**, and a new group is never on it.
///
/// **Empty means no Live, and empty is the default.** That way every child profile
/// that was created before this list stays exactly as it was (K4a of the board
/// `design/childInterface.html`); only a choice opens the area (K4b).
///
/// **Per channel list and group, not just per group name.** Two lists can both carry a
/// group "Kinder", and the second provider is not the one a parent
/// has reviewed. The key is therefore the pair of ``Core/Channel/playlistID``
/// and ``Core/Channel/group``.
///
/// **Adult channels are never allowed**, even in an allowed group: The list
/// asks ``Core/Channel/isAdult`` before the group. A group that consists only of
/// adult channels is therefore not even selectable (``selectable(_:)``).
///
/// **Where it lives:** in the Keychain, in the compartment of the profile (``ProfileSlot``) — the same
/// store as age limit and mapping board, and for the same reason: What applies together with
/// the PIN must survive together with it. **It does not travel via iCloud**, because
/// the limit does not travel either; a parental control of which one half
/// travels with the profile and the other stays on the device would be only half of one on the second
/// TV. When an identifier moves, it moves along (``ProfileKit/ProfileMove``).
public struct ChannelApproval: Sendable, Hashable {

    /// A channel group of a particular channel list.
    public struct Group: Sendable, Hashable, Codable, Comparable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case list = "liste"
            case name
        }

        /// The identifier of the channel list — ``Core/Channel/playlistID``.
        public let list: String

        /// The group name, **raw as delivered** — as ``Core/Channel/group`` carries it.
        public let name: String

        public init(list: String, name: String) {
            self.list = list
            self.name = name
        }

        /// The group of this channel — `nil` if it has none.
        ///
        /// **A channel without a group is never allowed.** It cannot be selected, and
        /// letting it through everywhere for that reason would be the gap that a provider with an
        /// unstructured list opens up immediately.
        public init?(_ channels: Channel) {
            guard let name = channels.group, !name.isEmpty else { return nil }
            self.init(list: channels.playlistID, name: name)
        }

        public static func < (links: Group, right: Group) -> Bool {
            (links.list, links.name) < (right.list, right.name)
        }
    }

    /// What is explicitly allowed.
    public private(set) var groups: Set<Group>

    /// The empty list — **no Live.**
    public init() {
        groups = []
    }

    public init(groups: Set<Group>) {
        self.groups = groups
    }

    /// Whether anything at all is allowed — **empty means no Live.**
    public var isEmpty: Bool { groups.isEmpty }

    /// Whether this group is on the list.
    public func contains(_ group: Group) -> Bool {
        groups.contains(group)
    }

    /// Adds a group or removes it.
    public mutating func set(_ isAllowed: Bool, forItem group: Group) {
        if isAllowed {
            groups.insert(group)
        } else {
            groups.remove(group)
        }
    }

    /// Removes everything — back to "no Live".
    public mutating func clear() {
        groups = []
    }

    // MARK: - The filter

    /// Whether this channel may appear and play for a child.
    ///
    /// **Three questions in this order:** not an adult channel, not a group heading
    /// from the provider, and the group is on the list. The first one first, so that an
    /// adult channel in an allowed group does not slip past the group.
    public func isAllowed(_ channels: Channel) -> Bool {
        guard !channels.isAdult, !channels.isSectionMarker, let group = Group(channels) else {
            return false
        }
        return groups.contains(group)
    }

    /// The same catalog as a child sees it — in the provider's order.
    ///
    /// **One line when something was really hidden** — no channel name, only the
    /// numbers (diagnostics coverage, 2026-09-27).
    public func isVisible(_ channels: [Channel]) -> [Channel] {
        let result = channels.filter(isAllowed)
        let hidden = channels.count - result.count
        if hidden > 0 {
            Diagnose.hint(
                .parentalControls, "Channel lock: \(channels.count) checked, \(hidden) hidden")
        }
        return result
    }

    // MARK: - The selection

    /// A selectable group together with the number of its channels that a child would see.
    public struct Choice: Sendable, Equatable, Identifiable {
        public let group: Group
        /// The channels without an adult flag — **the number the child would get**, and
        /// not that of the list. Whoever chooses "Kinder · 12" should see twelve channels.
        public let channels: Int

        public var id: Group { group }

        public init(group: Group, channels: Int) {
            self.group = group
            self.channels = channels
        }
    }

    /// The groups that can be selected for a child — **in the provider's order.**
    ///
    /// **Without groups in which nothing would be left:** a group made only of
    /// adult channels or headings. Showing it would mean offering a choice
    /// that does nothing — or, worse, one that looks as if it allowed
    /// adult channels.
    public static func selectable(_ catalog: [Channel]) -> [Choice] {
        var episode: [Group] = []
        var number: [Group: Int] = [:]
        for channels in catalog where !channels.isAdult && !channels.isSectionMarker {
            guard let group = Group(channels) else { continue }
            if number[group] == nil { episode.append(group) }
            number[group, default: 0] += 1
        }
        return episode.map { Choice(group: $0, channels: number[$0] ?? 0) }
    }

    /// How many channels a child would see with this list from this catalog.
    public func channelCount(in catalog: [Channel]) -> Int {
        catalog.count(where: isAllowed)
    }

    // MARK: - Ablage

    /// **Not a language key but a store key** — `scripts/strings.py` recognises
    /// this by the namespace `childLock.`.
    public static let storeKey = "childLock.liveGroups"

    /// The stored list of this profile — **empty if nothing or something unreadable is there.**
    ///
    /// **Unreadable means empty and not "everything".** A broken store is no reason to put a
    /// child in front of the whole channel catalog.
    ///
    /// - Parameter profil: Whose list. `nil` is the **device's** compartment — it is never
    ///   written and therefore reads as empty; it is there only so that "no profile"
    ///   can ask the same question.
    public static func load(from store: any KeyValueStore, forItem profile: String?) -> ChannelApproval {
        let key = ProfileSlot.key(storeKey, forItem: profile)
        guard let raw = try? store.value(for: key) else { return ChannelApproval() }
        guard let data = raw.data(using: .utf8),
            let groups = try? JSONDecoder().decode([Group].self, from: data)
        else {
            // Unreadable means empty, not "everything" — but it does not stay silent: A
            // broken store otherwise looks like a child without Live permission, although
            // a list was there.
            Diagnose.hint(.parentalControls, "Channel allow list unreadable, treated as empty")
            return ChannelApproval()
        }
        return ChannelApproval(groups: Set(groups))
    }

    /// Stores the list. **Empty means delete** — there is nothing to remember that is not
    /// already the default.
    ///
    /// **As JSON and not as lines like ``Core/LivePreferences``**, because these are pairs:
    /// A separator between list and group would be a second one that must not occur in a
    /// group name. Sorted, so that the same choice yields the same line.
    public func save(to store: any KeyValueStore, forItem profile: String?) {
        let key = ProfileSlot.key(Self.storeKey, forItem: profile)
        guard !groups.isEmpty else {
            try? store.remove(key)
            return
        }
        guard let data = try? JSONEncoder().encode(groups.sorted()),
            let text = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }
}
