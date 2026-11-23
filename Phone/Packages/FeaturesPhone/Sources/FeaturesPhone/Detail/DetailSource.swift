import Core
import Foundation

/// Where the detail page gets its information.
///
/// **Narrow like ``StartSource`` and for the same reason:** a protocol that only
/// demands what is needed can be rebuilt in a test with ten lines.
///
/// **The two marks are part of the contract although they fetch nothing.** Watched and
/// favorite are **set** from this page, and whoever set them via a second path
/// would have two truths about the same title: one in the model, one on the server.
/// That is exactly how the playback mark once went stale on the TV.
public protocol DetailSource: Sendable {

    func detailInfo(zu identifier: String) async throws -> DetailContent

    /// Sets or undoes the watched mark.
    func set(seen: Bool, forItem identifier: String) async throws

    /// Sets or undoes the favorite mark.
    func set(favorite: Bool, forItem identifier: String) async throws

    /// The address under which a trailer plays.
    ///
    /// `nil` means: there is none. That is the normal case and not an error — the
    /// media server carries trailers only where the metadata brings them.
    func previewURL(zu identifier: String) async throws -> URL?

    /// Removes a title from "Continue Watching" — only the position, as at Apple
    /// (``Core/ContentSource/removeFromContinueWatching(_:)``).
    func removeFromContinueWatching(_ identifier: String) async throws

    /// The series for a tile that does not carry it — see
    /// ``Core/ContentSource/seriesReference(zu:)``. On the phone for episodes that a provider
    /// carries as films ("Laitkrutbai Gezougros 5.Bölüm").
    func seriesReference(zu tile: TileContent) async -> String?
}

extension DetailSource {

    /// Without an answer of its own nothing happens — for sources that know no marks.
    ///
    /// A channel list and a portal keep no state per viewer; that is
    /// decision E5 and not a gap. Without these defaults every such source would have to
    /// carry two empty bodies along.
    public func set(seen: Bool, forItem identifier: String) async throws {}
    public func set(favorite: Bool, forItem identifier: String) async throws {}
    public func previewURL(zu identifier: String) async throws -> URL? { nil }
    public func removeFromContinueWatching(_ identifier: String) async throws {
        try await set(seen: false, forItem: identifier)
    }
    public func seriesReference(zu tile: TileContent) async -> String? { nil }
}

/// What is on the detail page.
///
/// **All at once and not in seven reloads.** The page is not a shelf that
/// grows while scrolling: whoever opens it has a title in mind and wants to see it whole.
/// What is added from **outside** — ratings, awards, voice actors, portraits — comes
/// separately and later; see ``DetailModel``.
public struct DetailContent: Sendable, Equatable {

    public let title: HeroContent

    /// Whether it is a series.
    ///
    /// **Remembered explicitly and not read off the season count.** A series whose
    /// episodes the server is currently not delivering has zero seasons — and would then look like
    /// a film, with "Play" instead of "no episodes found". That is exactly the
    /// difference that can no longer be recognized on screen.
    public let isSeries: Bool

    /// The episodes, bundled by season. Empty for a film.
    public let seasons: [Season]

    /// What the main button does — the **next** step and not "the title".
    public let next: TileContent?

    /// The sources of this title, for the sources sheet.
    public let sources: [SourceInfo]

    /// The audio tracks of the file — the second level of the sources sheet.
    public let audioTracks: [AudioTrackInfo]

    /// Who took part, in the server's order.
    public let cast: [PersonDetail]

    /// The chapter marks — only for films and only where the server has extracted them.
    public let chapters: [ChapterDetail]

    /// "Similar" from the catalog.
    public let similar: [TileContent]

    /// The parts of a collection, in release order.
    public let split: [TileContent]

    /// The fact list below the page.
    public let details: [Detail]

    /// The catalog's own trailer file with its audio language (AP78) — an ingredient for the
    /// ``Core/TrailerRule``, together with the TMDb videos from the ``RatingSource``.
    /// The address is only fetched when someone presses.
    public let trailerFile: TrailerFile?

    /// Whether the catalog carries a trailer file of its own.
    public var hasTrailer: Bool { trailerFile != nil }

    /// **How long the series lasts and how much is still outstanding** — the information the
    /// TV shows next to its grid (decision 27, C7). `nil` for films and where
    /// the server does not report episode count or runtime.
    public let watchDuration: WatchEstimate?

    /// The two marks — **mutable**, because this page sets them.
    public var seen: Bool
    public var favorite: Bool

    public init(
        title: HeroContent, isSeries: Bool = false, seasons: [Season] = [],
        next: TileContent? = nil, sources: [SourceInfo] = [],
        audioTracks: [AudioTrackInfo] = [],
        cast: [PersonDetail] = [], chapters: [ChapterDetail] = [],
        similar: [TileContent] = [], split: [TileContent] = [], details: [Detail] = [],
        trailerFile: TrailerFile? = nil, watchDuration: WatchEstimate? = nil
    ) {
        self.title = title
        self.isSeries = isSeries
        self.seasons = seasons
        self.next = next
        self.sources = sources
        self.audioTracks = audioTracks
        self.cast = cast
        self.chapters = chapters
        self.similar = similar
        self.split = split
        self.details = details
        self.trailerFile = trailerFile
        self.watchDuration = watchDuration
        self.seen = title.tile.seen
        self.favorite = title.tile.favorite
    }

    /// The same content with externally supplied data added afterwards.
    ///
    /// **Replaced and not supplemented**, as with the hero on the Home screen: the media
    /// server's number and the one from IMDb are both "the audience rating"; side by side
    /// there would be two numbers for the same thing that differ by a tenth.
    ///
    /// **The voices move into the cast and not next to it.** A second list with
    /// voice actors would be a second place for the same roles; here each person gets their
    /// voice, or none.
    public func using(_ info: ExternalInfo) -> DetailContent {
        var new = DetailContent(
            title: title.using(ratings: info.ratings).completed(um: info),
            isSeries: isSeries,
            seasons: seasons, next: next, sources: sources,
            audioTracks: audioTracks,
            // **The cast from TMDb, where the source carries none** (2026-09-29) — the same
            // row, the same taps to the career as with Jellyfin.
            cast: (cast.isEmpty ? info.cast : cast).map { person in
                var withVoice = person
                withVoice.voiceActor = info.voices.voice(forCharacter: person.characterName)?.name
                return withVoice
            },
            chapters: chapters, similar: similar, split: split, details: details,
            trailerFile: trailerFile, watchDuration: watchDuration)
        new.seen = seen
        new.favorite = favorite
        return new
    }

    /// The same cast with portraits fetched afterwards.
    public func using(portraits: [String: URL]) -> DetailContent {
        guard !portraits.isEmpty else { return self }
        var new = DetailContent(
            title: title, isSeries: isSeries, seasons: seasons, next: next,
            sources: sources, audioTracks: audioTracks,
            cast: cast.map { person in
                var withImage = person
                withImage.portrait = portraits[person.name]
                return withImage
            },
            chapters: chapters, similar: similar, split: split, details: details,
            trailerFile: trailerFile, watchDuration: watchDuration)
        new.seen = seen
        new.favorite = favorite
        return new
    }
}

/// A season with its episodes.
public struct Season: Sendable, Equatable, Identifiable {

    public let id: Int

    /// As the server names it — "Season 1", but also "Die Rückkehr".
    ///
    /// **Its name takes precedence over the computed number**, where it carries one: for
    /// anthology series a season is named after its subject, and "Season 3" would be
    /// less information there, not more.
    public let name: String?

    /// The story arc of this season.
    ///
    /// **Requirement of 2026-08-16:** each season represents an arc, so that one can read up on
    /// what it is about. Jellyfin carries it per season when the metadata
    /// has it; where not, the slot stays empty instead of showing a placeholder.
    public let description: String?

    public let episodes: [EpisodeInfo]

    public init(id: Int, name: String? = nil, description: String? = nil, episodes: [EpisodeInfo]) {
        self.id = id
        self.name = name
        self.description = description
        self.episodes = episodes
    }

    /// What the season is called in the picker.
    ///
    /// Season 0 is Jellyfin's collection point for special episodes — it is not called
    /// "Season 0", because nobody understands that.
    public var label: String {
        if let name, !name.isEmpty { return name }
        return id == 0
            ? AppLanguageSetting.text("season.specials")
            : AppLanguageSetting.text("season.number \(id)")
    }

    /// How many episodes are still open — for the number on the right in the season picker.
    public var pending: Int { episodes.filter { !$0.seen }.count }

    /// Whether the list shows description texts — **all or none.**
    ///
    /// **The finding of 2026-09-05, on screen** (*Krauklangram Mefobros*, season 1): One of
    /// twelve episodes carried a text, eleven did not. That one row was thus twice as
    /// tall as its neighbors, and the list looked as if something had gone wrong while
    /// loading — although every row was right on its own.
    ///
    /// The previous rule ("without a text the row looks the same, just shorter") was correct
    /// for **one** row and wrong for a **list**: in a list, equal height is
    /// the message that the entries are alike.
    ///
    /// **The rejected approach was to reserve the space.** Then there would be rows with an
    /// empty area where the others have text — the same unrest, just paid for more
    /// dearly. Here the information is dropped that only a twelfth of the episodes
    /// carries anyway; if they all carry one, it appears on all.
    public var showsDescriptions: Bool {
        !episodes.isEmpty && episodes.allSatisfy { $0.description != nil }
    }
}

/// An episode as it appears in the list.
///
/// **The description text is expressly optional.** 283 of 2,000 episodes of this
/// catalog have none — the row must look the same without it as with it, just
/// shorter. A placeholder text ("No description available") would be worse than the
/// gap: it fills the same height with information that gets nobody anywhere.
public struct EpisodeInfo: Sendable, Equatable, Identifiable {

    public let id: String
    public let number: Int?
    public let title: String
    public let description: String?
    public let image: URL?
    public let duration: TimeInterval?
    public let progress: Double?
    public var seen: Bool
    public var favorite: Bool

    public init(
        id: String, number: Int?, title: String, description: String? = nil,
        image: URL? = nil, duration: TimeInterval? = nil, progress: Double? = nil,
        seen: Bool = false, favorite: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.description = description
        self.image = image
        self.duration = duration
        self.progress = progress
        self.seen = seen
        self.favorite = favorite
    }
}

/// An audio track of the file.
///
/// **Language, channels, encoding — in that order.** Whoever switches the audio track
/// almost always looks for a language; "5.1" and "EAC3" are the distinction **within** a
/// language and therefore come after it. A title with "German 5.1" and "German stereo"
/// would be two identically labeled rows without them.
public struct AudioTrackInfo: Sendable, Equatable, Identifiable {

    public let id: String
    public let name: String
    /// Channels and encoding, where the server reports them.
    public let attributes: String?
    /// Whether the server carries it as the default.
    public let isDefault: Bool
    /// The language of the track as an ISO code — **for the per-title audio choice** (AP58 G1, A10):
    /// The language is remembered, not the track; the number only applies in this file.
    public let language: String?

    public init(
        id: String, name: String, attributes: String? = nil, isDefault: Bool = false,
        language: String? = nil
    ) {
        self.id = id
        self.name = name
        self.attributes = attributes
        self.isDefault = isDefault
        self.language = language
    }
}

/// A selectable version of a title.
///
/// **With its bitrate on every row.** "1080p" alone does not say whether it fits through the
/// line — and that is exactly the question you ask yourself on the go. The number
/// therefore appears alongside and not in a help text.
public struct SourceInfo: Sendable, Equatable, Identifiable {

    public let id: String
    public let name: String
    /// Bits per second. `nil` means "unknown" — the provider does not always say.
    public let bitrate: Int?
    public let isDirectlyPlayable: Bool

    public init(id: String, name: String, bitrate: Int? = nil, isDirectlyPlayable: Bool = true) {
        self.id = id
        self.name = name
        self.bitrate = bitrate
        self.isDirectlyPlayable = isDirectlyPlayable
    }

    /// "8.4 Mbit/s" — or nothing.
    public var bitrateText: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let mbit = Double(bitrate) / 1_000_000
        return AppLanguageSetting.text(
            "source.bitrate \(mbit.formatted(.number.precision(.fractionLength(1))))")
    }
}
