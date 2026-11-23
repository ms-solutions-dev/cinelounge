import Core
import Foundation

/// The response shapes of the Xtream protocol and their conversion into our models.
///
/// Kept apart from network access so that everything here can be **checked offline**.
/// And that is necessary: nothing pins this interface down, every provider
/// deviates a little, and the deviations are always the same —
/// numbers as text, missing fields, empty strings instead of `null`.
public enum XtreamPayload {

    /// A decoder that also accepts numbers as text.
    ///
    /// The reason is the most common deviation of all: `"stream_id": 123`
    /// at one provider, `"stream_id": "123"` at the next. Without this leniency
    /// the whole response fails on a single field — and the channel list stays empty
    /// although everything is there.
    public static let decoder = JSONDecoder()

    // MARK: - Sparten

    public struct Category: Decodable, Sendable {
        public let categoryID: String?
        public let categoryName: String?

        enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case categoryName = "category_name"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.categoryID = try container.decodeFlexibleString(.categoryID)
            self.categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        }
    }

    // MARK: - Sender

    public struct LiveStream: Decodable, Sendable {
        public let streamID: Int?
        public let name: String?
        public let streamIcon: String?
        public let epgChannelID: String?
        public let categoryID: String?
        public let number: Int?

        /// Kennzeichnung des Anbieters. 294 von 5389 Sendern tragen sie.
        public let isAdult: Bool

        /// `1` if the channel offers catch-up.
        ///
        /// Kept separate from ``tvArchiveDuration`` and not combined with it:
        /// 51 channels in the test catalog report `tv_archive: 1` with
        /// `tv_archive_duration: "3"`, all the others `0` and `0`. Some providers
        /// enter a duration without having enabled catch-up —
        /// in that case the UI must not offer it.
        public let tvArchive: Int?

        /// Catch-up in **days**, not hours.
        ///
        /// The test catalog reports the value as the string `"3"`, where the same field
        /// is the number `0` for channels without catch-up — both in the same
        /// response. Without lenient reading the whole channel list would fail here.
        public let tvArchiveDuration: Int?

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case name
            case streamIcon = "stream_icon"
            case epgChannelID = "epg_channel_id"
            case categoryID = "category_id"
            case number = "num"
            case isAdult = "is_adult"
            case tvArchive = "tv_archive"
            case tvArchiveDuration = "tv_archive_duration"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.streamID = try container.decodeFlexibleInt(.streamID)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
            self.streamIcon = try container.decodeIfPresent(String.self, forKey: .streamIcon)
            self.epgChannelID = try container.decodeIfPresent(String.self, forKey: .epgChannelID)
            self.categoryID = try container.decodeFlexibleString(.categoryID)
            self.number = try container.decodeFlexibleInt(.number)
            // If the field is missing, the channel counts as harmless. The opposite
            // assumption would be worse than wrong: with a provider that lacks this
            // field, the whole list would disappear behind the switch.
            self.isAdult = (try container.decodeFlexibleInt(.isAdult) ?? 0) == 1
            self.tvArchive = try container.decodeFlexibleInt(.tvArchive)
            self.tvArchiveDuration = try container.decodeFlexibleInt(.tvArchiveDuration)
        }

        /// How many days of catch-up the channel offers, or `nil`.
        ///
        /// Both conditions must hold: without `tv_archive == 1` catch-up is not
        /// enabled, and a duration of `0` days is none.
        public var archiveDays: Int? {
            guard tvArchive == 1, let days = tvArchiveDuration, days > 0 else { return nil }
            return days
        }
    }

    /// Turns a reported channel into a ``Channel``.
    ///
    /// Returns `nil` if something essential is missing — a channel without an ID or
    /// without a name could be neither played nor found. It is skipped
    /// individually; the list stays.
    ///
    /// **Also `nil` for group headings.** 113 of the 5389 entries in the
    /// test catalog are not channels at all but separator rows of the form
    /// `##### SOLA HEVC #####`. They carry an ID and an address like any channel and
    /// deliver nothing: anyone who selects one sees a black picture with no explanation
    /// and looks for the fault on their own side. They are recognised via
    /// ``ChannelName/isSectionMarker(_:)``, whose rule is checked against all 113
    /// occurrences. Their text is not worthless — see ``sectionTitles(in:)`` —,
    /// but it does not become a channel.
    public static func channel(
        from stream: LiveStream,
        categories: [String: String],
        playlistID: String,
        credentials: XtreamEndpoint
    ) -> Channel? {
        guard let streamID = stream.streamID,
            let name = stream.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
            !ChannelName.isSectionMarker(name),
            // **As an HLS list, not as a raw TS stream** (roadmap P8, "the
            // engine question"): every Xtream provider delivers the same channel under
            // both extensions. The native engine plays the `.m3u8` variant —
            // with the system bar, clean overlays and without VLC's second
            // memory budget. The raw stream stays with the M3U world.
            let url = credentials.liveStreamURL(streamID: streamID, extension: "m3u8")
        else { return nil }

        // The ID carries the provider's number, not a running count:
        // that keeps it the same across a reload, and favourites
        // are not lost when the provider changes the order.
        return Channel(
            id: channelID(playlistID: playlistID, streamID: streamID),
            name: name,
            streamURL: url,
            playlistID: playlistID,
            group: stream.categoryID.flatMap { categories[$0] },
            logoURL: stream.streamIcon.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            epgID: stream.epgChannelID.flatMap { $0.isEmpty ? nil : $0 },
            isAdult: stream.isAdult,
            archiveDays: stream.archiveDays
        )
    }

    /// The texts of the group headings in list order.
    ///
    /// **What is useful about them:** the heading names the section that
    /// follows it, and in a measured catalog nearly half of them name a
    /// subdivision that appears in no category. Typical is a large sports
    /// category with hundreds of channels whose only grouping by country is a
    /// run of such rows — `##### UNITED KINGDOM ᴿᴬᵂ #####`,
    /// `##### SINGAPORE ᴿᴬᵂ #####`. Without them the viewer faces hundreds of
    /// channels in one row.
    ///
    /// The others repeat the category name without its country code
    /// (`MOVIES HEVC` in the category `DE| MOVIES HEVC`) and are therefore
    /// dispensable.
    ///
    /// Delivered, not applied: whether they become intermediate rows in the channel
    /// list is up to the UI. This only states what is there.
    public static func sectionTitles(in streams: [LiveStream]) -> [String] {
        streams.compactMap { stream in
            guard let name = stream.name?.trimmingCharacters(in: .whitespaces),
                ChannelName.isSectionMarker(name)
            else { return nil }
            let text = ChannelName.display(name)
            return text.isEmpty ? nil : text
        }
    }

    /// ID of a channel: list and provider number.
    public static func channelID(playlistID: String, streamID: Int) -> String {
        "\(playlistID)#xtream#\(streamID)"
    }

    /// Reads the provider's number back out of a channel ID.
    ///
    /// Needed for the programme query, which asks for the number and not for
    /// our ID.
    public static func streamID(fromChannelID id: String) -> Int? {
        guard let last = id.split(separator: "#").last else { return nil }
        return Int(last)
    }

    // MARK: - Anmeldung

    public struct LoginResponse: Decodable, Sendable {
        public let userInfo: AccountInfo?

        enum CodingKeys: String, CodingKey {
            case userInfo = "user_info"
        }
    }

    public struct AccountInfo: Decodable, Sendable, Equatable {
        /// 1 means accepted. Some providers send it as text.
        public let auth: Int?
        public let status: String?
        /// When the account expires, as seconds since 1970 — and as text.
        public let expiryDate: Date?
        public let maxConnections: Int?
        public let activeConnections: Int?

        /// Which extensions this account actually supports — `["ts"]`, `["m3u8","ts"]`.
        ///
        /// **The finding from 2026-09-06, seen on the phone:** the Live area showed
        /// "The one connection is busy" for every channel — with `active_cons: 0`. Nothing
        /// was busy. This household's provider allows **only `ts`** and answers
        /// every `.m3u8` address with **407**; but the app builds every channel address as
        /// `.m3u8` (see ``XtreamPayload/channel(from:categories:playlistID:credentials:)``,
        /// verbatim: *"every Xtream provider delivers the same channel under both
        /// extensions"*). That assumption is wrong for this account.
        ///
        /// **The panel says so on its own**, which is better than any learned
        /// rule: `RawStreamMemory` and `RawStreamRule` on the TV learn the same thing only
        /// from failures — eight seconds of black each and one connection against an
        /// account that allows **one**.
        ///
        /// **If the field is missing, nothing is contradicted.** A provider that does not
        /// send it should not suddenly count as "cannot do m3u8".
        public let allowedOutputFormats: [String]?

        /// Ob dieser Zugang HLS-Listen hergibt.
        ///
        /// `true`, solange nichts dagegen spricht — siehe oben.
        public var allowsHLS: Bool {
            guard let allowedOutputFormats, !allowedOutputFormats.isEmpty else { return true }
            return allowedOutputFormats.contains { $0.lowercased() == "m3u8" }
        }

        /// Whether the account was accepted.
        ///
        /// **The status code alone does not say.** The server answers with 200 and a
        /// well-formed body even for a wrong password; only this field
        /// tells them apart. Judging by the status code takes a rejected
        /// account for a set-up one — the Live area stays empty, and that cannot be
        /// told apart from a provider with no channels.
        ///
        /// This explicitly covers only the **login**. Whether the account is also still
        /// valid is a second question: ``isActive``. Mixing the two
        /// would give an expired account the same message as a
        /// mistyped password — and the user would then look in the wrong place.
        public var isAuthorized: Bool { auth == 1 }

        /// Whether the account still works beyond the login.
        ///
        /// An expired account keeps logging in successfully and delivers
        /// nothing. If the field is missing, nothing is contradicted — some providers
        /// do not send it, and demanding an "Active" that does not exist
        /// would reject a working account.
        public var isActive: Bool {
            guard let status, !status.isEmpty else { return true }
            return status.compare("Active", options: .caseInsensitive) == .orderedSame
        }

        enum CodingKeys: String, CodingKey {
            case auth
            case status
            case expiryDate = "exp_date"
            case maxConnections = "max_connections"
            case activeConnections = "active_cons"
            case allowedOutputFormats = "allowed_output_formats"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.auth = try container.decodeFlexibleInt(.auth)
            self.status = try container.decodeIfPresent(String.self, forKey: .status)
            self.maxConnections = try container.decodeFlexibleInt(.maxConnections)
            self.activeConnections = try container.decodeFlexibleInt(.activeConnections)
            self.allowedOutputFormats = try container.decodeIfPresent(
                [String].self, forKey: .allowedOutputFormats)

            // An empty field means "does not expire" and is not an error.
            if let seconds = try container.decodeFlexibleInt(.expiryDate) {
                self.expiryDate = Date(timeIntervalSince1970: Double(seconds))
            } else {
                self.expiryDate = nil
            }
        }

        /// How many streams are allowed at the same time.
        ///
        /// For the user the most important detail of the whole account: it decides
        /// whether two TVs can run at the same time.
        public var hasRoomForAnotherStream: Bool {
            guard let maxConnections else { return true }
            return (activeConnections ?? 0) < maxConnections
        }
    }

    // MARK: - Programmzeitschrift

    public struct EPGResponse: Decodable, Sendable {
        public let epgListings: [EPGEntry]?

        enum CodingKeys: String, CodingKey {
            case epgListings = "epg_listings"
        }
    }

    public struct EPGEntry: Decodable, Sendable {
        public let id: String?
        /// In Grundzeichen kodiert — siehe ``XtreamPayload/decodeTitle(_:)``.
        public let title: String?
        public let description: String?
        public let start: String?
        public let end: String?

        /// Start as seconds since 1970 — the unambiguous one of the two values.
        ///
        /// Rationale at ``time(stamp:text:)``.
        public let startTimestamp: Int?
        public let stopTimestamp: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case description = "description"
            case start
            case end
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeFlexibleString(.id)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.start = try container.decodeIfPresent(String.self, forKey: .start)
            self.end = try container.decodeIfPresent(String.self, forKey: .end)
            // They come as strings in the test catalog — `"start_timestamp":
            // "1785248700"`. Other providers send numbers.
            self.startTimestamp = try container.decodeFlexibleInt(.startTimestamp)
            self.stopTimestamp = try container.decodeFlexibleInt(.stopTimestamp)
        }
    }

    /// Turns the entries of **one** response into ``Programme``s.
    ///
    /// The route goes via the whole response and not via the single entry, and the
    /// reason is the encoding: whether a provider sends its titles in base encoding
    /// is decided per response and not per row. Measurement and
    /// rationale at ``isEncoded(_:)``.
    public static func programmes(from entries: [EPGEntry], channelID: String) -> [Programme] {
        let encoded = isEncoded(entries)
        return entries.compactMap { programs(from: $0, channelID: channelID, isEncoded: encoded) }
    }

    /// A single entry, with no knowledge of the others.
    ///
    /// Only for the case that really just one is available. The encoding must then
    /// be inferred from that one text, which works worse —
    /// that is why the fetch goes through ``programmes(from:channelID:)``.
    public static func programs(from entry: EPGEntry, channelID: String) -> Programme? {
        programs(from: entry, channelID: channelID, isEncoded: isEncoded([entry]))
    }

    static func programs(
        from entry: EPGEntry,
        channelID: String,
        isEncoded encoded: Bool
    ) -> Programme? {
        guard let start = time(stamp: entry.startTimestamp, text: entry.start),
            let end = time(stamp: entry.stopTimestamp, text: entry.end),
            // An end before the start occurs in real responses. Such an
            // entry would confuse the display.
            end > start,
            let title = text(entry.title, isEncoded: encoded), !title.isEmpty
        else { return nil }

        return Programme(
            id: entry.id ?? "\(channelID)#\(start.timeIntervalSince1970)",
            channelID: channelID,
            title: title,
            start: start,
            end: end,
            description: text(entry.description, isEncoded: encoded)
        )
    }

    /// The time of a broadcast, from the timestamp and only as a fallback from
    /// the string.
    ///
    /// **Xtream delivers every time twice, and only one of the two is unambiguous.**
    /// This is how it appears in the recording:
    ///
    /// ```
    /// "start":           "2026-07-28 14:25:00"
    /// "start_timestamp": "1785248700"
    /// ```
    ///
    /// The string carries no time zone. Read as UTC it yields
    /// 1785248700 — exactly the supplied timestamp; the two values
    /// agree as soon as UTC is assumed. Read as German local time
    /// (CEST, UTC+2) it would yield 1785241500 and thus be **two hours early**: the
    /// broadcast that starts at 16:25 local time would appear in the list as "running since 14:25",
    /// and the current programme would be wrong throughout.
    ///
    /// That is why the timestamp takes precedence: it needs no assumption. The
    /// string remains as a fallback for providers that do not send it.
    static func time(stamp: Int?, text: String?) -> Date? {
        // The test catalog carries `0` for channels without a programme; that is not
        // 1 January 1970 but "no value".
        if let stamp, stamp > 0 { return Date(timeIntervalSince1970: Double(stamp)) }
        return date(fromXtream: text)
    }

    /// Times come as `2026-07-28 12:00:00`, in the server's time zone.
    ///
    /// With no time zone given — so UTC is assumed. Recomputed against real values,
    /// see ``time(stamp:text:)``: with the test provider this
    /// assumption matches the timestamp to the second.
    static func date(fromXtream text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return xtreamFormatter.date(from: text)
    }

    /// Whether the texts **of this response** are base-encoded.
    ///
    /// Titles and descriptions come base-encoded in Xtream: without reversing it,
    /// the programme shows `QWJlbmRqb3VybmFs` instead of "Abendjournal". Some providers
    /// send them as plain text, though.
    ///
    /// **Why the response and not the single row decides** — this is where the
    /// real bug was: an ordinary title can by itself be valid
    /// base encoding. `Morgen24` is eight characters long, uses only characters of the
    /// base alphabet and can therefore be "reversed" — what comes out is four
    /// random bytes. If those happen to be valid UTF-8, the programme would show
    /// gibberish instead of the show name, and only for individual titles.
    /// Such a bug is practically impossible to find.
    ///
    /// Looked at across the whole response, the problem disappears: with an
    /// encoding provider **all** titles are reversible, with another almost
    /// none. A single random hit does not tip the majority.
    static func isEncoded(_ entries: [EPGEntry]) -> Bool {
        let titles = entries.compactMap(\.title).filter { !$0.isEmpty }
        guard !titles.isEmpty else { return false }

        let decodable = titles.count { looksEncoded($0) }

        // Two thirds as the threshold, and the direction of the doubt is deliberate: whoever
        // does not reverse when in doubt shows `QWJlbmRqb3VybmFs` at worst —
        // visibly wrong, explained in one sentence. Whoever reverses when in doubt shows
        // gibberish, and nobody finds the cause.
        return decodable * 3 >= titles.count * 2
    }

    /// Whether a single text looks like base encoding.
    ///
    /// Deliberately strict. The length must be divisible by four, only characters
    /// of the base alphabet may appear, and the result must be valid UTF-8 with
    /// at least one letter. Without the last condition every byte sequence
    /// that happens to be readable would count.
    static func looksEncoded(_ text: String) -> Bool {
        guard text.count % 4 == 0,
            let data = Data(base64Encoded: text),
            let decoded = String(data: data, encoding: .utf8),
            decoded.contains(where: \.isLetter)
        else { return false }

        return true
    }

    /// The text of a field, reversed or unchanged.
    ///
    /// `isEncoded` comes from outside and is not determined here — the decision
    /// belongs to the whole response, see ``isEncoded(_:)``.
    static func text(_ raw: String?, isEncoded encoded: Bool) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard encoded else { return raw }

        guard let data = Data(base64Encoded: raw),
            let decoded = String(data: data, encoding: .utf8),
            !decoded.isEmpty
        else {
            // The response counts as encoded, but this field cannot be
            // reversed. Then the raw text stands — better than nothing, and you see
            // at once that something is wrong.
            return raw
        }

        return decoded
    }

    /// Built once and only read afterwards.
    ///
    /// Without `nonisolated(unsafe)`: the SDK now declares `DateFormatter` as
    /// `Sendable`, and the annotation produces a warning. The formatter is not
    /// mutated here anyway — otherwise it could not be shared.
    static let xtreamFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Nachsicht beim Lesen

extension KeyedDecodingContainer {

    /// Reads a number that may also come as text.
    ///
    /// The most common deviation between providers. Without this leniency
    /// the whole response fails on a single field.
    func decodeFlexibleInt(_ key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Reads a text that may also come as a number — the reverse case.
    func decodeFlexibleString(_ key: Key) throws -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return text.isEmpty ? nil : text
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }
}
