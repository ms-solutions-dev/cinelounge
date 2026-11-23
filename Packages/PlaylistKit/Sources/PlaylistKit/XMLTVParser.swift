import Core
import Foundation

/// Reads a program guide in XMLTV format.
///
/// The structure is manageable:
///
/// ```xml
/// <tv>
///   <channel id=`ahorn.de`><display-name>Das Nordlicht</display-name></channel>
///   <programme start="20260728120000 +0200" stop="20260728133000 +0200" channel=`ahorn.de`>
///     <title lang="de">Tagesfunke</title>
///     <desc lang="de">Nachrichten</desc>
///   </programme>
/// </tv>
/// ```
///
/// **Reading is event-based (SAX), not as a tree.** An XMLTV file for
/// four hundred channels over a week easily has 50 MB and over a hundred thousand
/// entries. An `XMLDocument` of that would be a multiple of it in memory —
/// every element an object with children, attributes and back reference. On an
/// Apple TV, whose memory the app shares with the player, that is
/// not acceptable; the app would be terminated by the system. ``XMLParser`` reports
/// each element as it walks through instead, and only the one
/// entry currently being worked on is kept.
///
/// As with the M3U parser: **What can be read is read; what cannot
/// is skipped.** A single entry with a broken time value must not
/// prevent the program guide of four hundred channels. Even an
/// aborted download — no rarity at 50 MB — thus still yields everything
/// that was read up to the point of abort.
public enum XMLTVParser {

    // MARK: - Einlesen

    /// Parses a data stream without loading it completely into memory.
    ///
    /// This is the path for real files. ``XMLParser`` reads the stream
    /// in small bites; in memory there is never more than the buffer and the currently
    /// open entry.
    ///
    /// - Parameter channelIDs: If set, only entries of these channels are
    ///   kept. Everything else is discarded as soon as the `channel` attribute
    ///   has been read — title and description of the other channels are not even
    ///   assembled. Whoever subscribes to sixty of four hundred channels
    ///   thereby saves the bulk of the work.
    public static func parse(stream: InputStream, channelIDs: Set<String>? = nil) -> [Programme] {
        run(XMLParser(stream: stream), channelIDs: channelIDs)
    }

    /// Parses a file without loading it completely into memory.
    ///
    /// Returns nothing if the file cannot be opened. Throwing an error would be
    /// useless here: the caller can respond to a missing program guide
    /// only with an empty display anyway.
    public static func parse(fileURL: URL, channelIDs: Set<String>? = nil) -> [Programme] {
        guard let parser = XMLParser(contentsOf: fileURL) else { return [] }
        return run(parser, channelIDs: channelIDs)
    }

    /// Parses data that has already been loaded.
    ///
    /// Meant only for small amounts and for test cases — here the whole
    /// file is already in memory, and that is exactly what is to be avoided for real
    /// files. For those there is ``parse(fileURL:channelIDs:)``.
    public static func parse(data: Data, channelIDs: Set<String>? = nil) -> [Programme] {
        run(XMLParser(data: data), channelIDs: channelIDs)
    }

    /// Convenience for text, mainly in test cases.
    public static func parse(_ text: String, channelIDs: Set<String>? = nil) -> [Programme] {
        parse(data: Data(text.utf8), channelIDs: channelIDs)
    }

    /// Reads a file **in batches** without keeping it as a whole.
    ///
    /// **The path for the complete program guide** (roadmap P8.2):
    /// The checked provider's file is 75 MiB; as a dictionary in
    /// memory that would be several hundred megabytes of objects — on an
    /// Apple TV, which shares memory with the running picture, that is
    /// the sure way to being terminated. Here every ``batchSize`` entries are
    /// handed off and the buffer is emptied; whoever stores them never holds more than one
    /// batch.
    ///
    /// - Parameter onBatch: Called on the parser's thread. It may
    ///   take its time — the parser waits, and that is desired: otherwise
    ///   reading would run away from writing and memory would fill up after all.
    public static func parse(
        fileURL: URL,
        channelIDs: Set<String>? = nil,
        batchSize: Int = 500,
        onBatch: @escaping ([Programme]) -> Void
    ) {
        guard let parser = XMLParser(contentsOf: fileURL) else { return }
        let collector = ProgrammeCollector(
            channelIDs: channelIDs, batchSize: batchSize, onBatch: onBatch)
        parser.delegate = collector
        parser.parse()
        collector.flush()
    }

    private static func run(_ parser: XMLParser, channelIDs: Set<String>?) -> [Programme] {
        let collector = ProgrammeCollector(channelIDs: channelIDs)
        parser.delegate = collector

        // The return value is deliberately not checked. It is `false` as soon as the
        // document is malformed anywhere — for instance with an aborted
        // download. The entries read up to then are valid and
        // usable anyway; throwing them away would mean turning half a program into none
        // at all.
        parser.parse()

        return collector.programmes
    }

    // MARK: - Zeitangaben

    /// Converts an XMLTV time value like `20260728120000 +0200` into a
    /// point in time. Returns `nil` if the value cannot be interpreted.
    ///
    /// Deliberately a pure function without state: it is the only part of the
    /// parser with calculation logic, the errors arise here, and this way it can
    /// be tested on its own.
    ///
    /// The structure is fourteen digits `YYYYMMDDHHMMSS`, then optionally a
    /// time zone offset `+HHMM` or `-HHMM`, with or without a separating
    /// space, optionally with a colon. **If the offset is missing,
    /// UTC applies.** That is what the format prescribes, and it is also the only
    /// defensible assumption: assuming the device's local time would shift the
    /// entire program as soon as someone watches TV on vacation.
    ///
    /// The format does allow values shorter than fourteen digits, but in real
    /// files they do not occur. They are rejected here instead of being padded with
    /// zeros: a guessed time of day puts the program in the wrong
    /// place in the grid, and that is worse than a gap you can see.
    public static func date(from text: String) -> Date? {
        var digits: [Int] = []
        digits.reserveCapacity(14)
        var rest = Substring(text)

        // Leading spaces occur when the value comes from a wrapped
        // attribute.
        rest = rest.drop(while: \.isWhitespace)

        while digits.count < 14, let character = rest.first, character.isASCII,
            character.isNumber, let value = character.wholeNumberValue
        {
            digits.append(value)
            rest = rest.dropFirst()
        }
        guard digits.count == 14 else { return nil }

        func number(_ range: Range<Int>) -> Int {
            digits[range].reduce(0) { $0 * 10 + $1 }
        }

        let year = number(0..<4)
        let month = number(4..<6)
        let day = number(6..<8)
        let hour = number(8..<10)
        let minute = number(10..<12)
        let second = number(12..<14)

        guard (1...12).contains(month),
            (1...daysInMonth(month: month, year: year)).contains(day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            // A 60 in the seconds is a leap second. Rejecting it
            // would be petty; it simply counts as one more second.
            (0...60).contains(second)
        else { return nil }

        guard let offset = timeZoneOffset(in: rest) else { return nil }

        let days = daysSinceEpoch(year: year, month: month, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Reads the time zone offset in seconds from the rest after the digits.
    ///
    /// Returns `0` if nothing follows (UTC), and `nil` if something follows
    /// that is not an offset. Simply ignoring what is not understood would be
    /// dangerous here: `20260728120000 EST` would silently become UTC, and
    /// the program would be off by five hours.
    private static func timeZoneOffset(in text: Substring) -> Int? {
        var rest = text.drop(while: \.isWhitespace)
        guard let sign = rest.first else { return 0 }
        guard sign == "+" || sign == "-" else { return nil }
        rest = rest.dropFirst()

        // Some generators write `+02:00` instead of `+0200`. And trailing
        // spaces occur when the value comes from a wrapped attribute
        // — without removing them it would be six characters instead of four, and
        // the offset would count as unreadable.
        let raw = rest.trimmingCharacters(in: .whitespaces).filter { $0 != ":" }
        guard raw.count == 4, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let value = raw.reduce(0) { $0 * 10 + ($1.wholeNumberValue ?? 0) }
        let hours = value / 100
        let minutes = value % 100
        guard hours <= 14, minutes <= 59 else { return nil }

        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }

    /// Days from 1 January 1970 to the given date, also backwards.
    ///
    /// Computed instead of via ``Calendar``: With over a hundred thousand entries with
    /// two time values each, two hundred thousand calendar conversions arise, and they
    /// go through the time zone database and locale every time. The formula
    /// comes from Howard Hinnant's "chrono-Compatible Low-Level Date Algorithms"
    /// (`days_from_civil`) and holds for the entire Gregorian calendar.
    /// Its agreement with ``Calendar`` is recorded in the test cases.
    ///
    /// The trick: the year begins in March in the mind, so that the leap day slides to the
    /// end of the year and no longer needs a case distinction.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400  // 0…399
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // 0…365
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear  // 0…146096

        // 719468 is the distance from 1 March 0000 to 1 January 1970.
        return era * 146097 + dayOfEra - 719468
    }

    /// Length of the month. Necessary because a 30 February would otherwise silently become
    /// 2 March — the program would then be on the wrong day in the grid.
    private static func daysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: 0
        }
    }

    // MARK: - Titel in mehreren Sprachen

    /// Picks the matching one from multilingual titles or descriptions.
    ///
    /// German program guides often list the same entry bilingually.
    /// The order is German, then English, then the first one at all:
    /// The app is built for German-language use, English is the
    /// most common second language in such files, and a title in any
    /// language is still better than "untitled".
    ///
    /// Only the language part before the hyphen is compared, so that `de-DE` and
    /// `de-AT` count just like `de`.
    static func preferredText(from candidates: [(language: String?, text: String)]) -> String? {
        for wanted in ["de", "en"] {
            if let hit = candidates.first(where: { $0.language?.prefix(2).lowercased() == wanted }) {
                return hit.text
            }
        }
        return candidates.first?.text
    }
}

// MARK: - Der Sammler

/// Assembles the entries while walking through the document.
///
/// A class because ``XMLParserDelegate`` requires it. It is used only within
/// a single call and never passed across concurrency boundaries — which is why
/// it is deliberately **not** `Sendable`.
private final class ProgrammeCollector: NSObject, XMLParserDelegate {

    private(set) var programmes: [Programme] = []

    /// If set, everything outside this set is discarded immediately.
    private let channelIDs: Set<String>?

    /// Prevents duplicate identifiers. Merged program guides
    /// carry the same entry several times; two entries with the same identifier
    /// are shown by the display as one, and focus jumps while scrolling.
    private var seen: Set<String> = []

    // Zustand des gerade offenen Eintrags.
    private var channelID: String?
    private var start: Date?
    private var end: Date?
    private var titles: [(language: String?, text: String)] = []
    private var descriptions: [(language: String?, text: String)] = []

    /// Sprache des offenen Kindelements.
    private var currentLanguage: String?
    /// Text buffer of the open child element. ``XMLParser`` reports the text of an
    /// element in any number of pieces — it breaks at every entity like `&amp;` and at
    /// every buffer boundary. Whoever takes only the last piece loses
    /// everything before the ampersand in "Tifraidrim & Raukreis".
    private var buffer = ""
    private var capturing = false

    /// True as long as a `<programs>` is open whose content is needed.
    private var collecting = false

    /// How many entries are collected before they are handed off.
    /// Zero means: never hand off, keep everything (the old way).
    private let batchSize: Int
    private let onBatch: (([Programme]) -> Void)?

    init(
        channelIDs: Set<String>?,
        batchSize: Int = 0,
        onBatch: (([Programme]) -> Void)? = nil
    ) {
        self.channelIDs = channelIDs
        self.batchSize = batchSize
        self.onBatch = onBatch
    }

    /// Hands off what is still in the buffer — at the end of the document.
    func flush() {
        guard let onBatch, !programmes.isEmpty else { return }
        onBatch(programmes)
        programmes.removeAll(keepingCapacity: true)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "programme":
            reset()

            // All three values are in the attribute and can be checked immediately. If one of them is missing
            // or useless, the content is not even
            // collected — with a 50 MB file that noticeably saves work and is
            // at the same time how filtering works here.
            guard let id = attributes["channel"], !id.isEmpty,
                channelIDs?.contains(id) ?? true,
                let begin = XMLTVParser.date(from: attributes["start"] ?? ""),
                let stop = XMLTVParser.date(from: attributes["stop"] ?? ""),
                // An end before or at the start occurs in real files, mostly
                // through a wrongly set time zone offset. Such an
                // entry never runs and covers the correct one in the grid.
                stop > begin
            else { return }

            channelID = id
            start = begin
            end = stop
            collecting = true

        case "title", "desc":
            guard collecting else { return }
            currentLanguage = attributes["lang"]
            buffer = ""
            capturing = true

        default:
            // `category`, `icon`, `episode-num`, `credits` and the whole rest of the
            // format's scope are skipped: The model does not know them,
            // and collecting them would cost memory for every entry.
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "title", "desc":
            guard capturing else { return }
            capturing = false

            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            if elementName == "title" {
                titles.append((currentLanguage, text))
            } else {
                descriptions.append((currentLanguage, text))
            }

        case "programme":
            defer { reset() }
            guard collecting, let channelID, let start, let end,
                let title = XMLTVParser.preferredText(from: titles)
            else { return }

            // Identifier from channel, start time and title.
            //
            // **Why the title is part of it — on-device finding 2026-08-29, 18:06.**
            // Until today only channel and start time were here, justified
            // by the claim that two programs cannot start at the same time on one
            // channel. The checked provider does exactly that, and en masse:
            // In the guide of 2026-08-29. (30,157 rows), **898 rows** dropped
            // out at this spot, and only 94 of them carried the same
            // title as the one kept. The other 804 were real
            // programs — parallel assignments of the same channel.
            //
            // What that cost was noticed on the TV: On
            // `arenaspor1.tr` there were three entries at 2026-08-29, 19:00 local time
            // — "Ç.Bulutspor - Dumanspor", "Süper Lig Raporu" and
            // "T.Tarlaspor - Tepelispor". The first was kept, the third was
            // played. In the schedule the viewer saw a match
            // that was not running on this channel at all, and the running one was missing.
            // Measured with the same probe: The schedule thereby gains five
            // confirmed rows (14 → 19), and `arenaspor3.tr` goes from zero
            // to two.
            //
            // **The title in plain text, not its hash.** `hashValue`
            // was ruled out: Swift randomizes it per program run, so the identifier
            // would be a different one after every app start and the store would carry
            // the same program twice. A digest of our own (FNV) would be stable,
            // but plain text is too — and it costs only space that
            // the row with its title already carries anyway. In return the
            // version level 6 can update the old identifiers with a single
            // `UPDATE` instead of throwing the guide away and leaving the
            // viewer facing an empty area after the update.
            //
            // The identifier stays the same across several fetches as long as
            // channel, time and title are the same — so after an update the display
            // still does not rebuild everything.
            //
            // **What the provider still does not say with this:** If two
            // real matches stand at the same second on the same channel, nobody
            // knows which one is running. The schedule decides it via the
            // fixture source — a kickoff that ESPN knows beats a row
            // without evidence. The channel list cannot do that and still takes
            // the first; that is open and is in the ROADMAP.
            let id = "\(channelID)#\(Int(start.timeIntervalSince1970))#\(title)"
            guard seen.insert(id).inserted else { return }

            programmes.append(
                Programme(
                    id: id,
                    channelID: channelID,
                    title: title,
                    start: start,
                    end: end,
                    description: XMLTVParser.preferredText(from: descriptions)
                )
            )

            // Full? Then hand off and empty the buffer. The identifiers of the
            // entries already seen stay — they are the protection
            // against duplicates and weigh only a few characters per entry.
            if batchSize > 0, programmes.count >= batchSize { flush() }

        default:
            break
        }
    }

    private func reset() {
        channelID = nil
        start = nil
        end = nil
        titles.removeAll(keepingCapacity: true)
        descriptions.removeAll(keepingCapacity: true)
        currentLanguage = nil
        buffer = ""
        capturing = false
        collecting = false
    }
}
