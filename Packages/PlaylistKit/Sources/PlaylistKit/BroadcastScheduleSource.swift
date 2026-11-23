import Core
import Foundation

/// Where the broadcast slots come from — **one source per country, one interface**.
///
/// **Why separate from the model** (``SportBroadcastPlan``): The rule for how a
/// broadcast slot belongs to a fixture and how its channel name meets the
/// channel list is the same everywhere. Only who provides the
/// information differs — and that will change: for Turkey a source has been
/// found and checked, for Germany on 2026-08-29 none (three candidates
/// looked at, none names the channel in a machine-readable way). A second source
/// should be pluggable without anything else changing.
public protocol BroadcastScheduleSource: Sendable {
    /// For which channel groups this source knows something — as an abbreviation of the
    /// guide identifiers (`tr`, `de`).
    var countries: Set<String> { get }
    /// Today's broadcast schedule.
    func broadcastSlots() async -> [SportBroadcastPlan.BroadcastSlot]
}

/// The Turkish source: `sporekrani.com`.
///
/// **What it can do.** It carries its whole daily schedule as
/// `schema.org` data in the page source — per broadcast channel name, pairing and
/// kickoff. Measured on 2026-08-29: 163 broadcasts, 75 of them with a channel. No
/// key, no login, and it maintains itself daily; a
/// channel→competition board by hand would be wrong after one season.
///
/// **What it cannot do, and that belongs here and not in a footnote:**
/// It delivers **only the current day**. The day tabs of the page
/// (`/home/day/YYYY-MM-DD`) are only loaded later in the browser; the server
/// answers every one of these addresses with today's schedule. Reproduced on 2026-08-29:
/// `/home/day/2026-08-30` and `/home/day/2026-08-31` both returned
/// the 163 entries of 2026-08-29. For the tabs "Tomorrow" and
/// "Day after tomorrow" it therefore stays with the guide and the channel board.
///
/// **And it is a web page, not an interface.** If it changes its form,
/// it fails — which is why it then stays silent instead of guessing: without a readable
/// data block an empty list comes back, and the schedule stays with what
/// it knew before.
public struct SporEkraniSource: BroadcastScheduleSource {

    public typealias Fetch = @Sendable (URL) async -> Data?

    public let countries: Set<String> = ["tr"]

    static let address = URL(string: "https://www.sporekrani.com/")!

    private let fetch: Fetch

    public init(session: URLSession = .shared) {
        fetch = { address in
            var request = URLRequest(url: address)
            // Without an identifier the page answers with a block page without a
            // data block. We present ourselves as a browser because we fetch exactly
            // what a browser would see there.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                forHTTPHeaderField: "User-Agent")
            guard let (bytes, reply) = try? await session.data(for: request),
                (reply as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return bytes
        }
    }

    /// For the test bench: the recording instead of the network.
    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func broadcastSlots() async -> [SportBroadcastPlan.BroadcastSlot] {
        guard let bytes = await fetch(Self.address) else { return [] }
        return Self.read(bytes)
    }

    /// Reads the page's response.
    ///
    /// **Two blocks, and both are needed.** The page carries its
    /// daily schedule twice in the source:
    ///
    /// * `window.__INITIAL_STATE__` names per broadcast **sport,
    ///   competition and kind** (match or show) — exactly what the first
    ///   version had to guess. On the TV, "Marovia – Talessa"
    ///   (volleyball) therefore appeared under football, and 88 shows ("Gol Saati",
    ///   "Maç Önü") stood between the matches.
    /// * The `schema.org` data additionally names the **end** of the
    ///   broadcast, which is missing from the state.
    ///
    /// The state leads, the end is added from the second block —
    /// merged via pairing and kickoff, which both blocks write the
    /// same way.
    static func read(_ bytes: Data) -> [SportBroadcastPlan.BroadcastSlot] {
        guard let page = String(data: bytes, encoding: .utf8) else { return [] }
        let endings = endTimes(from: page)
        return state(from: page).compactMap { $0.broadcastSlot(end: endings) }
    }

    /// The broadcasts from `window.__INITIAL_STATE__`.
    static func state(from page: String) -> [StateEntry] {
        guard let tag = page.range(of: "window.__INITIAL_STATE__"),
            let equal = page.range(of: "=", range: tag.upperBound..<page.endIndex)
        else { return [] }
        let rest = page[equal.upperBound...].drop(while: \.isWhitespace)
        guard let bytes = String(rest).data(using: .utf8),
            let state = try? JSONDecoder().decode(
                PlaybackPhase.self, from: untilEnd(bytes))
        else { return [] }
        return state.common.events
    }

    /// **`JSONDecoder` requires that nothing follows the object** —
    /// but in the page source the rest of the page follows. So here the
    /// closing brace is searched for, with a counter for the nesting
    /// and with regard to braces inside strings.
    static func untilEnd(_ bytes: Data) -> Data {
        var depth = 0
        var inText = false
        var masked = false
        for (location, character) in bytes.enumerated() {
            if masked { masked = false; continue }
            switch character {
            case UInt8(ascii: "\\") where inText: masked = true
            case UInt8(ascii: "\""): inText.toggle()
            case UInt8(ascii: "{") where !inText: depth += 1
            case UInt8(ascii: "}") where !inText:
                depth -= 1
                if depth == 0 { return bytes.prefix(location + 1) }
            default: break
            }
        }
        return bytes
    }

    /// The end times from the `schema.org` data, per pairing and kickoff.
    static func endTimes(from page: String) -> [String: Date] {
        guard let to = page.range(of: "application/ld+json"),
            let bracket = page.range(of: ">", range: to.upperBound..<page.endIndex),
            let closing = page.range(of: "</script>", range: bracket.upperBound..<page.endIndex),
            let bytes = String(page[bracket.upperBound..<closing.lowerBound]).data(using: .utf8),
            let entries = try? JSONDecoder().decode([SchemaEntry].self, from: bytes)
        else { return [:] }

        var found: [String: Date] = [:]
        for entry in entries {
            guard let match = entry.broadcastOfEvent, let name = match.name,
                let start = match.startDate.flatMap(datum(from:)),
                let end = match.endDate.flatMap(datum(from:))
            else { continue }
            found[key(name: name, kickoff: start)] = end
        }
        return found
    }

    static func key(name: String, kickoff: Date) -> String {
        "\(SportKind.normalized(name))#\(Int(kickoff.timeIntervalSince1970))"
    }

    /// The `schema.org` data stamps with a zone offset:
    /// "2026-08-29T19:00:00+03:00".
    static func datum(from stamp: String) -> Date? {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader.date(from: stamp)
    }

    /// The state stamps **without** a zone: "2026-08-29 21:30:00".
    ///
    /// What is meant is local time in Turkey. Without a fixed zone a device in
    /// Germany would read two hours off — and the reconciliation with the kickoff of
    /// the fixture source would match nothing anymore.
    static let localTimeZone = TimeZone(identifier: "Europe/Istanbul")!

    static func localDate(from stamp: String) -> Date? {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = localTimeZone
        reader.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return reader.date(from: stamp)
    }

    // MARK: - Die Form der Quelle

    struct PlaybackPhase: Decodable {
        struct Shared: Decodable { let events: [StateEntry] }
        let common: Shared
    }

    struct StateEntry: Decodable {
        struct Channel: Decodable {
            let name: String?
            let active: Int?
        }
        /// The names are those of the source, in our spelling — hence
        /// the ``CodingKeys`` below.
        let sportKind: String?
        let competition: String?
        let kind: String?
        let name: String?
        let timestamp: String?
        let home: String?
        let away: String?
        let channels: [Channel]?

        enum CodingKeys: String, CodingKey {
            case sportKind = "sport_name"
            case competition = "league_name"
            case kind = "event_type_name"
            case name
            case timestamp = "date_time"
            case home = "home_name"
            case away = "away_name"
            case channels
        }

        /// **Only matches, no shows.** The source lists both in
        /// the same list and tells them apart cleanly: `match` versus
        /// `commentary`. On 2026-08-29. **88** of 163 rows were shows —
        /// "Gol Saati", "Maç Önü", "Analiz Demirbahçe". Without this distinction
        /// they would stand between the matches, and §2 of the concept forbids
        /// exactly that.
        static let gameKind = "match"

        func broadcastSlot(end: [String: Date]) -> SportBroadcastPlan.BroadcastSlot? {
            guard kind == Self.gameKind,
                let name, !name.isEmpty,
                let stamp = timestamp,
                let kickoff = SporEkraniSource.localDate(from: stamp)
            else { return nil }

            let channelList = (channels ?? [])
                .filter { $0.active != 0 }
                .compactMap(\.name)
                .filter { !$0.isEmpty && !Self.isNotBroadcast($0) }
            guard !channelList.isEmpty else { return nil }

            return SportBroadcastPlan.BroadcastSlot(
                match: name,
                home: home,
                away: away,
                kickoff: kickoff,
                channels: channelList,
                end: end[SporEkraniSource.key(name: name, kickoff: kickoff)],
                sportKind: sportKind,
                competition: competition,
                land: "tr")
        }

        /// Whether the source says at this spot that there is **no** channel.
        ///
        /// It lists the fixture anyway and writes there what it
        /// knows: "Yayın Yok" (no broadcast) or "Yayıncı Belli Değil"
        /// (channel not yet known). Taking that over unfiltered would mean
        /// searching for a channel of that name.
        ///
        /// **One rule instead of a list of two words**, and the reason is in
        /// the find: The first version knew only "Yayın Yok" and let
        /// "Yayıncı Belli Değil" through — the test caught it. Both
        /// begin with "yayın", Turkish for "broadcast"; a channel name does not start
        /// that way.
        static func isNotBroadcast(_ name: String) -> Bool {
            let lowercased = name.lowercased()
            return lowercased.hasPrefix("yayın") || lowercased.hasPrefix("yayin")
        }
    }

    struct SchemaEntry: Decodable {
        struct Match: Decodable {
            let name: String?
            let startDate: String?
            let endDate: String?
        }
        let broadcastOfEvent: Match?
    }
}
