import Core
import Foundation

/// The computations behind the allow list for Live and the row before it — **checkable
/// without a view, once for both programs** (AP58 R1, finding K5).
///
/// Until now it existed literally twice, on the TV (`LivePermission.swift`) and on the phone
/// (`LiveForKidsView.swift`); only the way to the wording differed. The views stay per
/// platform, the computation and its sentences (shared catalog `WordingKit`) live here.
public enum LivePermission {

    /// A row of the list.
    public struct Row: Identifiable, Equatable, Sendable {
        public let group: ChannelApproval.Group
        /// How many channels the child would see in it — `nil` if the provider no longer carries the
        /// group.
        public let channels: Int?
        public let isAllowed: Bool

        public var id: ChannelApproval.Group { group }

        public init(group: ChannelApproval.Group, channels: Int?, isAllowed: Bool) {
            self.group = group
            self.channels = channels
            self.isAllowed = isAllowed
        }
    }

    /// The rows of a channel list.
    public struct Block: Identifiable, Equatable, Sendable {
        public let list: String
        public let rows: [Row]
        public var id: String { list }
    }

    /// What the list shows: **every selectable group in the provider's order**, followed by the
    /// permitted ones that the provider no longer carries.
    ///
    /// **The vanished ones stay listed** so that they can be removed. Otherwise a permission
    /// would lie invisible in the store and take effect again on the day the provider creates a
    /// group of the same name anew — with different content.
    public static func rows(choice: [ChannelApproval.Choice], approval: ChannelApproval) -> [Row] {
        let known = Set(choice.map(\.group))
        let da = choice.map {
            Row(group: $0.group, channels: $0.channels, isAllowed: approval.contains($0.group))
        }
        let route = approval.groups.subtracting(known).sorted().map {
            Row(group: $0, channels: nil, isAllowed: true)
        }
        return da + route
    }

    /// The rows per channel list, in the order of their first appearance.
    public static func blocks(_ rows: [Row]) -> [Block] {
        var episode: [String] = []
        var per: [String: [Row]] = [:]
        for row in rows {
            if per[row.group.list] == nil { episode.append(row.group.list) }
            per[row.group.list, default: []].append(row)
        }
        return episode.map { Block(list: $0, rows: per[$0] ?? []) }
    }

    /// Whether the headers of the channel lists are needed — **only from two on**, like the
    /// provider level of the bar.
    public static func hasMultipleLists(_ rows: [Row]) -> Bool {
        Set(rows.map(\.group.list)).count > 1
    }

    /// The label of a row: the readable group name and after it how many channels the child
    /// would see in it — or that the provider no longer carries the group.
    public static func caption(_ row: Row) -> String {
        let number =
            row.channels.map {
                AppLanguageSetting.word("childLock.liveChannels \($0)")
            } ?? AppLanguageSetting.word("childLock.liveGone")
        return ChannelName.display(row.group.name) + " · " + number
    }

    /// The focus ID of a group row — **with the list**, because two lists can carry the same
    /// group.
    public static func identifier(_ group: ChannelApproval.Group) -> String {
        "live-" + group.list + "|" + group.name
    }

    /// The value of a child's row: "No Live" or "3 groups · 42 channels".
    ///
    /// **The channels from the catalog and not from the list** — the number the child would
    /// really get. Without a loaded catalog only the number of groups is shown.
    public static func value(_ approval: ChannelApproval, catalog: [Channel]) -> String {
        guard !approval.isEmpty else {
            return AppLanguageSetting.word("childLock.liveOff")
        }
        let groups = approval.groups.count
        guard !catalog.isEmpty else {
            return AppLanguageSetting.word("childLock.liveGroupCount \(groups)")
        }
        let channels = approval.channelCount(in: catalog)
        return AppLanguageSetting.word("childLock.liveCount \(groups) \(channels)")
    }
}
