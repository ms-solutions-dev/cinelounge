import Foundation

/// The sport of a broadcast — recognised from the title, not asserted.
///
/// **Why from the title:** the EPG of the examined provider carries no categories
/// (dump of 2026-08-16, 62,895 programmes — not a single `<category>`). What remains
/// are the titles, and they are productive: leagues, tournaments and pairings
/// appear in them verbatim, across the languages of the channel lists (Turkish,
/// German, English, Portuguese, Polish).
///
/// The patterns are **enumerations, not intelligence**: each sport names the
/// competitions and words by which it is recognised. What none of them hits is no
/// sports broadcast — better a missing fringe event than a cooking show between
/// the games.
public enum SportKind: String, CaseIterable, Sendable, Codable {
    case football
    case basketball
    case tennis
    case volleyball
    case fighting
    case motorsport
    case handball
    case cycling
    case darts
    case golf
    case americanFootball
    case baseball
    case iceHockey
    case tableTennis
    case swimming
    case athletics
    case winterSport
    case equestrian
    case esports
    // Four sports added (2026-08-29). The test bench found them unrecognised in the
    // recording: snooker 29 programmes, motocross 30, rugby 24, judo 9 — 92 together,
    // and not a single one could ever get into the schedule, because filter 1 did
    // not know them. The French market broadcasts rugby and motocross daily.
    case snooker
    case rugby
    case motocross
    case judo

    /// The SF Symbol of the filter bar.
    public var symbol: String {
        switch self {
        case .football: "soccerball"
        case .basketball: "basketball"
        case .tennis: "tennisball"
        case .volleyball: "volleyball"
        case .fighting: "figure.boxing"
        case .motorsport: "flag.checkered"
        case .handball: "figure.handball"
        case .cycling: "figure.outdoor.cycle"
        case .darts: "target"
        case .golf: "figure.golf"
        case .americanFootball: "football"
        case .baseball: "baseball"
        case .iceHockey: "hockey.puck"
        case .tableTennis: "figure.table.tennis"
        case .swimming: "figure.pool.swim"
        case .athletics: "figure.run"
        case .winterSport: "figure.skiing.downhill"
        case .equestrian: "figure.equestrian.sports"
        case .esports: "gamecontroller"
        // There is no symbol for snooker in the system collection (checked against
        // CoreGlyphs, 9,184 names). The circle cluster comes closest to the triangle of
        // red balls; an invented name would be an empty field on the TV.
        case .snooker: "circle.hexagongrid.fill"
        case .rugby: "rugbyball"
        case .motocross: "motorcycle"
        case .judo: "figure.martial.arts"
        }
    }

    /// The translation key of the filter bar.
    public var labelKey: String { "sport.kind.\(rawValue)" }

    /// The words and competitions by which the sport is recognised.
    ///
    /// Compared lowercase and without diacritics — "Süper Lig" and "super lig" are the
    /// same competition.
    var patterns: [String] {
        switch self {
        case .football:
            [
                // "superliga" separately: since the word-boundary rule, "superlig" no longer
                // also covers the Romanian Superliga.
                "futbol", "fussball", "soccer", "super lig", "superlig", "superliga",
                "bundesliga",
                "premier league", "la liga", "laliga", "serie a", "ligue 1",
                "champions league", "sampiyonlar ligi", "uefa", "europa league",
                "conference league", "liga portugal", "eredivisie", "ziraat",
                "turkiye kupasi", "dfb-pokal", "copa del rey", "coppa italia",
                "pilka nozna", "primeira liga", "super kupa", "supercup",
                // "world cup" is deliberately NOT included (2026-08-29): the expression belongs to
                // no sport. Measured, the "Kessler-Dorn Bagger World Cup" therefore stood in
                // the schedule as a football game. The real football World Cup carries
                // "Fußball", "FIFA" or "Dünya Kupası" in the title in this program guide anyway
                // — it is not lost that way.
                "mls", "dunya kupasi", "em-quali",
                "wm-quali", "milli mac", "hazirlik maci", "derbi",
            ]
        case .basketball:
            [
                "basketbol", "basketball", "nba", "euroleague", "eurolig",
                "basketbol super ligi", "bbl", "acb", "eurocup", "fiba",
            ]
        case .tennis:
            [
                "tenis", "tennis", "atp", "wta", "wimbledon", "roland garros",
                "us open", "australian open", "davis cup",
            ]
        case .volleyball:
            [
                "voleybol", "volleyball", "filenin", "cev", "vnl",
                "efeler ligi", "sultanlar ligi",
            ]
        case .fighting:
            [
                "boks", "boxen", "boxing", "ufc", "mma", "kickbox", "muay thai",
                "wrestling", "gures", "dovus", "fight night", "glory",
            ]
        case .motorsport:
            [
                "formula 1", "formula1", "formel 1", "f1", "motogp", "moto gp",
                "nascar", "rallye", "ralli", "grand prix", "grosser preis",
                "indycar", "dtm", "formula e", "moto2", "moto3", "superbike",
                // 2026-08-29: "Formel E: FIA-Weltmeisterschaft Valmont" and "Formule E : ePrix de
                // Valmont" hit no pattern — "formula e" is the English spelling, and the French
                // one names only the ePrix. "wrc" covers the 43 rally programmes that get by
                // without the word "Rallye" as "Fractionné WRC".
                "formel e", "eprix", "wrc",
            ]
        case .handball:
            ["handball", "hentbol", "ehf"]
        case .cycling:
            [
                "cycling", "bisiklet", "radsport", "vuelta", "giro d",
                "tour de france", "radrennen",
            ]
        case .darts:
            ["darts"]
        case .golf:
            ["golf", "pga tour", "ryder cup"]
        case .americanFootball:
            ["nfl", "american football", "amerikan futbolu", "super bowl"]
        case .baseball:
            ["mlb", "beyzbol", "baseball"]
        case .iceHockey:
            ["nhl", "buz hokeyi", "eishockey", "ice hockey", "penny del"]
        case .tableTennis:
            ["masa tenisi", "tischtennis", "table tennis"]
        case .swimming:
            ["yuzme", "schwimmen", "swimming"]
        case .athletics:
            ["atletizm", "athletics", "leichtathletik", "diamond league", "marathon", "maraton"]
        case .winterSport:
            [
                "biathlon", "ski alpin", "skispringen", "kayak", "langlauf",
                "wintersport", "eiskunstlauf", "rodeln", "bob-",
            ]
        case .equestrian:
            // "fei " with a space: the world federation is called FEI, but the three letters
            // alone sit in too many words ("Feier").
            [
                "pferdesport", "reitsport", "reiten", "fei ", "equestrian",
                "binicilik", "at yarisi", "galopprennen", "horse racing",
            ]
        case .esports:
            // "esports"/"e-spor", not "esport": the substring sits in "Pferdesport" — the FEI
            // World Championship from Aachen stood in the schedule as esports (on-device
            // finding 2026-08-16).
            ["esports", "e-spor", "lave-breitia", "league of legends", "dota"]
        case .snooker:
            ["snooker", "bilardo"]
        case .rugby:
            // "rugby" alone suffices: the word appears in no other context in a TV program
            // guide.
            ["rugby", "top 14", "six nations", "supersevens"]
        case .motocross:
            // Placed before "motorsport", motocross is given nothing — it wins by pattern
            // length, like every sport here.
            ["motocross", "mxgp", "supercross"]
        case .judo:
            ["judo"]
        }
    }

    /// Channels whose name fixes the sport when the title is silent.
    ///
    /// **On-device finding 2026-08-16:** the Süper Lig games are called plainly
    /// "Demirbahçe - Bulutspor" in the EPG — no football word far and wide. What gives
    /// them away is the channel: Pusula SPORTS is the broadcasting channel of the Süper
    /// Lig and the 1. Lig, a bare pairing there is football. Deliberately kept short:
    /// a mixed sports channel (KULE SPORT, KANAL SPOR) fixes nothing — there the title has
    /// to speak.
    ///
    /// "pusulasports" without a space is the **program identifier** — `pusulasports1.tr`
    /// and relatives. It counts too, because the display names of the examined
    /// provider are garbled ("b**N SP*RTS 1", "SpaceX Sports 1") and no honest
    /// pattern fits them; the identifier remains untouched by that.
    /// "kule-sport"/"kulesport" (2026-08-16, Zenit follow-up): KULE-SPORT broadcasts LaLiga as a
    /// bare pairing ("Gaitero Vimar - Olmedo"), while basketball and volleyball are
    /// named in the title there ("Euroleague", "Voleybol …") — the title stage
    /// catches them first, the pairing stays football.
    var channelPatterns: [String] {
        switch self {
        case .football: ["pusula sports", "pusula max", "pusulasports", "kule-sport", "kulesport"]
        default: []
        }
    }

    /// Recognises the sport of a programme — or `nil` if none fits.
    ///
    /// Three stages, from the most reliable to the weakest: first the **title**, then
    /// the **channel name** with the same patterns ("NBA TV" says basketball), last
    /// the ``channelPatterns`` of the league channels. Title and channel name are kept
    /// separate, not concatenated — otherwise the channel "Pusula SPORTS" would make a
    /// basketball title unrecognisable.
    public static func classify(title: String, channelName: String = "") -> SportKind? {
        classify(title: title, channelSignal: channelSignal(channelName))
    }

    /// What the **channel alone** says about the sport — the two lower stages of
    /// ``classify(title:channelName:)``, taken by themselves.
    ///
    /// **Why this is a question of its own** (E5, 2026-08-29): the channel name does not
    /// change between two programmes of the same channel. Nevertheless it ran through
    /// all 158 patterns per programme — with 4,302 programmes on 136 channels that
    /// was 4,302 passes for 136 different answers. Measured on the recording of
    /// 2026-08-29, that alone cost the larger part of the event calculation: **0.793 s →
    /// 0.387 s**, extrapolated to device size (38,718 programmes) **7.353 s →
    /// 3.446 s** — and both **with an identical hit count** (185 events; the probe
    /// reports unchanged 835 / 213 / 120). The measurement is in
    /// ``ScheduleTimingTests``.
    ///
    /// The answer is a pure function of the name — whoever stores it stores nothing
    /// mutable. ``SportPlan/events(from:channelNames:)`` therefore keeps it per
    /// program identifier.
    public static func channelSignal(_ channelName: String) -> SportKind? {
        let channel = normalized(channelName)
        if let kind = bestMatch(in: channel, among: { $0.patterns }) { return kind }
        return bestMatch(in: channel, among: { $0.channelPatterns })
    }

    /// The same recognition with a **precomputed** channel signal.
    ///
    /// The order stays that of the three-stage rule: the title beats the channel, and
    /// only when it is silent does the signal speak.
    public static func classify(title: String, channelSignal: SportKind?) -> SportKind? {
        bestMatch(in: normalized(title), among: { $0.patterns }) ?? channelSignal
    }

    /// The best hit across all sports — not the first.
    ///
    /// **Precision beats order** (on-device finding 2026-08-16): "Basketbol Süper Lig
    /// Özetler" first hit the football pattern "super lig", because football comes
    /// first in the enumeration. Now the longest pattern wins, on a tie the earlier
    /// one in the text — in such titles the sport comes first ("Basketbol: …").
    private static func bestMatch(
        in haystack: String,
        among patterns: (SportKind) -> [String]
    ) -> SportKind? {
        guard !haystack.isEmpty else { return nil }
        var best: (kind: SportKind, length: Int, position: Int)?
        for kind in allCases {
            for pattern in patterns(kind) {
                guard let range = boundedRange(of: pattern, in: haystack) else { continue }
                let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let wins =
                    best.map {
                        pattern.count > $0.length
                            || (pattern.count == $0.length && position < $0.position)
                    } ?? true
                if wins { best = (kind, pattern.count, position) }
            }
        }
        return best?.kind
    }

    /// Finds the pattern only at word boundaries — not in the middle of a word.
    ///
    /// **The substring plague** (on-device finding 2026-08-16): "i(mma)gine" became combat
    /// sports, "Börse(nfl)ash" NFL, "Ru(bbl)e" basketball, and "Pferd(esport)" stood
    /// in the schedule as esports. The rule: if a pattern begins or ends with a
    /// letter, no further letter may follow there in the text. Digits and symbols
    /// stay permeable ("Serie A1", "Süper Lig:", "Bob-WM").
    static func boundedRange(of pattern: String, in haystack: String) -> Range<String.Index>? {
        guard !pattern.isEmpty else { return nil }
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
            let range = haystack.range(of: pattern, range: searchStart..<haystack.endIndex)
        {
            let beforeIsClear =
                !(pattern.first?.isLetter ?? false) || range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterIsClear =
                !(pattern.last?.isLetter ?? false) || range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
                || isTurkishSuffix(haystack[range.upperBound...])
            if beforeIsClear && afterIsClear { return range }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return nil
    }

    /// Turkish suffixes that may attach directly to a name.
    ///
    /// **Why the word boundary alone is too strict for Turkish** (2026-08-29): Turkish
    /// glues its endings on without a hyphen and without a space — "Süper Lig" becomes
    /// "Süper **Ligi**", "Bisiklet" becomes "Bisiklet**i**", "Maraton" becomes
    /// "Maraton**u**". For the word-boundary rule that is one letter too many, and
    /// the programme drops out of the recognition. Measured on the recording, this hit
    /// "2026 Dünya Dağ Bisikleti Şampiyonası" (8 programmes) and "Valdoria Maratonu"
    /// (2).
    ///
    /// **Corrected at the acceptance on 2026-08-29:** here additionally stood "Basketbol:
    /// Kadınlar Süper Ligi" and "Ova Sigorta Basketbol Süper Ligi" (9 programmes
    /// together). The rule does not owe them anything — both hit "basketbol" and are
    /// recognised just the same without it (re-measured). **And the price stands next
    /// to it:** calculated over the uncut capture (29,259 programmes, all 492
    /// channels), the chain wins exactly these two titles and buys them with a false
    /// one — "Froufou'sketkrospus Vitlunskai" on BABY TV, a children's cartoon as cycling. The
    /// schedule stays untouched because filter 2 stops it; the sport chips counted it.
    /// Both are recorded in ``SportPlanTests``.
    ///
    /// **Why a list and not "letters allowed"**: the same recording contains
    /// "Som**mma**ire Premier League", "Kloster TV Em**mma**us", "Senza
    /// program**mma**zione" and "das internationale Fuss**ball**magazin". If
    /// arbitrary letters were allowed to follow, those would all be combat-sports and
    /// football programmes — exactly the substring plague this rule is meant to
    /// eliminate. None of these suffixes can be composed from the list.
    ///
    /// Comparison is on the normalised form, in which "ı" has become "i" and "ü"
    /// has become "u" — that is why "ler"/"lar" stands here and not "ler"/"lar" in
    /// both spellings.
    static let turkishSuffixes: Set<String> = [
        "a", "e", "i", "u",
        "in", "un", "an", "en",
        "ne", "na", "ni", "nu",
        "se", "sa", "si", "su",
        "ye", "ya", "yi", "yu",
        "de", "da", "te", "ta",
        "den", "dan", "ten", "tan",
        "nde", "nda", "nden", "ndan",
        "nin", "nun",
        "ler", "lar", "leri", "lari",
    ]

    /// Whether the letter tail behind a pattern is a **chain** of Turkish suffixes —
    /// "ligi" is one, "liginde" is two.
    ///
    /// At most three links: a real chain gets no longer, and without a cap the rule
    /// would eventually assemble every word ending out of single-letter suffixes.
    static func isTurkishSuffix(_ tail: Substring) -> Bool {
        let letters = String(tail.prefix(while: \.isLetter))
        guard !letters.isEmpty else { return false }
        return canSplit(Substring(letters), remaining: 3)
    }

    private static func canSplit(_ rest: Substring, remaining: Int) -> Bool {
        if rest.isEmpty { return true }
        guard remaining > 0 else { return false }
        // The longest suffix first, so that "nden" does not fall apart into
        // "n"+"den" — every decomposition is checked anyway, because otherwise a greedy
        // choice can miss a valid chain.
        for length in stride(from: min(4, rest.count), through: 1, by: -1) {
            let header = rest.prefix(length)
            guard turkishSuffixes.contains(String(header)) else { continue }
            if canSplit(rest.dropFirst(length), remaining: remaining - 1) { return true }
        }
        return false
    }

    /// Lowercase, without diacritics — the comparison form of all patterns. Public,
    /// because the merging needs the same form.
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }
}
