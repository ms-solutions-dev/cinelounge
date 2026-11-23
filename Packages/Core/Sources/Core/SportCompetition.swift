import Foundation

/// The **one** competition board of the sports area.
///
/// **The finding it takes on** (concept, section 4): the leagues stood in two
/// places. In PlaylistKit lay the list of the tapped leagues
/// (`SportFixtureSource.leagues`, twenty numbers from TheSportsDB), in Core the
/// list of EPG placeholders (`SportMatch.placeholders`, seventeen word lists) —
/// connected solely by string similarity between the league name of the source
/// and the name of the placeholder. Whoever tapped a league and forgot the
/// placeholder never noticed: measured, MLS, EFL Cup and Euroleague fell out of
/// the placeholder stage this way even before E6, without any number anywhere
/// getting smaller.
///
/// Here every competition stands **once**, with everything the area knows about
/// it: where the fixtures come from (``path`` at ESPN, ``tsdb`` for the fallback),
/// which sport it is, and which words the program guide uses to name it.
/// ``SportCompetitionTests`` proves that every tapped competition has a
/// vocabulary — the check that could not exist before, because there was nothing
/// it could have run over.
///
/// **The mapping goes through the identifier, not through the name.** Since E6 a
/// fixture carries the ``path`` of its competition with it (``SportFixture``); the
/// placeholder is looked up with it and no longer guessed. The old board had to be
/// **ordered** for that — "2. bundesliga" before "bundesliga", otherwise the
/// shorter string swallowed the longer one. That order has become meaningless;
/// what remains of it stands in ``except`` and concerns only the search in the
/// program guide.
public struct SportCompetition: Sendable, Equatable, Identifiable {

    /// The path at ESPN — sport and league identifier, as the address carries them:
    /// `soccer/ger.1`, `basketball/nba`.
    public let path: String
    public var id: String { path }

    public let kind: SportKind

    /// What the competition is called in the report. Not what stands in the row —
    /// that holds the name the source delivers ("German Bundesliga").
    public let name: String

    /// The identifier of the same league at TheSportsDB — the fallback when ESPN does
    /// not answer (addendum of 2026-08-29).
    public let tsdb: Int

    /// What the program guide calls this competition when it names no pairing:
    /// "Bundesliga 26/27" on Zenit, "LaLiga 26/27" on Zenit 2.
    public let lexicon: [String]

    /// Titles with these words belong to a DIFFERENT competition.
    ///
    /// This is the remainder of the old ordering: "bundesliga" is contained in
    /// "2. Bundesliga", "laliga" in "LaLiga 2", "serie a" in "Brasileiro Série A".
    /// As long as the search runs over words, the shorter one has to delimit itself
    /// from the longer one.
    public let except: [String]

    public init(
        path: String, kind: SportKind, name: String, tsdb: Int,
        lexicon: [String], except: [String] = []
    ) {
        self.path = path
        self.kind = kind
        self.name = name
        self.tsdb = tsdb
        self.lexicon = lexicon
        self.except = except
    }

    /// The tapped competitions — the leagues of the viewer's channel lists.
    ///
    /// **They are exactly the twenty that previously stood there as TheSportsDB
    /// numbers**, translated to ESPN identifiers and re-measured: each of the twenty
    /// answers with HTTP 200 on 2026-08-29 (recording in the test stock). Extending
    /// the list is a decision of its own with its own measurement and does not belong
    /// in the same change.
    public static let all: [SportCompetition] = [
        SportCompetition(
            path: "soccer/tur.1", kind: .football, name: "Süper Lig", tsdb: 4339,
            lexicon: ["super lig", "superlig"], except: ["basketbol", "1. lig"]),
        SportCompetition(
            path: "soccer/ger.1", kind: .football, name: "Bundesliga", tsdb: 4331,
            lexicon: ["bundesliga"], except: ["2. bundesliga", "frauen"]),
        SportCompetition(
            path: "soccer/ger.2", kind: .football, name: "2. Bundesliga", tsdb: 4399,
            lexicon: ["2. bundesliga"]),
        SportCompetition(
            path: "soccer/eng.1", kind: .football, name: "Premier League", tsdb: 4328,
            lexicon: ["premier league"], except: ["premier league 2"]),
        SportCompetition(
            path: "soccer/esp.1", kind: .football, name: "LaLiga", tsdb: 4335,
            lexicon: ["laliga", "la liga"], except: ["laliga 2", "la liga 2"]),
        SportCompetition(
            path: "soccer/ita.1", kind: .football, name: "Serie A", tsdb: 4332,
            lexicon: ["serie a"], except: ["brasileiro", "brasileirao"]),
        SportCompetition(
            path: "soccer/fra.1", kind: .football, name: "Ligue 1", tsdb: 4334,
            lexicon: ["ligue 1"]),
        SportCompetition(
            path: "soccer/por.1", kind: .football, name: "Primeira Liga", tsdb: 4344,
            lexicon: ["primeira liga", "liga portugal"]),
        SportCompetition(
            path: "soccer/ned.1", kind: .football, name: "Eredivisie", tsdb: 4337,
            lexicon: ["eredivisie"]),
        SportCompetition(
            path: "soccer/uefa.champions", kind: .football, name: "Champions League", tsdb: 4480,
            lexicon: ["champions league", "sampiyonlar ligi"]),
        SportCompetition(
            path: "soccer/uefa.europa", kind: .football, name: "Europa League", tsdb: 4481,
            lexicon: ["europa league"]),
        SportCompetition(
            path: "soccer/eng.fa", kind: .football, name: "FA Cup", tsdb: 4482,
            lexicon: ["fa cup"]),
        // **Newly given a vocabulary.** EFL Cup, MLS and Euroleague stood in the league
        // list but had no placeholder — the finding that the one board eliminates.
        SportCompetition(
            path: "soccer/eng.league_cup", kind: .football, name: "Carabao Cup", tsdb: 4570,
            lexicon: ["carabao cup", "efl cup", "league cup"]),
        // **Without a hand-written vocabulary, and that is the finding** (acceptance of
        // E6, fixed in E7): here stood the bare word "championship". It is a generic
        // word and in the program guide belongs almost entirely to motorsport — measured
        // 74 titles with "Championship" in the recording of 2026-08-29, of which **two** are
        // the English second division ("Fußball: England, EFL Championship") and 72
        // others: "Motocross World Championship" (26×), "Supercars
        // Championship" (12×), "World Rally Championship" (8×). As a result three
        // Championship fixtures got as their only channel "DE: MOTORWELT", a channel
        // that carries not a single football title in the whole recording.
        //
        // The source says it more precisely than any hand-written list: ESPN calls the
        // competition "EFL Championship", and that is exactly how the provider writes it
        // too. The vocabulary therefore comes from the source here
        // (``SportMatch/sourceWords(_:)``) and is no longer entered by hand.
        SportCompetition(
            path: "soccer/eng.2", kind: .football, name: "Championship", tsdb: 4329,
            lexicon: []),
        SportCompetition(
            path: "soccer/usa.1", kind: .football, name: "MLS", tsdb: 4346,
            lexicon: ["mls", "major league soccer"]),
        SportCompetition(
            path: "soccer/bra.1", kind: .football, name: "Brasileirão", tsdb: 4351,
            lexicon: ["brasileiro", "brasileirao"]),
        SportCompetition(
            path: "soccer/esp.2", kind: .football, name: "LaLiga 2", tsdb: 4400,
            lexicon: ["laliga 2", "la liga 2"]),
        SportCompetition(
            path: "soccer/fra.2", kind: .football, name: "Ligue 2", tsdb: 4401,
            lexicon: ["ligue 2"]),
        SportCompetition(
            path: "basketball/nba", kind: .basketball, name: "NBA", tsdb: 4387,
            lexicon: ["nba"]),
        SportCompetition(
            path: "basketball/euroleague", kind: .basketball, name: "Euroleague", tsdb: 4546,
            lexicon: ["euroleague", "euroliga"]),
    ]

    /// The competition for an identifier — the lookup that replaces guessing.
    public static func using(path: String) -> SportCompetition? {
        byPath[path]
    }

    private static let byPath: [String: SportCompetition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.path, $0) })

    /// Whether a normalised title names this competition — without naming a pairing.
    ///
    /// - Parameter auch: Further words with which the **source** names this
    ///   competition ("EFL Championship", "German Bundesliga"). They come from the
    ///   fixture and not from this board — that is the core of E7: if a league is
    ///   added or the source renames it, its name comes along without anybody
    ///   entering anything here.
    public func names(_ normalizedTitle: String, also sourceWords: [String] = []) -> Bool {
        guard !except.contains(where: { Self.carries($0, normalizedTitle) }) else {
            return false
        }
        if lexicon.contains(where: { Self.carries($0, normalizedTitle) }) { return true }
        return sourceWords.contains {
            Self.carries(SportKind.normalized($0), normalizedTitle)
        }
    }

    /// Whether a single word names a competition or a rights package.
    ///
    /// Two sources, and neither ages with the provider: the vocabulary of the board
    /// above (it follows the fixture source) and a small list of generic words. Those
    /// belong to the **language** and not to the rights situation — "Pokal" will still
    /// be called Pokal next year, even if somebody else broadcasts it then.
    ///
    /// Needed by ``SportPlan/isWordCompound(links:right:)``. Measured, only "pokal"
    /// carries weight of these — it removes "DFB-Pokal" and "DFB-Pokal Junioren" from
    /// the schedule. The others are the same word in the other markets this provider
    /// carries.
    static func isCompetitionWord(_ word: String) -> Bool {
        if rightsPackageWords.contains(word) { return true }
        return all.contains { $0.lexicon.contains(word) }
    }

    static let rightsPackageWords: Set<String> = [
        "pokal", "cup", "kupa", "kupasi", "coupe", "copa", "supercup", "trophy",
    ]

    /// Whether a title carries this competition word **as a whole word**.
    ///
    /// **Why this cannot be ``SportKind/boundedRange(of:in:)``.** That rule draws the
    /// word boundary at letters, and that suffices for sport patterns: "live" must not
    /// sit inside "Livernholm". But competition names end in digits — "Ligue 1",
    /// "LaLiga 2", "2. Bundesliga" —, and the program guide appends the season to
    /// every competition: "LaLiga 26/27".
    ///
    /// Measured, the damage runs both ways: "laliga 2" is contained in "laliga
    /// 26/27", so LaLiga 2 would claim every LaLiga placeholder, and the exclusion
    /// "not laliga 2" would exclude every LaLiga placeholder. Both at the same spot,
    /// both silent. **A digit is therefore no more a word boundary here than a
    /// letter.**
    ///
    /// The Turkish suffix chain stays allowed where the word ends in a letter: the
    /// provider writes "Süper Ligi", and without it the whole Turkish market would
    /// fall out of the placeholder stage (``SportKind/isTurkishSuffix(_:)``).
    public static func carries(_ word: String, _ title: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchStart = title.startIndex
        while searchStart < title.endIndex,
            let location = title.range(of: word, range: searchStart..<title.endIndex)
        {
            let freeBefore =
                location.lowerBound == title.startIndex
                || !title[title.index(before: location.lowerBound)].isLetterOrDigit
            let freeAfter =
                location.upperBound == title.endIndex
                || !title[location.upperBound].isLetterOrDigit
                || ((word.last?.isLetter ?? false)
                    && SportKind.isTurkishSuffix(title[location.upperBound...]))
            if freeBefore && freeAfter { return true }
            searchStart = title.index(after: location.lowerBound)
        }
        return false
    }
}

extension Character {
    fileprivate var isLetterOrDigit: Bool { isLetter || isNumber }
}
