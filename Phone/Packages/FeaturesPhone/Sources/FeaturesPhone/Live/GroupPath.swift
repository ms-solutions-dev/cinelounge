import Core
import Foundation

/// The 96 channel groups in two levels — **country, then subdivision.**
///
/// **The shape comes from the provider and is not invented.** It writes its groups as
/// `DE | SOLA BUNDESLIGA`, `TR | SINEMA 2`, `FR | NATIONAL HD SPORT`. Counted on 2026-09-06:
/// 96 groups across **40** prefixes — and the distribution is the reason for this level.
/// **DE** leads with 23 groups, **TR** with 20, **FR** with 14; the remaining 37 prefixes have exactly
/// **one**. A chip row with 96 entries — two and a half per screen width — becomes
/// a list of 40, and three of them lead deeper.
///
/// **Two groups do not fit the pattern**, and both stay as they are instead of being bent into
/// shape: `SS: SCREENSAVER` carries a colon instead of a dash, and
/// `UFC * MMA | FIGHT` has a prefix that is not a country code. A group without a
/// recognized code is therefore its **own** country with exactly one subdivision — it
/// then stands in the first level and leads nowhere.
///
/// **After folding and not before**: the other way round would not work. The number on a
/// subdivision is meant to say how many rows stand behind it — and those are bundles, not
/// feeds.
public struct GroupPath: Sendable, Equatable, Identifiable {

    /// The prefix — "DE", "TR". Without a recognized code: the whole group name.
    public let land: String

    /// The groups under this prefix, in the provider's order.
    public let subdivisions: [Subdivision]

    /// How many rows stand beneath it in total.
    public let count: Int

    public var id: String { land }

    /// Whether this prefix has a second level.
    ///
    /// **With 37 of 40 it does not** — there, a tap on the country is directly the choice
    /// of the group. A second level with a single entry would be a step that
    /// decides nothing.
    public var leadsDeeper: Bool { subdivisions.count > 1 }

    /// A group as the provider keeps it.
    public struct Subdivision: Sendable, Equatable, Identifiable {
        /// The full group name — what is filtered by.
        public let group: String
        /// What stands behind the dash; without a dash the whole name.
        public let name: String
        public let count: Int

        public var id: String { group }
    }

    /// Determine the prefix of a group — **the whole group if no country code is recognized.**
    ///
    /// The rule lives in ``Core/ChannelName/countryCode(fromGroup:)`` and applies on the
    /// TV just the same (AP58 R5, finding L2): until 2026-09-26 the phone split
    /// at `" | "` and took every head — `DE|SPORT` was then a country of its own and
    /// `UFC * MMA | FIGHT` stood under the "country" `UFC * MMA`.
    public static func land(from group: String) -> String {
        ChannelName.countryCode(fromGroup: group) ?? group
    }

    /// What stands behind the prefix — ``Core/ChannelName/groupRemainder(fromGroup:)``.
    public static func subdivision(from group: String) -> String {
        ChannelName.groupRemainder(fromGroup: group)
    }

    /// Arrange the groups in two levels — **in the provider's order.**
    ///
    /// A country stands where its **first** group stood. Sorting alphabetically
    /// would here be almost the same — the provider keeps its list that way anyway —, but
    /// "almost the same" is no reason: whoever has ordered their groups has thereby
    /// said what matters to them.
    public static func routes(from groups: [ChannelGroup]) -> [GroupPath] {
        var order: [String] = []
        var collected: [String: [Subdivision]] = [:]

        for group in groups {
            let prefix = land(from: group.name)
            if collected[prefix] == nil { order.append(prefix) }
            collected[prefix, default: []].append(
                Subdivision(
                    group: group.name, name: subdivision(from: group.name),
                    count: group.count))
        }

        return order.map { prefix in
            let split = collected[prefix] ?? []
            return GroupPath(
                land: prefix, subdivisions: split,
                count: split.reduce(0) { $0 + $1.count })
        }
    }
}
