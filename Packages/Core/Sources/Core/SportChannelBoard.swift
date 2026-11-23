import Foundation

/// Where the information "this channel carries this competition" comes from.
///
/// **The order is the rule** (addendum 2 of 2026-08-29, a product objection): if
/// you commit today that the Bundesliga runs on these channels, that need not
/// be a fact in three years — rights can be reassigned.
///
/// The answer to that is not to maintain rights but to collect observations.
/// Who broadcasts what is already in the viewer's guide, and that renews
/// itself every few hours. An **observation** therefore beats every claim —
/// even when it contradicts it: then the world has changed and the
/// observation has not erred.
///
/// The cases are in the order of their rank: what stands further down wins.
/// It is decided in
/// ``SportChannelBoard/competitions(forItem:now:)``.
public enum ChannelOrigin: String, Sendable, Codable, CaseIterable {
    /// A hard-coded starting value. **A crutch, not a method.**
    case seedValue = "startwert"
    /// The channel name carries the competition name that the fixture source names
    /// today — "DE: ARENA BUNDESLIGA 1 HD" hits because ESPN says "Bundesliga".
    case name
    /// Both team cores were in the title of a programme of this channel.
    /// The only evidence that is written from.
    case observed = "beobachtet"
}

/// A row of the living board: this channel has carried this competition, this
/// often, first then, last then.
public struct ChannelCompetition: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case channels = "sender"
        case path = "pfad"
        case origin = "herkunft"
        case match = "treffer"
        case firstSeen = "zuerst"
        case recent = "zuletzt"
    }

    /// The channel key — the programme ID if it has one, otherwise its own ID
    /// (``SportChannel/key``).
    public let channels: String
    /// The competition ID (``SportCompetition/path``).
    public let path: String
    public let origin: ChannelOrigin
    /// How many **days** it has been carried — not how many programmes.
    /// Reasoning at ``SportChannelBoard/dayGap``.
    public let match: Int
    public let firstSeen: Date
    public let recent: Date

    public init(
        channels: String, path: String, origin: ChannelOrigin = .observed,
        match: Int = 1, firstSeen: Date, recent: Date
    ) {
        self.channels = channels
        self.path = path
        self.origin = origin
        self.match = match
        self.firstSeen = firstSeen
        self.recent = recent
    }
}

/// A channel, as the matching needs it.
///
/// **One list instead of two.** Until E7, ``SportMatch`` got the channel names
/// twice: once as `channelNames` (never read — a dead parameter that the
/// acceptance of 2026-08-29 named) and once as `channels`, and only those WITHOUT
/// a programme ID. That made two half-maintained places for the same
/// question. Here the channel list stands once, and every stage that needs a
/// channel name reads it.
public struct SportChannel: Sendable, Equatable, Hashable {
    /// The channel ID in the channel list.
    public let id: String
    public let name: String
    /// The programme ID, if the channel has one.
    public let epgID: String?

    public init(id: String, name: String, epgID: String? = nil) {
        self.id = id
        self.name = name
        self.epgID = epgID
    }

    /// Under which key this channel stands in the board — and under which it ends
    /// up in ``SportEvent/epgIDs``.
    ///
    /// The programme ID, if there is one: several versions of the same channel
    /// (HD/FHD/UHD) share it, and the view resolves back to the channel list via
    /// it. Without a programme ID the own ID remains — ``LiveLibrary/channels(forEPG:)``
    /// finds that too.
    public var key: String {
        if let epgID, !epgID.isEmpty { return epgID }
        return id
    }
}

/// The **living board**: which channel carries which competition.
///
/// **Why no hand-kept board** (addenda 1 and 2 of 2026-08-29, both product
/// decisions). The concept provided a hand-maintained channel→competition
/// board for a handful of league and pay channels. The question "if I switch
/// IPTV provider, would content still match cleanly?" toppled it. A hand-kept
/// board ages with every provider change, and invisibly: nothing breaks, it
/// just quietly gets emptier.
///
/// **Three origins, one rank** (``ChannelOrigin``):
///
/// 1. **Observed.** If both team cores of a fixture were in the EPG title of
///    this channel, it has carried this competition. That is a fact about the
///    past, not an entry about the future. Only this is written to the store.
/// 2. **From the name.** If a channel name carries a competition name that the
///    fixture source names today, it belongs to that competition. "DE: ARENA
///    BUNDESLIGA 1 HD" hits because ESPN says "Bundesliga" — not because
///    someone entered it. If the provider changes, the channel names change;
///    the vocabulary keeps coming from the same source. If a league is added,
///    its name comes with it. This origin is **not** stored: it arises anew on
///    every computation from the channel list and the fixtures in the
///    downloads, and so it cannot go stale.
/// 3. **Starting value.** The crutch for the cold start — see ``seedValues``.
///
/// **It ages, and that is the point.** An observation older than
/// ``memory`` assigns nothing any more and is deleted at the next
/// matching. If a right moves to another channel, the board heals itself
/// within a few weeks — without maintenance, without a new version of the
/// app. That is the automatic upkeep the product requirement asked for, only
/// with the guide as the source instead of a rights database, which does not
/// exist.
public struct SportChannelBoard: Sendable, Equatable {

    /// How many **days** assign a channel to a competition.
    ///
    /// **Two, and the number is reasoned.** A single day can be a guest
    /// appearance: a cup match on a channel that otherwise does not have the
    /// league, or a title that happens to carry both team cores. Two distinct
    /// days are a pattern — and that is the question at hand, because a broadcast
    /// right applies to a season and not to an afternoon.
    ///
    /// Measured on the recording of 2026-08-29. (``ChannelBoardMeasurementTests``): one run
    /// writes 10 rows on 9 channels, **each with exactly one day**. With a
    /// threshold of 1 the board would therefore assign after the very first
    /// matching, without ever having seen a pattern — a cup match on a channel
    /// foreign to the league would at once be a rights claim. Only the second
    /// match day separates the channel that has the league from the one that once
    /// showed a match.
    public static let minimumDays = 2

    /// How far back an observation may lie.
    ///
    /// **Sixty days, and this number is not round arbitrariness either.** It must
    /// be **longer** than the longest break a competition takes without anything
    /// changing in the rights — the Bundesliga winter break is around four weeks,
    /// an international break two. And it must be **shorter** than the interval
    /// at which rights are reassigned: that happens at the season change, and the
    /// summer break lasts around three months. Sixty days lie between the two.
    /// An assignment thus survives every break within the season and **none**
    /// across the season boundary — exactly where rights change, the board
    /// learns anew.
    public static let memory: TimeInterval = 60 * 24 * 3600

    /// From which distance two pieces of evidence count as two days.
    ///
    /// **Otherwise the threshold would be meaningless.** On a Bundesliga Saturday
    /// five matches kick off together; if every piece of evidence counted
    /// individually, a channel would have five hits after a single afternoon and
    /// the threshold of two days would be met in the same hour in which the board
    /// sees the channel for the first time. **Days** are therefore counted: a
    /// piece of evidence raises the hit count only if it lies at least twenty
    /// hours from the last observation. Twenty and not twenty-four, because a
    /// Sunday match at 15:30 may follow a Saturday match at 20:30.
    public static let dayGap: TimeInterval = 20 * 3600

    /// The stored observations, by channel key.
    private let observed: [String: [ChannelCompetition]]
    /// The assignments from the channel name — rebuilt on every computation.
    private let fromNames: [String: Set<String>]

    public init(observations: [ChannelCompetition] = [], fromNames: [String: Set<String>] = [:]) {
        self.observed = Dictionary(grouping: observations, by: \.channels)
        self.fromNames = fromNames
    }

    public static let empty = SportChannelBoard()

    /// Only the assignments from the channel name — for report and measurement.
    public var namesOnly: [String: Set<String>] { fromNames }

    /// Which competitions this channel carries — the strongest origin wins.
    ///
    /// - Parameter jetzt: The point in time against which ageing is measured. **Core
    ///   stays clock-free**: the matching passes in the kick-off of the fixture it
    ///   is currently about. The question thus becomes "did this channel carry the
    ///   competition in the weeks BEFORE this kick-off" — and that can be
    ///   answered without a calendar.
    public func competitions(forItem channels: String, now: Date) -> Set<String> {
        let fresh = (observed[channels] ?? []).filter {
            $0.match >= Self.minimumDays
                && now.timeIntervalSince($0.recent) <= Self.memory
        }
        // **Observations beat everything else, even when they contradict it.** If
        // there are viable observations for this channel, ONLY they count — not their
        // union with the name or the starting value. Otherwise an expired right would
        // outlive its own observation, and the board could not heal itself.
        if !fresh.isEmpty { return Set(fresh.map(\.path)) }
        if let fromName = fromNames[channels], !fromName.isEmpty { return fromName }
        return Self.seedValues[channels] ?? []
    }

    /// Where the information for this channel comes from — for report and check.
    public func origin(forItem channels: String, now: Date) -> ChannelOrigin? {
        let fresh = (observed[channels] ?? []).filter {
            $0.match >= Self.minimumDays
                && now.timeIntervalSince($0.recent) <= Self.memory
        }
        if !fresh.isEmpty { return .observed }
        if !(fromNames[channels] ?? []).isEmpty { return .name }
        if !(Self.seedValues[channels] ?? []).isEmpty { return .seedValue }
        return nil
    }

    // MARK: - Das Vokabular der Quelle

    /// The word list of the competitions, **from the fixtures in the downloads**.
    ///
    /// No second fetch and no second normalisation: what is here, E6 fetched
    /// anyway. ESPN names every competition three times — "German Bundesliga" /
    /// "Bundesliga" / `ger.1` — and the short form is the one that occurs in
    /// channel names and programme titles.
    ///
    /// The ID (`ger.1`) stays out: it occurs in no channel name and as "ger" or
    /// "1" would only hit nonsense.
    public static func vocabulary(_ fixtures: [SportFixture]) -> [String: Set<String>] {
        var built: [String: Set<String>] = [:]
        for fixture in fixtures {
            for word in [fixture.league, fixture.leagueShort]
            where word.count >= Self.minimumWordLength {
                built[fixture.path, default: []].insert(word)
            }
        }
        return built
    }

    /// How short a competition word may be to count in a channel name.
    ///
    /// **Five, because of "EURO".** For ESPN the Euroleague has the short form
    /// "EURO", and that is inside every "EUROARENA". The word-boundary rule
    /// (``SportCompetition/carries(_:_:)``) does catch exactly this case — in
    /// "euroarena" a letter follows "euro" — but it only catches it as long as
    /// the provider writes "EUROARENA" as one word. "EURO ARENA 1" would be a
    /// hit, and a four-letter word is no evidence for a competition.
    static let minimumWordLength = 5

    // MARK: - Schreiben und Altern

    /// Introduces new evidence into the catalog.
    ///
    /// **The hit count counts days, not programmes** — reasoning at
    /// ``dayGap``. Evidence lying less than a day from the last observation
    /// only moves `recent`; evidence lying further away raises the count.
    ///
    /// Pure computation, so that the rule is testable and does not live in SQL.
    public static func merged(
        catalog: [ChannelCompetition], fresh: [(channels: String, path: String, when: Date)]
    ) -> [ChannelCompetition] {
        var byKey: [String: ChannelCompetition] = [:]
        var order: [String] = []
        for row in catalog {
            let key = row.channels + "#" + row.path
            if byKey[key] == nil { order.append(key) }
            byKey[key] = row
        }
        for evidence in fresh.sorted(by: { $0.when < $1.when }) {
            let key = evidence.channels + "#" + evidence.path
            guard let old = byKey[key] else {
                order.append(key)
                byKey[key] = ChannelCompetition(
                    channels: evidence.channels, path: evidence.path, match: 1,
                    firstSeen: evidence.when, recent: evidence.when)
                continue
            }
            let farEnough =
                evidence.when.timeIntervalSince(old.recent) >= dayGap
                || old.firstSeen.timeIntervalSince(evidence.when) >= dayGap
            byKey[key] = ChannelCompetition(
                channels: old.channels, path: old.path, origin: old.origin,
                match: old.match + (farEnough ? 1 : 0),
                firstSeen: min(old.firstSeen, evidence.when),
                recent: max(old.recent, evidence.when))
        }
        return order.compactMap { byKey[$0] }
    }

    /// Throws out what has grown too old.
    ///
    /// This is the ageing that answers the product objection: a right that has
    /// moved disappears here by itself — nobody has to learn of it, and no new
    /// version of the app is needed for it.
    public static func aged(_ catalog: [ChannelCompetition], now: Date) -> [ChannelCompetition] {
        catalog.filter { now.timeIntervalSince($0.recent) <= memory }
    }

    // MARK: - Der kalte Start

    /// **A crutch, not a method.**
    ///
    /// On the first day there are no observations, and an empty sport section
    /// would be the worst first encounter. So a small set of starting values —
    /// with the **lowest** rank: as soon as viable observations exist for a
    /// channel, they win, even when they contradict the starting value.
    ///
    /// **What may be here and what not.** Only channels that unambiguously belong
    /// to one league. "MIX" and "INFO" channels stay out, and so does every
    /// channel that carries its competition in its name anyway — the name stage
    /// finds it, even after the provider changes.
    ///
    /// **Counted before entering:** in the recording of 2026-08-29, 136 channels carry
    /// a programme ID. Of those, 15 carry a competition name of the source in
    /// their name and need no starting value. That leaves exactly **two** that
    /// unambiguously belong to one league and do not say so: `zenit1.de` and
    /// `zenit2.de`. Both name only placeholders in their whole guide ("Bundesliga
    /// 26/27", "LaLiga 26/27"), and both are known by name from the concept. The
    /// 230 sports channels **without** a programme ID that the concept mentions
    /// cannot be counted from here: they are in the device's channel list, not in
    /// the guide, and the channel list is not in the test downloads.
    ///
    /// The key is ``SportChannel/key`` — the programme ID.
    static let seedValues: [String: Set<String>] = [
        "zenit1.de": ["soccer/ger.1"],
        "zenit2.de": ["soccer/esp.1"],
    ]
}
