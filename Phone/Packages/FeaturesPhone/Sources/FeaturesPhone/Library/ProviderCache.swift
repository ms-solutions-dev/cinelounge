import Core
import Foundation
import PlaylistKit

/// What has already been fetched once from the provider — **for the whole session.**
///
/// **The finding of 2026-09-05, read from our own error log:** When opening the library
/// and when building Home, the same category appeared **three times** in the log —
/// "DE| KINO: 26 titles" at 22:25:21, 22:25:32 and 22:26:01. Each of those lines is a
/// round trip to the provider, and in between the viewer saw "Loading library".
///
/// The question that came with it was justified: why does this always take so long? On
/// tvOS everything is always there immediately. The TV keeps its lists — `JellyfinSource`
/// one snapshot per library, `XtreamVODSource` the full movie list for the lifetime of
/// the source. On the phone nobody kept it: The library remembered its titles in its own
/// model, Home in its own, and neither knew about the other.
///
/// **One store beneath both, not inside one of them.** Whoever puts it in a view will
/// not have it again at the next screen.
///
/// **Only for the session and not on disk.** A provider's title list changes when it
/// rearranges its catalog — and it does so daily. Kept across a launch it would show
/// yesterday's state, and nobody would see that. Exactly the same reasoning as for the
/// library's title lists.
public actor ProviderCache {

    public static let shared = ProviderCache()

    private var categories: [String: [Library]] = [:]
    private var title: [String: [MediaItem]] = [:]

    /// What is being fetched right now — per access and per category **at most one operation.**
    ///
    /// **The second finding of 2026-09-07:** An actor does not hold its lock across an
    /// `await`. Home and library ask simultaneously when they are built; both found the
    /// store empty because the other was still at the provider, and both fetched. The
    /// store prevented the second request only once the first was finished — so never at
    /// the moment it mattered.
    ///
    /// **Attach instead of starting over.** Whoever finds a running operation waits for
    /// its result; a second task would be a second request to an account with one
    /// permitted connection. The entry is cleared on completion, also after a failure —
    /// otherwise an access that failed once would hang the whole session on a dead task.
    private var inFlightCategories: [String: Task<[Library], Never>] = [:]
    /// Siehe ``inFlightCategories``.
    private var inFlightTitles: [String: Task<[MediaItem], Error>] = [:]

    public init() {}

    /// The libraries **of one access** — once per session.
    ///
    /// **Asked per access and remembered per access.** Until 2026-09-07 this used
    /// ``XtreamVODSource/libraries()``, which runs over **all** enabled lists,
    /// while the store put the result under **one** list. With two accesses,
    /// each access therefore queried both: four requests for list 1, then
    /// the same four again for list 2. ``XtreamVODSource/libraries(for:)``
    /// brings question and key back into line.
    ///
    /// **An empty result is not remembered.** `libraries(for:)` does not discard
    /// but returns what it has — for a panel that is currently answering with HTTP 512,
    /// that is nothing. Kept, the access would stand there without categories for the rest
    /// of the session, with never a second attempt.
    func libraries(_ source: ProviderSource, credential: String) async -> [Library] {
        if let remembered = categories[credential] { return remembered }
        if let running = inFlightCategories[credential] { return await running.value }

        let job = Task {
            defer { self.inFlightCategories[credential] = nil }
            let fetched = await source.libraries(for: credential)
            // After a ``clear()``, nothing is stored any more: The answer belongs to the
            // state somebody has just thrown away. The caller still gets it —
            // they asked for it, and it is not wrong, only old.
            guard !Task.isCancelled else { return fetched }
            if !fetched.isEmpty { self.categories[credential] = fetched }
            return fetched
        }
        inFlightCategories[credential] = job
        return await job.value
    }

    /// The titles of a category — once per session.
    ///
    /// An **empty** category is very much remembered here: It is an answer and not a
    /// failure. What goes wrong throws and never reaches the store.
    func title(
        _ source: ProviderSource, category: Library.ID, filter: ItemFilter
    ) async throws -> [MediaItem] {
        if let remembered = title[category] { return remembered }
        if let running = inFlightTitles[category] { return try await running.value }

        let job = Task<[MediaItem], Error> {
            defer { self.inFlightTitles[category] = nil }
            let fetched = try await source.items(in: category, filter: filter)
            guard !Task.isCancelled else { return fetched }
            self.title[category] = fetched
            return fetched
        }
        inFlightTitles[category] = job
        return try await job.value
    }

    /// Throws everything away — for the checks and for a manual "reload".
    ///
    /// **Running operations are cancelled and not awaited.** Cancellation does not stop
    /// the request — it only tells it that its result may no longer be stored. Without
    /// that, a task that returns shortly after the clearing would fill the store again
    /// with exactly the state somebody has just thrown away.
    public func clear() {
        for job in inFlightCategories.values { job.cancel() }
        for job in inFlightTitles.values { job.cancel() }
        inFlightCategories.removeAll()
        inFlightTitles.removeAll()
        categories.removeAll()
        title.removeAll()
    }
}
