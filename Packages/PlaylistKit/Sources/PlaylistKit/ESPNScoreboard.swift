import Core
import Foundation

/// Reads the response of ESPN's open scoreboard service.
///
/// **Why ESPN comes first** (addendum of 2026-08-29 to the sports concept, a
/// product decision): Against the reference figures given for 2026-08-29, the source
/// hits three out of three — Süper Lig 3, Bundesliga 6, Premier League 4 — and
/// with the **full league round** instead of a single token fixture. Measured
/// against the same program guide, 19 of 77 ESPN fixtures found a channel,
/// versus 4 of 19 for TheSportsDB. No key is needed.
///
/// **What the source delivers on the side and E7 needs:** its own
/// vocabulary. The head of every response names the competition three ways
/// ("German Bundesliga" / "Bundesliga" / `ger.1`), and every team four ways
/// ("1. FC Union Kesselburg" / "Union Kesselburg" / "FCU" / location). That is why both
/// are read, although E6 only needs the fixtures.
///
/// **The honest limit:** The service is undocumented and guarantees nothing.
/// It can disappear without notice — which is what the fallback to
/// TheSportsDB in ``SportFixtureSource`` is for.
enum ESPNScoreboard {

    /// What a response yields.
    struct Reply: Sendable, Equatable {
        /// How ESPN names the competition — "German Bundesliga".
        let league: String
        /// The short form — "Bundesliga". The word E7 looks for in channel names.
        let short: String
        let fixtures: [SportFixture]
    }

    static func read(_ data: Data, competition: SportCompetition) -> Reply? {
        guard let content = try? JSONDecoder().decode(Content.self, from: data),
            let events = content.events
        else { return nil }

        let header = content.leagues?.first
        let league = header?.name ?? competition.name
        let short = header?.abbreviation ?? competition.name

        let fixtures: [SportFixture] = events.compactMap { event in
            guard let start = datum(from: event.date),
                let teams = event.competitions?.first?.competitors,
                let home = teams.first(where: { $0.homeAway == "home" })?.team,
                let away = teams.first(where: { $0.homeAway == "away" })?.team,
                let homeName = home.displayName, !homeName.isEmpty,
                let awayName = away.displayName, !awayName.isEmpty
            else { return nil }
            return SportFixture(
                id: SportFixtureProvider.espn.prefix + event.id,
                source: .espn,
                path: competition.path,
                kind: competition.kind,
                league: league,
                leagueShort: short,
                home: homeName,
                away: awayName,
                start: start,
                homeVariantsList: home.variants,
                awayVariantsList: away.variants)
        }
        return Reply(league: league, short: short, fixtures: fixtures)
    }

    /// ESPN stamps without seconds: "2026-08-29T13:30Z".
    ///
    /// The form with seconds is handled as well, because a service without a
    /// guaranteed format may deliver it tomorrow, and a fixture without a kickoff
    /// time would silently vanish.
    static func datum(from stamp: String) -> Date? {
        for form in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = form
            if let datum = formatter.date(from: stamp) { return datum }
        }
        return nil
    }

    // MARK: - Die Form der Antwort

    private struct Content: Decodable {
        struct League: Decodable {
            let name: String?
            let abbreviation: String?
        }
        struct Team: Decodable {
            let abbreviation: String?
            let displayName: String?
            let shortDisplayName: String?
            let name: String?
            let location: String?

            /// The other spellings — without the one that is already the display name,
            /// and without empty lines.
            var variants: [String] {
                [shortDisplayName, name, location, abbreviation]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty && $0 != displayName }
            }
        }
        struct Participant: Decodable {
            let homeAway: String?
            let team: Team?
        }
        struct Match: Decodable {
            let competitors: [Participant]?
        }
        struct Event: Decodable {
            let id: String
            let date: String
            let competitions: [Match]?
        }
        let leagues: [League]?
        let events: [Event]?
    }
}
