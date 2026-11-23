import Foundation

/// What is visible in the Live area.
///
/// Two decisions that belong to the viewer and to no automatic mechanism.
public struct LivePreferences: Sendable, Equatable {

    /// Whether channels marked as adult content appear.
    ///
    /// **Default: no** — and that is not prudishness, but the direction of the
    /// surprise. Anyone flipping through 79 groups with family around should not
    /// stumble into it; anyone who wants to see them finds a switch. The other way round the
    /// mistake could not be undone.
    ///
    /// **Not a hard filter, but a switch.** Two reasons. The decision
    /// belongs to the user and not to the app. And `is_adult` is a claim **by the
    /// provider** — in a checked catalog 294 of 5389 channels carry it,
    /// but whether that is complete and correct only the provider knows. An automatic mechanism that acts
    /// as if it knew is less honest than a switch.
    ///
    /// Later the parental controls from E7 attach here with a PIN.
    public private(set) var showsAdultChannels: Bool

    /// Groups that stay hidden.
    ///
    /// What is stored is what is **excluded**, not what is allowed —
    /// the same consideration as with ``HeroPreferences``: If the provider adds a
    /// group, it is included without any action. With an allow list it would be
    /// silently invisible, and one would look for the fault in the app.
    ///
    /// With 79 groups, of which 46 are German, hiding the rest is the
    /// most important lever of all.
    public private(set) var hiddenGroups: Set<String>

    /// Whether the overview area stands in front of playback — channel list, search,
    /// guide.
    ///
    /// **Default: no.** The reason has been fixed since the build of ``LiveMemory``
    /// and is also written down there: "Anyone who selects 'Live' wants to watch TV
    /// and not browse a list." Channels, groups and guide can be reached from
    /// running playback — once to the left for the channel list, once
    /// more for the groups. The area in front is thus a step without a
    /// purpose, and a press on "Live" opens the channel where one
    /// left off.
    ///
    /// **Why it stays anyway:** for searching and browsing. Anyone who needs that
    /// switches it on here. It just must not be taken away — it is the
    /// only place where one searches across all channels.
    ///
    /// The very first time it appears anyway: Without a channel that the app
    /// remembers, skipping would lead nowhere.
    public private(set) var showsBrowseArea: Bool

    /// Whether the focused channel appears as a running picture after a short dwell.
    ///
    /// **Default: no, and the reason is the connection.** The checked access
    /// allows exactly one. The preview gives it up before playback starts —
    /// two streams are therefore never open at the same time —, but whether the provider
    /// frees it immediately again is up to the provider and not this app. If it stays
    /// occupied there briefly, the start of the channel one actually wanted to see
    /// fails: a worse result than a missing preview.
    ///
    /// Anyone with several connections switches it on and has nothing to fear.
    public private(set) var previewsChannels: Bool

    /// The order of the groups as the viewer has set it.
    ///
    /// Empty means: The provider's order applies — for many it is
    /// the familiar channel numbering and therefore stays the default.
    /// Groups that have been set come first in this sequence, all others after them in
    /// provider order — so the setting also survives groups that
    /// the provider inserts later.
    public private(set) var groupOrder: [String]

    public init(
        showsAdultChannels: Bool = false,
        hiddenGroups: Set<String> = [],
        previewsChannels: Bool = false,
        groupOrder: [String] = [],
        showsBrowseArea: Bool = false
    ) {
        self.showsAdultChannels = showsAdultChannels
        self.hiddenGroups = hiddenGroups
        self.previewsChannels = previewsChannels
        self.groupOrder = groupOrder
        self.showsBrowseArea = showsBrowseArea
    }

    public mutating func setShowsBrowseArea(_ shows: Bool) {
        showsBrowseArea = shows
    }

    // MARK: - Ändern

    public mutating func setShowsAdultChannels(_ shows: Bool) {
        showsAdultChannels = shows
    }

    public mutating func setPreviewsChannels(_ previews: Bool) {
        previewsChannels = previews
    }

    public mutating func setVisible(_ visible: Bool, group: String) {
        if visible {
            hiddenGroups.remove(group)
        } else {
            hiddenGroups.insert(group)
        }
    }

    public mutating func setGroupOrder(_ order: [String]) {
        groupOrder = order
    }

    /// Applies the set order to group names.
    ///
    /// Stable in both directions: Names that have been set come in their set
    /// sequence, unknown ones after them in the order in which they came in.
    public func ordered(_ names: [String]) -> [String] {
        guard !groupOrder.isEmpty else { return names }

        var position: [String: Int] = [:]
        for (index, name) in groupOrder.enumerated() where position[name] == nil {
            position[name] = index
        }

        let known = names.filter { position[$0] != nil }
            .sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
        let unknown = names.filter { position[$0] == nil }
        return known + unknown
    }

    public func allows(group: String?) -> Bool {
        guard let group else { return true }
        return !hiddenGroups.contains(group)
    }

    /// Whether a channel may appear.
    ///
    /// Both conditions in one place, so that no view applies the one and
    /// forgets the other — a channel that shows up in search but not in
    /// the list looks like a bug.
    public func allows(group: String?, isAdult: Bool) -> Bool {
        if isAdult, !showsAdultChannels { return false }
        return allows(group: group)
    }

    /// The catalog as it may appear — channels **and** thereby also groups.
    ///
    /// **The finding of 2026-08-29:** Hiding worked only in the Live area. Anyone who
    /// had a channel open and went into the group list in the player's overlay
    /// still saw **all** groups there. The cause was
    /// not a forgotten condition but a second source: The overlay
    /// fetches the full catalog itself when the one passed in is empty — and
    /// "full" meant unfiltered until then.
    ///
    /// The group list is derived from the channels. Anyone who filters the channels
    /// filters the groups too; a separate group rule would be a second
    /// place where the same thing can be forgotten.
    public func isVisible(_ channels: [Channel]) -> [Channel] {
        channels.filter { allows(group: $0.group, isAdult: $0.isAdult) }
    }

    // MARK: - Ablage

    static let adultKey = "live.showsAdult"
    static let groupsKey = "live.hiddenGroups"
    static let previewKey = "live.previewsChannels"
    static let browseKey = "live.showsBrowseArea"
    static let orderKey = "live.groupOrder"
    /// Where until 2026-09-26 the phone stored its sports filters — **now only for the
    /// one-time migration** into ``SportFilterSettings`` (AP58 R5, finding L4).
    static let sportsKey = "live.hiddenSports"

    public static func load(from store: any KeyValueStore) -> LivePreferences {
        let shows = (try? store.value(for: adultKey)) == "1"

        // As one line with a separator and not as JSON: These are group names
        // without structure. The line break as separator, because in group names
        // really everything occurs — commas, vertical bars, colons, hash signs
        // and superscript characters. A line break does not occur in them.
        let raw = (try? store.value(for: groupsKey)) ?? ""
        let groups = raw.split(separator: "\n").map(String.init)

        // The same storage form as the hidden groups, for the same
        // reason: In group names everything occurs except the line break.
        let rawOrder = (try? store.value(for: orderKey)) ?? ""
        let order = rawOrder.split(separator: "\n").map(String.init)

        return LivePreferences(
            showsAdultChannels: shows,
            hiddenGroups: Set(groups),
            previewsChannels: (try? store.value(for: previewKey)) == "1",
            groupOrder: order,
            showsBrowseArea: (try? store.value(for: browseKey)) == "1"
        )
    }

    public func save(to store: any KeyValueStore) {
        if showsAdultChannels {
            try? store.set("1", for: Self.adultKey)
        } else {
            try? store.remove(Self.adultKey)
        }

        if previewsChannels {
            try? store.set("1", for: Self.previewKey)
        } else {
            try? store.remove(Self.previewKey)
        }

        if showsBrowseArea {
            try? store.set("1", for: Self.browseKey)
        } else {
            try? store.remove(Self.browseKey)
        }

        if hiddenGroups.isEmpty {
            try? store.remove(Self.groupsKey)
        } else {
            // Sorted, so that the same selection always yields the same line — otherwise a comparison
            // sees changes where there are none.
            try? store.set(hiddenGroups.sorted().joined(separator: "\n"), for: Self.groupsKey)
        }

        // UNsorted, on purpose: The order IS the content.
        if groupOrder.isEmpty {
            try? store.remove(Self.orderKey)
        } else {
            try? store.set(groupOrder.joined(separator: "\n"), for: Self.orderKey)
        }
    }
}
