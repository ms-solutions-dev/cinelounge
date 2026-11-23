import Core
import Diagnose
import Foundation
import Observation

/// A row of results from one source — **what ``Search`` needs to know about it.**
///
/// The platforms fill it differently (the TV with `MediaItem`, the phone with
/// tiles including footer and portal state); the search needs only three pieces of information.
public protocol SearchGroup: Sendable, Equatable {
    /// Whether the source found anything.
    var hasMatches: Bool { get }
    /// Whether the source answered at all — **separate from "no results".** The
    /// one says something about the search term, the other about the connection.
    var hasAnswered: Bool { get }
    /// Which source was asked — for interpreting the failure when none answers.
    var source: Origin { get }
    /// What the group is called in the log, with its result count.
    var logLine: String { get }
}

/// The search across all catalogs — **one flow for both programs** (AP58 R6, St4).
///
/// **What had drifted apart** (report A): 350 against 300 ms wait time, 60 against 20 results per
/// source, and on the TV an error from the media server aborted the whole search, whereas
/// on the phone only the affected group fell silent. Now **the phone
/// behavior** applies everywhere: each source answers for itself, a silent group stays as
/// information, and only when **none** answers is it a failure.
///
/// **What stays per platform:** the sources (the phone also searches the channels)
/// and what appears before the first input (the TV shows suggestions).
@MainActor
@Observable
public final class Search<Group: SearchGroup> {

    /// One source: search term and upper limit in, one group out. **Does not throw** —
    /// "did not answer" is a result and is stored in the group.
    public typealias Source = @Sendable (String, Int) async -> Group

    public enum Situation: Sendable, Equatable {
        /// Nothing entered — **a screen of its own**, not an empty result.
        case idle
        case isSearching
        case settled
        /// Searched and found nothing.
        case nothingFound
        /// Searched and **nobody** answered — then "nothing found" is wrong.
        case disrupted(PlaybackPhase)
    }

    /// **From two characters** — a single letter matches almost everything and says nothing.
    public static var minimumLength: Int { 2 }

    /// How long to wait after the last keystroke — **350 ms on both devices.**
    ///
    /// The TV had 350, the phone 300. The longer one wins: on the TV one types more slowly
    /// on an on-screen keyboard, and every search fewer is, at the provider
    /// (one allowed connection), one connection fewer. Both are below the half
    /// second from which a delay becomes noticeable.
    public static var waitTime: Duration { .milliseconds(350) }

    /// At most this many results per group — **twenty on both devices.**
    ///
    /// The TV asked for sixty. More is not a result but a second list
    /// to page through — and the group below would sit unreachably far down with the
    /// remote. Whoever has thirty results searched too vaguely.
    public static var perGroup: Int { 20 }

    public private(set) var state: Situation = .idle

    /// The groups in the order of the sources — **without those that answered and found
    /// nothing.** A silent group stays: that a source is silent is part of the
    /// result.
    public private(set) var groups: [Group] = []

    /// What is in the field. **Only a real change searches** — the tvOS search field resets
    /// its text with the same wording on focus changes (on-device finding 2026-08-16), and
    /// a new search then threw the focus back into the field.
    public var word: String = "" {
        didSet { if word != oldValue { triggered() } }
    }

    /// The search currently running — **the handle the checks wait for.**
    public private(set) var running: Task<Void, Never>?

    private let sources: [Source]
    private let debounce: Duration
    private let offline: @MainActor () -> PlaybackPhase?

    /// The error the interpretation receives when nobody answers — the sources do not
    /// throw, after all.
    enum Silence: Error { case all }

    /// - Parameters:
    ///   - quellen: in the order in which their groups appear. **Asked concurrently,
    ///     shown in a fixed order** — otherwise the fastest would be on top.
    ///   - entprellung: in the program ``waitTime``, in the checks zero.
    ///   - ohneNetz: the state this platform shows without a network, or `nil`.
    public init(
        sources: [Source], debounce: Duration = waitTime,
        offline: @escaping @MainActor () -> PlaybackPhase? = { nil }
    ) {
        self.sources = sources
        self.debounce = debounce
        self.offline = offline
    }

    /// Search once more — **after a failure**, when the word is already in the field.
    public func retry() { triggered() }

    /// Clear the field — back to idle, not "no results".
    public func clear() {
        running?.cancel()
        word = ""
        groups = []
        state = .idle
    }

    /// The search term without whitespace.
    public var term: String { word.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func triggered() {
        running?.cancel()
        let term = self.term
        guard term.count >= Self.minimumLength else {
            groups = []
            state = .idle
            return
        }
        running = Task { [weak self, debounce] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            await self?.search(term)
        }
    }

    private func search(_ term: String) async {
        guard !sources.isEmpty else {
            state = .nothingFound
            return
        }
        state = groups.isEmpty ? .isSearching : state

        let found = await withTaskGroup(of: (Int, Group).self) { group in
            for (number, source) in sources.enumerated() {
                group.addTask { (number, await source(term, Self.perGroup)) }
            }
            var collected: [(Int, Group)] = []
            for await entry in group { collected.append(entry) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !Task.isCancelled, term == self.term else { return }

        groups = found.filter { $0.hasMatches || !$0.hasAnswered }
        let muted = found.filter { !$0.hasAnswered }
        // **Silent and nothing found otherwise is a failure** (audit finding B-S1, 2026-09-27).
        // Until then only if *all* were silent: a silent media server next to a provider
        // without results produced "nothing found" — the claim that the title does not exist,
        // although the main catalog had not been asked at all.
        if !found.contains(where: \.hasMatches), let first = muted.first {
            state = .disrupted(
                DisruptionInterpretation.state(
                    forItem: Silence.all, source: first.source, offline: offline()))
            return
        }
        state = groups.contains(where: \.hasMatches) ? .settled : .nothingFound
        Diagnose.step(
            .network,
            "Search for \(term): "
                + groups.map(\.logLine).joined(separator: " · "))
    }
}
