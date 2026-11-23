import Core
import DesignSystemPhone
import Foundation

/// What lies in a catalog — a **hint**, not an identifier.
///
/// **Why open and not `Core.Library.Kind`.** The shared type has seven cases (`movies`,
/// `series`, `homeVideos`, `music`, `liveTV`, `mixed`, `portalLevel`), and **two of the six
/// libraries on the test server fit none of them**: Collections and folders both fall onto
/// `.mixed` and can no longer be told apart afterwards. An enumeration type in the
/// neighbouring directory that would have to be extended for every new library kind is the
/// wrong boundary — the phone should be able to show an unknown kind without knowing it.
///
/// **The hint carries rules, not identity.** A shelf asks "is this music" (then it gets
/// none, since album covers are 1 : 1); nobody asks "is this *the* film library". Whoever
/// wants to recognise a catalog again uses its identifier.
public struct Genre: Sendable, Hashable, Codable, RawRepresentable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let movies = Genre(rawValue: "movies")
    public static let allSeries = Genre(rawValue: "series")
    public static let homeVideos = Genre(rawValue: "homeVideos")
    public static let music = Genre(rawValue: "music")
    public static let isCollection = Genre(rawValue: "boxsets")
    public static let directory = Genre(rawValue: "folders")
    public static let live = Genre(rawValue: "liveTV")
    public static let sport = Genre(rawValue: "sport")
    public static let portalLevel = Genre(rawValue: "portalLevel")
    public static let unknown = Genre(rawValue: "unknown")

    /// From what the shared set knows.
    ///
    /// Collections and folders both arrive as `.mixed` — the derivation ends here, and the
    /// finer information has to come from the source itself (Jellyfin names it in the
    /// `CollectionType`). Whoever gets `.mixed` only knows that mixed content lies inside.
    public init(_ kind: Core.Library.Kind) {
        switch kind {
        case .movies: self = .movies
        case .series: self = .allSeries
        case .homeVideos: self = .homeVideos
        case .music: self = .music
        case .liveTV: self = .live
        case .portalLevel: self = .portalLevel
        case .mixed: self = .unknown
        }
    }

    /// The kind by which the board of the Home screen orders catalogs (``Flows/ShelfSequence``) —
    /// `nil` for everything that stands there under "Other".
    public var libraryKind: Core.Library.Kind? {
        switch self {
        case .movies: .movies
        case .allSeries: .series
        case .homeVideos: .homeVideos
        default: nil
        }
    }

    /// Which title kinds are meant from a catalog of this genre.
    ///
    /// **Without a kind the server delivers everything inside** — from a series library
    /// therefore single episodes, and they push out the series they belong to. The finding of
    /// 2026-09-05 measured this at "Recently added": 5 of 20 titles were right.
    ///
    /// **Empty means "delivers nothing for the shelf"** and not "delivers everything": Music
    /// does not belong in a 2 : 3 shelf, and a portal level delivers episodes, films, seasons
    /// and folders side by side — any kind filter would be a claim about a foreign list there.
    public var titleKinds: [MediaItem.Kind] {
        switch self {
        case .movies: [.movie]
        case .allSeries: [.series]
        case .homeVideos: [.homeVideo]
        // **A collection is a kind of its own, not a film.** Seen on the screen: With the filter
        // `[.series, .movie]` the shelf "Collections" stayed empty although sixteen lie in it — a
        // BoxSet library contains collections and not their parts. The rule "an empty shelf does
        // not appear" then covered up the wrong filter noiselessly.
        case .isCollection: [.collection]
        case .directory, .unknown: [.series, .movie, .collection]
        default: []
        }
    }
}

extension Genre {

    /// The symbol that stands before the name in the register.
    ///
    /// **A hint and no identifier** — six libraries of the same genre carry the same symbol,
    /// and they are told apart by name. That is exactly why the origin stands once as a
    /// section heading and not as a badge on every row: "JF" six times one below the other says
    /// nothing.
    public var icon: String {
        switch self {
        case .movies: Glyph.film.name
        case .allSeries: Glyph.series.name
        case .homeVideos: Glyph.homeVideo.name
        case .music: Glyph.music.name
        case .isCollection: Glyph.isCollection.name
        case .directory: Glyph.folder.name
        case .live, .sport: Glyph.live.name
        case .portalLevel: Glyph.portal.name
        default: Glyph.folder.name
        }
    }
}
