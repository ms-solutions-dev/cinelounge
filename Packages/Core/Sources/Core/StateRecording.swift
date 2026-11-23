import Foundation

/// The readable part of the ``StillLedger`` — **the answer, without walking
/// through the journal.**
///
/// Every tile on Home asks here: how far along is the film, is the channel a
/// favourite, where did I last watch TV. Answering this from an event list
/// would mean walking five hundred entries on every draw.
public struct StateRecording: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case lastChannel = "letzterSender"
        case titlePositions = "titelstellen"
        case channelFavorites = "senderfavoriten"
        case groupOrder = "gruppenreihenfolge"
        case hiddenGroups = "ausgeblendeteGruppen"
    }

    /// List key → last watched channel. **The empty key is "last overall"** and
    /// the answer for a press on "Live" without a chosen list.
    public var lastChannel: [String: String]

    /// Title ID → state. Carries films, episodes and recalled programmes.
    public var titlePositions: [String: TitlePosition]

    /// The channels' favourite keys. **A sorted list and not a set**, so that two
    /// equal states look equal as a file — ``RecordSheet`` sorts only the field
    /// names, not the values.
    public var channelFavorites: [String]

    /// The channel groups in the chosen order. **Empty means "as the provider
    /// delivers".**
    public var groupOrder: [String]

    /// The groups that should not appear.
    public var hiddenGroups: [String]

    public init(
        lastChannel: [String: String] = [:],
        titlePositions: [String: TitlePosition] = [:],
        channelFavorites: [String] = [],
        groupOrder: [String] = [],
        hiddenGroups: [String] = []
    ) {
        self.lastChannel = lastChannel
        self.titlePositions = titlePositions
        self.channelFavorites = channelFavorites
        self.groupOrder = groupOrder
        self.hiddenGroups = hiddenGroups
    }

    /// **Jedes Feld darf fehlen** — siehe ``StillLedger/init(from:)``.
    public init(from decoder: any Decoder) throws {
        let bucket = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] {
            try bucket.decodeIfPresent([String].self, forKey: key) ?? []
        }
        self.init(
            lastChannel: try bucket.decodeIfPresent([String: String].self, forKey: .lastChannel)
                ?? [:],
            titlePositions: try bucket.decodeIfPresent([String: TitlePosition].self, forKey: .titlePositions)
                ?? [:],
            channelFavorites: try list(.channelFavorites),
            groupOrder: try list(.groupOrder),
            hiddenGroups: try list(.hiddenGroups))
    }

    // MARK: - Ein Ereignis anwenden

    /// Writes an event into the state.
    ///
    /// **The only way in**, so that state and journal cannot drift apart:
    /// ``StillLedger/record(_:on:)`` calls exactly this and appends the same event to
    /// the outbox. Two write paths would inevitably have one that forgets the
    /// journal.
    mutating func apply(_ event: StillEvent, on timestamp: Date) {
        switch event {
        case .senderGewaehlt(let list, let channels):
            lastChannel[list] = channels
            // **Additionally as "last overall"** — the idea from ``LiveMemory``, and for
            // the same reason: whoever selects "Live" without a list should continue
            // where they were, regardless of which list that was in.
            if !list.isEmpty { lastChannel[""] = channels }

        case .titlePosition(let title, let location, let duration):
            update(title, on: timestamp) { state in
                // **The first ten seconds do not count.** Whoever looks in and leaves again
                // has not started anything — the same threshold as in the previous store,
                // see ``PlaylistKit/VODMemory``.
                state.location = location > 10 ? location : nil
                if let duration, duration > 0 { state.duration = duration }
            }

        case .seen(let title, let note):
            update(title, on: timestamp) { state in
                state.seen = note
                // **The unwatched mark also resets the position** — as with Jellyfin, and
                // there is no separate path for it. Whoever says "not yet watched" wants the
                // title from the beginning, not from minute 40.
                //
                // The other way round the position stays: a title ticked off drops out of
                // "Continue Watching" because that filters on ``seen`` — deleting the
                // position for that would also take it from whoever opens it again.
                if !note { state.location = nil }
            }

        case .titelfavorit(let title, let tag):
            update(title, on: timestamp) { $0.favorite = tag }

        case .senderfavorit(let key, let tag):
            var isSet = Set(channelFavorites)
            if tag { isSet.insert(key) } else { isSet.remove(key) }
            channelFavorites = isSet.sorted()

        case .senderreihenfolge(let groups, let hidden):
            groupOrder = groups
            hiddenGroups = hidden

        case .profileCard(let title, let name, let kind, let image, let series):
            // **The profile card creates no entry.** Otherwise this store would collect
            // an entry for every title that ever passed through a list — with 27,558
            // films that is no longer a dictionary. The finding is at
            // ``PlaylistKit/VODMemory``.
            guard titlePositions[title] != nil else { return }
            update(title, on: nil) { state in
                state.title = name
                state.kind = kind
                state.image = image
                // A profile card without a series (from a film list) deletes no remembered
                // one.
                if let series { state.series = series }
            }
        }
    }

    /// - Parameter zeitpunkt: `nil` leaves ``TitlePosition/recent`` alone. The
    ///   profile card is no action of the viewer and must not shuffle the order of
    ///   "Continue Watching".
    private mutating func update(
        _ title: String, on timestamp: Date?, _ change: (inout TitlePosition) -> Void
    ) {
        var state = titlePositions[title] ?? TitlePosition()
        change(&state)
        if let timestamp { state.recent = timestamp }
        // **An empty entry is deleted and not stored.** It says the same as none and
        // would keep the store full of titles with nothing left on them.
        if state.isEmpty {
            titlePositions.removeValue(forKey: title)
        } else {
            titlePositions[title] = state
        }
    }

    // MARK: - Der Stand eines Titels

    /// How far a title has been watched — and what is on its tile.
    ///
    /// **The fields of ``PlaylistKit/VODMemory/Entry``, taken over unchanged.**
    /// They grew over a year on real catalogs; reinventing them here would mean
    /// making the same findings a second time. The only difference is who owns the
    /// dictionary: before, the device; now, the person.
    public struct TitlePosition: Codable, Sendable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case location = "stelle"
            case duration = "dauer"
            case seen = "gesehen"
            case favorite = "favorit"
            case title = "titel"
            case kind = "art"
            case image = "bild"
            case series = "serie"
            case recent = "zuletzt"
        }

        public var location: TimeInterval?
        public var duration: TimeInterval?
        public var seen: Bool
        public var favorite: Bool

        /// The profile card: name, kind and poster — **what a tile needs when no list
        /// is behind it.**
        public var title: String?
        public var kind: MediaItem.Kind?
        public var image: String?

        /// The series this title belongs to — the ID of its detail page (2026-10-01).
        ///
        /// **An Xtream episode cannot be fetched individually**
        /// (``PlaylistKit/XtreamVODSource`` throws on `.episode`); its tile in
        /// "Continue Watching" arises solely from this profile card. Without the
        /// series in it, "Details" led to a page with exactly this episode instead of
        /// to the series with seasons and cast.
        public var series: String?

        /// When something last happened to this title — the order of "Continue
        /// Watching".
        public var recent: Date?

        public init(
            location: TimeInterval? = nil, duration: TimeInterval? = nil,
            seen: Bool = false, favorite: Bool = false,
            title: String? = nil, kind: MediaItem.Kind? = nil, image: String? = nil,
            series: String? = nil, recent: Date? = nil
        ) {
            self.location = location
            self.duration = duration
            self.seen = seen
            self.favorite = favorite
            self.title = title
            self.kind = kind
            self.image = image
            self.series = series
            self.recent = recent
        }

        /// **The profile card alone does not keep an entry alive** — see
        /// ``apply(_:on:)``.
        public var isEmpty: Bool {
            location == nil && !seen && !favorite
        }
    }
}
