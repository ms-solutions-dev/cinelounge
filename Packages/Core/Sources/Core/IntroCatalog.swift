import Foundation

/// What the intro shows and when — **read from `intros.json`, not written into
/// the source** (AP51, 2026-09-24).
///
/// **Why the times live in a file.** Anyone who touches up a clip — renders it
/// brighter, swaps a figure — should change a number in a file and not have to
/// recompile. The file lies next to the clips in `App/Resources/Intro/` and is
/// fetched via `Bundle.main`; loading therefore belongs to the view, the computation here.
///
/// **All times refer to the start of the MP4 file**, not to `trimStart`.
/// What a computation needs in running time from the first picture shown is a
/// separate property on ``Clip`` — so that nobody does the subtraction
/// differently in two places.
///
/// **Lives in `Core` and is shared with the phone**, but purely additive: The phone
/// does not use it, and nothing existing depends on it.
public struct IntroCatalog: Codable, Sendable, Equatable {

    /// A spot in the picture, as a fraction of width and height (0 to 1).
    public struct Placement: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
    }

    /// A figure: its file and the points in time within it.
    public struct Clip: Codable, Sendable, Equatable, Identifiable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case file
            case bellAt
            case reactionAt
            case exitAt
            case trimStart
            case cardsAt
            case audio = "ton"
        }

        public let id: String
        /// The file name in the app bundle — **flat**, without subfolders: Xcode copies
        /// `App/Resources` without the folder structure.
        public let file: String
        /// Wann es klingelt.
        public let bellAt: Double
        /// When the figure reacts.
        public let reactionAt: Double
        /// When the figure is out of the picture on the right.
        public let exitAt: Double
        /// From where it plays. What lies before that is startup without content.
        public let trimStart: Double
        /// The **latest** time for the cards — a cap, not an appointment
        /// (concept, rule K). See ``cardsDeadline``.
        public let cardsAt: Double
        /// The sound for the ringing, as a file name in the bundle — **optional.** The clips are
        /// silent; with the raccoon the "ring ring" carries the punchline (AP51, decision 5),
        /// and the sound then comes exactly at ``bellAt``. Another figure gets it with
        /// a field in `intros.json`, without code.
        public let audio: String?

        /// The deadline for the cards **from the first picture shown**.
        ///
        /// `cardsAt` counts from the start of the file, playback starts at `trimStart`. Anyone who set the deadline
        /// without the subtraction would hold the cards back 1.1 s longer with the raccoon
        /// than the intro lasts — exactly the extension that must not exist.
        public var cardsDeadline: Double { max(0, cardsAt - trimStart) }

        /// When it rings, counted from the first picture shown.
        public var bellAfterStart: Double { max(0, bellAt - trimStart) }
    }

    /// The fallback still frame — for starts without a clip (stage 1).
    public let fallbackStill: String

    /// Where the ring sign stands: in the right third, on black.
    public let ringRingPosition: Placement

    /// The figures to draw from — **the default set.**
    public let clips: [Clip]

    /// A set for a period of the year — **replaceable via app update** (AP51,
    /// decision 4, 2026-09-25).
    ///
    /// **A new intro needs files and an entry, no code:** for example
    /// Christmas from 2026-12-20 to 2026-12-26 with its own clips. `from` and `until` are `MM-TT`
    /// and both include their day; if `until` lies before `from`, the period spans the
    /// turn of the year (New Year's Eve `12-31` to `01-01`).
    public struct Season: Codable, Sendable, Equatable, Identifiable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case from = "von"
            case until = "bis"
            case clips
        }

        public let id: String
        public let from: String
        public let until: String
        public let clips: [Clip]

        /// Month and day as one number, `MMTT` — `nil` for a value that is not a date.
        static func dayNumber(_ text: String) -> Int? {
            let split = text.split(separator: "-")
            guard split.count == 2, let month = Int(split[0]), let tag = Int(split[1]),
                (1...12).contains(month), (1...31).contains(tag)
            else { return nil }
            return month * 100 + tag
        }

        /// Whether the day falls into this period — **in the device's time zone**, because
        /// Christmas begins where the TV stands. An unreadable period never
        /// applies.
        ///
        /// **Computation is always Gregorian**, only the time zone comes from `calendar`
        /// (cross-check strand D, finding 3.1): `MM-TT` in `intros.json` is a
        /// Gregorian date. With a device's Islamic calendar, month and
        /// day would be different, and Christmas would never happen.
        public func applies(on datum: Date, calendar: Calendar) -> Bool {
            guard let start = Self.dayNumber(from), let end = Self.dayNumber(until) else {
                return false
            }
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let split = gregorian.dateComponents([.month, .day], from: datum)
            guard let month = split.month, let tag = split.day else { return false }
            let today = month * 100 + tag
            return start <= end
                ? (start...end).contains(today) : today >= start || today <= end
        }
    }

    /// The seasons, in the order of the file — **the first that applies wins.**
    /// If the field is missing, there is only the default set.
    ///
    /// **Read leniently** (cross-check strand D, finding 3.3): A broken entry —
    /// a typo in `from`, a missing field — drops out alone. Before, it threw away
    /// the reading of the whole file, and the TV had no intro at all any more.
    public let seasons: [Season]?

    /// The calendar with which the intro determines the day: **Gregorian, in the device's
    /// time zone** — see ``Season/applies(on:calendar:)``.
    public static var deviceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// An entry that cannot be read becomes `nil` instead of an error.
    private struct Lenient<Value: Decodable>: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case value = "wert"
        }

        let value: Value?
        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case fallbackStill, ringRingPosition, clips, seasons = "saisons"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fallbackStill = try values.decode(String.self, forKey: .fallbackStill)
        ringRingPosition = try values.decode(Placement.self, forKey: .ringRingPosition)
        clips = try values.decode([Clip].self, forKey: .clips)
        seasons = (try? values.decodeIfPresent([Lenient<Season>].self, forKey: .seasons))?
            .map { $0.compactMap(\.value) }
    }

    /// Reads the catalog from the bytes of `intros.json`.
    ///
    /// **Unknown fields are skipped** — the file carries a `hint` for
    /// humans, and the editing copy outside the repository has more fields than the bundle.
    public static func read(_ data: Data) throws -> IntroCatalog {
        try JSONDecoder().decode(IntroCatalog.self, from: data)
    }

    /// Draws a figure from the default set.
    ///
    /// **The randomness is passed in** and not rolled here: That way it can be
    /// verified that every figure can be drawn, without the test depending on
    /// luck. `nil` only for an empty list — then there is the still frame.
    public func select<Zufall: RandomNumberGenerator>(using random: inout Zufall) -> Clip? {
        clips.randomElement(using: &random)
    }

    /// The figures that apply **on this day**.
    ///
    /// **The first valid season, as far as its files are present** — otherwise the
    /// default set, likewise only with present files. An entry whose file
    /// is missing thus falls back quietly to the default, instead of leaving the start without an intro.
    ///
    /// - Parameter vorhanden: Whether a file is in the bundle — in the program
    ///   `Bundle.main.url(forResource:withExtension:) != nil`.
    public func clips(
        on datum: Date, calendar: Calendar, available: (String) -> Bool
    ) -> [Clip] {
        for saison in seasons ?? [] where saison.applies(on: datum, calendar: calendar) {
            let da = saison.clips.filter { available($0.file) }
            if !da.isEmpty { return da }
        }
        return clips.filter { available($0.file) }
    }

    /// Draws a figure from this day's set — see ``clips(on:calendar:available:)``.
    public func select<Zufall: RandomNumberGenerator>(
        on datum: Date, calendar: Calendar, available: (String) -> Bool,
        using random: inout Zufall
    ) -> Clip? {
        clips(on: datum, calendar: calendar, available: available).randomElement(using: &random)
    }

    /// The deadline for the **still frame** when no clip runs ("Reduce Motion",
    /// already played, no file).
    ///
    /// **The shortest card deadline of this day's figures** and no number of its own: A
    /// still frame has nothing to tell, it only covers the waiting time. It must therefore
    /// never stand longer than the shortest clip that could run today — otherwise the
    /// start without motion would be the slower one. **Today** (finding 3.4): On a day with a season
    /// its clips run, and the deadline follows them, not
    /// the default set. If no files are present, the default set counts without a file check.
    public func stillFrameDeadline(
        on datum: Date, calendar: Calendar, available: (String) -> Bool
    ) -> Double {
        let today = clips(on: datum, calendar: calendar, available: available)
        return (today.isEmpty ? clips : today).map(\.cardsDeadline).min() ?? 0
    }

    /// The deadline for the cap: that of the drawn clip, without a clip that of the still frame on
    /// this day.
    ///
    /// **One place for the choice**, so that the view does not assemble the deadline itself
    /// — and so that the test sees the same computation as the TV.
    public func deadline(
        forItem clip: Clip?, on datum: Date, calendar: Calendar, available: (String) -> Bool
    ) -> Double {
        clip?.cardsDeadline ?? stillFrameDeadline(on: datum, calendar: calendar, available: available)
    }
}
