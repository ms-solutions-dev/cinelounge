import Foundation

/// A live broadcast in the schedule — one event, any number of channels.
/// An event in the schedule.
///
/// **`Codable`, so the computation survives a restart** (device finding
/// 2026-08-29: the app reloads everything every time it is opened, although the
/// programme guide does not change during the day). The result cache in
/// ``ScheduleCalculator`` lived only in memory and was gone when the app quit —
/// every start recomputed the whole guide from scratch, measured on the device
/// at 3.4 s.
public struct SportEvent: Identifiable, Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case competition
        case title
        case start
        case end
        case epgIDs
        case competitionPath = "wettbewerbPfad"
        case isVerified
        case evidence = "beleg"
    }

    public let id: String
    public let kind: SportKind
    /// The competition, when the title names it — "Liga Portugal", "UFC 320".
    public let competition: String?
    /// The event itself: the pairing or the event name.
    public let title: String
    public let start: Date
    public let end: Date
    /// The programme IDs of the channels that show it — the view resolves them
    /// to the channel list (several versions share one ID).
    public private(set) var epgIDs: [String]
    /// The competition ID (``SportCompetition/path``), when a fixture from the
    /// source stands behind it.
    ///
    /// **What it is needed for** (E7): it answers "is this the same competition",
    /// and without it the row "Bundesliga · 15:30 · 5 matches" cannot be built —
    /// ``SportConference`` groups by it. The display name is no good for that: it
    /// comes from the source and, for the heuristic rows, is the competition part
    /// of the programme title, so sometimes "Bundesliga", sometimes "Football",
    /// sometimes nothing at all.
    ///
    /// Heuristic rows carry `nil` and are not grouped. That is intentional: what
    /// only the EPG title claims is not a league membership.
    public var competitionPath: String?
    /// Whether an online source confirms the kick-off (``SportMatch``) — then the
    /// time is the real kick-off and not a broadcast time, and a rerun is ruled
    /// out.
    public var isVerified = false

    /// **Where the evidence came from.**
    ///
    /// Product requirement, 2026-08-29: an IPTV EPG cannot be trusted 100 % to be
    /// correct; what is known is that ESPN and Spor Ekranı are correct. That is a
    /// statement about the **quality** of two kinds of evidence, and it can be
    /// measured instead of believed: the origin therefore sits on the row, and the
    /// diagnostics count both separately. If after a few days the guide often
    /// contradicts the broadcast schedule, it is dropped as evidence — with a
    /// number in hand.
    ///
    /// `nil` means: no evidence, so an expectation (placeholder, channel board) or
    /// a heuristic row.
    public enum Evidence: String, Sendable, Codable {
        /// A broadcast-schedule source names the channel for exactly this match.
        case broadcastPlan = "sendeplan"
        /// The guide title carries both team names.
        case magazine = "zeitschrift"
        /// The channel name carries the pairing (League Pass channels).
        case channelName = "sendername"
    }

    public var evidence: Evidence?

    /// **Public since the schedule is stored on disk.** The synthesised
    /// initialiser is internal, so nobody outside `Core` could build an event —
    /// including no test of the store in `PlaylistKit` that is meant to prove a
    /// computed schedule survives a restart completely.
    public init(
        id: String, kind: SportKind, competition: String?, title: String, start: Date, end: Date,
        epgIDs: [String], competitionPath: String? = nil, isVerified: Bool = false,
        evidence: Evidence? = nil
    ) {
        self.id = id
        self.kind = kind
        self.competition = competition
        self.title = title
        self.start = start
        self.end = end
        self.epgIDs = epgIDs
        self.competitionPath = competitionPath
        self.isVerified = isVerified
        self.evidence = evidence
    }

    /// Whether the event is running at this point in time.
    public func isRunning(at date: Date) -> Bool {
        date >= start && date < end
    }

    /// Adds another broadcast of the same event.
    mutating func adopt(_ epgID: String) {
        if !epgIDs.contains(epgID) { epgIDs.append(epgID) }
    }
}

/// Builds the day list of live broadcasts from the programme guide.
///
/// **Three filters, one merge** — all pure computation, all tested:
///
/// 1. **Sport** via ``SportKind/classify(title:channelName:)`` — whatever none
///    matches is not a sports broadcast.
/// 2. **Events only:** a pairing ("Rio Lume-Serrano", "Kalberg – Serrat"), a
///    race ("Grand Prix …") or an explicit live mark. Magazines and studio
///    shows drop out, even when they run on sports channels.
/// 3. **No reruns** (user rule): "Tekrar", "Özet", "Highlights" and relatives
///    are dropped — the provider's EPG marks them reliably.
///
/// Merging goes by sport, normalised event and time window: the same match on
/// four channels is ONE entry with four IDs.
/// **Honest limit:** channels in different languages name the same pairing
/// differently ("Bergland München" / "B. Münih") — such broadcasts stay two
/// entries. Better true twice than wrongly merged once.
public enum SportPlan {

    /// What identifies a rerun.
    ///
    /// "goller"/"10 gol" (2026-08-16): since the league channels deliver bare
    /// pairings, "Süper Lig Haftanın Golleri" and "1 Yıldız 10 Gol - Van Kerstie"
    /// would otherwise also get through as events — goal shows, not broadcasts.
    /// **Studio marks added** (2026-08-29): since the tournament words count as the
    /// third admission ticket, the shows *around* the match get through as well —
    /// they carry the same words. Measured, "Avant-match Ligue 2", "Après-match",
    /// "Pitchside – Supercup 26/27", "Nougrir Lefriaka" and "Die Telefunk
    /// Highlight-Show" then appeared as rows of their own in the schedule. Those
    /// are previews and studio shows, and by design the section must not show
    /// exactly those.
    ///
    /// "highlight" instead of "highlights": the singular covers both and also
    /// catches "Highlight-Show". "alle tore" catches the goal shows of the
    /// Bundesliga channels ("Alle Spiele, alle Tore"), which would otherwise get
    /// in through the competition word.
    static let rerunMarkers = [
        "tekrar", "ozet", "wdh.", "wiederholung", "replay", "rediffusion",
        "highlight", "klasik", "arsiv", "powtorka", "resumo", "relive",
        "best of", "en iyi", "goller", "10 gol", "alle tore",
        "avant-match", "apres-match", "pitchside", "backstage",
    ]

    /// What identifies an explicit live broadcast.
    ///
    /// **Only at word boundaries** (2026-08-29): "live" is inside "Livernholm", and so
    /// the mark knighted every magazine, every review and every studio show whose
    /// title mentioned a club from Livernholm — with no pairing, no kick-off. The
    /// same goes for "canli" in Turkish proper names. The check therefore goes
    /// through ``SportKind/boundedRange(of:in:)``, the same word-boundary rule
    /// that already protects the sport patterns from the substring plague.
    static let liveMarkers = ["canli", "live", "direto", "en vivo", "en directo", "na zywo"]

    /// What identifies a tournament or stage format — the **third, equal-ranking
    /// admission ticket** next to pairing and live mark.
    ///
    /// **Why it is needed** (2026-08-29): the event check demanded a pairing, a live
    /// mark or "Grand Prix". A tournament has no opponent, a tour has no two
    /// sides — and so exactly the formats the section exists for dropped out:
    /// Ronda 22 broadcasts → 0, Lindmar Open 5 → 0, Euroleague 4 → 0, WTA 4 → 0,
    /// Golf 25 → 0. A viewer looking for the Ronda finds the opposite of a
    /// reason to open the schedule.
    ///
    /// **Why a word list and not "a recognised sport is enough".** The obvious
    /// rework — simply inverting filter 2 — was measured and rejected: it lets
    /// 770 broadcasts through instead of 155, among them 56 rows "Sendepause",
    /// 23× "Premier League" and 18× "Ça se passe sur ARENA SPORT". Those are rights
    /// packages and time slots, not broadcasts. The word list lets exactly the
    /// tournaments in and none of those: none of these titles carries a
    /// tournament or stage word.
    static let tournamentMarkers = [
        // Tours and stage races, the same stem in four languages.
        "etap", "etape", "etapa", "etappe",
        // Tournament rounds. "tour" does double duty here: "2e tour" is the French
        // round, "European Tour" the tournament series.
        "runde", "round", "tour", "turu",
        // Qualifying and session — the time window of a tournament day.
        "qualifying", "qualifikation", "kualifikasyon", "session",
        // Final rounds. Without them, of all things the most important match would
        // drop out.
        "finale", "final", "halbfinale", "viertelfinale", "semifinal",
        // The open tournaments: Lindmar Open, Jadeport Open, Abierto.
        "open", "abierto",
    ]

    /// How far apart two start times may be and still be the same event.
    /// Channels round differently — one starts with the preview at 20:15, the
    /// other at the kick-off at 20:30.
    static let mergeWindow: TimeInterval = 25 * 60

    /// How far back the first-wins rule looks.
    ///
    /// **It used to look back without a time limit, and that cost real matches**
    /// (2026-08-29): `SportModel` also reads two days before the window so that the
    /// first broadcast can swallow its reruns. But because the comparison knew no
    /// time limit, the broadcast of **yesterday** also swallowed the match of
    /// **today**. Measured on the recording, that cost nine of today's events —
    /// among them Demirbahçe–Tarlaspor, Gökyamaç–Fidanbirliği and
    /// Bulutspor–Dumanspor, exactly the evening matches of the Turkish channels
    /// that show their canned recordings in the morning.
    ///
    /// 18 hours, and the number is not round arbitrariness: it must be longer
    /// than a broadcast day from the morning recording (10:00) to the evening
    /// match (22:00) and shorter than the gap to the previous day's broadcast —
    /// otherwise we are back at the timeless rule. Whatever lies further apart is
    /// an event of its own; whether it is a rerun is then decided by filter 3 on
    /// its marks.
    static let rerunWindow: TimeInterval = 18 * 3600

    /// From which difference a broadcast duration counts as an argument.
    ///
    /// A recording is cut together, a live broadcast runs straight through. Under
    /// half an hour of difference the duration says nothing — the channels merely
    /// round differently.
    static let durationEdge: TimeInterval = 30 * 60

    /// Builds the event list of a time range.
    ///
    /// - Parameters:
    ///   - programmes: Programmes from the programme guide; `channelID` is the
    ///     programme ID (`epgID`) of the channel.
    ///   - channelNames: Display name per programme ID — for detection ("NBA Arena"
    ///     tells the sport when the title is silent).
    public static func events(
        from programmes: [Programme],
        channelNames: [String: String] = [:]
    ) -> [SportEvent] {
        var merged: [SportEvent] = []
        // The comparison key per entry, kept alongside the list: it contains the
        // competition, and ``SportEvent`` does not carry that in a form from which it
        // could be recomputed.
        var keys: [String] = []
        // **The channel signal once per channel, not per programme** (E5, 2026-08-29).
        // A channel's name does not change between two of its programmes; yet it ran
        // through the 158 patterns for every single one. On the recording that was
        // 4,302 passes for 136 distinct answers. Measured: 0.79 s → 0.39 s with an
        // identical hit count. The signal is only created at a channel's first
        // occurrence — a channel that broadcasts nothing costs nothing.
        var signals: [String: SportKind?] = [:]

        for programs in programmes.sorted(by: { $0.start < $1.start }) {
            // The programme ID counts toward the channel signal: with the checked
            // provider the display names are mangled ("A***A SP*R 1"), the ID
            // `arenaspor1.tr` is not — see ``SportKind/channelPatterns``.
            let signal: SportKind?
            if let known = signals[programs.channelID] {
                signal = known
            } else {
                let name = (channelNames[programs.channelID] ?? "") + " " + programs.channelID
                signal = SportKind.channelSignal(name)
                signals[programs.channelID] = signal
            }
            guard let kind = SportKind.classify(title: programs.title, channelSignal: signal),
                isLiveEvent(programs.title)
            else { continue }

            let (competition, event) = parsed(programs.title)
            let key = eventKey(kind: kind, competition: competition, event: event)

            // Is the same event already there?
            //
            // Three distances, three answers — and the middle one is new:
            //
            // 1. **Within the merge window:** the same kick-off on another channel. One
            //    entry, two IDs.
            // 2. **Within the look-back:** the same match a second time on the same
            //    broadcast day. One of them is a recording — it stays one entry, but the
            //    more plausible one wins, no longer blindly the first.
            // 3. **Further apart:** an event of its own. The timeless first-wins rule let
            //    a match of today fail on the broadcast of yesterday.
            if let index = keys.lastIndex(of: key) {
                let spacing = abs(merged[index].start.timeIntervalSince(programs.start))
                if spacing <= mergeWindow {
                    merged[index].adopt(programs.channelID)
                    continue
                }
                if spacing <= rerunWindow {
                    if isMorePlausible(programs, than: merged[index]) {
                        merged[index] = SportEvent(
                            id: identifier(kind: kind, key: key, start: programs.start),
                            kind: kind,
                            competition: competition,
                            title: event,
                            start: programs.start,
                            end: Self.end(from: programs, title: event),
                            epgIDs: [programs.channelID]
                        )
                    }
                    continue
                }
            }

            merged.append(
                SportEvent(
                    id: identifier(kind: kind, key: key, start: programs.start),
                    kind: kind,
                    competition: competition,
                    title: event,
                    start: programs.start,
                    end: Self.end(from: programs, title: event),
                    epgIDs: [programs.channelID]
                ))
            keys.append(key)
        }

        return merged
    }

    /// Which of two broadcasts of the same match is the real one.
    ///
    /// **Duration first.** A recording is cut together, a live broadcast runs
    /// through with pre- and post-show. If half an hour or more lies between them,
    /// the longer one is the broadcast.
    ///
    /// **Otherwise the later one** (2026-08-29): the Turkish Arena channels air the
    /// previous day's recording in the morning and live in the evening — and the
    /// old rule systematically picked the recording because it came first. Within
    /// one broadcast day, sport is announced first and repeated afterwards, not the
    /// other way round; when the duration says nothing, the later one is the
    /// better choice.
    ///
    /// The fixture — that is, the evidence from an online source — belongs in
    /// front as the strongest argument. It deliberately is not here yet:
    /// ``SportPlan`` knows no fixtures, ``SportMatch`` only hands them in after
    /// this computation. Pulling it in here would mean reversing the data chain.
    static func isMorePlausible(_ fresh: Programme, than old: SportEvent) -> Bool {
        let newDuration = fresh.end.timeIntervalSince(fresh.start)
        let oldDuration = old.end.timeIntervalSince(old.start)
        if newDuration - oldDuration >= durationEdge { return true }
        if oldDuration - newDuration >= durationEdge { return false }
        return fresh.start > old.start
    }

    /// The key under which two broadcasts are the same match.
    ///
    /// **The competition belongs in it** (2026-08-29): without it, "Moto 2 — Grand
    /// Prix von Valmont" on Friday occupied the same key as the MotoGP race on
    /// Sunday, and the race was missing from the schedule. The guide writes the
    /// class into the competition part, not the event part — exactly there lies
    /// the difference.
    ///
    /// **And the team cores**: "F. Akgümrük - Kozaspor" and "Fatih Akgümrük -
    /// Kozaspor" are the same fixture. The core strips each side of its legal
    /// form and abbreviated first names so that the two spellings coincide. Only
    /// for a recognised pairing — a tournament name must not be cut up.
    static func eventKey(kind: SportKind, competition competitionRef: String?, event: String) -> String {
        let contest = squashed(competitionRef ?? "")
        guard let matchup = pairing(in: event) else {
            return "\(kind.rawValue)#\(contest)#\(squashed(event))"
        }
        return "\(kind.rawValue)#\(contest)#\(teamCore(matchup.home))-\(teamCore(matchup.away))"
    }

    /// The comparison core of a team name.
    ///
    /// What falls away are the legal forms and club abbreviations that the same
    /// team sometimes carries and sometimes not ("FC", "SV", "1."), and the
    /// abbreviated first names ("F. Akgümrük"). Deliberately **no** alias table
    /// and no similarity computation: "Bergland München" and "Bergland Munich" stay
    /// different. Better true twice than wrongly merged once — the one answer to
    /// "is this the same club" is planned in the concept as a building block of
    /// its own and not here.
    static func teamCore(_ name: String) -> String {
        let words = SportKind.normalized(name)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !clubAffixes.contains($0) && $0.count > 1 }
        return words.isEmpty ? squashed(name) : words.joined()
    }

    /// Club abbreviations and legal forms that contribute nothing to the name.
    static let clubAffixes: Set<String> = [
        "fc", "cf", "sc", "ac", "as", "sk", "fk", "cd", "rc", "sv", "tsv",
        "vfl", "vfb", "bsc", "ud", "afc", "ck",
    ]

    /// The ID of an event — the same across several fetches, so the display does
    /// not rebuild everything after a refresh.
    static func identifier(kind: SportKind, key: String, start: Date) -> String {
        "\(key)#\(Int(start.timeIntervalSince1970))"
    }

    /// Whether the programme is a live broadcast of an event.
    ///
    /// A rerun mark beats everything; after that a pairing, a race or the live
    /// mark is enough.
    ///
    /// Public since E2: the schedule probe in PlaylistKit counts the stations
    /// individually — "sport recognised" and "through filter 2" must be visible
    /// separately, otherwise a dropped event count does not say which of the two
    /// filters ate it. Exactly this mix-up cost half a day on 2026-08-16.
    public static func isLiveEvent(_ title: String) -> Bool {
        if isRerun(title) { return false }
        let plain = SportKind.normalized(title)
        if hasLiveMarker(plain) { return true }
        if plain.contains("grand prix") || plain.contains("grosser preis") { return true }
        if hasTournamentMarker(plain) { return true }
        return pairing(in: title) != nil
    }

    /// Whether the title carries a rerun or studio mark.
    ///
    /// Public since E7: the placeholder stage of the matching
    /// (``SportMatch/events(fixtures:programmes:channels:board:)``) needs the same
    /// answer. It did not know the marks until then — "CUGRINKLIT Ceidriot
    /// 26/27" names the competition, carries no pairing and therefore counted as a
    /// broadcast slot of a match.
    public static func isRerun(_ title: String) -> Bool {
        let plain = SportKind.normalized(title)
        return rerunMarkers.contains(where: plain.contains)
    }

    /// Whether one of the live marks stands as a word of its own in the
    /// normalised title.
    static func hasLiveMarker(_ plain: String) -> Bool {
        liveMarkers.contains { SportKind.boundedRange(of: $0, in: plain) != nil }
    }

    /// Whether a tournament or stage word stands as a word of its own in the
    /// normalised title.
    static func hasTournamentMarker(_ plain: String) -> Bool {
        tournamentMarkers.contains { SportKind.boundedRange(of: $0, in: plain) != nil }
    }

    /// Finds the pairing "A versus B" in a title — or `nil`.
    ///
    /// Separation is at " - ", " – ", " / ", " vs ", " x " or a hyphen between
    /// two names ("Rio Lume-Serrano"). Both sides must look like names: at least
    /// three characters, with letters in them — otherwise every score or date
    /// would be a pairing.
    ///
    /// **The order is the rule** (2026-08-29): the French market writes its pairings
    /// exclusively as "home / away". Without the slash, 37 titles got no pairing
    /// at all — and six a wrong one, because further down the bare hyphen struck
    /// and turned "Baidrohain JUCI / Bellerive" into the pairing "Paris" versus
    /// "SG / Bellerive". That is why " / " comes **before** the bare hyphen: the
    /// unambiguous separator must beat the ambiguous one, not the other way
    /// round.
    /// How long a **pairing** runs at most.
    ///
    /// **Device finding 2026-08-29, 21:00:** in the sport section, Mill U against
    /// Ashwick from 17:30 is shown although it is 21:00 — it can never be current
    /// any more. The finding was right: in the guide this match runs from 18:30 to
    /// 07:45 local time — **thirteen hours**. As long as it runs,
    /// ``SportWindow/list(_:span:now:)`` considers it live, and it stood at
    /// the top the whole evening.
    ///
    /// Counted again on the recording: **seven** pairings with more than five
    /// hours, up to nineteen ("Escolar - Serrano"). Those are slots the provider
    /// does not close cleanly, not broadcasts.
    ///
    /// **Six hours, and only for pairings.** The concept rejects a general
    /// duration cap, measured, and rightly so: it would kill the "Ultra-Trail du
    /// Mont-Valmeur" and the 165 other broadcasts over six hours — exactly the
    /// formats the section exists for. A **match between two teams** is none of
    /// them. Six hours leave room for every tennis match and every extra time and
    /// cut off the obviously wrong rows.
    ///
    /// Only the **end** is cut off. The kick-off stays where it is — it is the
    /// information that matters.
    public static let pairingAtMost: TimeInterval = 6 * 3600

    static func end(from programs: Programme, title: String) -> Date {
        guard pairing(in: title) != nil else { return programs.end }
        return min(programs.end, programs.start.addingTimeInterval(pairingAtMost))
    }

    public static func pairing(in title: String) -> (home: String, away: String)? {
        let separators = [" - ", " – ", " — ", " / ", " vs. ", " vs ", " x ", "-"]
        // The event part without competition prefix — otherwise the hyphen in
        // "DFB-Pokal" cuts the wrong part.
        let event = parsed(title).event

        for separator in separators {
            let parts = event.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let home = parts[0].trimmingCharacters(in: .whitespaces)
            let away = trimmedTail(parts[1])
            guard looksLikeName(home), looksLikeName(away) else { continue }
            if separator == "-", isWordCompound(left: home, right: away) { continue }
            return (home, away)
        }
        return nil
    }

    /// Whether the bare hyphen joins a **word** instead of two opponents.
    ///
    /// **The finding (acceptances for E2, open until E7):** the bare hyphen turns
    /// rights packages into pairings. Measured on the recording of 2026-08-29, that
    /// put five rows in the schedule that are not matches: "Fußball-Bundesliga",
    /// "Fußball: DFB-Pokal", "Fußball: DFB-Pokal Junioren", "Fußball:
    /// Frauen-Bundesliga" and "FIFA Fußball-WM 2026 Achtelfinale". By the concept
    /// (§2) the section must not show exactly those — "no magazine, no recording,
    /// no rights package".
    ///
    /// **The rule is deliberately asymmetric, and for a reason rooted in the
    /// language.** German compounds write `sport-competition`:
    /// "Fußball-Bundesliga", "Handball-EM", "Basketball-Bundesliga". So:
    ///
    /// - **On the left** no sport name may stand. If one does, the hyphen is a
    ///   joining hyphen.
    /// - **On the right** no competition or rights-package word may stand.
    ///
    /// Conversely, neither holds, explicitly — and exactly there lies the gain
    /// over the obvious symmetric version: on the right a sport name may stand
    /// ("Valdoria-Marathon"), on the left a place name ("Valmora-Tour"), and
    /// both remain what they are: real events. The symmetric rule would have
    /// killed "Valdoria-Marathon", "FIA-Weltmeisterschaft Valmont" and "2026 E-spor
    /// Dünya Kupası" on the same recording. Measured, this version costs **zero**
    /// real events and removes exactly the five rights packages.
    ///
    /// Only the word **directly at the hyphen** is checked — the last one on the
    /// left, the first on the right. "Sahilspor-Ekip Grup Sarıdere" thus remains a
    /// pairing, although further back there are words that mean something
    /// elsewhere.
    static func isWordCompound(left: String, right: String) -> Bool {
        guard let leftWord = SportKind.normalized(left).split(separator: " ").last,
            let rightWord = SportKind.normalized(right).split(separator: " ").first
        else { return false }
        if SportKind.allCases.contains(where: { $0.patterns.contains(String(leftWord)) }) {
            return true
        }
        return SportCompetition.isCompetitionWord(String(rightWord))
    }

    /// Splits a title into competition and event.
    ///
    /// "Live Liga Portugal: Rio Lume-Serrano Etapa 2" → ("Liga Portugal",
    /// "Rio Lume-Serrano Etapa 2"). Without a colon everything stays event; the live
    /// marks disappear from both parts — they are state, not a name.
    static func parsed(_ title: String) -> (competition: String?, event: String) {
        let cleaned = withoutLiveMarkers(title)
        guard let colon = cleaned.firstIndex(of: ":") else {
            return (nil, cleaned.trimmingCharacters(in: .whitespaces))
        }
        let head = String(cleaned[..<colon]).trimmingCharacters(in: .whitespaces)
        let tail = String(cleaned[cleaned.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else {
            return (nil, cleaned.trimmingCharacters(in: .whitespaces))
        }
        return (head, tail)
    }

    // MARK: - Handwerkszeug

    private static func withoutLiveMarkers(_ title: String) -> String {
        var text = title
        for marker in ["Live ", "LIVE ", "Canlı ", "CANLI ", "(Direto)", "(Live)", "(Canlı)"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The comparison core of an event: lowercase, without symbols, without
    /// spaces.
    static func squashed(_ text: String) -> String {
        String(
            SportKind.normalized(text).unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init))
    }

    private static func looksLikeName(_ text: String) -> Bool {
        text.count >= 3 && text.rangeOfCharacter(from: .letters) != nil
            && text.rangeOfCharacter(from: .decimalDigits.inverted) != nil
    }

    /// Cuts trailing material after the pairing ("FC Serrano (Direto)" → stays, but
    /// league suffixes after numbers such as "Etapa 2" belong to the name — only
    /// parenthesised extras are removed here).
    private static func trimmedTail(_ text: String) -> String {
        var result = text
        if let bracket = result.firstIndex(of: "(") {
            result = String(result[..<bracket])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
