import Foundation

/// The **broadcast schedule**: which match runs on which channel — from a
/// source that answers exactly this question.
///
/// **The user's draft (2026-08-29), and it reverses the previous order:** if ESPN
/// says Demirbahçe plays tomorrow, and Spor Ekranı says tomorrow Demir plays
/// on Arena Spor 1 — and Arena Spor 1 is in the channel list — then there is a
/// hit, and the link must be given. An IPTV EPG cannot be trusted 100 % to be
/// correct; what is known is that ESPN and Spor Ekranı are correct.
///
/// Three facts, of which **none** comes from the provider's guide:
///
///     ESPN          Tarlaspor – Tepelispor, 19:00
///     Schedule      runs on "Arena Spor 1"
///     Channel list  "TR: ARENA SPOR 1 HD" is present
///                   → hit
///
/// **Why this became necessary.** On 2026-08-29 a bundle of sixteen channels hung
/// on "Westfalia Erzfeld – Elbhafener SV". Measured again on the provider's
/// guide: on all Arena Bundesliga channels there is nothing but "BL" at kick-off
/// time. The only channel in the whole programme that names the pairing is
/// `arenaspor2.fr` — from a group the viewer has hidden. The guide **cannot**
/// answer the question; a broadcast schedule can.
///
/// **What this file is and is not.** Here lives the rule: how a broadcast slot
/// belongs to a fixture and how its channel name meets the viewer's channel
/// list. Where the slots come from is in `PlaylistKit` — one source per
/// country, behind the same interface.
public enum SportBroadcastPlan {

    /// A broadcast, as the source reports it.
    public struct BroadcastSlot: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case match = "spiel"
            case home = "heim"
            case away = "gast"
            case kickoff = "anstoss"
            case end = "ende"
            case channels = "sender"
            case sportKind = "sportart"
            case competition = "wettbewerb"
            case land
        }

        /// The pairing, as the source writes it ("Tarlaspor - Tepelispor").
        public let match: String
        /// The home team, when the source names it separately.
        public let home: String?
        /// The away team, when the source names it separately.
        public let away: String?
        /// The kick-off according to the source.
        public let kickoff: Date
        /// The end of the broadcast according to the source.
        ///
        /// **It names it, and that is more than the guide can.** In the provider's
        /// guide "Mill Utd - Ashwick" ran from 18:30 to 07:45 — thirteen hours, and the
        /// row stayed as "live now" the whole evening (device finding 2026-08-29, 21:00).
        /// For the same kind of row the source says three hours.
        public let end: Date?
        /// The channels it runs on — the source names one or several.
        public let channels: [String]
        /// The sport, as the source names it ("Futbol", "Voleybol").
        ///
        /// **It says so, and that spares the guessing.** The first version read only
        /// the page's `schema.org` data; that names no sport, and the row fell back
        /// to football. On the TV, "Marovia – Talessa" (volleyball) therefore showed
        /// up under football.
        public let sportKind: String?
        /// The competition, as the source names it ("Pazaryol 1. Lig").
        public let competition: String?
        /// The country the source speaks for — as the abbreviation used in the
        /// programme IDs (`tr`).
        ///
        /// **Without it the join misses, and exactly where it hurts:** the provider
        /// carries `arenaspor1.tr` and `arenaspor1.fr`. Via the stem of the ID both
        /// are `arenaspor1`, and a Turkish source thereby covered a French channel.
        /// It occurred while building and was caught by the test.
        public let land: String?

        public init(
            match: String, home: String?, away: String?, kickoff: Date, channels: [String],
            end: Date? = nil, sportKind: String? = nil, competition: String? = nil,
            land: String? = nil
        ) {
            self.match = match
            self.home = home
            self.away = away
            self.kickoff = kickoff
            self.channels = channels
            self.end = end
            self.sportKind = sportKind
            self.competition = competition
            self.land = land
        }
    }

    /// How far apart the kick-off according to the fixture source and the
    /// kick-off according to the broadcast schedule may be.
    ///
    /// A quarter of an hour, in both directions. Both sources mean the same
    /// kick-off and should not contradict each other; the span absorbs rounded
    /// values ("19:00" against "19:05"), not a different broadcast. Any wider and
    /// it would start guessing: on a match day several matches of the same league
    /// kick off close together, and telling exactly those apart is the whole
    /// purpose of this source.
    public static let kickoffSpan: TimeInterval = 15 * 60

    /// How short a channel name may be to be searched for at all.
    ///
    /// Four characters. "TV" or "S" as a search word would hit every second
    /// channel in the list; a hit that separates nothing is worse than none.
    public static let minimumNameLength = 4

    /// The broadcast slot for a fixture — or none.
    ///
    /// **The search goes by the teams, not by the name of the match.** The source
    /// writes "Tarlaspor - Tepelispor", the fixture source "Tarlaspor" and
    /// "Tepelispor" — and sometimes a prefix stands in front ("T.Tarlaspor"),
    /// sometimes a legal form behind. The core formation that the matching with
    /// the guide uses anyway already answers exactly this question.
    public static func broadcastSlot(
        forItem fixture: SportFixture, in slots: [BroadcastSlot]
    ) -> BroadcastSlot? {
        slots.first { slot in
            guard abs(slot.kickoff.timeIntervalSince(fixture.start)) <= kickoffSpan,
                !slot.channels.isEmpty
            else { return false }
            return SportMatch.sharesBothTeams(fixture, with: slot.searchText)
        }
    }

    /// The viewer's channels that belong to the channel names of a broadcast slot.
    ///
    /// **The join is the channel name — and exactly there this provider snags.**
    /// The source writes "Arena Spor 1"; the channel list writes
    /// `TR: A**** S*** 1 RAW`. The names of the Turkish channels are **masked**,
    /// apparently against automatic filters. A name comparison finds nothing
    /// there, and that was the first failure while building: Tarlaspor got its
    /// evidence from the guide instead of from the broadcast schedule.
    ///
    /// **The programme ID is not masked** — `arenaspor1.tr`. It carries the same
    /// name, just without spaces and with a country abbreviation. Comparison
    /// therefore goes two ways:
    ///
    /// 1. **The ID, without spaces and without country abbreviation, for
    ///    equality.** "Arena Spor 1" becomes `arenaspor1`, and so does the ID
    ///    `arenaspor1.tr`. Equality and not containment: otherwise
    ///    `arenaspor1` would also hit `arenaspor10`, and a contracted ID has no
    ///    word boundary.
    /// 2. **The display name with word boundaries**, for the channels whose name
    ///    is readable.
    ///
    /// If both are walled off — masked name *and* meaningless ID — the broadcast
    /// schedule finds nothing, and the matching goes on its old way. That is the
    /// honest outcome and not an error.
    ///
    /// - Returns: The channel keys (programme ID, otherwise own ID) — the same
    ///   ones under which ``SportEvent/epgIDs`` is kept.
    public static func key(
        forItem slot: BroadcastSlot, in channels: [SportChannel]
    ) -> [String] {
        let needle = slot.channels
            .map(SportKind.normalized)
            .filter { $0.count >= minimumNameLength }
        guard !needle.isEmpty else { return [] }
        let searchedCompact = Set(needle.map(compact))

        var found: [String] = []
        for candidate in channels {
            let name = SportKind.normalized(candidate.name)
            let viaIdentifier = candidate.epgID.map {
                searchedCompact.contains(stem(from: $0)) && fitsCountry($0, slot.land)
            }
            let hits =
                viaIdentifier == true
                || needle.contains { SportCompetition.carries($0, name) }
            guard hits else { continue }
            if !found.contains(candidate.key) { found.append(candidate.key) }
        }
        return found
    }

    /// Whether a programme ID belongs to the country the source speaks for.
    ///
    /// If the ID carries no country abbreviation, it does not decide the question
    /// — it then counts as matching, and the name comparison remains.
    static func fitsCountry(_ identifier: String, _ country: String?) -> Bool {
        guard let country, let point = identifier.lastIndex(of: ".") else { return true }
        let fileExtension = String(identifier[identifier.index(after: point)...]).lowercased()
        guard (2...3).contains(fileExtension.count), fileExtension.allSatisfy(\.isLetter) else { return true }
        return fileExtension == country.lowercased()
    }

    /// A string without everything that is neither a letter nor a digit.
    static func compact(_ text: String) -> String {
        SportKind.normalized(text).filter { $0.isLetter || $0.isNumber }
    }

    /// The programme ID without its country abbreviation: `arenaspor1.tr` →
    /// `arenaspor1`.
    ///
    /// Only the **last** dot, and only if two or three letters follow — otherwise
    /// it would cut `s.sport.2` apart in the middle.
    static func stem(from identifier: String) -> String {
        guard let point = identifier.lastIndex(of: ".") else { return compact(identifier) }
        let fileExtension = identifier[identifier.index(after: point)...]
        guard (2...3).contains(fileExtension.count), fileExtension.allSatisfy(\.isLetter) else {
            return compact(identifier)
        }
        return compact(String(identifier[..<point]))
    }
}

extension SportBroadcastPlan.BroadcastSlot {
    /// A fixed ID for this broadcast slot — pairing and kick-off.
    ///
    /// It must be the same across programme runs, because a row gets its ID from
    /// it and the view keeps focus by it.
    public var identifier: String {
        "\(SportKind.normalized(match))#\(Int(kickoff.timeIntervalSince1970))"
    }

    /// What the team cores are searched in.
    ///
    /// The name of the match, and when the source names the teams separately,
    /// those too: some rows write the pairing differently from their two team
    /// fields, and searching both costs nothing.
    public var searchTextPublic: String { searchText }

    var searchText: String {
        [match, home, away].compactMap { $0 }.joined(separator: " ")
    }
}
