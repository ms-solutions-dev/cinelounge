import Core
import Flows
import Foundation
import SwiftUI

/// Loads a person's career and matches it against the own library.
///
/// **Both at the same time, not one after the other.** The request to the film database
/// takes its time, collecting the own catalog does too — and neither
/// needs the other. Placed one after the other the wait would be the
/// sum; side by side it is that of the longer one.
final class FilmographyModel: ObservableObject {

    enum State: Equatable {
        case loading
        case ready
        /// Translation key — the view shows it as a sentence.
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var filmography = Filmography()

    /// The short profile of a foreign title while it is open.
    ///
    /// **In the same window and not in a second one** (roadmap P17): a
    /// window above the window above the film is one level too many, and the
    /// way back could no longer be explained. If something is here, the view shows
    /// it **instead of** the list; the Menu button leads back to the list.
    @Published private(set) var profile: TitleProfile?
    /// For which entry loading is currently running — the row shows it, so that
    /// a press does not look swallowed.
    @Published private(set) var loadingProfileID: String?
    /// Whether the last attempt yielded nothing.
    @Published private(set) var profileFailed = false

    let person: Person

    private let source: any FilmographySource
    private let library: @Sendable () async -> LibraryIndex

    init(
        person: Person,
        source: any FilmographySource,
        library: @escaping @Sendable () async -> LibraryIndex
    ) {
        self.person = person
        self.source = source
        self.library = library
    }

    /// Fetches the short profile for a row and shows it.
    ///
    /// **Only on press, never in advance.** A career has forty rows;
    /// forty requests in advance would be, with a provider with a metered counter, the
    /// daily ration for a person you are only browsing.
    ///
    /// **Only the most recently pressed entry writes** (review 2026-09-27, D5): if the
    /// profile of A arrived after the press on B, A's profile stood above B, and A's `defer` removed
    /// B's loading indicator. The same mark as on the phone's career.
    func showProfile(for entry: FilmographyEntry) async {
        profileFailed = false
        loadingProfileID = entry.id
        profileMarker &+= 1
        let tag = profileMarker
        defer { if tag == profileMarker { loadingProfileID = nil } }

        let found = try? await source.profile(for: entry)
        guard tag == profileMarker else { return }
        guard let found else {
            profileFailed = true
            return
        }
        profile = found
    }

    /// The mark of the last profile fetch — see ``showProfile(for:)``.
    private var profileMarker = 0

    /// Back to the list. `true` if there was something to close — that is how
    /// the view recognizes whether the Menu button is already consumed.
    @discardableResult
    func closeProfile() -> Bool {
        profileFailed = false
        profileMarker &+= 1
        loadingProfileID = nil
        guard profile != nil else { return false }
        profile = nil
        return true
    }

    func load() async {
        state = .loading

        // Nebeneinander: siehe oben.
        async let career = try? source.filmography(forPersonNamed: person.name)
        async let index = library()

        guard var found = await career else {
            state = .failed(Self.messageKey(for: person))
            return
        }
        let known = await index

        found.movies = Self.mark(found.movies, against: known)
        found.series = Self.mark(found.series, against: known)

        filmography = found
        // A person to whom the film database leads nothing is not an error
        // of the app — the view says so in a sentence instead of a message.
        state = found.isEmpty ? .failed("filmography.nothing") : .ready
    }

    /// Records on each entry whether and where it is in the library — **since AP58 R6
    /// ``Flows/CatalogIndex/mark(_:against:)``**, the same rule as on the phone.
    static func mark(
        _ entries: [FilmographyEntry], against index: LibraryIndex
    )
        -> [FilmographyEntry]
    {
        CatalogIndex.mark(entries, against: index)
    }

    /// What is said when nothing came back.
    ///
    /// Without a key the cause is a different one than with an unknown
    /// name, and the viewer should not look in their own setup if they merely have not
    /// entered anything.
    private static func messageKey(for person: Person) -> String {
        SecureStore().tmdbAPIKey()?.isEmpty == false
            ? "filmography.nothing" : "error.tmdbNoKey"
    }
}
