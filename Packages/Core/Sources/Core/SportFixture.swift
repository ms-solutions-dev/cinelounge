import Foundation

/// Where a fixture comes from.
///
/// **Two sources with raw identifiers collide silently** (concept, section 3):
/// TheSportsDB numbers its events consecutively, ESPN does too, and both start
/// somewhere in the six-digit numbers. Without a prefix one source overwrites the
/// row of the other, and nobody sees it — the catalog stays complete, only the
/// content of a row changes. The identifier therefore carries the origin in its
/// name (`espn#7001006`), and the store additionally in a column of its own.
public enum SportFixtureProvider: String, Sendable, Codable, CaseIterable {
    /// ESPN's open scoreboard service — since the addendum of 2026-08-29. **the** source.
    case espn
    /// TheSportsDB — since then only the fallback.
    case tsdb

    /// The prefix in front of the source's raw identifier.
    public var prefix: String { rawValue + "#" }
}

/// A scheduled game from the online source — with a real kickoff time.
///
/// This is the ingredient the provider EPG lacks (concept
/// `design/schedule-sync.md`): when an event REALLY begins and what the
/// participants are canonically called. Where the fixtures come from is the
/// source's business (PlaylistKit) — here only what they deliver counts.
public struct SportFixture: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case source = "quelle"
        case path = "pfad"
        case kind
        case league
        case leagueShort = "ligaKurz"
        case home
        case away
        case start
        case homeVariantsList = "homeVarianten"
        case awayVariantsList = "awayVarianten"
    }

    public let id: String
    /// Welche Quelle diesen Termin geliefert hat.
    public let source: SportFixtureProvider
    /// The identifier of the competition in the one board (``SportCompetition/path``).
    ///
    /// **Why the identifier and not the name** (E6): the placeholder used to be
    /// searched by string similarity between the source's league name and the
    /// placeholder's name — "Turkish Super Lig" hit "super lig", "MLS" hit nothing.
    /// With the identifier it is a lookup, and a competition without a placeholder is
    /// caught in ``SportCompetitionTests`` instead of silently missing for years.
    public let path: String
    public let kind: SportKind
    /// What the source calls the competition — it appears later in the row.
    public let league: String
    /// The source's short form — "Bundesliga" for "German Bundesliga", "EFL
    /// Championship" for "English League Championship".
    ///
    /// **This is the word E7 searches for.** The long name occurs in no channel name
    /// and in no program title; the short form is exactly the spelling the provider
    /// uses. It stands here so that the channel board and the placeholder stage get
    /// their word list from the source and not from a hand-written list that ages
    /// with every provider change (addendum of 2026-08-29).
    public let leagueShort: String
    public let home: String
    public let away: String
    public let start: Date
    /// Further spellings of the home team, as the source delivers them.
    ///
    /// **The alias source that maintains itself** (E6): ESPN gives four forms per
    /// team — "1. FC Union Kesselburg" / "Union Kesselburg" / "FCU" / the place. The alias
    /// board in ``SportMatch/aliases`` stays alongside, because ESPN writes English:
    /// it delivers "Cologne", not "Köln", and exactly the local spelling is what the
    /// EPG needs. What the source brings along, however, nobody has to add by hand
    /// any more.
    public let homeVariantsList: [String]
    public let awayVariantsList: [String]

    public init(
        id: String, source: SportFixtureProvider = .espn, path: String = "",
        kind: SportKind, league: String, leagueShort: String = "", home: String, away: String,
        start: Date, homeVariantsList: [String] = [], awayVariantsList: [String] = []
    ) {
        self.id = id
        self.source = source
        self.path = path
        self.kind = kind
        self.league = league
        self.leagueShort = leagueShort.isEmpty ? league : leagueShort
        self.home = home
        self.away = away
        self.start = start
        self.homeVariantsList = homeVariantsList
        self.awayVariantsList = awayVariantsList
    }

    /// The competition from the one board, if the identifier knows it.
    public var competition: SportCompetition? { SportCompetition.using(path: path) }
}

/// The matching: scheduled games × program guide → confirmed events.
///
/// **The search direction is the core** (user draft 2026-08-16): the EPG is not
/// classified; instead, for each fixture the EPG is searched — in the window
/// around the kickoff, for the team cores. What matches is a live broadcast WITH
/// a channel; a recording cannot get in, because only fixtures of the day are
/// searched.
public enum SportMatch {

    /// How early before the kickoff a broadcast may begin (pre-reports).
    static let leadWindow: TimeInterval = 45 * 60
    /// How late after the kickoff it may still begin (channels round).
    static let lagWindow: TimeInterval = 15 * 60

    /// Known spellings that the normal form does not flatten.
    ///
    /// Kept small and growing: every entry stands for a real find ("B. Münih" on Arena
    /// against the source's "Bergland Munich").
    static let aliases: [String: [String]] = [
        "munich": ["munih", "munchen"],
        "cologne": ["koln"],
        "istanbul basaksehir": ["basaksehir"],
        "manchester united": ["bousjinflut.vegrit", "man utd", "manchester utd"],
        "manchester city": ["man.city", "man city"],
        "psg": ["paris saint germain", "paris sg"],
    ]

    /// Generic cores — words that never stand alone for a team.
    ///
    /// **The finding** (concept, E6): "Covewood City – Hollin City" yielded the cores
    /// [covewood, city] and [hollin, city]. Because ONE core per side suffices, this
    /// fixture sealed every title in which "City" occurred — the crime documentary
    /// included, and with `isVerified`, the seal that is supposed to say precisely
    /// that the row is watertight.
    ///
    /// **"club" is on the list too, and that is not a nicety.** Without it, after
    /// dropping "united" exactly [club] would remain of "United Club" — a core
    /// that fits every second title. **The price stands next to it:** for this one
    /// team nothing remains after the dropping, and the fallback then searches the
    /// whole phrase "united club". If the EPG says "United Bergtal", the fixture
    /// does not find its channel. A missed channel is the cheaper mistake than a
    /// wrong seal.
    static let genericCores: Set<String> = [
        "city", "united", "real", "athletic", "club", "fc", "sc",
    ]

    /// Builds the confirmed events from fixtures and program guide.
    ///
    /// **Four stages per fixture, strongest first** (as of E7):
    ///
    /// 1. **Both team cores in the program title.** The only proof. It seals
    ///    (`isVerified == true`) — and it is also the only one from which the live
    ///    board writes (``observations(fixtures:programmes:)``).
    /// 2. **Both team cores in the channel name.** League-pass channels carry the
    ///    pairing in the name and have no EPG at all. Seals as well.
    /// 3. **The competition placeholder in the title** — "LaLiga 26/27" without a
    ///    pairing. A reasoned expectation, no proof.
    /// 4. **The channel board** (E7) — for the silent cases: a channel without EPG,
    ///    or one that names nothing recognisable in the kickoff window. Likewise an
    ///    expectation, not proof.
    ///
    /// **The placeholder stage no longer requires the game in the window to be the
    /// only one of its league** (E6). It did, in order not to guess — but it fell
    /// silent exactly when the most is on: on a Bundesliga Saturday five games kick
    /// off together, and the safeguard took the channel away from all five. A
    /// placeholder now carries **all** games of its league in the window.
    ///
    /// **The seal has told the truth since E6.** Before, every result of this
    /// calculation carried `isVerified == true`, including the one guessed via the
    /// placeholder — and the "confirmed only" filter in the settings thereby showed
    /// rows for which nobody had proof. The seal is true only for the two strong
    /// stages.
    ///
    /// **One channel list instead of two** (E7): `channelNames` was a dead parameter —
    /// read nowhere in the body, but dragged along by every caller, which made the
    /// measurements look as if channel names played a part in it. It is gone;
    /// ``SportChannel`` now carries identifier, name and program identifier in one, and
    /// all stages read the same list.
    ///
    /// - Returns: One ``SportEvent`` per fixture that found at least one channel —
    ///   with the source's REAL kickoff time, not the broadcast time.
    public static func events(
        fixtures: [SportFixture],
        programmes: [Programme],
        channels: [SportChannel] = [],
        board: SportChannelBoard = .empty,
        broadcastPlan: [SportBroadcastPlan.BroadcastSlot] = []
    ) -> [SportEvent] {
        let directory = Directory(programmes)
        // **Normalise the channel names once, not per fixture** (E5). The name stage ran
        // over the same channel list for every fixture and, in doing so, folded every
        // name down to its comparison form again.
        let channelNames = channels.map { (key: $0.key, core: SportKind.normalized($0.name)) }
        // The board stage queries the same channel list per fixture; the keys therefore
        // stand here once and not anew per fixture.
        let channelKeys = channels.map(\.key)

        var result: [SportEvent] = []
        // Which broadcast slots already belong to a fixture — the remaining ones become
        // rows themselves below.
        var consumed: Set<String> = []
        for fixture in fixtures {
            let lower = fixture.start.addingTimeInterval(-leadWindow)
            let upper = fixture.start.addingTimeInterval(lagWindow)
            let (homeKeys, awayKeys) = cores(forItem: fixture)
            // Only the programmes of the kickoff window, fetched from the half-hour buckets
            // — instead of the whole program guide for every fixture.
            let slots = directory.slots(from: lower, until: upper)

            var epgIDs: [String] = []
            // Whether a STRONG proof is among them. Only that carries the seal.
            var taken = false
            // Where it came from — for diagnosis, and so that it can later be **measured**
            // how often the program guide contradicts the broadcast schedule, instead of
            // guessing.
            var origin: SportEvent.Evidence?

            // **Stage 0: the broadcast schedule** (user draft 2026-08-29). It is the only one
            // that answers the question directly — which game on which channel — and it does
            // so independently of the provider's program guide. Where it answers, it applies
            // **alone**: its channels replace everything else instead of joining it. That is
            // exactly the difference from the sixteen channels that hung on "Westfalia
            // Erzfeld – Elbhafener SV" on 2026-08-29, because on all Arena channels only "BL" was
            // written.
            if let slot = SportBroadcastPlan.broadcastSlot(forItem: fixture, in: broadcastPlan) {
                consumed.insert(slot.identifier)
                let found = SportBroadcastPlan.key(forItem: slot, in: channels)
                if !found.isEmpty {
                    result.append(
                        SportEvent(
                            id: "fixture#\(fixture.id)",
                            kind: fixture.kind,
                            competition: fixture.leagueShort,
                            title: "\(fixture.home) - \(fixture.away)",
                            start: fixture.start,
                            end: fixture.start.addingTimeInterval(2 * 3600),
                            epgIDs: found,
                            competitionPath: fixture.path.isEmpty ? nil : fixture.path,
                            isVerified: true,
                            evidence: .broadcastPlan))
                    continue
                }
                // The source knows the game, but none of its channels is in the viewer's list.
                // **Then processing continues as without it** — and from experience: the first
                // draft aborted here, and the measurement dropped from 34 to 20 rows, the Süper
                // Lig from one channel per row to zero. The source is meant to displace the
                // poorer proofs, not the row.
            }
            // Which channels in the window recognisably show something ELSE: a programme with
            // a pairing. They are not silent, and the board stage keeps away from them (see
            // below).
            var speaks: Set<String> = []
            for slot in slots {
                let broadcast = directory.broadcasts[slot]
                if SportPlan.pairing(in: broadcast.title) != nil {
                    speaks.insert(broadcast.channelID)
                }
                let haystack = directory.title[slot]
                guard matches(haystack, any: homeKeys), matches(haystack, any: awayKeys)
                else { continue }
                if !epgIDs.contains(broadcast.channelID) { epgIDs.append(broadcast.channelID) }
                taken = true
                origin = .magazine
            }

            // Stage 2: the channel name carries the pairing — "NBA 01: Sunhawks @ Pinecrests".
            // Such channels have no EPG at all.
            for candidate in channelNames {
                guard matches(candidate.core, any: homeKeys), matches(candidate.core, any: awayKeys)
                else { continue }
                taken = true
                origin = origin ?? .channelName
                if !epgIDs.contains(candidate.key) { epgIDs.append(candidate.key) }
            }

            // Stage 3: the placeholder. The lookup goes through the competition's identifier,
            // not through the similarity of its name — that is why it now also works for MLS,
            // EFL Cup and Euroleague, which silently missed before. **The source's
            // vocabulary counts too** (E7): ESPN calls the competition "EFL Championship",
            // and that is exactly how it stands in the program guide.
            if !taken, let competition = fixture.competition {
                for slot in slots {
                    let broadcast = directory.broadcasts[slot]
                    guard SportPlan.pairing(in: broadcast.title) == nil else { continue }
                    // **What E2 recognised as a magazine show is none as a placeholder either**
                    // (acceptance of E6): "CUGRINKLIT Ceidriot 26/27" names the competition and
                    // still carries no game. Until E7 the placeholder stage did not know the rerun
                    // and studio markers.
                    guard !SportPlan.isRerun(broadcast.title) else { continue }
                    guard competition.names(directory.title[slot], also: sourceWords(fixture))
                    else { continue }
                    if !epgIDs.contains(broadcast.channelID) {
                        epgIDs.append(broadcast.channelID)
                    }
                }
            }

            // Stage 4: the live board (E7). It speaks only for the **silent** channels —
            // those that show no recognisable other game in the kickoff window. A channel
            // that demonstrably broadcasts another game right now cannot also show this one;
            // and a channel that reports "BL" or nothing at all is exactly the case the
            // board was built for.
            //
            // **It stands next to the placeholder stage, not behind it.** Both are
            // expectations of the same quality, and whoever chained them would lose the
            // better channels to the poorer one's coincidence: on 2026-08-29 the placeholder
            // found for the Bundesliga "DE: ARENA NEWS HD" — a news channel that carries
            // "Fußball: Bundesliga" as a topic line — and would thereby have displaced the
            // ten Arena Bundesliga channels and Zenit 1. Both are suppressed only by a real
            // **proof**.
            if !taken, !fixture.path.isEmpty {
                for identifier in channelKeys where !speaks.contains(identifier) {
                    guard
                        board.competitions(forItem: identifier, now: fixture.start)
                            .contains(fixture.path)
                    else { continue }
                    if !epgIDs.contains(identifier) { epgIDs.append(identifier) }
                }
            }

            guard !epgIDs.isEmpty else { continue }

            result.append(
                SportEvent(
                    id: "fixture#\(fixture.id)",
                    kind: fixture.kind,
                    competition: fixture.leagueShort,
                    title: "\(fixture.home) - \(fixture.away)",
                    start: fixture.start,
                    end: fixture.start.addingTimeInterval(2 * 3600),
                    epgIDs: epgIDs,
                    competitionPath: fixture.path.isEmpty ? nil : fixture.path,
                    isVerified: taken,
                    evidence: origin
                ))
        }

        // **The broadcast schedule is also a source, not only a confirmation**
        // (on-device finding 2026-08-29, 21:00: the sports screen offers much, much more than
        // what we cover; games such as Kayalıdere against Rüzgarlı or Petrolköy against Gümüşova do not
        // appear in our list at all, although the channels are there).
        //
        // The finding was right, and the reason was a design error in the structure: a
        // row came into being only from a **fixture** of the fixture source, and that
        // knows twenty competitions. The Pazaryol 1. Lig is not among them, volleyball is
        // not either — and the program guide did not help out there: on `kanalkurdi.tr`
        // only "Futbol: Pazaryol 1. Lig" stood at kickoff, on `arenaspormax1.tr`
        // nothing at all.
        //
        // The broadcast schedule knows both: the pairing and the channel. That makes it a
        // complete row by itself — better proven than anything the program guide yields.
        // Measured on 2026-08-29: six games that nobody else would have found, among them
        // exactly the two that the viewer had missed.
        for slot in broadcastPlan where !consumed.contains(slot.identifier) {
            let found = SportBroadcastPlan.key(forItem: slot, in: channels)
            guard !found.isEmpty else { continue }
            result.append(
                SportEvent(
                    id: "sendeplan#\(slot.identifier)",
                    kind: sportKind(forItem: slot, to: found, in: directory, names: channelNames),
                    competition: slot.competition,
                    title: slot.match,
                    start: slot.kickoff,
                    // **The end comes from the source**, not from an assumption. Only when it is
                    // silent do two hours apply.
                    end: slot.end ?? slot.kickoff.addingTimeInterval(2 * 3600),
                    epgIDs: found,
                    competitionPath: nil,
                    isVerified: true,
                    evidence: .broadcastPlan))
        }
        return result
    }

    /// Which sport a row from the broadcast schedule carries.
    ///
    /// The questions are asked in this order:
    ///
    /// 1. **What the source says.** It names the sport ("Futbol", "Voleybol",
    ///    "Basketbol"), and this project's recognition has understood these words
    ///    since E2.
    /// 2. **What is running on the channel.** If "Futbol: Pazaryol 1. Lig" stands
    ///    there, the question is answered.
    /// 3. **What the channel is called.**
    /// 4. **Football.**
    ///
    /// **The first step was missing until 2026-08-29, 22:00**, because the first version
    /// read only the page's `schema.org` data — which names no sport. On the TV
    /// "Marovia – Talessa" (volleyball) therefore stood under football. The last step
    /// remains a guess and is presented as one: a wrong sport icon is the smaller
    /// error compared with a game that does not appear at all.
    private static func sportKind(
        forItem slot: SportBroadcastPlan.BroadcastSlot, to identifiers: [String],
        in directory: Directory, names: [(key: String, core: String)]
    ) -> SportKind {
        // **First, what the source itself says.** It names the sport ("Futbol",
        // "Voleybol", "Basketbol") — this project's recognition has long understood
        // these words, it was just never asked.
        if let word = slot.sportKind, let kind = SportKind.classify(title: word) {
            return kind
        }
        let window = directory.slots(
            from: slot.kickoff.addingTimeInterval(-leadWindow),
            until: slot.kickoff.addingTimeInterval(lagWindow))
        for location in window where identifiers.contains(directory.broadcasts[location].channelID) {
            if let kind = SportKind.classify(title: directory.broadcasts[location].title) {
                return kind
            }
        }
        for candidate in names where identifiers.contains(candidate.key) {
            if let kind = SportKind.channelSignal(candidate.core) { return kind }
        }
        return .football
    }

    /// The words with which the **source** names this competition.
    ///
    /// No second retrieval and no second normalisation: both are on the fixture since
    /// E6 stores it.
    static func sourceWords(_ fixture: SportFixture) -> [String] {
        [fixture.league, fixture.leagueShort].filter {
            $0.count >= SportChannelBoard.minimumWordLength
        }
    }

    /// **The observations for the live board** — and only for it.
    ///
    /// **Writing happens exclusively from the strongest proof:** both team cores stood
    /// in the EPG title of this channel. That is an observation about the past, not an
    /// assignment for the future.
    ///
    /// **Why hits via the placeholder, via the channel name or via the board itself
    /// must NEVER write here** — this is the one way this design can break silently,
    /// and that is why the reasoning stands in the source and not only in the concept:
    /// if the board wrote from its own assignments, it would confirm its own guess
    /// every week. Its hit count would rise, its `recent` would stay fresh, and
    /// **no row would ever die again**. The ageing that carries the whole design
    /// would thereby be switched off — it would never become visible, because from
    /// outside the board would look exactly like one that is right. For the same
    /// reason the channel-name stage does not write either: a name is a claim by the
    /// provider, not a broadcast slot.
    ///
    /// The time of an observation is the **kickoff of the fixture**, not the moment
    /// of the calculation. The board thereby counts match days and not matchings:
    /// whoever opens the area five times on a Saturday does not move it an inch.
    ///
    /// **Per channel and competition at most ONE proof comes back from a run** (the
    /// earliest), and that is more than the line above says — addendum of the E7
    /// acceptance (2026-08-29). The deduplication catches the Bundesliga Saturday on
    /// which five games prove the same channel. But it also throws away the second
    /// **match day** if it stands in the same program guide: if a channel carries the
    /// league on Fridays and Saturdays and the guide spans both days, still only the
    /// Friday counts. A channel therefore needs at least two matchings on different
    /// days to reach ``SportChannelBoard/minimumDays`` — not two match days. On the
    /// recording of 2026-08-29 that costs nothing (all ten proofs lie on the same
    /// calendar day anyway); on the device it slows down learning.
    public static func observations(
        fixtures: [SportFixture], programmes: [Programme],
        channels: [SportChannel] = [], broadcastPlan: [SportBroadcastPlan.BroadcastSlot] = []
    ) -> [(channels: String, path: String, when: Date)] {
        let directory = Directory(programmes)
        var found: [(channels: String, path: String, when: Date)] = []
        var seen: Set<String> = []
        for fixture in fixtures where !fixture.path.isEmpty {
            // **The broadcast schedule is the strongest proof there is** — and therefore it
            // writes here too (requirement 2026-08-29: we need a solution that works solely in
            // the app; whoever gets the application for IPTV may not run a home lab at all).
            //
            // That is the answer to the reach: the broadcast-schedule source delivers only
            // **today's** day, and nothing can be done about that — its day tabs are filled
            // only by a browser, and there is none on the TV. What is proven today can carry
            // tomorrow, though: "Arena Spor 1 showed the Süper Lig" is a fact about the
            // channel, not about the game. After two such days tomorrow's fixture finds its
            // channel from the app's own observation — without network, without a third-party
            // service, in the app.
            //
            // **No feedback loop**, and the difference matters: the board must not confirm
            // its own guesses. The broadcast schedule is not a guess of ours but outside
            // information — the same quality as both team names in the title.
            if let slot = SportBroadcastPlan.broadcastSlot(forItem: fixture, in: broadcastPlan) {
                for identifier in SportBroadcastPlan.key(forItem: slot, in: channels) {
                    let entryKey = identifier + "#" + fixture.path
                    guard seen.insert(entryKey).inserted else { continue }
                    found.append((channels: identifier, path: fixture.path, when: fixture.start))
                }
            }

            let (homeKeys, awayKeys) = cores(forItem: fixture)
            let slots = directory.slots(
                from: fixture.start.addingTimeInterval(-leadWindow),
                until: fixture.start.addingTimeInterval(lagWindow))
            for slot in slots {
                let haystack = directory.title[slot]
                guard matches(haystack, any: homeKeys), matches(haystack, any: awayKeys)
                else { continue }
                let identifier = directory.broadcasts[slot].channelID
                let entryKey = identifier + "#" + fixture.path
                guard !seen.contains(entryKey) else { continue }
                seen.insert(entryKey)
                found.append((channels: identifier, path: fixture.path, when: fixture.start))
            }
        }
        return found
    }

    /// The program guide's **word index**: built once, used by every fixture.
    ///
    /// **The finding** (concept, stage 5): the matching searches the EPG per fixture —
    /// and read through the whole program guide for it, anew for every fixture, folding
    /// every title down to its comparison form again each time. A fixture was thus as
    /// many comparisons as the program guide has rows. Of that only a single hour is
    /// needed: the window from 45 minutes before to 15 minutes after the kickoff.
    ///
    /// **Two grips, both without a rule change.** The normalised title stands once
    /// instead of once per fixture. And the programmes lie in **half-hour buckets**:
    /// whoever searches the kickoff window reaches into three buckets instead of the
    /// whole program guide.
    ///
    /// Measured with 600 fixtures (``ScheduleTimingTests``): on the recording of
    /// 2026-08-29. **0.216 s → 0.049 s**, extrapolated to device size (38,718 programmes)
    /// **1.703 s → 0.419 s** — each time with an **identical hit count**. That the hit
    /// count MUST stay the same and did not merely happen to, ``SportMatchTests``
    /// records: the buckets must deliver exactly the slots that a pass over the whole
    /// list delivers — order included, because it later appears as the channel bar in
    /// the row.
    ///
    /// **The concept's target value (5.8 s for 600 fixtures on an M3) cannot be
    /// reproduced here** — measured, it is 1.703 s before. The direction and the
    /// factor agree, the magnitude does not; why that is cannot be settled from here,
    /// because the concept measured on the uncut dump with 30,157 programmes and
    /// 7,735 channels and this file is not in the test stock.
    ///
    /// **The order stays that of the input.** It stands in ``epgIDs`` and thereby in
    /// the row's channel bar; a bucket delivers its slots ordered by time, but the
    /// buckets among each other not necessarily. That is why the slots are re-sorted
    /// before searching — three buckets are a handful of numbers, that costs nothing.
    struct Directory {
        let broadcasts: [Programme]
        /// The normalised title per programme, at the same position.
        let title: [String]
        /// Bucket number → positions of the programmes that begin in it.
        let buckets: [Int: [Int]]

        /// Half an hour. Narrower would mean more buckets for the same window, wider more
        /// wrong grabs per bucket; the kickoff window is one hour, so this width reaches
        /// into three buckets.
        static let bucketWidth: TimeInterval = 30 * 60

        init(_ broadcasts: [Programme]) {
            self.broadcasts = broadcasts
            title = broadcasts.map { SportKind.normalized($0.title) }
            var built: [Int: [Int]] = [:]
            for (slot, broadcast) in broadcasts.enumerated() {
                built[Self.bucket(broadcast.start), default: []].append(slot)
            }
            buckets = built
        }

        static func bucket(_ timestamp: Date) -> Int {
            Int((timestamp.timeIntervalSince1970 / bucketWidth).rounded(.down))
        }

        /// The positions of the programmes that begin between `from` and `until` — in the
        /// order of the input, both bounds inclusive.
        func slots(from: Date, until: Date) -> [Int] {
            let first = Self.bucket(from)
            let last = Self.bucket(until)
            guard first <= last else { return [] }
            var found: [Int] = []
            for number in first...last {
                guard let bucket = buckets[number] else { continue }
                for slot in bucket
                where broadcasts[slot].start >= from && broadcasts[slot].start <= until {
                    found.append(slot)
                }
            }
            return found.sorted()
        }
    }

    /// Confirmed and guessed events merged — proof beats guess.
    ///
    /// Two displacements:
    /// 1. What the source confirms replaces the heuristic find of the same game.
    /// 2. **The wrong-time rule** (stage 2, against "not live"): if the source knows
    ///    the game but at a DIFFERENT time, today's broadcast is a recording or
    ///    preview — it is dropped. Both teams must be in the title, a single name
    ///    alone would be too sharp.
    /// What only the heuristic knows (minor sports, a league missing in the source)
    /// stays as a supplement — the area stays full even without a network.
    public static func combined(
        verified: [SportEvent],
        heuristic: [SportEvent],
        fixtures: [SportFixture] = []
    ) -> [SportEvent] {
        let remaining = heuristic.filter { guessed in
            if verified.contains(where: { known in
                known.kind == guessed.kind
                    && abs(known.start.timeIntervalSince(guessed.start)) <= leadWindow + lagWindow
                    && sharesTeam(known, with: guessed.title)
            }) {
                return false
            }

            if fixtures.contains(where: { fixture in
                fixture.kind == guessed.kind
                    && abs(fixture.start.timeIntervalSince(guessed.start)) > leadWindow + lagWindow
                    && sharesBothTeams(fixture, with: guessed.title)
            }) {
                return false
            }

            return true
        }
        return verified + remaining
    }

    /// Whether a title carries BOTH teams of a fixture.
    ///
    /// Public since ``ScheduleFixturesTests`` uses it to cross-check whether the seal
    /// `isVerified` tells the truth: a sealed row must have a programme whose title
    /// carries both cores, an expected one must not have any. Without this
    /// cross-check the seal would again be only a claim about itself.
    public static func sharesBothTeams(_ fixture: SportFixture, with title: String) -> Bool {
        let haystack = SportKind.normalized(title)
        let (home, away) = cores(forItem: fixture)
        return matches(haystack, any: home) && matches(haystack, any: away)
    }

    /// Whether a confirmed event shares a team with a title.
    static func sharesTeam(_ event: SportEvent, with title: String) -> Bool {
        let haystack = SportKind.normalized(title)
        guard let pairing = SportPlan.pairing(in: event.title) else { return false }
        let (home, away) = corePair(home: pairing.home, away: pairing.away)
        return matches(haystack, any: home) || matches(haystack, any: away)
    }

    /// The search cores of both sides of a fixture.
    static func cores(forItem fixture: SportFixture) -> (home: [String], away: [String]) {
        corePair(
            home: fixture.home, away: fixture.away,
            homeVariants: fixture.homeVariantsList, awayVariants: fixture.awayVariantsList)
    }

    /// The search cores of a pairing — **formed for both sides together**.
    ///
    /// **Why together and not each on its own** (E6): a core that both sides carry
    /// cannot separate the sides. "Covewood City – Hollin City", formed individually,
    /// demanded of each title only that "City" appears somewhere — once for the home
    /// side, once for the away side, and both times satisfied by the same word. What
    /// both share is therefore dropped from both.
    ///
    /// If a side is left with nothing afterwards, it searches its whole phrase. That
    /// is stricter than a core and finds less — but it seals nothing false, and here
    /// that is the order of evils.
    static func corePair(
        home: String, away: String,
        homeVariants: [String] = [], awayVariants: [String] = []
    ) -> (home: [String], away: [String]) {
        let a = cores(home, variants: homeVariants)
        let b = cores(away, variants: awayVariants)
        let shared = Set(a).intersection(b)
        guard !shared.isEmpty else { return (a, b) }
        return (
            withoutShared(a, shared, wholePhrase: home),
            withoutShared(b, shared, wholePhrase: away)
        )
    }

    private static func withoutShared(
        _ cores: [String], _ shared: Set<String>, wholePhrase: String
    ) -> [String] {
        let remaining = cores.filter { !shared.contains($0) }
        return remaining.isEmpty ? [SportKind.normalized(wholePhrase)] : remaining
    }

    /// The search cores of a club name: every significant word plus aliases plus the
    /// spellings the source delivers.
    ///
    /// "İnciköy Başakvadi" → [incikoy, basakvadi, …] — the EPG writes
    /// "Başakvadi F.K", and ONE core suffices; short filler words ("fc", "fk",
    /// "sk") do not count as a core, and generic ones do not either
    /// (``genericCores``).
    ///
    /// **The source's spellings stand in as a whole phrase**, not split into words:
    /// "Union Kesselburg" split would give "kesselburg", and that would also fit Viktoria. As a
    /// phrase the variant is stricter than any core and therefore cannot break
    /// anything. Measured, it brings little at ESPN — the source writes English
    /// ("Cologne"), the EPG German ("Köln"); the alias board stays for exactly that.
    static func cores(_ team: String, variants variantList: [String] = []) -> [String] {
        let normalized = SportKind.normalized(team)
        var found = normalized.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !genericCores.contains($0) }
        for (canonical, variants) in aliases where normalized.contains(canonical) {
            found.append(contentsOf: variants)
        }
        for variant in variantList {
            let phrase = SportKind.normalized(variant)
            guard phrase.count >= 4, phrase != normalized, !found.contains(phrase) else {
                continue
            }
            found.append(phrase)
        }
        if found.isEmpty { found = [normalized] }
        return found
    }

    private static func matches(_ haystack: String, any keys: [String]) -> Bool {
        keys.contains { SportKind.boundedRange(of: $0, in: haystack) != nil }
    }
}
