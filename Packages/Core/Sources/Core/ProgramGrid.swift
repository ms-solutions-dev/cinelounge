import Foundation

/// Computes the grid's rows from channels and their program.
///
/// **The view that the Live block exists for** (`design/konzept-p8.md`,
/// section 3). On the left the channel column, on the right the time axis; here what stands
/// on the right is produced — and **without a view**, so that it is testable.
///
/// ## This model does three things, and each has a reason
///
/// **It fills holes.** 89 percent of the test provider's channels have no
/// EPG. A grid that shows nothing there looks broken — and it is also
/// not operable: an empty row has nothing on which the focus
/// could land. Every unoccupied stretch therefore becomes a cell of its own with the
/// channel name. The hole is the normal case here, not the error.
///
/// **It trims at the window edge.** A feature film of three hours sticks out
/// left and right. The cell therefore carries its real times
/// **and** the note on which side it is cut off — the view
/// draws the arrow on that, which says "continues".
///
/// **It throws away overlaps, but not silently.** Since 2026-08-29 it is
/// proven that this provider occupies the same channel in parallel (290 rows
/// of 5512). Two cells on top of each other would be no information in the grid,
/// but a drawing error; so the second one is dropped. How many there were
/// is in ``Row/discarded`` — a number nobody reads would be the
/// beginning of the next silent gap.
public enum ProgramGrid {

    /// Where an entry stands in time.
    public enum Situation: Sendable, Equatable {
        case past
        case running
        case upcoming
    }

    /// A box in the grid.
    public struct Cell: Sendable, Equatable, Identifiable {
        public let id: String
        /// The channel the box belongs to.
        public let channelID: String
        public let title: String
        /// Start and end **as broadcast**, not as drawn.
        public let start: Date
        public let end: Date
        /// What of it lies in the window — the view computes the width from this.
        public let visibleFrom: Date
        public let visibleUntil: Date
        public let state: Situation
        /// Whether there was no program at all here.
        public let isGap: Bool

        /// Whether the entry began before the window.
        public var extendsLeft: Bool { start < visibleFrom }
        /// Whether it continues after the window.
        public var extendsRight: Bool { end > visibleUntil }
        /// How long the visible part is, in seconds.
        public var visibleDuration: TimeInterval { visibleUntil.timeIntervalSince(visibleFrom) }
    }

    /// A channel row.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let channels: Channel
        public let cells: [Cell]
        /// How many entries were dropped because of overlap.
        public let discarded: Int
        /// Whether this channel carries a program at all.
        public var hasProgram: Bool { cells.contains { !$0.isGap } }
    }

    /// How short a remaining gap may be before it is dropped.
    ///
    /// **Slivers of seconds are not a cell.** Between two shows there regularly gapes
    /// a gap of a few seconds in the XMLTV — as a box of its own it would be a line that nobody can hit,
    /// and in the focus path a stop without content. One minute is the limit: anything shorter is
    /// added to the previous cell.
    public static let smallestGap: TimeInterval = 60

    /// Builds the rows of a window.
    ///
    /// - Parameters:
    ///   - sender: The channels of the chosen group, in their order.
    ///   - programme: The program per **EPG identifier** — as it comes from the
    ///     database, and HD and FHD of the same channel share one.
    ///   - von: Start of the window.
    ///   - bis: End of the window.
    ///   - jetzt: The point in time against which "running" is measured.
    public static func rows(
        channels: [Channel],
        programs: [String: [Programme]],
        from: Date,
        until: Date,
        now: Date
    ) -> [Row] {
        guard until > from else { return [] }
        return channels.map { channel in
            let own = channel.epgID.map { programs[$0] ?? [] } ?? []
            let (cells, discarded) = self.cells(
                forItem: channel, from: own, from: from, until: until, now: now)
            return Row(id: channel.id, channels: channel, cells: cells, discarded: discarded)
        }
    }

    /// The boxes of a row — gapless from `from` to `until`.
    static func cells(
        forItem channel: Channel,
        from programs: [Programme],
        from: Date,
        until: Date,
        now: Date
    ) -> (cells: [Cell], discarded: Int) {
        // Only what touches the window at all — and in channel order.
        let matched =
            programs
            .filter { $0.end > from && $0.start < until }
            .sorted { $0.start < $1.start }

        var cells: [Cell] = []
        var discarded = 0
        /// Up to where the row is already occupied.
        var cursor = from

        for broadcast in matched {
            let visibleFrom = max(broadcast.start, from)
            let visibleUntil = min(broadcast.end, until)
            // **The parallel occupancy** — see the class doc: what begins within what is already
            // occupied is dropped.
            //
            // **Measured at the visible start and not at the broadcast start.** The
            // first version compared `broadcast.start < cursor` — and thereby threw away
            // precisely the show that began **before** the window and sticks
            // into it: the feature film that started at 8 pm while the
            // window begins at 9 pm. The most common case of the whole
            // view, and it would have vanished silently. At the window start
            // `visibleFrom == cursor` applies, so no overlap.
            guard visibleFrom >= cursor else {
                discarded += 1
                continue
            }
            // The stretch before it is unoccupied.
            if visibleFrom.timeIntervalSince(cursor) >= smallestGap {
                cells.append(gap(channel, from: cursor, until: visibleFrom, now: now))
            }
            cells.append(
                Cell(
                    id: broadcast.id,
                    channelID: channel.id,
                    title: broadcast.title,
                    start: broadcast.start,
                    end: broadcast.end,
                    visibleFrom: visibleFrom,
                    visibleUntil: visibleUntil,
                    state: state(from: broadcast.start, until: broadcast.end, now: now),
                    isGap: false
                ))
            cursor = max(cursor, visibleUntil)
        }
        // **No early exit**, although it would suggest itself as soon as the
        // window is full: the loop counts the parallel occupancies on the side,
        // and an exit would conceal exactly those that lie at the window end.
        // The list is already filtered to the window anyway.

        // The rest — and for a channel without EPG that is the whole row.
        if until.timeIntervalSince(cursor) >= smallestGap || cells.isEmpty {
            cells.append(gap(channel, from: cursor, until: until, now: now))
        }
        return (cells, discarded)
    }

    /// A box without a program — it carries the channel name.
    private static func gap(
        _ channel: Channel, from: Date, until: Date, now: Date
    ) -> Cell {
        Cell(
            id: "luecke|\(channel.id)|\(Int(from.timeIntervalSince1970))",
            channelID: channel.id,
            title: channel.cleanName,
            start: from,
            end: until,
            visibleFrom: from,
            visibleUntil: until,
            state: state(from: from, until: until, now: now),
            isGap: true
        )
    }

    static func state(from: Date, until: Date, now: Date) -> Situation {
        if until <= now { return .past }
        if from > now { return .upcoming }
        return .running
    }
}
