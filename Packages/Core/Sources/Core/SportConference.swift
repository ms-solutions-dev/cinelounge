import Foundation

/// The row the sports area lacked until E7: **"Bundesliga · 15:30 · 5 games"**.
///
/// **What it is for** (concept, section 8, open decision 1): on a Bundesliga
/// Saturday five games kick off together, and Arena broadcasts them on ten channels,
/// all called "BL". Without this row, five identical-looking entries would stand
/// one below the other, each with the same ten channels beneath it, and the
/// viewer would have to guess which of the ten shows their game. With it, a
/// heading stands there and below it the five games.
///
/// **What it expressly does NOT do: create rows.** It summarises what is there
/// anyway. The same game on four channels is still **one** row — that is decided
/// by the merging in ``SportPlan`` and ``SportMatch``, long before. Whoever sees
/// ten rows here where six games are scheduled has an error in the merging and
/// not in the grouping; ``SportConferenceTests`` records that.
public enum SportConference {

    /// How far apart two kickoffs may be and still be the same conference.
    ///
    /// **Ten minutes**, and the number sits between two others: a conference is by
    /// definition simultaneous — the source gives the same minute for all five games.
    /// The window only catches the case that a source rounds one game to 15:30 and
    /// another to 15:35. It is clearly narrower than the merge window of 25 minutes
    /// (``SportPlan/mergeWindow``), which decides whether two broadcasts are the
    /// **same** game — otherwise this calculation would group games together that the
    /// other still considers one.
    public static let window: TimeInterval = 10 * 60

    /// An entry of the list: either a conference or a single event.
    public enum ContentEntryRecord: Identifiable, Sendable, Equatable {
        case conference(Group)
        case single(SportEvent)

        public var id: String {
            switch self {
            case .conference(let group): group.id
            case .single(let event): event.id
            }
        }

        /// The events of this entry, in their order.
        public var events: [SportEvent] {
            switch self {
            case .conference(let group): group.matches
            case .single(let event): [event]
            }
        }
    }

    /// Several games of the same competition at the same time.
    public struct Group: Identifiable, Sendable, Equatable {
        /// The identifier of the competition (``SportCompetition/path``).
        public let path: String
        /// What the competition is called in the row — the source's name.
        public let name: String
        /// The shared kickoff: the earliest of the group.
        public let start: Date
        public let matches: [SportEvent]

        public var id: String { "konferenz#\(path)#\(Int(start.timeIntervalSince1970))" }
    }

    /// Summarises the list into conferences, **without changing its order**.
    ///
    /// A group comes into being where its first game stands; the remaining games are
    /// pulled there. That is the only rearrangement that takes place — nothing is
    /// sorted, because the order of the list is decided by the caller (watch list,
    /// sections), and a grouping must not override it.
    ///
    /// Events without ``SportEvent/competitionPath`` stay single: without an
    /// identifier there is no answer to "is that the same competition", and the
    /// similarity of two names is none.
    public static func grouped(_ events: [SportEvent]) -> [ContentEntryRecord] {
        var entries: [ContentEntryRecord] = []
        // Where a game that comes later belongs: competition → position in `entries`
        // and kickoff of the group.
        var pending: [String: (slot: Int, start: Date)] = [:]

        for event in events {
            guard let path = event.competitionPath else {
                entries.append(.single(event))
                continue
            }
            if let group = pending[path],
                abs(event.start.timeIntervalSince(group.start)) <= window
            {
                var matches = entries[group.slot].events
                matches.append(event)
                entries[group.slot] = .conference(
                    Group(
                        path: path, name: name(matches), start: matches.map(\.start).min() ?? group.start,
                        matches: matches))
                continue
            }
            pending[path] = (slot: entries.count, start: event.start)
            entries.append(.single(event))
        }
        return entries
    }

    /// The name of the group — the first one that a game brings along.
    private static func name(_ matches: [SportEvent]) -> String {
        matches.compactMap(\.competition).first { !$0.isEmpty } ?? ""
    }
}
