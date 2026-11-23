import Core
import Diagnose
import Foundation
import Observation

/// What the player shows about the running title — **cast, further episodes, similar**
/// (AP58 G1, A4). On the TV the area that slides out downward, on the phone a sheet.
///
/// **Why it exists.** The board model sat in the TV's `PlayerModel`; the
/// phone had only audio and subtitles in the player. The rules are not trivial and
/// belong in one place: load only once and only on opening, check after every answer
/// whether it still belongs to the running title, and **send every offered title through the filter of
/// the parental controls** (audit 2026-09-25, finding 1).
@Observable
public final class InfoBoard {

    /// The full title for the details line — year, director, runtime appear only there.
    public private(set) var title: MediaItem?
    /// The leading roles — director and writer are in the details line.
    public private(set) var cast: [Person] = []
    /// The further episodes from the current one on, or for a movie the similar titles.
    public private(set) var more: [MediaItem] = []
    /// Whether the title belongs to a series — then the list is called "More Episodes", otherwise
    /// "Similar Movies".
    public private(set) var isSeries = false

    /// Whether cast and episodes have **arrived**.
    ///
    /// Set only after the answer and not before: the query hangs on a `task`
    /// of the view, and it is cancelled as soon as the view closes. Whoever set the flag earlier
    /// blocked an attempt that never had a result — the cast would never come.
    public private(set) var loaded = false
    /// Prevents two simultaneous queries when the board opens and closes quickly.
    @ObservationIgnored private var isLoading = false
    /// Whether the title could not be looked up on the last load — then the next
    /// look asks again, although the board is complete (finding S7): a network error in the tunnel
    /// should not take the cast away for the whole movie.
    @ObservationIgnored private var titleWasMissing = false

    public init() {}

    /// Clears the board — **on a title change**, otherwise the cast of the episode just
    /// left would stand above the new picture.
    public func clear() {
        title = nil
        if !cast.isEmpty { cast = [] }
        if !more.isEmpty { more = [] }
        isSeries = false
        loaded = false
        titleWasMissing = false
    }

    /// Loads the board — **once, and only when someone opens it.**
    ///
    /// **A title that cannot be looked up ends loading anyway** (player audit,
    /// finding S7): the provider catalog throws on `item(id:)` for **every** episode,
    /// and otherwise every network error does. Until then the board returned without ``loaded``,
    /// and both devices showed the spinner without end — the episodes of the known series were
    /// not fetched any more either. Now they come through the series passed in, and what is missing
    /// is stated by the board (``hasNothing``). **A cancellation** (the board closed) leaves ``loaded``
    /// open; after a failure it is complete, but the next look asks for the title
    /// again.
    ///
    /// - Parameters:
    ///   - naechste: the already known next episode — it fills the list if the filter
    ///     lets none of all episodes pass, but the source named an allowed one.
    ///   - darfSpielen: the parental-controls filter, meant **fail-closed**: what it
    ///     does not let pass is not in the board.
    ///   - gilt: whether the title is still running — asked after every answer.
    public func load(
        source: any ContentSource, identifier: String, series: String?, next: MediaItem?,
        mayPlay: (MediaItem) -> Bool, applies: () -> Bool
    ) async {
        guard !loaded || titleWasMissing, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let total: MediaItem?
        do {
            total = try await source.item(id: identifier)
        } catch {
            guard !Self.wasCancelled(error) else { return }
            Diagnose.hint(.playback, "Info board: title not fetched", error)
            total = nil
        }
        guard applies() else { return }
        titleWasMissing = total == nil
        if let total {
            title = total
            cast = total.cast.filter { $0.role.isProminent }
        }

        // **The series from the title itself too** — on the phone the entry point does not
        // always know it, and without it "Similar Movies" would appear under an episode.
        if let series = series ?? total?.seriesID {
            isSeries = true
            let all = (try? await source.episodes(of: series)) ?? []
            guard applies() else { return }
            more = Self.episodes(all, after: identifier, next: next, mayPlay: mayPlay)
        } else if total == nil {
            // **Without a title and without a series, no guessing** — whether it is a movie, nobody
            // knows then, and "Similar Movies" under a provider episode would be an assertion.
            more = []
        } else {
            // Movies have no sibling episodes — there "Similar" fills the
            // list, and it is then honestly called "Similar Movies".
            let similar = (try? await source.similarItems(to: identifier, limit: 12)) ?? []
            guard applies() else { return }
            more = similar.filter(mayPlay)
        }
        loaded = true
    }

    /// Whether the board has loaded and there is still nothing to show — then it says so, instead of
    /// spinning on (finding S7).
    public var hasNothing: Bool { loaded && title == nil && cast.isEmpty && more.isEmpty }

    /// Whether an error only means that nobody is waiting any more — the task of the view is gone.
    static func wasCancelled(_ error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// The episodes **from the current one forward** — those before are watched, and whoever wants to go
    /// back uses the detail page.
    static func episodes(
        _ all: [MediaItem], after identifier: String, next: MediaItem?,
        mayPlay: (MediaItem) -> Bool
    ) -> [MediaItem] {
        let following: [MediaItem]
        if let now = all.firstIndex(where: { $0.id == identifier }) {
            following = Array(all[all.index(after: now)...])
        } else {
            following = all.filter { $0.id != identifier }
        }
        let allowed = following.filter(mayPlay)
        return allowed.isEmpty ? [next].compactMap { $0 } : allowed
    }

    /// The related title for the offer after the end of a movie — **the first one the filter
    /// lets pass**, or none (A8).
    ///
    /// The source names one (collection before similar, ``Core/ContentSource/similarItem(to:)``).
    /// If the filter blocks it, the search runs in the same list that also fills the board;
    /// if nothing allowed is found there, there is no offer.
    public static func allowedRelated(
        zu identifier: String, from source: any ContentSource, mayPlay: (MediaItem) -> Bool
    ) async -> MediaItem? {
        guard let first = try? await source.similarItem(to: identifier) else { return nil }
        if mayPlay(first) { return first }
        let more = (try? await source.similarItems(to: identifier, limit: 12)) ?? []
        return more.first { $0.id != first.id && mayPlay($0) }
    }

    /// The next episode, **if the filter lets it pass.**
    public static func allowedNext(
        after identifier: String, from source: any ContentSource, mayPlay: (MediaItem) -> Bool
    ) async -> MediaItem? {
        guard let episode = try? await source.nextEpisode(after: identifier) else { return nil }
        return mayPlay(episode) ? episode : nil
    }
}
