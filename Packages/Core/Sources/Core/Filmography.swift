import Foundation

/// A title from a person's career.
///
/// **Deliberately not ``MediaItem``**, although much is named the same. A `MediaItem`
/// is something you can play — it carries playback state, sources and
/// a media server identifier. An entry here is a **piece of information**: the
/// viewer does not own most of these titles at all. Forcing both into one type would
/// mean carrying along on every library title fields that only
/// a film database fills — and conversely claiming on every piece of information a
/// play button that leads nowhere.
public struct FilmographyEntry: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable {
        case movie
        case series
    }

    /// The film database's identifier — here only to tell the rows apart.
    public let id: String
    public let kind: Kind
    public let title: String

    /// The release year, if stored.
    ///
    /// `nil` for announced titles: TMDb lists titles whose date is still open
    /// with an empty date. They are therefore **not** dropped — whoever wants to know
    /// what someone is working on right now finds it nowhere else. Since 2026-09-08
    /// they are sorted to the **end**: they have no poster and usually no
    /// role and are thus the weakest rows of the list (see ``sorted(_:)``).
    public let year: Int?

    /// The character played. For directing or screenwriting, the activity appears here.
    public let role: String?

    /// The film database's rating, from 0 to 10.
    ///
    /// `nil` if too few votes exist. **A zero would be a
    /// claim** — it would stand as a damning verdict where in truth
    /// nobody has voted.
    public let rating: Double?

    /// The poster's address, already assembled.
    public let posterURL: URL?

    /// The identifier in the own library — `nil` if the title is not
    /// there. Carries both at once: the marker in the row and the target when
    /// opening. Two separate fields would drift apart as soon as the matching
    /// becomes more precise later.
    public var libraryItemID: String?

    /// Whether the title is in the own library.
    public var isInLibrary: Bool { libraryItemID != nil }

    /// Whether this entry is an appearance as oneself — talk show,
    /// award ceremony, interview.
    ///
    /// **Not a role, but an appointment.** The film database keeps both in the
    /// same field: "Self", "Himself", "Self - Guest", "Herself (archive
    /// footage)". For a well-known actor, thirty rows of these quickly
    /// appear in the list, and the actual career drowns among
    /// appearances on Wedorn Flevakat (test report 2026-08-08).
    ///
    /// **The beginning is checked, not containment.** "Self" occurs in
    /// character names — "Jiotslion-Cebrehou Bousjinflut", "Herself" as the title of an episode —,
    /// and a rule that searches anywhere in the text throws away roles that
    /// are roles.
    public var isSelfAppearance: Bool {
        guard let role = role?.lowercased() else { return false }
        let words = ["self", "himself", "herself", "themselves", "themself"]
        for word in words {
            guard role.hasPrefix(word) else { continue }
            // Exactly the word, or the word with a suffix after it:
            // "Self - Host", "Self (archive footage)".
            //
            // **The hyphen explicitly does not count as a separator**, and the
            // test found that: "Jiotslion-Cebrehou Bousjinflut" is a role. With
            // "Self - Host" there is a space before it anyway.
            let rest = role.dropFirst(word.count)
            if rest.isEmpty || rest.first == " " || rest.first == "(" {
                return true
            }
        }
        return false
    }

    public init(
        id: String,
        kind: Kind,
        title: String,
        year: Int? = nil,
        role: String? = nil,
        rating: Double? = nil,
        posterURL: URL? = nil,
        libraryItemID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.role = role
        self.rating = rating
        self.posterURL = posterURL
        self.libraryItemID = libraryItemID
    }
}

/// A person's career, split into films and series.
///
/// Split and not as one list with a flag, because the view shows two
/// tabs: an actor with forty films and sixty guest appearances
/// in series would otherwise produce a list in which you cannot find what you are looking for.
public struct Filmography: Sendable, Equatable {

    public var movies: [FilmographyEntry]
    public var series: [FilmographyEntry]

    public var isEmpty: Bool { movies.isEmpty && series.isEmpty }

    public init(movies: [FilmographyEntry] = [], series: [FilmographyEntry] = []) {
        self.movies = movies
        self.series = series
    }

    /// From new to old, announced titles last.
    ///
    /// **A title can occur several times**, and that is no invention: the
    /// film database keeps one entry per role, and whoever played two
    /// characters in a series appears in it twice. The roles are therefore
    /// merged instead of repeating the row — a list in which
    /// the same title stands three times in a row looks like an error.
    public static func sorted(_ entries: [FilmographyEntry]) -> [FilmographyEntry] {
        var merged: [String: FilmographyEntry] = [:]
        var order: [String] = []

        for entry in entries {
            let key = entry.id
            guard var existing = merged[key] else {
                merged[key] = entry
                order.append(key)
                continue
            }
            // Beide Rollen nebeneinander, ohne Doppelung.
            let roles = [existing.role, entry.role]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            let unique = roles.reduce(into: [String]()) { list, role in
                if !list.contains(role) { list.append(role) }
            }
            existing = FilmographyEntry(
                id: existing.id,
                kind: existing.kind,
                title: existing.title,
                year: existing.year,
                role: unique.isEmpty ? nil : unique.joined(separator: ", "),
                rating: existing.rating,
                posterURL: existing.posterURL,
                libraryItemID: existing.libraryItemID
            )
            merged[key] = existing
        }

        let all = order.compactMap { merged[$0] }
        // **Appearances as oneself are dropped — unless nothing
        // would be left.** Whoever sits in talk shows for a living would otherwise have an
        // empty career, and an empty list is worse information than
        // one in which too much appears.
        let played = all.filter { !$0.isSelfAppearance }
        return (played.isEmpty ? all : played).sorted { left, right in
            // **Without a year to the END — since 2026-09-08, and the reversal is a
            // finding from the screen.**
            //
            // This used to say: "Without a year to the top — 'not yet released' is the
            // newest there is." In terms of time that is true and still answers
            // the wrong question. Whoever opens a career asks "what has this person
            // done"; an announced film has no date, **no poster** and
            // usually no role — it is the weakest row of the list.
            //
            // Seen on the phone on 2026-09-08: Piosiaspeit Misplaus opened with "Kaiblaupun praitbrio Glugromeind",
            // "G Drifoubruk Kritrout 2", "Nougunprou" and "Tropal" — five empty boxes without a
            // year, where "Jaubrok frisco Stusmeis", "G Drifoubruk Kritrout" and "Greswotrio" belong. The
            // list showed first what does not exist.
            //
            // **They are not dropped, they stand at the back.** That a film is coming is
            // information — just not information a career starts with.
            switch (left.year, right.year) {
            case (nil, nil): return left.title < right.title
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?): return a == b ? left.title < right.title : a > b
            }
        }
    }
}

/// Where a person's career comes from.
///
/// As a contract and not as a class, for the same reason as with
/// ``ContentSource``: the view should not know which film database
/// answers. Today it is TMDb — the only one of the connected ones that
/// holds people —, and if it one day changes its terms, the
/// switch costs a new implementation instead of a rebuild of the UI.
public protocol FilmographySource: Sendable {

    /// The career for a name.
    ///
    /// **By name and not by an identifier**, because the media server keeps no
    /// film database identifier for an actor. That is the
    /// weaker match, and it can miss on identical names;
    /// the implementation decides such cases by popularity.
    func filmography(forPersonNamed name: String) async throws -> Filmography

    /// The short profile for an entry of the career — see ``TitleProfile``.
    ///
    /// `nil` means: the database holds nothing on it. That is not an error and
    /// therefore is not reported as a throw.
    func profile(for entry: FilmographyEntry) async throws -> TitleProfile?
}

/// A short profile for a title that one does **not** have.
///
/// **Why it exists** (test report 2026-08-08): whoever tapped a foreign title in a person's career
/// got nothing — the button simply did nothing.
/// Two thirds of the rows are such titles; a window in which most
/// rows do not respond trains people not to tap at all anymore.
///
/// **Deliberately little.** Poster, year, genre, plot, a few names from the
/// cast — what answers the question "what is that?". Everything else
/// belongs on a detail page, and there is none for something you do not
/// own.
public struct TitleProfile: Sendable, Equatable {
    public let title: String
    public let year: Int?
    /// The genres, already as a finished line — the view should assemble nothing.
    public let genres: [String]
    /// The plot summary. Empty if the film database has none in the selected
    /// language; the view then shows a sentence instead of a gap.
    public let overview: String
    /// The first names of the cast, in the database's order.
    public let cast: [String]
    public let posterURL: URL?
    public let rating: Double?
    /// The trailer according to the ``TrailerRule`` (AP78) — for titles outside the catalog the
    /// only thing that can be played in the profile. `nil`: no button.
    public let trailer: TrailerChoice?

    public init(
        title: String,
        year: Int? = nil,
        genres: [String] = [],
        overview: String = "",
        cast: [String] = [],
        posterURL: URL? = nil,
        rating: Double? = nil,
        trailer: TrailerChoice? = nil
    ) {
        self.title = title
        self.year = year
        self.genres = genres
        self.overview = overview
        self.cast = cast
        self.posterURL = posterURL
        self.rating = rating
        self.trailer = trailer
    }
}

extension FilmographySource {

    /// Without its own implementation there is no profile — and the view continues to show
    /// only the row. As a default and not a requirement, so that a source that
    /// can only do careers does not have to be rewritten.
    public func profile(for entry: FilmographyEntry) async throws -> TitleProfile? { nil }
}
